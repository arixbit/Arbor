//! D3：shelve round-trip，专测 `glm_5.2_ark_toC` 类序列化 bug。
//! shelve -> **重开 repo handle（模拟跨进程）** -> shelve_list 非空 -> shelve_pop。
//! 跨进程必须能读回：序列化文件里写的是真实 object id hex，不是占位串。

mod common;

use arbor_engine::{
    DiffSettings, EngineError, FilePick, GitCancelHandle, ShelvePatchSelection,
    ShelveRestoreHunkResolution,
};
use common::TestRepo;

/// 核心：shelve 后重开句柄，列表仍非空且可弹出（跨进程读回）。
#[test]
fn shelve_survives_reopen() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    r.open().shelve("p1".into(), vec!["a.txt".into()]).unwrap();

    // 保存后工作区应回 HEAD（v1）
    assert_eq!(r.read("a.txt"), "v1");

    // 重开 repo handle（模拟跨进程：另一个进程打开同一仓库）
    let repo2 = r.open();
    let list = repo2.shelve_list().unwrap();
    // 修复前：列表文件里 id 写成占位串 glm_5.2_ark_toC，from_hex 解析失败 -> 列表空
    assert_eq!(
        list.len(),
        1,
        "shelve list must survive reopen (serialization bug)"
    );
    assert_eq!(list[0].name, "p1");
    assert_eq!(list[0].paths, vec!["a.txt"]);
    assert!(
        !list[0].id.is_empty(),
        "shelve id must be a real hex object id"
    );

    // 弹出 -> 工作区恢复 v2
    repo2.shelve_pop("p1".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");

    // 弹出后列表清空
    let list2 = repo2.shelve_list().unwrap();
    assert!(list2.is_empty(), "shelve list should be empty after pop");
}

#[test]
fn cancelled_preservation_shelf_pop_keeps_snapshot_for_retry() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base\n", "init");
    r.write("a.txt", "staged\n");
    r.git(&["add", "a.txt"]);
    r.write("a.txt", "unstaged\n");

    let repo = r.open();
    repo.shelve_for_preservation("preserve".into(), vec!["a.txt".into()])
        .expect("create preservation shelf");
    assert_eq!(r.read("a.txt"), "base\n");

    let cancel = GitCancelHandle::new();
    cancel.cancel();
    let error = repo
        .shelve_pop_with_cancel("preserve".into(), cancel)
        .expect_err("cancelled preservation restore must stop before apply");
    assert!(matches!(error, EngineError::Cancelled));
    assert_eq!(r.read("a.txt"), "base\n");
    assert!(repo
        .shelve_list()
        .expect("preservation shelf list")
        .iter()
        .any(|shelf| shelf.name == "preserve"));

    repo.shelve_pop("preserve".into())
        .expect("retry preservation restore");
    let staged_diff = r.git(&["diff", "--cached", "--", "a.txt"]);
    assert!(staged_diff.contains("-base") && staged_diff.contains("+staged"));
    let unstaged_diff = r.git(&["diff", "--", "a.txt"]);
    assert!(unstaged_diff.contains("-staged") && unstaged_diff.contains("+unstaged"));
    assert!(repo
        .shelve_list()
        .expect("shelf list after retry")
        .is_empty());
}

/// unshelve 应用但不删除补丁；随后 drop 删除。
#[test]
fn shelve_unshelve_then_drop() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("p1".into(), vec!["a.txt".into()]).unwrap();
    assert_eq!(r.read("a.txt"), "v1");

    // unshelve：应用回工作区但保留补丁
    repo.shelve_unshelve("p1".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
    let unshelved = repo.shelve_list().unwrap();
    assert_eq!(unshelved.len(), 1, "unshelve keeps a recoverable patch");
    assert!(unshelved[0].is_recycled);

    // drop：仅删除补丁，不动工作区
    repo.shelve_drop("p1".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
    assert!(repo.shelve_list().unwrap().is_empty());
}

#[test]
fn shelve_unshelve_selected_hunk_keeps_unselected_hunk_and_lifecycle() {
    let r = TestRepo::new();
    let base = (1..=20)
        .map(|line| format!("line-{line}\n"))
        .collect::<String>();
    common::commit(&r.path, "multi.txt", &base, "init");

    let mut changed = base.clone();
    changed = changed.replace("line-2\n", "first-change\n");
    changed = changed.replace("line-18\n", "second-change\n");
    r.write("multi.txt", &changed);
    let repo = r.open();
    repo.shelve("partial".into(), vec!["multi.txt".into()])
        .unwrap();

    let patch = repo.shelve_diff("partial".into()).unwrap();
    assert_eq!(
        patch.lines().filter(|line| line.starts_with("@@")).count(),
        2,
        "fixture must contain two hunks"
    );
    repo.shelve_unshelve_selections_with_options(
        "partial".into(),
        vec![ShelvePatchSelection {
            path: "multi.txt".into(),
            hunk_index: Some(0),
        }],
        true,
    )
    .unwrap();

    let applied = r.read("multi.txt");
    assert!(applied.contains("first-change"));
    assert!(applied.contains("line-18\n"));
    let remaining_patch = repo.shelve_diff("partial".into()).unwrap();
    assert!(!remaining_patch.contains("first-change"));
    assert!(remaining_patch.contains("second-change"));

    let deleted = repo.shelve_deleted_list().unwrap();
    assert!(deleted
        .iter()
        .any(|item| item.name.starts_with("partial (deleted)")));
}

#[test]
fn shelve_move_selected_members_between_changelists_and_pop_target() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    common::commit(&r.path, "b.txt", "b1\n", "add b");
    common::commit(&r.path, "c.txt", "c1\n", "add c");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    r.write("c.txt", "c2\n");
    let repo = r.open();

    repo.shelve("first".into(), vec!["a.txt".into(), "b.txt".into()])
        .unwrap();
    repo.shelve("second".into(), vec!["c.txt".into()]).unwrap();
    repo.shelve_move_paths("first".into(), "second".into(), vec!["b.txt".into()])
        .unwrap();

    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves[0].name, "second");
    assert_eq!(shelves[0].paths, vec!["c.txt", "b.txt"]);
    assert_eq!(shelves[1].name, "first");
    assert_eq!(shelves[1].paths, vec!["a.txt"]);

    repo.shelve_pop("second".into()).unwrap();
    assert_eq!(r.read("b.txt"), "b2\n");
    assert_eq!(r.read("c.txt"), "c2\n");
    assert_eq!(r.read("a.txt"), "a1\n");
    repo.shelve_pop("first".into()).unwrap();
    assert_eq!(r.read("a.txt"), "a2\n");
}

#[test]
fn shelve_move_last_member_archives_source_and_keeps_target_recoverable() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    common::commit(&r.path, "b.txt", "b1\n", "add b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let repo = r.open();
    repo.shelve("source".into(), vec!["a.txt".into()]).unwrap();
    repo.shelve("target".into(), vec!["b.txt".into()]).unwrap();

    repo.shelve_move_paths("source".into(), "target".into(), vec!["a.txt".into()])
        .unwrap();
    assert!(repo
        .shelve_list()
        .unwrap()
        .iter()
        .all(|item| item.name != "source"));
    assert_eq!(repo.shelve_deleted_list().unwrap()[0].name, "source");
    assert_eq!(repo.shelve_list().unwrap()[0].paths, vec!["b.txt", "a.txt"]);

    repo.shelve_pop("target".into()).unwrap();
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "b2\n");
}

#[test]
fn shelve_move_preserves_binary_and_rename_members() {
    let r = TestRepo::new();
    r.write("old.txt", "old\n");
    r.write("target.bin", "\0\x04\x05\x06");
    common::commit(&r.path, "old.txt", "old\n", "init");
    common::commit(&r.path, "target.bin", "\0\x04\x05\x06", "add target");

    r.git(&["mv", "old.txt", "new.txt"]);
    r.write("new.txt", "old\n");
    let rename_patch = r.git(&["diff", "HEAD", "--binary", "--find-renames=0%"]) + "\n";
    r.git(&["reset", "--hard", "-q", "HEAD"]);
    r.write("target.bin", "\0\x04\x05\x07");
    let repo = r.open();
    repo.shelve("target".into(), vec!["target.bin".into()])
        .unwrap();
    repo.shelve_import("source".into(), rename_patch).unwrap();

    repo.shelve_move_paths("source".into(), "target".into(), vec!["new.txt".into()])
        .unwrap();

    assert_eq!(
        repo.shelve_list().unwrap()[0].paths,
        vec!["target.bin", "new.txt"]
    );
    repo.shelve_pop("target".into()).unwrap();
    assert!(!r.exists("old.txt"));
    assert_eq!(r.read("new.txt"), "old\n");
    assert_eq!(r.read("target.bin").as_bytes(), b"\0\x04\x05\x07");
}

#[test]
fn shelve_drop_moves_to_recently_deleted_and_restores_after_reopen() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("recoverable".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_drop("recoverable".into()).unwrap();

    assert!(repo.shelve_list().unwrap().is_empty());
    assert_eq!(repo.shelve_deleted_list().unwrap()[0].name, "recoverable");
    assert!(!std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/shelved/recoverable"
        ])
        .current_dir(&r.path)
        .status()
        .unwrap()
        .success());
    assert!(std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/shelved-deleted/recoverable"
        ])
        .current_dir(&r.path)
        .status()
        .unwrap()
        .success());

    let repo2 = r.open();
    repo2.shelve_restore_deleted("recoverable".into()).unwrap();
    assert!(repo2.shelve_deleted_list().unwrap().is_empty());
    assert_eq!(repo2.shelve_list().unwrap()[0].paths, vec!["a.txt"]);
    repo2.shelve_pop("recoverable".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
}

#[test]
fn shelve_recycled_drop_restore_preserves_recycled_state_and_description() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("recycled recovery".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_unshelve("recycled recovery".into()).unwrap();
    assert!(repo.shelve_list().unwrap()[0].is_recycled);

    repo.shelve_drop("recycled recovery".into()).unwrap();
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert!(deleted[0].is_deleted);
    assert!(deleted[0].is_recycled);
    assert_eq!(deleted[0].description, "recycled recovery");

    repo.shelve_restore_deleted("recycled recovery".into())
        .unwrap();
    let restored = repo.shelve_list().unwrap();
    assert_eq!(restored.len(), 1);
    assert!(restored[0].is_recycled);
    assert_eq!(restored[0].description, "recycled recovery");
}

#[test]
fn shelve_unshelve_remove_applied_moves_whole_shelf_to_recently_deleted() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("remove after apply".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_unshelve_with_options("remove after apply".into(), true)
        .unwrap();

    assert_eq!(r.read("a.txt"), "v2");
    assert!(repo.shelve_list().unwrap().is_empty());
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert!(deleted[0].is_deleted);
    assert!(!deleted[0].is_recycled);
    assert_eq!(deleted[0].description, "remove after apply");
}

#[test]
fn deleted_shelf_can_be_unshelved_without_restoring_the_list() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("deleted apply".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_drop("deleted apply".into()).unwrap();
    r.write("a.txt", "v1");

    repo.shelve_unshelve_deleted_with_options("deleted apply".into(), false)
        .unwrap();

    assert_eq!(r.read("a.txt"), "v2");
    assert!(repo.shelve_list().unwrap().is_empty());
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].name, "deleted apply");
    assert!(deleted[0].is_deleted);
}

#[test]
fn deleted_shelf_remove_applied_permanently_consumes_the_list() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("deleted consume".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_drop("deleted consume".into()).unwrap();
    r.write("a.txt", "v1");

    repo.shelve_unshelve_deleted_with_options("deleted consume".into(), true)
        .unwrap();

    assert_eq!(r.read("a.txt"), "v2");
    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
    assert!(!std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/shelved-deleted/deleted-consume"
        ])
        .current_dir(&r.path)
        .status()
        .unwrap()
        .success());
}

#[test]
fn deleted_shelf_can_unshelve_selected_members_and_consume_only_them() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "deleted selected".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();
    repo.shelve_drop("deleted selected".into()).unwrap();

    repo.shelve_unshelve_deleted_paths_with_options(
        "deleted selected".into(),
        vec!["a.txt".into()],
        true,
    )
    .unwrap();

    assert_eq!(r.read("a.txt"), "a2");
    assert_eq!(r.read("b.txt"), "b1");
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].paths, ["b.txt"]);
    assert!(deleted[0].is_deleted);
}

#[test]
fn empty_deleted_shelf_remove_applied_is_consumed_without_a_selected_path() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    let repo = r.open();
    repo.shelve("empty deleted".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_drop("empty deleted".into()).unwrap();

    repo.shelve_unshelve_deleted_with_options("empty deleted".into(), true)
        .unwrap();

    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
}

#[test]
fn shelve_partial_unshelve_remove_applied_creates_deleted_copy() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "partial remove after apply".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    repo.shelve_unshelve_paths_with_options(
        "partial remove after apply".into(),
        vec!["a.txt".into()],
        true,
    )
    .unwrap();
    let active = repo.shelve_list().unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].paths, ["b.txt"]);
    assert!(!active[0].is_recycled);
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].paths, ["a.txt"]);
    assert!(deleted[0].is_deleted);
    assert!(!deleted[0].is_recycled);
    assert_eq!(deleted[0].description, "partial remove after apply");
}

#[test]
fn shelve_pending_delete_converges_after_reopen() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("interrupted delete".into(), vec!["a.txt".into()])
        .unwrap();
    let shelf = repo.shelve_list().unwrap().remove(0);

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
    let metadata = format!(
        "{}\t{}\t{}\t{}\t0\t1\t0\n",
        hex(b"interrupted delete"),
        shelf.id,
        shelf.timestamp,
        hex(b"interrupted delete")
    );
    std::fs::write(r.path.join(".git/arbor-shelves-meta"), metadata).unwrap();

    let repo2 = r.open();
    assert!(repo2.shelve_list().unwrap().is_empty());
    let deleted = repo2.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].name, "interrupted delete");
    assert!(deleted[0].is_deleted);
    assert!(!deleted[0].is_pending_delete);
}

#[test]
fn shelve_metadata_tracks_description_timestamp_and_deleted_state() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("metadata".into(), vec!["a.txt".into()])
        .unwrap();
    let active = repo.shelve_list().unwrap().remove(0);
    assert_eq!(active.description, "metadata");
    assert!(active.timestamp > 0);
    assert!(!active.is_deleted);

    repo.shelve_drop("metadata".into()).unwrap();
    let deleted = repo.shelve_deleted_list().unwrap().remove(0);
    assert!(deleted.is_deleted);
    assert!(deleted.timestamp >= active.timestamp);

    repo.shelve_restore_deleted("metadata".into()).unwrap();
    let restored = repo.shelve_list().unwrap().remove(0);
    assert!(!restored.is_deleted);
    assert!(restored.timestamp >= deleted.timestamp);
}

#[test]
fn shelve_set_description_keeps_stable_identity_for_active_and_deleted_lists() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("stable".into(), vec!["a.txt".into()]).unwrap();
    let before = repo.shelve_list().unwrap().remove(0);
    let patch = repo.shelve_diff("stable".into()).unwrap();
    let ref_target = r.git(&["rev-parse", "refs/shelved/stable"]);

    repo.shelve_set_description("stable".into(), "Display label".into())
        .unwrap();
    let active = repo.shelve_list().unwrap().remove(0);
    assert_eq!(active.name, before.name);
    assert_eq!(active.id, before.id);
    assert_eq!(active.description, "Display label");
    assert_eq!(repo.shelve_diff("stable".into()).unwrap(), patch);
    assert_eq!(r.git(&["rev-parse", "refs/shelved/stable"]), ref_target);

    assert!(repo
        .shelve_set_description("stable".into(), "bad\nlabel".into())
        .is_err());
    assert_eq!(
        repo.shelve_list().unwrap().remove(0).description,
        "Display label"
    );

    repo.shelve_drop("stable".into()).unwrap();
    repo.shelve_set_description("stable".into(), "Deleted label".into())
        .unwrap();
    let deleted = repo.shelve_deleted_list().unwrap().remove(0);
    assert_eq!(deleted.name, "stable");
    assert_eq!(deleted.id, before.id);
    assert_eq!(deleted.description, "Deleted label");
    assert!(repo
        .shelve_deleted_diff("stable".into())
        .unwrap()
        .contains("+v2"));
    assert_eq!(
        r.git(&["rev-parse", "refs/shelved-deleted/stable"]),
        ref_target
    );
}

#[test]
fn shelve_undo_delete_restores_original_timestamp() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("undo timestamp".into(), vec!["a.txt".into()])
        .unwrap();
    let active = repo.shelve_list().unwrap().remove(0);
    repo.shelve_drop("undo timestamp".into()).unwrap();

    repo.shelve_restore_deleted_with_timestamp("undo timestamp".into(), Some(active.timestamp))
        .unwrap();
    let restored = repo.shelve_list().unwrap().remove(0);
    assert_eq!(restored.timestamp, active.timestamp);
}

#[test]
fn recently_deleted_shelves_expire_after_seven_days() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("expired".into(), vec!["a.txt".into()]).unwrap();
    repo.shelve_drop("expired".into()).unwrap();
    let deleted = repo.shelve_deleted_list().unwrap();
    let id = deleted[0].id.clone();

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
    let metadata = format!("{}\t{}\t{}\t{}\n", hex(b"expired"), id, 1, hex(b"expired"));
    std::fs::write(r.path.join(".git/arbor-shelves-meta"), metadata).unwrap();

    assert!(repo.shelve_deleted_list().unwrap().is_empty());
    assert!(!std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/shelved-deleted/expired"
        ])
        .current_dir(&r.path)
        .status()
        .unwrap()
        .success());
}

#[test]
fn malformed_shelf_metadata_falls_back_to_patch_commit() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("fallback".into(), vec!["a.txt".into()])
        .unwrap();

    std::fs::write(
        r.path.join(".git/arbor-shelves-meta"),
        "not-hex\tinvalid\tnot-a-time\tnot-hex\n",
    )
    .unwrap();
    let shelf = repo.shelve_list().unwrap().remove(0);
    assert_eq!(shelf.name, "fallback");
    assert_eq!(shelf.description, "fallback");
    assert!(shelf.timestamp > 0);
}

#[test]
fn shelve_drop_can_be_deleted_permanently() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("permanent".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_drop("permanent".into()).unwrap();
    repo.shelve_delete_deleted("permanent".into()).unwrap();

    assert!(repo.shelve_deleted_list().unwrap().is_empty());
    assert!(!std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/shelved-deleted/permanent"
        ])
        .current_dir(&r.path)
        .status()
        .unwrap()
        .success());
}

#[test]
fn deleted_shelf_can_delete_selected_members_permanently() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init a");
    common::commit(&r.path, "b.txt", "b1", "init b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();

    repo.shelve(
        "deleted member removal".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();
    repo.shelve_drop("deleted member removal".into()).unwrap();

    let invalid = repo
        .shelve_delete_deleted_paths("deleted member removal".into(), vec!["missing.txt".into()]);
    assert!(invalid.is_err());
    assert_eq!(
        repo.shelve_deleted_list().unwrap()[0].paths,
        ["a.txt", "b.txt"]
    );

    repo.shelve_delete_deleted_paths("deleted member removal".into(), vec!["a.txt".into()])
        .unwrap();
    let remaining = repo.shelve_deleted_list().unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].paths, ["b.txt"]);
    assert!(!repo
        .shelve_deleted_diff("deleted member removal".into())
        .unwrap()
        .contains("a.txt"));

    repo.shelve_delete_deleted_paths("deleted member removal".into(), vec!["b.txt".into()])
        .unwrap();
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
}

#[test]
fn deleted_shelf_member_delete_preserves_non_utf8_patch_payload() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init a");
    common::commit(&r.path, "b.txt", "b1", "init b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();

    repo.shelve(
        "nonutf8-payload".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();
    repo.shelve_drop("nonutf8-payload".into()).unwrap();

    let patch_path = r
        .path
        .join(".git/arbor-shelf-patches-deleted/nonutf8-payload.patch");
    assert!(!patch_path.exists());

    let generated = repo.shelve_deleted_diff("nonutf8-payload".into()).unwrap();
    let mut patch = generated.into_bytes();
    let marker = b"+b2";
    let marker_start = patch
        .windows(marker.len())
        .position(|window| window == marker)
        .expect("b.txt payload");
    patch.insert(marker_start + 1, 0xff);
    std::fs::create_dir_all(patch_path.parent().unwrap()).unwrap();
    std::fs::write(&patch_path, &patch).unwrap();

    assert_eq!(
        repo.shelve_deleted_list().unwrap()[0].paths,
        ["a.txt", "b.txt"]
    );
    repo.shelve_delete_deleted_paths("nonutf8-payload".into(), vec!["a.txt".into()])
        .unwrap();
    let remaining = std::fs::read(&patch_path).unwrap();
    assert!(remaining.contains(&0xff));
    assert!(!String::from_utf8_lossy(&remaining).contains("a/a.txt"));
    assert_eq!(repo.shelve_deleted_list().unwrap()[0].paths, ["b.txt"]);

    repo.shelve_delete_deleted_paths("nonutf8-payload".into(), vec!["b.txt".into()])
        .unwrap();
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
}

#[test]
fn dropping_last_shelf_member_enters_recently_deleted() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("last member recoverable".into(), vec!["a.txt".into()])
        .unwrap();

    repo.shelve_drop_paths("last member recoverable".into(), vec!["a.txt".into()])
        .unwrap();

    assert!(repo.shelve_list().unwrap().is_empty());
    assert_eq!(
        repo.shelve_deleted_list().unwrap()[0].name,
        "last member recoverable"
    );
}

#[test]
fn shelve_pop_empty_patch_is_a_noop_and_drops_shelf() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    let repo = r.open();

    repo.shelve("empty".into(), vec!["a.txt".into()]).unwrap();
    assert!(repo.shelve_list().unwrap()[0].paths.is_empty());
    repo.shelve_pop("empty".into()).unwrap();

    assert_eq!(r.read("a.txt"), "v1");
    assert!(repo.shelve_list().unwrap().is_empty());
}

#[test]
fn shelve_unshelve_merges_non_overlapping_local_edits() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "one\nbase\nthree\nfour\nfive\n", "init");
    r.write("a.txt", "shelf-one\nbase\nthree\nfour\nfive\n");
    let repo = r.open();
    repo.shelve("merge".into(), vec!["a.txt".into()]).unwrap();

    r.write("a.txt", "one\nbase\nthree\nfour\nlocal-five\n");
    repo.shelve_unshelve("merge".into()).unwrap();

    assert_eq!(
        r.read("a.txt"),
        "shelf-one\nbase\nthree\nfour\nlocal-five\n"
    );
    assert!(repo.conflict_workspace().unwrap().files.is_empty());
    assert_eq!(repo.shelve_list().unwrap().len(), 1);
}

#[test]
fn shelve_unshelve_selected_member_keeps_other_members_shelved() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");

    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve("selected".into(), vec!["a.txt".into(), "b.txt".into()])
        .unwrap();

    repo.shelve_unshelve_paths("selected".into(), vec!["a.txt".into()])
        .unwrap();
    assert_eq!(r.read("a.txt"), "a2");
    assert_eq!(r.read("b.txt"), "b1");
    let after_first = repo.shelve_list().unwrap();
    assert_eq!(after_first.len(), 2);
    assert!(after_first
        .iter()
        .any(|item| item.name == "selected" && !item.is_recycled && item.paths == ["b.txt"]));
    assert!(after_first
        .iter()
        .any(|item| { item.name != "selected" && item.is_recycled && item.paths == ["a.txt"] }));

    repo.shelve_unshelve_paths("selected".into(), vec!["b.txt".into()])
        .unwrap();
    assert_eq!(r.read("b.txt"), "b2");
    let after_second = repo.shelve_list().unwrap();
    assert!(after_second
        .iter()
        .any(|item| item.name == "selected" && item.is_recycled));
    assert_eq!(after_second.len(), 2);
}

#[test]
fn shelve_recycled_state_survives_reopen_and_keeps_description() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "recoverable unshelve".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();
    repo.shelve_unshelve_paths("recoverable unshelve".into(), vec!["a.txt".into()])
        .unwrap();

    let repo2 = r.open();
    let shelves = repo2.shelve_list().unwrap();
    let recycled = shelves
        .iter()
        .find(|item| item.is_recycled)
        .expect("partial unshelve creates a recycled copy");
    assert_eq!(recycled.description, "recoverable unshelve");
    assert_eq!(recycled.paths, ["a.txt"]);
    assert!(shelves
        .iter()
        .any(|item| !item.is_recycled && item.paths == ["b.txt"]));
}

#[test]
fn shelve_clean_recycled_removes_only_already_unshelved_lists() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();

    repo.shelve("already applied".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_unshelve("already applied".into()).unwrap();
    repo.shelve("still active".into(), vec!["b.txt".into()])
        .unwrap();

    assert!(repo.shelve_clean_recycled(0).unwrap().is_empty());
    let cleaned = repo.shelve_clean_recycled(i64::MAX).unwrap();
    assert_eq!(cleaned, vec!["already applied"]);
    let remaining = repo.shelve_list().unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].name, "still active");
    assert!(!remaining[0].is_recycled);
    assert!(repo.shelve_deleted_list().unwrap().is_empty());

    let reopened = r.open();
    assert_eq!(reopened.shelve_list().unwrap().len(), 1);
    assert_eq!(reopened.shelve_list().unwrap()[0].name, "still active");
}

#[test]
fn shelve_partial_unshelve_conflict_completion_recycles_only_selected_members() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "partial conflict recovery".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    r.write("a.txt", "local");
    let error = repo
        .shelve_unshelve_paths("partial conflict recovery".into(), vec!["a.txt".into()])
        .unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    repo.accept_conflict("a.txt".into(), FilePick::Ours)
        .unwrap();
    repo.shelve_complete_restore("partial conflict recovery".into())
        .unwrap();

    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 2);
    assert!(shelves.iter().any(|item| {
        item.name == "partial conflict recovery" && !item.is_recycled && item.paths == ["b.txt"]
    }));
    assert!(shelves.iter().any(|item| {
        item.name != "partial conflict recovery" && item.is_recycled && item.paths == ["a.txt"]
    }));
    assert_eq!(r.read("a.txt"), "local");
}

#[test]
fn shelve_partial_unshelve_remove_strategy_survives_conflict_completion() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "partial conflict delete".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    r.write("a.txt", "local");
    let error = repo
        .shelve_unshelve_paths_with_options(
            "partial conflict delete".into(),
            vec!["a.txt".into()],
            true,
        )
        .unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    repo.accept_conflict("a.txt".into(), FilePick::Ours)
        .unwrap();
    repo.shelve_complete_restore("partial conflict delete".into())
        .unwrap();

    let active = repo.shelve_list().unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].paths, ["b.txt"]);
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].paths, ["a.txt"]);
    assert!(deleted[0].is_deleted);
    assert!(!deleted[0].is_recycled);
}

#[test]
fn shelve_remove_strategy_survives_reopen_before_conflict_completion() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "reopen conflict delete".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    r.write("a.txt", "local");
    let error = repo
        .shelve_unshelve_paths_with_options(
            "reopen conflict delete".into(),
            vec!["a.txt".into()],
            true,
        )
        .unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    repo.shelve_set_restore_target("reopen conflict delete".into(), "Feature".into())
        .unwrap();

    let repo2 = r.open();
    let restore_info = repo2.shelve_restore_info().unwrap().unwrap();
    assert!(restore_info.remove_applied);
    assert_eq!(restore_info.target_change_list.as_deref(), Some("Feature"));
    repo2
        .accept_conflict("a.txt".into(), FilePick::Ours)
        .unwrap();
    repo2
        .shelve_complete_restore("reopen conflict delete".into())
        .unwrap();

    let active = repo2.shelve_list().unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].paths, ["b.txt"]);
    let deleted = repo2.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].paths, ["a.txt"]);
    assert!(deleted[0].is_deleted);
    assert!(!deleted[0].is_recycled);
}

#[test]
fn shelve_unshelve_selected_rename_moves_both_endpoints() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "content", "init");

    r.git(&["mv", "old.txt", "new.txt"]);
    let repo = r.open();
    repo.shelve("rename".into(), vec!["old.txt".into(), "new.txt".into()])
        .unwrap();
    let applied_paths = repo
        .shelve_unshelve_paths_with_options("rename".into(), vec!["new.txt".into()], false)
        .unwrap();
    assert_eq!(applied_paths, vec!["new.txt", "old.txt"]);

    assert!(!r.exists("old.txt"));
    assert_eq!(r.read("new.txt"), "content");
}

#[test]
fn shelve_unshelve_selected_does_not_overwrite_local_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    r.write("a.txt", "a2");
    let repo = r.open();
    repo.shelve("conflict".into(), vec!["a.txt".into()])
        .unwrap();

    r.write("a.txt", "local");
    let error = repo
        .shelve_unshelve_paths("conflict".into(), vec!["a.txt".into()])
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::ShelveApplyConflict { ref name, ref paths }
            if name == "conflict" && paths == &["a.txt".to_string()]
    ));
    assert!(r.read("a.txt").contains("<<<<<<<"));
    let workspace = repo.conflict_workspace().unwrap();
    assert_eq!(workspace.files.len(), 1);
    assert_eq!(workspace.files[0].path, "a.txt");
    assert_eq!(repo.shelve_list().unwrap().len(), 1);

    // The normal conflict resolver can choose the pre-existing local side;
    // resolving the file does not consume the shelf.
    repo.accept_conflict("a.txt".into(), FilePick::Ours)
        .unwrap();
    assert_eq!(r.read("a.txt"), "local");
    assert!(repo.conflict_workspace().unwrap().files.is_empty());
    repo.shelve_complete_restore("conflict".into()).unwrap();
    assert_eq!(repo.shelve_list().unwrap().len(), 1);
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn shelve_conflict_abort_restores_worktree_and_index_after_reopen() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base", "init");

    r.write("a.txt", "shelf");
    let repo = r.open();
    repo.shelve("rollback".into(), vec!["a.txt".into()])
        .unwrap();

    // The local version is staged before the shelf is applied. Rollback must
    // restore both the bytes and the staged/unstaged dimension.
    r.write("a.txt", "local");
    repo.stage("a.txt".into()).unwrap();
    let error = repo
        .shelve_unshelve("rollback".into())
        .expect_err("the shelf and local edit overlap");
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    let info = repo.shelve_restore_info().unwrap().unwrap();
    assert_eq!(info.name, "rollback");
    assert!(!info.is_pop);
    assert_eq!(info.paths, vec!["a.txt"]);

    // A new handle simulates an app restart while the resolver is open.
    let repo2 = r.open();
    assert!(repo2.shelve_restore_info().unwrap().is_some());
    repo2.shelve_abort_restore("rollback".into()).unwrap();

    assert_eq!(r.read("a.txt"), "local");
    assert!(r.git(&["diff", "--", "a.txt"]).is_empty());
    assert!(r
        .git(&["diff", "--cached", "--", "a.txt"])
        .contains("local"));
    assert!(repo2.conflict_workspace().unwrap().files.is_empty());
    assert_eq!(repo2.shelve_list().unwrap().len(), 1);
    assert!(repo2.shelve_restore_info().unwrap().is_none());
}

#[test]
fn shelve_pop_conflict_complete_drops_shelf_only_after_resolution() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base", "init");

    r.write("a.txt", "shelf");
    let repo = r.open();
    repo.shelve("pop-conflict".into(), vec!["a.txt".into()])
        .unwrap();
    r.write("a.txt", "local");

    let error = repo.shelve_pop("pop-conflict".into()).unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    assert_eq!(repo.shelve_list().unwrap().len(), 1);
    repo.accept_conflict("a.txt".into(), FilePick::Theirs)
        .unwrap();
    repo.shelve_complete_restore("pop-conflict".into()).unwrap();

    assert_eq!(r.read("a.txt"), "shelf");
    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn preservation_shelf_conflict_completion_restores_original_index_boundary() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base", "init");

    r.write("a.txt", "staged");
    r.git(&["add", "a.txt"]);
    r.write("a.txt", "unstaged");
    let repo = r.open();
    repo.shelve_for_preservation("temporary-pop".into(), vec!["a.txt".into()])
        .unwrap();

    r.write("a.txt", "other");
    let error = repo.shelve_pop("temporary-pop".into()).unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    repo.accept_conflict("a.txt".into(), FilePick::Theirs)
        .unwrap();
    repo.shelve_complete_restore("temporary-pop".into())
        .unwrap();

    let staged_diff = r.git(&["diff", "--cached", "--", "a.txt"]);
    assert!(staged_diff.contains("-base") && staged_diff.contains("+staged"));
    let unstaged_diff = r.git(&["diff", "--", "a.txt"]);
    assert!(unstaged_diff.contains("-staged") && unstaged_diff.contains("+unstaged"));
    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn shelve_drop_selected_member_keeps_other_members() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");

    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve("partial drop".into(), vec!["a.txt".into(), "b.txt".into()])
        .unwrap();

    repo.shelve_drop_paths("partial drop".into(), vec!["a.txt".into()])
        .unwrap();
    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 1);
    assert_eq!(shelves[0].paths, vec!["b.txt"]);
    assert_eq!(r.read("a.txt"), "a1");
    assert_eq!(r.read("b.txt"), "b1");

    repo.shelve_unshelve("partial drop".into()).unwrap();
    assert_eq!(r.read("a.txt"), "a1");
    assert_eq!(r.read("b.txt"), "b2");
}

#[test]
fn shelve_drop_partial_members_creates_restorable_deleted_changelist() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    common::commit(&r.path, "b.txt", "b1", "add b");
    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve(
        "partial recovery".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    repo.shelve_drop_paths("partial recovery".into(), vec!["a.txt".into()])
        .unwrap();
    let active = repo.shelve_list().unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].paths, vec!["b.txt"]);
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].paths, vec!["a.txt"]);
    assert_eq!(deleted[0].description, "partial recovery");

    let deleted_name = deleted[0].name.clone();
    repo.shelve_restore_deleted(deleted_name.clone()).unwrap();
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
    assert_eq!(
        repo.shelve_list().unwrap()[0].description,
        "partial recovery"
    );
    repo.shelve_pop(deleted_name).unwrap();
    repo.shelve_pop("partial recovery".into()).unwrap();
    assert_eq!(r.read("a.txt"), "a2");
    assert_eq!(r.read("b.txt"), "b2");
}

#[test]
fn shelve_drop_selected_last_member_removes_shelf() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init");
    r.write("a.txt", "a2");
    let repo = r.open();
    repo.shelve("last member".into(), vec!["a.txt".into()])
        .unwrap();

    repo.shelve_drop_paths("last member".into(), vec!["a.txt".into()])
        .unwrap();
    assert!(repo.shelve_list().unwrap().is_empty());
    assert_eq!(r.read("a.txt"), "a1");
    let ref_lookup = std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/shelved/last-member",
        ])
        .current_dir(&r.path)
        .status()
        .unwrap();
    assert!(!ref_lookup.success(), "last shelf ref must be removed");
}

#[test]
fn shelve_drop_selected_rename_removes_both_endpoints() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "content", "init");
    r.git(&["mv", "old.txt", "new.txt"]);
    let repo = r.open();
    repo.shelve(
        "rename drop".into(),
        vec!["old.txt".into(), "new.txt".into()],
    )
    .unwrap();

    repo.shelve_drop_paths("rename drop".into(), vec!["new.txt".into()])
        .unwrap();
    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(r.exists("old.txt"));
    assert!(!r.exists("new.txt"));
}

#[test]
fn shelve_rename_preserves_patch_and_moves_ref() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("before rename".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_rename("before rename".into(), "after rename".into())
        .unwrap();

    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 1);
    assert_eq!(shelves[0].name, "after rename");
    assert!(repo
        .shelve_diff("after rename".into())
        .unwrap()
        .contains("+v2"));
    assert!(repo.shelve_diff("before rename".into()).is_err());

    repo.shelve_pop("after rename".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
}

#[test]
fn shelve_rejects_sanitized_ref_collisions_before_mutation() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("one two".into(), vec!["a.txt".into()]).unwrap();
    r.write("a.txt", "v3");
    let error = repo
        .shelve("one-two".into(), vec!["a.txt".into()])
        .unwrap_err();
    assert!(error
        .to_string()
        .contains("conflicts with an existing shelf ref"));
    assert_eq!(r.read("a.txt"), "v3");
    assert_eq!(repo.shelve_list().unwrap().len(), 1);
}

#[test]
fn shelve_rejects_line_break_names() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");

    let error = r
        .open()
        .shelve("bad\tname".into(), vec!["a.txt".into()])
        .unwrap_err();
    assert!(error.to_string().contains("tabs or line breaks"));
    assert_eq!(r.read("a.txt"), "v2");
}

#[test]
fn shelve_rejects_paths_outside_the_worktree() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");

    let error = r
        .open()
        .shelve("unsafe-path".into(), vec!["../outside.txt".into()])
        .unwrap_err();
    assert!(error.to_string().contains("escapes repository"));
    assert_eq!(r.read("a.txt"), "v2");
}

/// shelf 预览返回父提交到补丁提交之间的完整 patch，并且不改变工作区或 shelf 列表。
#[test]
fn shelve_diff_returns_patch_without_mutation() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("preview".into(), vec!["a.txt".into()]).unwrap();

    let patch = repo.shelve_diff("preview".into()).unwrap();
    assert!(patch.contains("diff --git a/a.txt b/a.txt"));
    assert!(patch.contains("-v1"));
    assert!(patch.contains("+v2"));
    assert_eq!(r.read("a.txt"), "v1");
    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 1);

    // The Swift preview uses the shelf commit as a normal commit diff source
    // for structured side-by-side rendering.
    let structured = repo
        .commit_file_diff(shelves[0].id.clone(), Some(0), "a.txt".into(), false)
        .unwrap();
    assert!(!structured.binary);
    assert!(!structured.hunks.is_empty());

    let shelf_against_base = repo
        .shelve_file_diff("preview".into(), "a.txt".into(), false, false)
        .unwrap();
    assert!(!shelf_against_base.binary);
    assert!(!shelf_against_base.hunks.is_empty());

    // Diff Shelved Changes with Local must use the current worktree as the
    // left side, not the HEAD captured when the shelf was created.
    r.write("a.txt", "v3");
    let shelf_against_local = repo
        .shelve_file_diff("preview".into(), "a.txt".into(), true, false)
        .unwrap();
    let old_text: Vec<_> = shelf_against_local.hunks[0]
        .old_lines
        .iter()
        .map(|line| line.text.as_str())
        .collect();
    let new_text: Vec<_> = shelf_against_local.hunks[0]
        .new_lines
        .iter()
        .map(|line| line.text.as_str())
        .collect();
    assert!(old_text.contains(&"v3"));
    assert!(new_text.contains(&"v2"));
}

/// Revision-backed Shelf 的结构化 Diff 也必须遵守显式 textconv 设置；
/// with-local 方向反转后，工作区仍在左侧、Shelved version 仍在右侧。
#[test]
fn shelve_file_diff_with_settings_uses_textconv_for_both_sources() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=upper\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attributes",
    );
    r.git(&["config", "diff.upper.textconv", "awk '{print toupper($0)}'"]);
    common::commit(&r.path, "a.txt", "v1\n", "init");

    r.write("a.txt", "v2\n");
    let repo = r.open();
    repo.shelve("textconv-preview".into(), vec!["a.txt".into()])
        .unwrap();

    let settings = DiffSettings {
        use_external_textconv: true,
        ..Default::default()
    };
    let against_base = repo
        .shelve_file_diff_with_settings("textconv-preview".into(), "a.txt".into(), false, settings)
        .expect("shelf against base textconv diff");
    assert!(against_base.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "V1")
            && hunk.new_lines.iter().any(|line| line.text == "V2")
    }));

    r.write("a.txt", "v3\n");
    let against_local = repo
        .shelve_file_diff_with_settings("textconv-preview".into(), "a.txt".into(), true, settings)
        .expect("shelf against local textconv diff");
    assert!(against_local.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "V3")
            && hunk.new_lines.iter().any(|line| line.text == "V2")
    }));
}

#[test]
fn recently_deleted_shelf_file_diff_supports_structured_and_local_views() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=upper\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attributes",
    );
    r.git(&["config", "diff.upper.textconv", "awk '{print toupper($0)}'"]);
    common::commit(&r.path, "a.txt", "v1\n", "init");

    r.write("a.txt", "v2\n");
    let repo = r.open();
    repo.shelve("deleted-preview".into(), vec!["a.txt".into()])
        .unwrap();
    repo.shelve_drop("deleted-preview".into()).unwrap();

    let settings = DiffSettings {
        use_external_textconv: true,
        ..Default::default()
    };
    let against_base = repo
        .shelve_deleted_file_diff_with_settings(
            "deleted-preview".into(),
            "a.txt".into(),
            false,
            settings,
        )
        .expect("deleted shelf against base diff");
    assert!(against_base.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "V1")
            && hunk.new_lines.iter().any(|line| line.text == "V2")
    }));

    r.write("a.txt", "v3\n");
    let against_local = repo
        .shelve_deleted_file_diff_with_settings(
            "deleted-preview".into(),
            "a.txt".into(),
            true,
            settings,
        )
        .expect("deleted shelf against local diff");
    assert!(against_local.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "V3")
            && hunk.new_lines.iter().any(|line| line.text == "V2")
    }));
}

/// 预览必须遵守 Arbor 的安全边界：不执行 attributes 中配置的 external
/// diff command 或 textconv，只返回 Git 自身生成的 patch。
#[test]
fn shelve_diff_does_not_execute_external_diff_configuration() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    common::commit(
        &r.path,
        ".gitattributes",
        "*.txt diff=unsafe\n",
        "attributes",
    );

    let marker = r.path.join("external-diff-was-run");
    let command = format!("touch '{}'", marker.display());
    r.git(&["config", "diff.unsafe.command", &command]);
    r.git(&["config", "diff.unsafe.textconv", &command]);
    r.write("a.txt", "v2");

    let repo = r.open();
    repo.shelve("safe-preview".into(), vec!["a.txt".into()])
        .unwrap();
    let patch = repo.shelve_diff("safe-preview".into()).unwrap();

    assert!(patch.contains("-v1"));
    assert!(patch.contains("+v2"));
    assert!(
        !marker.exists(),
        "shelf preview executed external Git config"
    );
}

/// `--binary` 选项必须保留二进制 shelf 的可应用 patch 元数据，而不是把它
/// 当成空的文本 diff 返回。
#[test]
fn shelve_diff_preserves_binary_patch_metadata() {
    let r = TestRepo::new();
    common::commit(&r.path, "image.bin", "\0\x01\x02\x03", "init");

    r.write("image.bin", "\0\x01\x02\x04");
    let repo = r.open();
    repo.shelve("binary-preview".into(), vec!["image.bin".into()])
        .unwrap();

    let patch = repo.shelve_diff("binary-preview".into()).unwrap();
    assert!(patch.contains("GIT binary patch"));

    let structured = repo
        .shelve_file_diff("binary-preview".into(), "image.bin".into(), false, false)
        .unwrap();
    assert!(structured.binary);
    assert!(structured.hunks.is_empty());
}

#[test]
fn shelve_import_exports_a_patch_without_touching_worktree_or_index() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("source".into(), vec!["a.txt".into()]).unwrap();
    let patch = repo.shelve_diff("source".into()).unwrap();

    repo.shelve_import("imported".into(), patch).unwrap();

    assert_eq!(r.read("a.txt"), "v1");
    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 2);
    assert_eq!(shelves[0].name, "imported");
    assert_eq!(shelves[0].paths, vec!["a.txt"]);
    assert!(r.git(&["diff", "--"]).is_empty());
    assert!(r.git(&["diff", "--cached", "--"]).is_empty());

    let structured_error = repo
        .shelve_file_diff("imported".into(), "a.txt".into(), true, false)
        .unwrap_err();
    assert!(structured_error
        .to_string()
        .contains("no structured revision tree"));

    repo.shelve_pop("imported".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
    assert!(r.git(&["diff", "--"]).contains("+v2"));
    assert!(r.git(&["diff", "--cached", "--"]).is_empty());
}

#[test]
fn imported_patch_preview_differs_against_current_local_content() {
    let r = TestRepo::new();
    common::commit(&r.path, "subdir/a.txt", "one\nold\nthree\n", "init");
    r.write(
        "subdir/a.txt",
        "local-prefix\none\nold\nthree\nlocal-suffix\n",
    );
    let repo = r.open();
    let patch = concat!(
        "--- a/a.txt\n",
        "+++ b/a.txt\n",
        "@@ -1,3 +1,3 @@\n",
        " one\n",
        "-old\n",
        "+new\n",
        " three\n",
    );

    let preview = repo
        .imported_patch_file_diff(patch.into(), "a.txt".into(), "subdir".into(), 1, false)
        .unwrap();
    let old_text = preview.hunks[0]
        .old_lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>();
    let new_text = preview.hunks[0]
        .new_lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>();
    assert!(old_text.contains(&"local-prefix"));
    assert!(old_text.contains(&"old"));
    assert!(new_text.contains(&"local-suffix"));
    assert!(new_text.contains(&"new"));
    assert_eq!(
        r.read("subdir/a.txt"),
        "local-prefix\none\nold\nthree\nlocal-suffix\n"
    );
}

#[test]
fn imported_shelf_can_apply_selected_paths_with_a_mapped_base_directory() {
    let r = TestRepo::new();
    common::commit(&r.path, "subdir/a.txt", "v1", "init");

    r.write("subdir/a.txt", "v2");
    let repo = r.open();
    repo.shelve("source".into(), vec!["subdir/a.txt".into()])
        .unwrap();
    let patch = repo
        .shelve_diff("source".into())
        .unwrap()
        .replace("subdir/a.txt", "a.txt");
    repo.shelve_import("mapped".into(), patch).unwrap();
    assert!(repo.shelve_is_imported("mapped".into()).unwrap());

    repo.shelve_unshelve_paths_with_options_and_base(
        "mapped".into(),
        vec!["a.txt".into()],
        false,
        "subdir".into(),
        1,
    )
    .unwrap();

    assert_eq!(r.read("subdir/a.txt"), "v2");
    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves[0].paths, vec!["a.txt"]);
    assert!(shelves[0].is_recycled);
}

#[test]
fn revision_shelf_rejects_a_mapped_base_directory() {
    let r = TestRepo::new();
    common::commit(&r.path, "subdir/a.txt", "v1", "init");
    r.write("subdir/a.txt", "v2");
    let repo = r.open();
    repo.shelve("native".into(), vec!["subdir/a.txt".into()])
        .unwrap();

    let error = repo
        .shelve_unshelve_paths_with_options_and_base(
            "native".into(),
            vec!["subdir/a.txt".into()],
            false,
            "subdir".into(),
            1,
        )
        .unwrap_err();
    assert!(error
        .to_string()
        .contains("only available for imported patches"));
    assert_eq!(r.read("subdir/a.txt"), "v1");
}

#[test]
fn imported_shelf_can_apply_selected_paths_with_a_path_strip() {
    let r = TestRepo::new();
    common::commit(&r.path, "src/a.txt", "v1", "init");

    r.write("src/a.txt", "v2");
    let repo = r.open();
    repo.shelve("source".into(), vec!["src/a.txt".into()])
        .unwrap();
    let patch = repo
        .shelve_diff("source".into())
        .unwrap()
        .replace("src/a.txt", "project/src/a.txt");
    repo.shelve_import("stripped".into(), patch).unwrap();

    repo.shelve_unshelve_paths_with_options_and_base(
        "stripped".into(),
        vec!["project/src/a.txt".into()],
        false,
        String::new(),
        2,
    )
    .unwrap();

    assert_eq!(r.read("src/a.txt"), "v2");
}

#[test]
fn imported_shelf_can_apply_a_zero_path_strip_with_raw_endpoints() {
    let r = TestRepo::new();
    common::commit(&r.path, "a/a/a.txt", "old\n", "init");

    let repo = r.open();
    repo.shelve_import(
        "raw-prefix".into(),
        "diff --git a/a/a.txt b/b/b.txt\n--- a/a/a.txt\n+++ b/b/b.txt\n@@ -1 +1 @@\n-old\n+new\n"
            .into(),
    )
    .unwrap();

    repo.shelve_unshelve_paths_with_options_and_base(
        "raw-prefix".into(),
        vec!["a/a.txt".into(), "b/b.txt".into()],
        false,
        String::new(),
        0,
    )
    .unwrap();

    assert!(!r.exists("a/a/a.txt"));
    assert_eq!(r.read("b/b/b.txt"), "new\n");
}

#[test]
fn imported_shelf_is_persisted_independently_of_the_current_head() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2");
    let repo = r.open();
    repo.shelve("source".into(), vec!["a.txt".into()]).unwrap();
    let patch = repo.shelve_diff("source".into()).unwrap();

    // Move HEAD after the patch was produced. Import must not try to
    // materialize the patch against this newer tree.
    common::commit(&r.path, "b.txt", "head-only", "advance head");
    let repo2 = r.open();
    repo2.shelve_import("delayed".into(), patch).unwrap();
    assert_eq!(r.read("a.txt"), "v1");
    assert_eq!(r.read("b.txt"), "head-only");
    assert!(r.git(&["diff", "--"]).is_empty());
    assert_eq!(repo2.shelve_list().unwrap()[0].paths, vec!["a.txt"]);

    repo2.shelve_pop("delayed".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
    assert_eq!(r.read("b.txt"), "head-only");
    assert!(r.git(&["diff", "--cached", "--"]).is_empty());
}

#[test]
fn imported_shelf_conflict_is_delayed_until_unshelve_and_can_abort() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base", "init");

    r.write("a.txt", "shelf\n");
    let repo = r.open();
    repo.shelve("source".into(), vec!["a.txt".into()]).unwrap();
    let patch = repo.shelve_diff("source".into()).unwrap();

    common::commit(&r.path, "a.txt", "head\n", "advance head differently");
    let repo2 = r.open();
    repo2
        .shelve_import("delayed-conflict".into(), patch)
        .unwrap();
    assert_eq!(r.read("a.txt"), "head\n");

    let error = repo2.shelve_pop("delayed-conflict".into()).unwrap_err();
    assert!(matches!(
        error,
        EngineError::ShelveApplyConflict { ref name, ref paths }
            if name == "delayed-conflict" && paths == &["a.txt".to_string()]
    ));
    assert!(repo2.shelve_restore_info().unwrap().is_some());
    assert!(r.read("a.txt").contains("<<<<<<<"));

    repo2
        .shelve_abort_restore("delayed-conflict".into())
        .unwrap();
    assert_eq!(r.read("a.txt"), "head\n");
    assert!(repo2.shelve_restore_info().unwrap().is_none());
    assert_eq!(repo2.shelve_list().unwrap().len(), 2);
}

#[test]
fn imported_shelf_skips_already_applied_hunks_and_applies_the_rest() {
    let r = TestRepo::new();
    let base = (1..=20)
        .map(|line| format!("line-{line}\n"))
        .collect::<String>();
    common::commit(&r.path, "multi.txt", &base, "init");

    let patch = concat!(
        "diff --git a/multi.txt b/multi.txt\n",
        "index 1111111..2222222 100644\n",
        "--- a/multi.txt\n",
        "+++ b/multi.txt\n",
        "@@ -1,3 +1,3 @@\n",
        " line-1\n",
        "-line-2\n",
        "+first-change\n",
        " line-3\n",
        "@@ -17,3 +17,3 @@\n",
        " line-17\n",
        "-line-18\n",
        "+second-change\n",
        " line-19\n",
    );
    let repo = r.open();
    repo.shelve_import("partial-import".into(), patch.into())
        .unwrap();

    let mut local = base.replace("line-2\n", "first-change\n");
    r.write("multi.txt", &local);
    let result = repo
        .shelve_pop_differentiated("partial-import".into())
        .unwrap();

    local = r.read("multi.txt");
    assert!(local.contains("first-change\n"));
    assert!(local.contains("second-change\n"));
    assert_eq!(
        result.overall_status,
        arbor_engine::PatchApplyStatus::Partial
    );
    assert_eq!(
        result.member_statuses,
        [arbor_engine::PatchApplyMemberResult {
            path: "multi.txt".into(),
            status: arbor_engine::PatchApplyStatus::Partial,
        }]
    );
    assert!(repo.shelve_list().unwrap().is_empty());
}

#[test]
fn imported_shelf_that_is_fully_applied_is_a_successful_noop() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1\n", "init");
    let repo = r.open();
    repo.shelve_import(
        "already-applied".into(),
        concat!(
            "diff --git a/a.txt b/a.txt\n",
            "index 1111111..2222222 100644\n",
            "--- a/a.txt\n",
            "+++ b/a.txt\n",
            "@@ -1 +1 @@\n",
            "-v1\n",
            "+v2\n",
        )
        .into(),
    )
    .unwrap();

    r.write("a.txt", "v2\n");
    let result = repo
        .shelve_pop_differentiated("already-applied".into())
        .unwrap();

    assert_eq!(r.read("a.txt"), "v2\n");
    assert_eq!(
        result.overall_status,
        arbor_engine::PatchApplyStatus::AlreadyApplied
    );
    assert_eq!(
        result.member_statuses,
        [arbor_engine::PatchApplyMemberResult {
            path: "a.txt".into(),
            status: arbor_engine::PatchApplyStatus::AlreadyApplied,
        }]
    );
    assert!(repo.shelve_list().unwrap().is_empty());
}

#[test]
fn imported_shelf_patch_follows_rename_recently_deleted_and_member_drop() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1", "init a");
    common::commit(&r.path, "b.txt", "b1", "init b");

    r.write("a.txt", "a2");
    r.write("b.txt", "b2");
    let repo = r.open();
    repo.shelve("source".into(), vec!["a.txt".into(), "b.txt".into()])
        .unwrap();
    let patch = repo.shelve_diff("source".into()).unwrap();
    repo.shelve_import("imported".into(), patch).unwrap();

    repo.shelve_rename("imported".into(), "renamed".into())
        .unwrap();
    assert!(repo.shelve_diff("renamed".into()).unwrap().contains("+a2"));
    repo.shelve_drop_paths("renamed".into(), vec!["a.txt".into()])
        .unwrap();
    assert_eq!(repo.shelve_list().unwrap()[0].paths, vec!["b.txt"]);

    repo.shelve_drop("renamed".into()).unwrap();
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted[0].paths, vec!["b.txt"]);
    assert!(deleted.iter().any(|item| item.paths == vec!["a.txt"]));
    repo.shelve_restore_deleted("renamed".into()).unwrap();
    repo.shelve_pop("renamed".into()).unwrap();
    assert_eq!(r.read("a.txt"), "a1");
    assert_eq!(r.read("b.txt"), "b2");
}

#[test]
fn imported_shelf_parses_quoted_paths_and_context_only_patches() {
    let r = TestRepo::new();
    common::commit(&r.path, "space name.txt", "v1\n", "init");

    r.write("space name.txt", "v2\n");
    let repo = r.open();
    repo.shelve("source".into(), vec!["space name.txt".into()])
        .unwrap();
    let patch = repo.shelve_diff("source".into()).unwrap();
    let context_only = patch
        .lines()
        .filter(|line| !line.starts_with("index "))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";

    repo.shelve_import("quoted-context".into(), context_only)
        .unwrap();
    assert_eq!(repo.shelve_list().unwrap()[0].paths, vec!["space name.txt"]);
    repo.shelve_pop("quoted-context".into()).unwrap();
    assert_eq!(r.read("space name.txt"), "v2\n");
}

#[test]
fn imported_plain_unified_patch_keeps_multiple_members_selectable() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    let repo = r.open();
    let patch = concat!(
        "--- a/a.txt\n",
        "+++ b/a.txt\n",
        "@@ -1 +1 @@\n",
        "-a1\n",
        "+a2\n",
        "--- a/b.txt\n",
        "+++ b/b.txt\n",
        "@@ -1 +1 @@\n",
        "-b1\n",
        "+b2\n",
    );

    repo.shelve_import("plain-unified".into(), patch.into())
        .unwrap();
    assert_eq!(repo.shelve_list().unwrap()[0].paths, ["a.txt", "b.txt"]);

    repo.shelve_unshelve_paths_with_options("plain-unified".into(), vec!["b.txt".into()], false)
        .unwrap();

    assert_eq!(r.read("a.txt"), "a1\n");
    assert_eq!(r.read("b.txt"), "b2\n");
    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 2);
    assert!(shelves
        .iter()
        .any(|shelf| !shelf.is_recycled && shelf.paths == ["a.txt"]));
    assert!(shelves
        .iter()
        .any(|shelf| shelf.is_recycled && shelf.paths == ["b.txt"]));
}

#[test]
fn imported_shelf_keeps_successful_members_when_another_member_fails() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    let repo = r.open();
    repo.shelve_import(
        "partial-members".into(),
        concat!(
            "--- a/a.txt\n",
            "+++ b/a.txt\n",
            "@@ -1 +1 @@\n",
            "-a1\n",
            "+a2\n",
            "--- a/b.txt\n",
            "+++ b/b.txt\n",
            "@@ -1 +1 @@\n",
            "-b1\n",
            "+b2\n",
        )
        .into(),
    )
    .unwrap();
    r.write("b.txt", "local\n");

    let result = repo
        .shelve_unshelve_with_options_differentiated("partial-members".into(), false)
        .unwrap();

    assert_eq!(result.applied_paths, ["a.txt"]);
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local\n");
    assert_eq!(
        result.overall_status,
        arbor_engine::PatchApplyStatus::Failure
    );
    assert_eq!(
        result.member_statuses,
        [
            arbor_engine::PatchApplyMemberResult {
                path: "a.txt".into(),
                status: arbor_engine::PatchApplyStatus::Success,
            },
            arbor_engine::PatchApplyMemberResult {
                path: "b.txt".into(),
                status: arbor_engine::PatchApplyStatus::Failure,
            },
        ]
    );
    let shelves = repo.shelve_list().unwrap();
    assert!(shelves
        .iter()
        .any(|shelf| !shelf.is_recycled && shelf.paths == ["b.txt"]));
    assert!(shelves
        .iter()
        .any(|shelf| shelf.is_recycled && shelf.paths == ["a.txt"]));
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn native_differentiated_unshelve_conflict_completion_restores_index_boundary() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let repo = r.open();
    repo.shelve(
        "native differentiated conflict".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    r.write("b.txt", "local-b\n");
    let error = repo
        .shelve_unshelve_with_options_differentiated("native differentiated conflict".into(), false)
        .unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    repo.accept_conflict("b.txt".into(), FilePick::Ours)
        .unwrap();
    repo.shelve_complete_restore("native differentiated conflict".into())
        .unwrap();

    let shelves = repo.shelve_list().unwrap();
    assert!(shelves.iter().any(|item| {
        item.name == "native differentiated conflict"
            && item.is_recycled
            && item.paths == ["a.txt", "b.txt"]
    }));
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local-b\n");
    assert!(r.git(&["diff", "--cached", "--", "b.txt"]).is_empty());
}

#[test]
fn native_differentiated_conflict_completion_leaves_unattempted_members_shelved() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    common::commit(&r.path, "c.txt", "c1\n", "init c");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    r.write("c.txt", "c2\n");
    let repo = r.open();
    repo.shelve(
        "native unattempted conflict".into(),
        vec!["a.txt".into(), "b.txt".into(), "c.txt".into()],
    )
    .unwrap();

    r.write("a.txt", "local-a\n");
    r.write("b.txt", "local-b\n");
    r.write("c.txt", "local-c\n");
    let error = repo
        .shelve_unshelve_with_options_differentiated("native unattempted conflict".into(), false)
        .unwrap_err();
    let conflict_paths = match error {
        EngineError::ShelveApplyConflict { paths, .. } => paths,
        other => panic!("expected Shelf conflict, got {other:?}"),
    };
    for path in &conflict_paths {
        repo.accept_conflict(path.clone(), FilePick::Ours).unwrap();
    }
    repo.shelve_complete_restore("native unattempted conflict".into())
        .unwrap();

    let shelves = repo.shelve_list().unwrap();
    let all_paths = std::collections::HashSet::from([
        "a.txt".to_string(),
        "b.txt".to_string(),
        "c.txt".to_string(),
    ]);
    let conflict_set = conflict_paths
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    let expected_remaining = all_paths
        .difference(&conflict_set)
        .cloned()
        .collect::<std::collections::HashSet<_>>();
    assert!(
        shelves.iter().any(|item| {
            item.name == "native unattempted conflict"
                && !item.is_recycled
                && item
                    .paths
                    .iter()
                    .cloned()
                    .collect::<std::collections::HashSet<_>>()
                    == expected_remaining
        }),
        "shelves={shelves:?}, conflict={conflict_set:?}, expected={expected_remaining:?}"
    );
    assert!(shelves.iter().any(|item| {
        item.name != "native unattempted conflict"
            && item.is_recycled
            && item
                .paths
                .iter()
                .cloned()
                .collect::<std::collections::HashSet<_>>()
                == conflict_set
    }));
    assert_eq!(r.read("a.txt"), "local-a\n");
    assert_eq!(r.read("b.txt"), "local-b\n");
    assert_eq!(r.read("c.txt"), "local-c\n");
}

#[test]
fn native_differentiated_pop_conflict_completion_consumes_only_attempted_members() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    common::commit(&r.path, "c.txt", "c1\n", "init c");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    r.write("c.txt", "c2\n");
    let repo = r.open();
    repo.shelve(
        "native pop conflict".into(),
        vec!["a.txt".into(), "b.txt".into(), "c.txt".into()],
    )
    .unwrap();

    r.write("a.txt", "local-a\n");
    r.write("b.txt", "local-b\n");
    r.write("c.txt", "local-c\n");
    let error = repo
        .shelve_pop_differentiated("native pop conflict".into())
        .unwrap_err();
    let conflict_paths = match error {
        EngineError::ShelveApplyConflict { paths, .. } => paths,
        other => panic!("expected Shelf pop conflict, got {other:?}"),
    };
    let restore_info = repo.shelve_restore_info().unwrap().unwrap();
    assert_eq!(restore_info.is_pop, true);
    assert_eq!(restore_info.conflict_paths, conflict_paths);
    for path in &conflict_paths {
        repo.accept_conflict(path.clone(), FilePick::Ours).unwrap();
    }
    repo.shelve_complete_restore("native pop conflict".into())
        .unwrap();

    let all_paths = std::collections::HashSet::from([
        "a.txt".to_string(),
        "b.txt".to_string(),
        "c.txt".to_string(),
    ]);
    let conflict_set = conflict_paths
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    let expected_remaining = all_paths
        .difference(&conflict_set)
        .cloned()
        .collect::<std::collections::HashSet<_>>();
    let shelves = repo.shelve_list().unwrap();
    assert!(shelves.iter().any(|item| {
        item.name == "native pop conflict"
            && !item.is_recycled
            && item
                .paths
                .iter()
                .cloned()
                .collect::<std::collections::HashSet<_>>()
                == expected_remaining
    }));
    assert!(!shelves.iter().any(|item| item.is_recycled));
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
    assert!(r.git(&["diff", "--cached"]).is_empty());
}

#[test]
fn preservation_pop_without_snapshot_uses_differentiated_conflict_restore() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let repo = r.open();
    repo.shelve(
        "preservation fallback".into(),
        vec!["a.txt".into(), "b.txt".into()],
    )
    .unwrap();

    // Simulate a preserving-process Shelf whose staged-state sidecar was lost
    // during an older crash. The recovery API must still use per-file apply,
    // rather than silently falling back to an all-or-nothing tree merge.
    r.write("b.txt", "local\n");
    let error = repo
        .shelve_pop_preservation("preservation fallback".into())
        .unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    assert_eq!(r.read("a.txt"), "a2\n");
    assert!(r.read("b.txt").contains("<<<<<<<"));

    repo.accept_conflict("b.txt".into(), FilePick::Ours)
        .unwrap();
    repo.shelve_complete_restore("preservation fallback".into())
        .unwrap();

    let shelves = repo.shelve_list().unwrap();
    assert!(shelves.is_empty());
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local\n");
}

#[test]
fn imported_shelf_pop_keeps_failed_members_in_the_active_remainder() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    let repo = r.open();
    repo.shelve_import(
        "partial-pop".into(),
        concat!(
            "--- a/a.txt\n",
            "+++ b/a.txt\n",
            "@@ -1 +1 @@\n",
            "-a1\n",
            "+a2\n",
            "--- a/b.txt\n",
            "+++ b/b.txt\n",
            "@@ -1 +1 @@\n",
            "-b1\n",
            "+b2\n",
        )
        .into(),
    )
    .unwrap();
    r.write("b.txt", "local\n");

    let result = repo
        .shelve_pop_differentiated("partial-pop".into())
        .unwrap();

    assert_eq!(result.applied_paths, ["a.txt"]);
    assert_eq!(result.failed_paths, ["b.txt"]);
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local\n");
    let shelves = repo.shelve_list().unwrap();
    assert_eq!(shelves.len(), 1);
    assert_eq!(shelves[0].paths, ["b.txt"]);
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
}

#[test]
fn imported_shelf_hunk_selection_keeps_failed_file_in_the_remainder() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    let repo = r.open();
    repo.shelve_import(
        "partial-hunks".into(),
        concat!(
            "--- a/a.txt\n",
            "+++ b/a.txt\n",
            "@@ -1 +1 @@\n",
            "-a1\n",
            "+a2\n",
            "--- a/b.txt\n",
            "+++ b/b.txt\n",
            "@@ -1 +1 @@\n",
            "-b1\n",
            "+b2\n",
        )
        .into(),
    )
    .unwrap();
    r.write("b.txt", "local\n");

    let applied_paths = repo
        .shelve_unshelve_selections_with_options(
            "partial-hunks".into(),
            vec![
                ShelvePatchSelection {
                    path: "a.txt".into(),
                    hunk_index: Some(0),
                },
                ShelvePatchSelection {
                    path: "b.txt".into(),
                    hunk_index: Some(0),
                },
            ],
            false,
        )
        .unwrap();

    assert_eq!(applied_paths, ["a.txt"]);
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local\n");
    let shelves = repo.shelve_list().unwrap();
    assert!(shelves
        .iter()
        .any(|shelf| !shelf.is_recycled && shelf.paths == ["b.txt"]));
    assert!(shelves
        .iter()
        .any(|shelf| shelf.is_recycled && shelf.paths == ["a.txt"]));
}

#[test]
fn imported_deleted_shelf_remove_applied_keeps_failed_member_deleted() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    let repo = r.open();
    repo.shelve_import(
        "deleted-partial".into(),
        concat!(
            "--- a/a.txt\n",
            "+++ b/a.txt\n",
            "@@ -1 +1 @@\n",
            "-a1\n",
            "+a2\n",
            "--- a/b.txt\n",
            "+++ b/b.txt\n",
            "@@ -1 +1 @@\n",
            "-b1\n",
            "+b2\n",
        )
        .into(),
    )
    .unwrap();
    repo.shelve_drop("deleted-partial".into()).unwrap();
    r.write("b.txt", "local\n");

    let applied_paths = repo
        .shelve_unshelve_deleted_with_options("deleted-partial".into(), true)
        .unwrap();

    assert_eq!(applied_paths, ["a.txt"]);
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local\n");
    assert!(repo.shelve_list().unwrap().is_empty());
    let deleted = repo.shelve_deleted_list().unwrap();
    assert_eq!(deleted.len(), 1);
    assert_eq!(deleted[0].paths, ["b.txt"]);
    assert!(deleted[0].is_deleted);
}

#[test]
fn imported_shelf_partial_apply_pauses_on_a_later_conflict() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let source = r.open();
    source
        .shelve(
            "conflict-source".into(),
            vec!["a.txt".into(), "b.txt".into()],
        )
        .unwrap();
    let patch = source.shelve_diff("conflict-source".into()).unwrap();

    common::commit(&r.path, "b.txt", "head\n", "advance b differently");
    let repo = r.open();
    repo.shelve_import("partial-conflict".into(), patch)
        .unwrap();

    let error = repo.shelve_pop("partial-conflict".into()).unwrap_err();
    assert!(matches!(
        error,
        EngineError::ShelveApplyConflict { ref name, ref paths }
            if name == "partial-conflict" && paths == &["b.txt".to_string()]
    ));
    assert_eq!(r.read("a.txt"), "a2\n");
    assert!(r.read("b.txt").contains("<<<<<<<"));
    let restore_info = repo.shelve_restore_info().unwrap().unwrap();
    assert_eq!(restore_info.paths, ["a.txt", "b.txt"]);
    assert!(restore_info.is_pop);
    assert!(!restore_info.remove_applied);

    repo.shelve_abort_restore("partial-conflict".into())
        .unwrap();
    assert_eq!(r.read("a.txt"), "a1\n");
    assert_eq!(r.read("b.txt"), "head\n");
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn imported_shelf_partial_conflict_completion_consumes_only_applied_members() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init a");
    common::commit(&r.path, "b.txt", "b1\n", "init b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let source = r.open();
    source
        .shelve(
            "completion-source".into(),
            vec!["a.txt".into(), "b.txt".into()],
        )
        .unwrap();
    let patch = source.shelve_diff("completion-source".into()).unwrap();

    common::commit(&r.path, "b.txt", "head\n", "advance b differently");
    let repo = r.open();
    repo.shelve_import("partial-completion".into(), patch)
        .unwrap();
    let error = repo.shelve_pop("partial-completion".into()).unwrap_err();
    assert!(matches!(error, EngineError::ShelveApplyConflict { .. }));
    assert_eq!(r.read("a.txt"), "a2\n");

    r.write("b.txt", "resolved\n");
    common::git(&r.path, &["add", "b.txt"]);
    repo.shelve_complete_restore("partial-completion".into())
        .unwrap();

    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "resolved\n");
    assert!(!repo
        .shelve_list()
        .unwrap()
        .iter()
        .any(|shelf| shelf.name == "partial-completion"));
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn imported_patch_can_apply_directly_without_creating_a_shelf() {
    let r = TestRepo::new();
    common::commit(&r.path, "subdir/a.txt", "a1\n", "init");
    let repo = r.open();
    let patch = concat!(
        "--- a/a.txt\n",
        "+++ b/a.txt\n",
        "@@ -1 +1 @@\n",
        "-a1\n",
        "+a2\n",
    );

    let applied_paths = repo
        .apply_imported_patch(
            "Apply Patch: direct".into(),
            patch.into(),
            vec!["a.txt".into()],
            "subdir".into(),
            1,
        )
        .unwrap();

    assert_eq!(applied_paths, ["subdir/a.txt"]);
    assert_eq!(r.read("subdir/a.txt"), "a2\n");
    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn direct_imported_patch_keeps_successful_members_when_another_member_fails() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "add a");
    common::commit(&r.path, "b.txt", "b1\n", "add b");
    r.write("b.txt", "local\n");
    let repo = r.open();
    let patch = concat!(
        "--- a/a.txt\n",
        "+++ b/a.txt\n",
        "@@ -1 +1 @@\n",
        "-a1\n",
        "+a2\n",
        "--- a/b.txt\n",
        "+++ b/b.txt\n",
        "@@ -1 +1 @@\n",
        "-b1\n",
        "+b2\n",
    );

    let result = repo
        .apply_imported_patch_differentiated(
            "Apply Patch: partial".into(),
            patch.into(),
            vec!["a.txt".into(), "b.txt".into()],
            Vec::new(),
            "".into(),
            1,
        )
        .unwrap();

    assert_eq!(result.applied_paths, ["a.txt"]);
    assert_eq!(result.failed_paths, ["b.txt"]);
    assert_eq!(r.read("a.txt"), "a2\n");
    assert_eq!(r.read("b.txt"), "local\n");
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn patch_index_paths_exposes_tracked_paths_for_base_matching() {
    let r = TestRepo::new();
    common::commit(&r.path, "Package/Resources/a.txt", "a1\n", "init");
    common::commit(&r.path, "src/b.txt", "b1\n", "add b");
    let repo = r.open();

    let paths = repo.patch_index_paths().unwrap();
    assert!(paths.contains(&"Package/Resources/a.txt".to_string()));
    assert!(paths.contains(&"src/b.txt".to_string()));
}

#[test]
fn blob_identity_matches_a_clean_filtered_worktree_rename_without_mutation() {
    let r = TestRepo::new();
    r.git(&["config", "filter.upper.clean", "tr a-z A-Z"]);
    r.git(&["config", "filter.upper.smudge", "tr A-Z a-z"]);
    r.write(".gitattributes", "*.txt filter=upper\n");
    common::commit(&r.path, ".gitattributes", "*.txt filter=upper\n", "attrs");
    common::commit(&r.path, "old.txt", "same content\n", "init");
    let expected = r.git(&["rev-parse", "HEAD:old.txt"]);
    let repo = r.open();

    std::fs::rename(r.path.join("old.txt"), r.path.join("new-name.txt")).unwrap();

    assert_eq!(
        repo.worktree_blob_id("new-name.txt".into()).unwrap(),
        expected
    );
    assert_eq!(
        repo.index_blob_id("old.txt".into()).unwrap().as_deref(),
        Some(expected.as_str())
    );
    let status = r.git(&["status", "--porcelain=v1"]);
    assert!(status.contains("D old.txt"));
    assert!(status.contains("?? new-name.txt"));
}

#[test]
fn direct_imported_patch_conflict_can_be_completed_without_shelf_metadata() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base\n", "init");

    r.write("a.txt", "patch\n");
    let source = r.open();
    source
        .shelve("source".into(), vec!["a.txt".into()])
        .unwrap();
    let patch = source.shelve_diff("source".into()).unwrap();

    common::commit(&r.path, "a.txt", "head\n", "advance head");
    let repo = r.open();
    let error = repo
        .apply_imported_patch_differentiated(
            "Apply Patch: conflict".into(),
            patch.clone(),
            vec!["a.txt".into()],
            Vec::new(),
            "".into(),
            1,
        )
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::ShelveApplyConflict { ref name, ref paths }
            if name == "Apply Patch: conflict" && paths == &["a.txt".to_string()]
    ));
    let restore_info = repo.shelve_restore_info().unwrap().unwrap();
    assert!(restore_info.is_direct_patch);
    assert_eq!(restore_info.patch.as_deref(), Some(patch.as_str()));

    repo.shelve_set_restore_hunk_resolution(
        "Apply Patch: conflict".into(),
        "a.txt".into(),
        0,
        "ignored".into(),
    )
    .unwrap();
    let reopened = r.open();
    let reopened_info = reopened.shelve_restore_info().unwrap().unwrap();
    assert_eq!(
        reopened_info.resolved_hunks,
        vec![ShelveRestoreHunkResolution {
            path: "a.txt".into(),
            hunk_index: 0,
            resolution: "ignored".into(),
        }]
    );
    reopened
        .shelve_clear_restore_hunk_resolutions("Apply Patch: conflict".into(), "a.txt".into())
        .unwrap();
    assert!(reopened
        .shelve_restore_info()
        .unwrap()
        .unwrap()
        .resolved_hunks
        .is_empty());

    r.write("a.txt", "resolved\n");
    common::git(&r.path, &["add", "a.txt"]);
    repo.apply_imported_patch_complete_restore("Apply Patch: conflict".into())
        .unwrap();

    assert_eq!(r.read("a.txt"), "resolved\n");
    assert!(repo.shelve_restore_info().unwrap().is_none());
    assert_eq!(repo.shelve_list().unwrap().len(), 1);
}

#[test]
fn cancelled_direct_imported_patch_returns_abort_without_mutation() {
    let target = TestRepo::new();
    common::commit(&target.path, "a.txt", "base\n", "init");

    let source = TestRepo::new();
    common::commit(&source.path, "a.txt", "base\n", "init");
    source.write("a.txt", "patch\n");
    let source_repo = source.open();
    source_repo
        .shelve("source".into(), vec!["a.txt".into()])
        .unwrap();
    let patch = source_repo.shelve_diff("source".into()).unwrap();

    let repo = target.open();
    let cancel = GitCancelHandle::new();
    cancel.cancel();
    let result = repo
        .apply_imported_patch_differentiated_with_cancel(
            "Apply Patch: cancelled".into(),
            patch,
            vec!["a.txt".into()],
            Vec::new(),
            "".into(),
            1,
            cancel,
        )
        .unwrap();

    assert_eq!(result.overall_status, arbor_engine::PatchApplyStatus::Abort);
    assert_eq!(result.applied_paths, Vec::<String>::new());
    assert_eq!(result.failed_paths, vec!["a.txt"]);
    assert_eq!(
        result.member_statuses,
        vec![arbor_engine::PatchApplyMemberResult {
            path: "a.txt".into(),
            status: arbor_engine::PatchApplyStatus::Abort,
        }]
    );
    assert_eq!(target.read("a.txt"), "base\n");
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn direct_imported_patch_preflight_failure_does_not_create_restore_snapshot() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base\n", "init");
    let repo = r.open();

    let error = repo
        .apply_imported_patch_differentiated(
            "Apply Patch: invalid".into(),
            "not a patch".into(),
            vec!["a.txt".into()],
            Vec::new(),
            "".into(),
            1,
        )
        .unwrap_err();

    assert!(error.to_string().contains("patch"));
    assert_eq!(r.read("a.txt"), "base\n");
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn shelve_import_rejects_invalid_patch_without_mutation() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "local");
    let repo = r.open();

    let error = repo
        .shelve_import("invalid".into(), "not a patch".into())
        .unwrap_err();
    assert!(error.to_string().contains("could not be applied"));
    assert_eq!(r.read("a.txt"), "local");
    assert!(repo.shelve_list().unwrap().is_empty());
    assert!(repo.shelve_deleted_list().unwrap().is_empty());
}

#[test]
fn shelve_import_round_trips_binary_patch() {
    let r = TestRepo::new();
    r.write("image.bin", "\0\x01\x02\x03");
    common::commit(&r.path, "image.bin", "\0\x01\x02\x03", "init");

    r.write("image.bin", "\0\x01\x02\x04");
    let repo = r.open();
    repo.shelve("binary-source".into(), vec!["image.bin".into()])
        .unwrap();
    let patch = repo.shelve_diff("binary-source".into()).unwrap();
    assert!(patch.contains("GIT binary patch"));

    repo.shelve_import("binary-import".into(), patch).unwrap();
    repo.shelve_pop("binary-import".into()).unwrap();
    assert_eq!(r.read("image.bin").as_bytes(), b"\0\x01\x02\x04");
}

/// 多个 shelve 跨进程都能读回。
#[test]
fn shelve_multiple_survive_reopen() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    common::commit(&r.path, "b.txt", "v1", "add b");

    let repo = r.open();
    r.write("a.txt", "a2");
    repo.shelve("sa".into(), vec!["a.txt".into()]).unwrap();
    r.write("b.txt", "b2");
    repo.shelve("sb".into(), vec!["b.txt".into()]).unwrap();

    let repo2 = r.open();
    let list = repo2.shelve_list().unwrap();
    assert_eq!(list.len(), 2);
    // 弹出第二个（sb），验证 b 恢复
    repo2.shelve_pop("sb".into()).unwrap();
    assert_eq!(r.read("b.txt"), "b2");
    assert_eq!(repo2.shelve_list().unwrap().len(), 1);
}

#[cfg(unix)]
#[test]
fn shelve_roundtrip_preserves_symlink_and_executable_mode() {
    use std::os::unix::fs::{symlink, PermissionsExt};

    let r = TestRepo::new();
    r.write("target.txt", "target\n");
    symlink("target.txt", r.path.join("link.txt")).unwrap();
    r.write("run.sh", "base\n");
    let mut permissions = std::fs::metadata(r.path.join("run.sh"))
        .unwrap()
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(r.path.join("run.sh"), permissions).unwrap();
    r.git(&["add", "target.txt", "link.txt", "run.sh"]);
    r.git(&["commit", "-q", "-m", "init"]);

    std::fs::remove_file(r.path.join("link.txt")).unwrap();
    symlink("other-target.txt", r.path.join("link.txt")).unwrap();
    r.write("run.sh", "shelved\n");
    let mut permissions = std::fs::metadata(r.path.join("run.sh"))
        .unwrap()
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(r.path.join("run.sh"), permissions).unwrap();

    let repo = r.open();
    repo.shelve("modes".into(), vec!["link.txt".into(), "run.sh".into()])
        .unwrap();

    assert_eq!(
        std::fs::read_link(r.path.join("link.txt")).unwrap(),
        std::path::PathBuf::from("target.txt")
    );
    assert_eq!(r.read("run.sh"), "base\n");

    repo.shelve_unshelve("modes".into()).unwrap();
    assert_eq!(
        std::fs::read_link(r.path.join("link.txt")).unwrap(),
        std::path::PathBuf::from("other-target.txt")
    );
    assert_eq!(r.read("run.sh"), "shelved\n");
    assert_ne!(
        std::fs::metadata(r.path.join("run.sh"))
            .unwrap()
            .permissions()
            .mode()
            & 0o111,
        0
    );
}

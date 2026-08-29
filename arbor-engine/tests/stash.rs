//! D2：stash round-trip。
//! stash_save -> stash_list 非空 -> stash_pop -> 工作区恢复。

mod common;

use arbor_engine::GitCancelHandle;
use common::TestRepo;

/// 保存 -> 列表非空 -> 弹出 -> 工作区恢复 + 列表清空。
#[test]
fn stash_save_list_pop() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    // 未暂存修改
    r.write("a.txt", "v2");
    let repo = r.open();

    let id = repo.stash_save(Some("my stash".into())).unwrap();
    assert!(!id.is_empty());

    // 保存后工作区应回 HEAD（v1）
    assert_eq!(r.read("a.txt"), "v1");

    let list = repo.stash_list().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].message, "my stash");

    // 弹出 -> 工作区恢复到 v2
    repo.stash_pop(0).unwrap();
    assert_eq!(r.read("a.txt"), "v2");

    // 弹出后列表清空
    let list2 = repo.stash_list().unwrap();
    assert!(list2.is_empty(), "stash list should be empty after pop");
}

#[test]
fn stash_pop_without_saved_changes_keeps_new_head_index_clean() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    let repo = r.open();

    // This models Arbor's temporary pull stash when the worktree has no
    // effective local content change.
    repo.stash_save(Some("temporary pull workspace".into()))
        .unwrap();
    common::commit(&r.path, "a.txt", "v2", "remote update");

    repo.stash_pop(0).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
    assert_eq!(repo.stash_list().unwrap().len(), 0);
}

#[test]
fn cancelled_stash_pop_keeps_stash_and_worktree_before_restore() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");
    let repo = r.open();
    repo.stash_save(Some("pull workspace".into())).unwrap();

    let cancel = GitCancelHandle::new();
    cancel.cancel();
    let result = repo.stash_pop_with_index_and_cancel(0, true, cancel);

    assert!(matches!(result, Err(arbor_engine::EngineError::Cancelled)));
    assert_eq!(r.read("a.txt"), "v1");
    assert_eq!(repo.stash_list().unwrap().len(), 1);
}

/// 多条 stash：drop 中间一条不影响其余。
#[test]
fn stash_drop_keeps_others() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    let repo = r.open();

    r.write("a.txt", "v2");
    repo.stash_save(Some("first".into())).unwrap();
    // 保存后工作区回 v1，再改
    r.write("a.txt", "v3");
    repo.stash_save(Some("second".into())).unwrap();

    let list = repo.stash_list().unwrap();
    assert_eq!(list.len(), 2);

    // drop 最新的（index 0 = second）
    repo.stash_drop(0).unwrap();
    let list2 = repo.stash_list().unwrap();
    assert_eq!(list2.len(), 1);
    assert_eq!(list2[0].message, "first");
}

#[test]
fn stash_stack_uses_standard_commit_parents_and_reflog_order() {
    let r = TestRepo::new();
    let initial = common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");
    let repo = r.open();
    let first = repo.stash_save(Some("first".into())).unwrap();

    let after_update = common::commit(&r.path, "a.txt", "v3", "update");
    r.write("a.txt", "v4");
    let second = repo.stash_save(Some("second".into())).unwrap();

    let first_parent = r.git(&["rev-parse", &format!("{first}^1")]);
    let second_parent = r.git(&["rev-parse", &format!("{second}^1")]);
    assert_eq!(first_parent, initial);
    assert_eq!(second_parent, after_update);

    let list = repo.stash_list().unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].message, "second");
    assert_eq!(list[1].message, "first");

    repo.stash_drop(0).unwrap();
    let remaining = repo.stash_list().unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].message, "first");
}

/// Apply 只恢复工作区，不删除 stash；随后 Pop 才会移除它。
#[test]
fn stash_apply_keeps_stash() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write("a.txt", "v2");
    let repo = r.open();
    repo.stash_save(Some("keep me".into())).unwrap();

    repo.stash_apply(0).unwrap();
    assert_eq!(r.read("a.txt"), "v2");
    assert_eq!(repo.stash_list().unwrap().len(), 1);
}

#[test]
fn stash_apply_with_index_restores_staged_and_unstaged_dimensions() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base\n", "init");
    r.write("a.txt", "staged\n");
    r.git(&["add", "a.txt"]);
    r.write("a.txt", "staged plus worktree\n");
    let repo = r.open();
    repo.stash_save(Some("index semantics".into())).unwrap();

    repo.stash_apply_with_index(0, true).unwrap();
    let staged = r.git(&["diff", "--cached", "--", "a.txt"]);
    let unstaged = r.git(&["diff", "--", "a.txt"]);
    assert!(staged.contains("+staged"));
    assert!(unstaged.contains("staged plus worktree"));
    assert_eq!(repo.stash_list().unwrap().len(), 1);
}

/// stash 的内部提交在没有 user.name/user.email 时也应使用内存 fallback，
/// 不要求用户先修改全局或仓库 Git 配置。
#[test]
fn stash_save_without_configured_identity() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.git(&["config", "--local", "--unset-all", "user.name"]);
    r.git(&["config", "--local", "--unset-all", "user.email"]);
    r.write("a.txt", "v2");

    let repo = r.open();
    let id = repo.stash_save(Some("identity fallback".into())).unwrap();

    assert!(!id.is_empty());
    assert_eq!(r.read("a.txt"), "v1");
    assert_eq!(repo.stash_list().unwrap().len(), 1);
}

/// Pull 专用的临时保存必须覆盖未跟踪文件，但普通 stash 仍保持原有语义。
#[test]
fn stash_save_including_untracked_round_trips_without_staging() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base", "init");
    r.write("local.log", "local only");

    let repo = r.open();
    repo.stash_save_including_untracked(Some("pull workspace".into()))
        .unwrap();

    assert!(r
        .git(&["ls-tree", "-r", "--name-only", "refs/stash"])
        .contains("local.log"));
    assert!(!r.path.join("local.log").exists());
    repo.stash_pop(0).unwrap();
    assert_eq!(r.read("local.log"), "local only");
    assert!(r.git(&["status", "--porcelain"]).contains("?? local.log"));
    assert_eq!(repo.stash_list().unwrap().len(), 0);
}

/// IntelliJ Git 的 Stash Files 只保存选中的路径：未选中的 tracked
/// 修改继续留在工作区，选中的未跟踪文件也能随 `-u` 一起保存。
#[test]
fn stash_save_paths_preserves_unselected_changes_and_round_trips() {
    let r = TestRepo::new();
    common::commit(&r.path, "selected.txt", "base\n", "init");
    common::commit(&r.path, "other.txt", "base\n", "other");
    r.write("selected.txt", "selected staged\n");
    r.git(&["add", "selected.txt"]);
    r.write("selected.txt", "selected local\n");
    r.write("other.txt", "other local\n");
    r.write("selected.log", "untracked local\n");

    let repo = r.open();
    let id = repo
        .stash_save_paths(
            Some("selected files".into()),
            vec!["selected.txt".into(), "selected.log".into()],
            true,
        )
        .unwrap();
    assert!(!id.is_empty());
    assert_eq!(r.read("selected.txt"), "base\n");
    assert!(!r.exists("selected.log"));
    assert_eq!(r.read("other.txt"), "other local\n");
    let status = r.git(&["status", "--porcelain"]);
    assert!(
        status.contains("other.txt"),
        "status after path stash: {status:?}"
    );

    let list = repo.stash_list().unwrap();
    assert_eq!(list.len(), 1);
    assert!(list[0].message.contains("selected files"));

    repo.stash_pop(0).unwrap();
    assert_eq!(r.read("selected.txt"), "selected local\n");
    assert_eq!(r.read("other.txt"), "other local\n");
    assert_eq!(r.read("selected.log"), "untracked local\n");
    assert!(r
        .git(&["status", "--porcelain"])
        .contains("?? selected.log"));
    assert!(repo.stash_list().unwrap().is_empty());
}

#[test]
fn stash_save_paths_rejects_empty_or_unmatched_paths() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base\n", "init");
    let repo = r.open();

    let empty = repo.stash_save_paths(None, Vec::new(), true).unwrap_err();
    assert!(empty.to_string().contains("at least one"));

    let unmatched = repo
        .stash_save_paths(None, vec!["missing.txt".into()], true)
        .unwrap_err();
    assert!(unmatched.to_string().contains("no changes matched"));
    assert!(repo.stash_list().unwrap().is_empty());
}

/// 未跟踪文件与远程新增同一路径时，不要求 Add/Commit，恢复阶段保留冲突现场。
#[test]
fn stash_pop_untracked_add_add_conflict_keeps_stash() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base", "init");
    r.write("new.txt", "local\n");

    let repo = r.open();
    repo.stash_save_including_untracked(Some("pull workspace".into()))
        .unwrap();
    common::commit(&r.path, "new.txt", "remote\n", "remote add");

    let error = repo.stash_pop(0).unwrap_err().to_string();
    assert!(error.contains("stash apply conflicts"));
    assert_eq!(repo.stash_list().unwrap().len(), 1);
    assert!(r.read("new.txt").contains("<<<<<<<"));
}

#[test]
fn stash_diff_and_branch_follow_git_semantics() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1\n", "init");
    r.write("a.txt", "v2\n");
    let repo = r.open();
    repo.stash_save(Some("branch me".into())).unwrap();

    let diff = repo.stash_diff(0).unwrap();
    assert!(diff.contains("+v2"));
    repo.stash_branch(0, "from-stash".into()).unwrap();
    assert_eq!(r.read("a.txt"), "v2\n");
    assert!(r.git(&["branch", "--show-current"]).trim() == "from-stash");
    assert!(repo.stash_list().unwrap().is_empty());
}

/// stash pop 使用共同基线做三方合并；同一位置冲突时不能静默覆盖远程内容，
/// 且 stash 必须保留给用户继续处理。
#[test]
fn stash_pop_conflict_keeps_stash_and_marks_worktree() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base\n", "init");
    r.write("a.txt", "local\n");
    let repo = r.open();
    repo.stash_save(Some("local change".into())).unwrap();

    common::commit(&r.path, "a.txt", "remote\n", "remote change");

    let error = repo.stash_pop(0).unwrap_err().to_string();
    assert!(error.contains("stash apply conflicts"));
    assert_eq!(repo.stash_list().unwrap().len(), 1);
    assert!(r.read("a.txt").contains("<<<<<<<"));
}

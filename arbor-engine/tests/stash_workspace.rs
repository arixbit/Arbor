//! STASH-001：Stash Workspace。
//! tracked/untracked/ignored 选项、clear、列表刷新一致性、
//! apply 冲突恢复与 unstash-as 分支，真实 fixture 验证。

mod common;

use arbor_engine::DiffSettings;
use common::TestRepo;

/// 构造带 tracked 修改 + untracked + ignored 文件的工作区。
fn dirty_workspace(r: &TestRepo) {
    common::commit(&r.path, "tracked.txt", "t1\n", "init");
    r.write(".gitignore", "*.log\n");
    r.git(&["add", ".gitignore"]);
    r.git(&["commit", "-q", "-m", "gitignore"]);
    r.write("tracked.txt", "t2\n");
    r.write("untracked.txt", "u\n");
    r.write("debug.log", "ignored content\n");
}

#[test]
fn save_with_options_tracked_untracked_ignored() {
    let r = TestRepo::new();
    dirty_workspace(&r);
    let repo = r.open();

    // tracked only:untracked/ignored 保留在工作区
    repo.stash_save_with_options(None, false, false)
        .expect("tracked stash");
    assert_eq!(r.read("tracked.txt"), "t1\n", "tracked 修改被收走");
    assert!(r.exists("untracked.txt"), "untracked 保留");
    assert!(r.exists("debug.log"), "ignored 保留");

    // 恢复后 untracked stash:untracked 收走,ignored 保留
    repo.stash_apply(0).expect("apply 1");
    r.write("tracked.txt", "t3\n");
    r.write("untracked2.txt", "u2\n");
    repo.stash_save_with_options(None, true, false)
        .expect("untracked stash");
    assert!(!r.exists("untracked2.txt"), "untracked 被收走");
    assert!(r.exists("debug.log"), "ignored 保留");

    // ignored stash:ignored 也收走
    repo.stash_apply(0).expect("apply 2");
    r.write("debug.log", "ignored2\n");
    repo.stash_save_with_options(None, true, true)
        .expect("ignored stash");
    assert!(!r.exists("debug.log"), "ignored 被收走");
}

#[test]
fn save_with_keep_index_preserves_staged_snapshot_and_removes_unstaged_delta() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "base\n", "init");
    r.write(".gitignore", "*.log\n");
    r.git(&["add", ".gitignore"]);
    r.git(&["commit", "-q", "-m", "ignore"]);
    r.write("tracked.txt", "staged\n");
    r.git(&["add", "tracked.txt"]);
    r.write("tracked.txt", "staged plus unstaged\n");
    r.write("untracked.txt", "untracked\n");
    r.write("debug.log", "ignored\n");

    let repo = r.open();
    repo.stash_save_with_keep_index(None)
        .expect("save keep-index stash");

    assert_eq!(r.read("tracked.txt"), "staged\n");
    assert!(
        r.exists("untracked.txt"),
        "keep-index must not include untracked files"
    );
    assert!(
        r.exists("debug.log"),
        "keep-index must not include ignored files"
    );
    assert_eq!(
        r.git(&["status", "--porcelain", "--untracked-files=no"]),
        "M  tracked.txt"
    );
    assert!(r
        .git(&["diff", "--cached", "--", "tracked.txt"])
        .contains("+staged"));
    assert!(
        r.git(&["diff", "--", "tracked.txt"]).is_empty(),
        "unstaged delta must be removed"
    );
}

#[test]
fn apply_restores_all_layers() {
    let r = TestRepo::new();
    dirty_workspace(&r);
    let repo = r.open();
    repo.stash_save_with_options(None, true, true)
        .expect("save all");
    assert!(!r.exists("untracked.txt"));
    assert!(!r.exists("debug.log"));

    repo.stash_apply(0).expect("apply");
    assert_eq!(r.read("tracked.txt"), "t2\n");
    assert!(r.exists("untracked.txt"));
    assert!(r.exists("debug.log"));
    // stash 仍在列表(apply 不删除)
    assert_eq!(repo.stash_list().expect("list").len(), 1);
}

#[test]
fn stash_clear_empties_stack() {
    let r = TestRepo::new();
    dirty_workspace(&r);
    let repo = r.open();
    repo.stash_save_with_options(None, true, false)
        .expect("save 1");
    r.write("tracked.txt", "t3\n");
    repo.stash_save_with_options(None, true, false)
        .expect("save 2");
    assert_eq!(repo.stash_list().expect("list").len(), 2);

    repo.stash_clear().expect("clear");
    assert!(repo.stash_list().expect("list").is_empty(), "栈已清空");
    // 清空后 apply 报错而非静默
    assert!(repo.stash_apply(0).is_err());
}

#[test]
fn list_refreshes_after_external_git_stash() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("f.txt", "2\n");
    // 外部 git stash
    r.git(&["stash", "push", "-m", "external stash"]);
    let repo = r.open();
    let list = repo.stash_list().expect("list");
    assert_eq!(list.len(), 1);
    assert!(
        list[0].message.contains("external stash"),
        "message: {}",
        list[0].message
    );

    // 外部 drop 后列表同步
    r.git(&["stash", "drop", "-q"]);
    let list = repo.stash_list().expect("list");
    assert!(list.is_empty());
}

#[test]
fn apply_conflict_keeps_stash_and_enters_conflict_flow() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.write("f.txt", "stashed change\n");
    let repo = r.open();
    repo.stash_save(None).expect("save");

    // HEAD 前进(工作区保持干净):apply 的三方合并与新的 HEAD 内容冲突
    r.write("f.txt", "new head change\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "advance"]);
    let err = repo.stash_apply(0).unwrap_err().to_string();
    assert!(err.contains("conflicts"), "冲突提示: {err}");
    // stash 保留,可再选其他动作(abort/drop/继续解决)
    assert_eq!(repo.stash_list().expect("list").len(), 1);
}

#[test]
fn unstash_as_branch_creates_branch_and_pops() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("f.txt", "2\n");
    let repo = r.open();
    repo.stash_save(None).expect("save");

    repo.stash_branch(0, "wip-feature".into())
        .expect("unstash as branch");
    assert_eq!(r.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "wip-feature");
    assert_eq!(r.read("f.txt"), "2\n", "变更恢复");
    // unstash-as 弹出 stash
    assert!(repo.stash_list().expect("list").is_empty());
}

#[test]
fn show_diff_returns_patch_for_preview() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("f.txt", "2\n3\n");
    let repo = r.open();
    repo.stash_save(None).expect("save");
    let patch = repo.stash_diff(0).expect("diff");
    assert!(patch.contains("+2"), "patch 含新增行: {patch}");
    assert!(patch.contains("+3"));
    assert!(patch.contains("-1"), "patch 含删除行");
}

#[test]
fn stash_preview_exposes_structured_tracked_and_untracked_diffs() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "base\n", "init");
    r.write("tracked.txt", "changed\n");
    r.write("untracked.txt", "new\n");
    let repo = r.open();
    repo.stash_save_with_options(None, true, false)
        .expect("save stash");

    assert_eq!(repo.stash_list().expect("list stash").len(), 1);
    let tracked = repo
        .stash_file_diff(0, "tracked.txt".into(), false)
        .expect("tracked stash file diff");
    assert!(!tracked.binary);
    assert!(!tracked.hunks.is_empty(), "tracked stash diff has hunks");

    let untracked = repo
        .stash_file_diff(0, "untracked.txt".into(), false)
        .expect("untracked stash file diff");
    assert!(!untracked.binary);
    assert!(
        !untracked.hunks.is_empty(),
        "untracked stash diff has hunks"
    );

    let patch = repo.stash_diff(0).expect("stash patch");
    assert!(patch.contains("tracked.txt"), "patch includes tracked file");
    assert!(
        patch.contains("untracked.txt"),
        "patch includes untracked file"
    );
}

#[test]
fn stash_preview_uses_opt_in_textconv_for_tracked_files() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=upper\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attributes",
    );
    r.git(&["config", "diff.upper.textconv", "awk '{print toupper($0)}'"]);
    common::commit(&r.path, "tracked.txt", "base\n", "init");
    r.write("tracked.txt", "changed\n");

    let repo = r.open();
    repo.stash_save(None).expect("save stash");
    let diff = repo
        .stash_file_diff_with_settings(
            0,
            "tracked.txt".into(),
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("textconv stash file diff");
    assert!(diff.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "BASE")
            && hunk.new_lines.iter().any(|line| line.text == "CHANGED")
    }));
}

#[test]
fn stash_preview_reads_untracked_files_from_system_git_third_parent() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "base\n", "init");
    r.write("untracked.txt", "new\n");
    r.git(&["stash", "push", "-u", "-m", "external"]);
    let repo = r.open();

    let untracked = repo
        .stash_file_diff(0, "untracked.txt".into(), false)
        .expect("system stash untracked diff");
    assert!(!untracked.binary);
    assert!(!untracked.hunks.is_empty(), "third-parent file has hunks");
    assert!(repo
        .stash_diff(0)
        .expect("system stash patch")
        .contains("untracked.txt"));
}

#[test]
fn stash_save_resets_worktree_and_index() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("f.txt", "2\n");
    r.git(&["add", "f.txt"]);
    let repo = r.open();
    repo.stash_save(None).expect("save");
    // 工作区与索引都回到 HEAD
    assert_eq!(r.read("f.txt"), "1\n");
    let st = repo.status().expect("status");
    assert!(st
        .iter()
        .all(|e| e.staged == arbor_engine::ChangeKind::Unchanged
            && e.unstaged == arbor_engine::ChangeKind::Unchanged));
}

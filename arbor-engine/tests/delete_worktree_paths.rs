mod common;

use arbor_engine::{ChangeKind, EngineError};
use common::{commit, TestRepo};

/// IntelliJ 对照：`Git.Stage.Tree.Menu` 里的 `$Delete`（platform Delete 动作）。
/// fork 侧是 VFS 删除：只动磁盘，不跑 `git rm`，被跟踪文件随后以 deleted
/// 出现在状态里。Arbor 的 `delete_worktree_paths` 保持同一语义。
#[test]
fn delete_removes_a_tracked_file_and_status_reports_it_deleted() {
    let repo = TestRepo::new();
    commit(&repo.path, "a.txt", "v1\n", "init");

    let engine = repo.open();
    let deleted = engine
        .delete_worktree_paths(vec!["a.txt".into()])
        .expect("delete tracked file");

    assert_eq!(deleted, vec!["a.txt".to_string()]);
    assert!(!repo.exists("a.txt"));
    // 不跑 git rm：删除留在工作区侧，index 仍然有该条目。
    let entry = engine
        .status()
        .unwrap()
        .into_iter()
        .find(|entry| entry.path == "a.txt")
        .expect("a.txt status entry");
    assert_eq!(entry.staged, ChangeKind::Unchanged);
    assert_eq!(entry.unstaged, ChangeKind::Deleted);
}

#[test]
fn delete_removes_an_untracked_file() {
    let repo = TestRepo::new();
    commit(&repo.path, "a.txt", "v1\n", "init");
    repo.write("scratch.txt", "temporary\n");

    let engine = repo.open();
    engine
        .delete_worktree_paths(vec!["scratch.txt".into()])
        .expect("delete untracked file");

    assert!(!repo.exists("scratch.txt"));
    assert!(engine
        .status()
        .unwrap()
        .iter()
        .all(|entry| entry.path != "scratch.txt"));
}

#[test]
fn delete_removes_a_directory_recursively() {
    let repo = TestRepo::new();
    commit(&repo.path, "a.txt", "v1\n", "init");
    repo.write("folder/one.txt", "1\n");
    repo.write("folder/nested/two.txt", "2\n");

    let engine = repo.open();
    engine
        .delete_worktree_paths(vec!["folder".into()])
        .expect("delete directory");

    assert!(!repo.exists("folder"));
    assert!(!repo.exists("folder/nested/two.txt"));
}

#[test]
fn delete_rejects_paths_that_escape_the_worktree() {
    let repo = TestRepo::new();
    commit(&repo.path, "a.txt", "v1\n", "init");
    let engine = repo.open();

    for bad in ["../outside.txt", "/etc/hosts", ".git/config", ""] {
        let error = engine
            .delete_worktree_paths(vec![bad.into()])
            .expect_err("path must be rejected");
        assert!(
            matches!(error, EngineError::GitOperation { .. }),
            "{bad} produced {error:?}"
        );
    }
    // 拒绝之后工作区不能被改动。
    assert!(repo.exists("a.txt"));
    assert!(repo.exists(".git/config"));
}

#[test]
fn delete_fails_closed_for_a_missing_path() {
    let repo = TestRepo::new();
    commit(&repo.path, "a.txt", "v1\n", "init");
    let engine = repo.open();

    let error = engine
        .delete_worktree_paths(vec!["gone.txt".into()])
        .expect_err("missing path must fail");
    assert!(matches!(error, EngineError::GitOperation { .. }));
}

#[cfg(unix)]
#[test]
fn delete_removes_a_symlink_without_following_it() {
    let repo = TestRepo::new();
    commit(&repo.path, "target/keep.txt", "keep\n", "init");
    std::os::unix::fs::symlink("target", repo.path.join("link")).unwrap();

    let engine = repo.open();
    engine
        .delete_worktree_paths(vec!["link".into()])
        .expect("delete symlink");

    // 链接消失，链接指向的目录仍在。
    assert!(!repo.exists("link"));
    assert!(repo.exists("target/keep.txt"));
}

//! Rebased/IntelliJ reset 面板四种模式 + 单文件恢复回归。

mod common;

use arbor_engine::{EngineError, LocalChangesSavePolicy, ResetMode, ResetRecoveryTarget};
use common::TestRepo;

#[test]
fn reset_soft_moves_head_but_keeps_index_and_worktree() {
    let r = TestRepo::new();
    let first = common::commit(&r.path, "a.txt", "one\n", "one");
    let _second = common::commit(&r.path, "a.txt", "two\n", "two");
    r.open().reset(first.clone(), ResetMode::Soft).unwrap();
    assert_eq!(r.git(&["rev-parse", "HEAD"]), first);
    assert_eq!(r.read("a.txt"), "two\n");
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .contains("a.txt"));
    assert!(!first.is_empty());
}

#[test]
fn reset_mixed_keeps_worktree_but_resets_index() {
    let r = TestRepo::new();
    let first = common::commit(&r.path, "a.txt", "one\n", "one");
    let second = common::commit(&r.path, "a.txt", "two\n", "two");
    r.open().reset(first.clone(), ResetMode::Mixed).unwrap();
    assert_eq!(r.git(&["rev-parse", "HEAD"]), first);
    assert_eq!(r.read("a.txt"), "two\n");
    assert!(r.git(&["diff", "--cached", "--name-only"]).is_empty());
    assert!(r.git(&["diff", "--name-only"]).contains("a.txt"));
    assert!(!second.is_empty());
}

#[test]
fn reset_keep_preserves_unrelated_local_change() {
    let r = TestRepo::new();
    let first = common::commit(&r.path, "a.txt", "one\n", "one");
    common::commit(&r.path, "b.txt", "base\n", "two");
    r.write("a.txt", "local a\n");
    r.open().reset(first.clone(), ResetMode::Keep).unwrap();
    assert_eq!(r.git(&["rev-parse", "HEAD"]), first);
    assert_eq!(r.read("a.txt"), "local a\n");
    assert!(!r.exists("b.txt"));
}

#[test]
fn smart_reset_preserves_overlapping_local_changes_and_cleans_marker() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\nkeep\n", "target");
    common::commit(&r.path, "a.txt", "current\nkeep\n", "current");
    r.write("a.txt", "current\nlocal\n");
    let repo = r.open();

    let error = repo
        .reset(target.clone(), ResetMode::Keep)
        .expect_err("direct Keep reset must protect the overlapping edit");
    assert!(matches!(
        error,
        EngineError::LocalChangesWouldBeOverwritten { paths }
            if paths == vec!["a.txt".to_string()]
    ));

    repo.reset_with_policy(
        target.clone(),
        ResetMode::Keep,
        LocalChangesSavePolicy::Stash,
    )
    .expect("Smart Reset should restore the local edit");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), target);
    assert_eq!(r.read("a.txt"), "base\nlocal\n");
    assert!(r.git(&["stash", "list"]).is_empty());
    assert!(!r.path.join(".git/arbor-apply-local-changes").exists());
}

#[test]
fn hard_reset_force_path_discards_local_changes_only_when_explicit() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    common::commit(&r.path, "a.txt", "current\n", "current");
    r.write("a.txt", "local\n");

    let error = r
        .open()
        .reset(target.clone(), ResetMode::Hard)
        .expect_err("normal Hard reset must expose Smart/Force choice");
    assert!(matches!(
        error,
        EngineError::LocalChangesWouldBeOverwritten { .. }
    ));
    r.open()
        .reset_hard(target.clone())
        .expect("explicit force reset");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), target);
    assert_eq!(r.read("a.txt"), "base\n");
}

#[test]
fn smart_hard_reset_preserves_overlapping_local_changes() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    common::commit(&r.path, "a.txt", "current\n", "current");
    r.write("a.txt", "current\nlocal\n");

    let recovery = r
        .open()
        .reset_with_recovery(
            target.clone(),
            ResetMode::Hard,
            LocalChangesSavePolicy::Stash,
            true,
            false,
        )
        .expect("Smart Hard reset should restore the local edit");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), target);
    assert_eq!(r.read("a.txt"), "base\nlocal\n");
    assert!(recovery.rollback_id.is_some());
    assert!(r.git(&["stash", "list"]).is_empty());
    assert!(!r.path.join(".git/arbor-apply-local-changes").exists());
}

#[test]
fn reset_recovery_restores_mixed_index_worktree_and_untracked_scene() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    let initial = common::commit(&r.path, "a.txt", "current\n", "current");
    r.write("a.txt", "local worktree\n");
    r.write("staged.txt", "staged\n");
    common::git(&r.path, &["add", "staged.txt"]);
    r.write("untracked.txt", "untracked\n");
    let status_before = r.git(&[
        "status",
        "--porcelain=v1",
        "--ignored",
        "--untracked-files=all",
    ]);

    let recovery = r
        .open()
        .reset_with_recovery(
            target.clone(),
            ResetMode::Mixed,
            LocalChangesSavePolicy::Stash,
            false,
            false,
        )
        .expect("mixed reset with recovery");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), target);
    let rollback_id = recovery.rollback_id.clone().expect("undo marker");

    r.open()
        .rollback_reset_recovery(ResetRecoveryTarget {
            root_path: r.path.display().to_string(),
            display_name: "repo".into(),
            initial_head: recovery.initial_head,
            expected_head: recovery.final_head,
            expected_head_branch: recovery.final_branch,
            mode: ResetMode::Mixed,
            rollback_id,
        })
        .expect("mixed reset rollback");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), initial);
    assert_eq!(r.read("a.txt"), "local worktree\n");
    assert_eq!(r.read("staged.txt"), "staged\n");
    assert_eq!(r.read("untracked.txt"), "untracked\n");
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .contains("staged.txt"));
    assert_eq!(
        r.git(&[
            "status",
            "--porcelain=v1",
            "--ignored",
            "--untracked-files=all"
        ]),
        status_before
    );
    assert!(!r.path.join(".git/arbor-reset-rollback").exists());
}

#[test]
fn reset_recovery_restores_force_hard_scene_and_ignored_files() {
    let r = TestRepo::new();
    common::git(&r.path, &["config", "core.excludesfile", ""]);
    r.write(".gitignore", "ignored.txt\n");
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    let initial = common::commit(&r.path, "a.txt", "current\n", "current");
    r.write("a.txt", "local\n");
    r.write("untracked.txt", "untracked\n");
    r.write("ignored.txt", "ignored\n");

    let recovery = r
        .open()
        .reset_with_recovery(
            target.clone(),
            ResetMode::Hard,
            LocalChangesSavePolicy::Stash,
            false,
            true,
        )
        .expect("force hard reset with recovery");
    assert_eq!(r.read("a.txt"), "base\n");

    r.open()
        .rollback_reset_recovery(ResetRecoveryTarget {
            root_path: r.path.display().to_string(),
            display_name: "repo".into(),
            initial_head: recovery.initial_head,
            expected_head: recovery.final_head,
            expected_head_branch: recovery.final_branch,
            mode: ResetMode::Hard,
            rollback_id: recovery.rollback_id.expect("undo marker"),
        })
        .expect("hard reset rollback");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), initial);
    assert_eq!(r.read("a.txt"), "local\n");
    assert_eq!(r.read("untracked.txt"), "untracked\n");
    assert_eq!(r.read("ignored.txt"), "ignored\n");
    assert!(r.path.join(".git/arbor-reset-rollback").exists() == false);
}

#[test]
fn reset_recovery_refuses_a_changed_post_scene_without_mutation() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    common::commit(&r.path, "a.txt", "current\n", "current");
    let recovery = r
        .open()
        .reset_with_recovery(
            target.clone(),
            ResetMode::Mixed,
            LocalChangesSavePolicy::Stash,
            false,
            false,
        )
        .expect("mixed reset with recovery");
    r.write("a.txt", "changed after reset\n");
    let error = r
        .open()
        .rollback_reset_recovery(ResetRecoveryTarget {
            root_path: r.path.display().to_string(),
            display_name: "repo".into(),
            initial_head: recovery.initial_head,
            expected_head: recovery.final_head.clone(),
            expected_head_branch: recovery.final_branch,
            mode: ResetMode::Mixed,
            rollback_id: recovery.rollback_id.expect("undo marker"),
        })
        .expect_err("changed post-reset scene must fail closed");
    assert!(
        error.to_string().contains("changed after the reset")
            || error.to_string().contains("index or worktree")
    );
    assert_eq!(r.git(&["rev-parse", "HEAD"]), recovery.final_head);
}

#[test]
fn reset_recovery_keep_releases_snapshot_without_changing_result() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    let initial = common::commit(&r.path, "a.txt", "current\n", "current");
    r.write("a.txt", "local\n");
    r.write("untracked.txt", "keep me\n");

    let recovery = r
        .open()
        .reset_with_recovery(
            target.clone(),
            ResetMode::Mixed,
            LocalChangesSavePolicy::Stash,
            false,
            false,
        )
        .expect("reset with recovery");
    let rollback_id = recovery.rollback_id.clone().expect("undo marker");
    r.open()
        .keep_reset_recovery(ResetRecoveryTarget {
            root_path: r.path.display().to_string(),
            display_name: "repo".into(),
            initial_head: recovery.initial_head,
            expected_head: recovery.final_head,
            expected_head_branch: recovery.final_branch,
            mode: ResetMode::Mixed,
            rollback_id,
        })
        .expect("keep reset result");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), target);
    assert_eq!(r.read("a.txt"), "local\n");
    assert_eq!(r.read("untracked.txt"), "keep me\n");
    assert!(!r.path.join(".git/arbor-reset-rollback").exists());

    let next = r
        .open()
        .reset_with_recovery(
            initial,
            ResetMode::Mixed,
            LocalChangesSavePolicy::Stash,
            false,
            false,
        )
        .expect("a later reset is not blocked by a kept result");
    assert!(next.rollback_id.is_some());
}

#[test]
fn reset_recovery_preserves_existing_user_stash_stack() {
    let r = TestRepo::new();
    let target = common::commit(&r.path, "a.txt", "base\n", "target");
    let initial = common::commit(&r.path, "a.txt", "current\n", "current");
    r.write("a.txt", "user stash\n");
    common::git(&r.path, &["stash", "push", "-u", "-m", "user stash"]);
    r.write("a.txt", "local after stash\n");

    let recovery = r
        .open()
        .reset_with_recovery(
            target,
            ResetMode::Mixed,
            LocalChangesSavePolicy::Stash,
            false,
            false,
        )
        .expect("reset with recovery");
    assert!(r.git(&["stash", "list"]).contains("user stash"));

    r.open()
        .rollback_reset_recovery(ResetRecoveryTarget {
            root_path: r.path.display().to_string(),
            display_name: "repo".into(),
            initial_head: recovery.initial_head,
            expected_head: recovery.final_head,
            expected_head_branch: recovery.final_branch,
            mode: ResetMode::Mixed,
            rollback_id: recovery.rollback_id.expect("undo marker"),
        })
        .expect("reset rollback");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), initial);
    assert_eq!(r.read("a.txt"), "local after stash\n");
    assert!(r.git(&["stash", "list"]).contains("user stash"));
}

#[test]
fn restore_file_restores_deleted_file_from_head() {
    let r = TestRepo::new();
    common::commit(&r.path, "removed.txt", "restore me\n", "init");
    std::fs::remove_file(r.path.join("removed.txt")).unwrap();
    r.open().restore_file("removed.txt".into(), None).unwrap();
    assert_eq!(r.read("removed.txt"), "restore me\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn uncommit_moves_head_to_parent_and_keeps_changes_staged() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    let child = common::commit(&r.path, "a.txt", "two\n", "two");

    r.open().uncommit().unwrap();

    assert_eq!(r.git(&["rev-parse", "HEAD"]), parent);
    assert_ne!(child, parent);
    assert_eq!(r.read("a.txt"), "two\n");
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .contains("a.txt"));
}

#[test]
fn uncommit_allows_an_empty_head_commit() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    r.git(&["commit", "--allow-empty", "-q", "-m", "empty"]);
    let child = r.git(&["rev-parse", "HEAD"]);

    r.open().uncommit().unwrap();

    assert_eq!(r.git(&["rev-parse", "HEAD"]), parent);
    assert_ne!(child, parent);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn uncommit_supports_detached_head_and_keeps_changes_staged() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    let child = common::commit(&r.path, "a.txt", "two\n", "two");
    r.git(&["checkout", "-q", "--detach", &child]);

    r.open()
        .uncommit_expected_head(child.clone())
        .expect("detached HEAD should support soft uncommit");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), parent);
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .contains("a.txt"));
    assert!(
        common::git_allow_failure(&r.path, &["symbolic-ref", "-q", "--short", "HEAD"]).is_empty()
    );
}

#[test]
fn uncommit_rejects_a_stale_expected_head_without_mutating_head() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    let child = common::commit(&r.path, "a.txt", "two\n", "two");

    let error = r
        .open()
        .uncommit_expected_head(parent)
        .expect_err("stale expected HEAD must fail closed");
    assert!(
        matches!(error, EngineError::GitOperation { message } if message.contains("HEAD changed"))
    );
    assert_eq!(r.git(&["rev-parse", "HEAD"]), child);
}

#[test]
fn undo_uncommit_restores_original_head_without_rewriting_local_scene() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    let child = common::commit(&r.path, "a.txt", "two\n", "two");

    let repo = r.open();
    repo.uncommit_expected_head(child.clone()).unwrap();
    r.write("local.txt", "created after uncommit\n");

    repo.undo_uncommit_expected_head(child.clone(), parent.clone(), "main".into())
        .expect("undo should only move the branch ref");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), child);
    assert_eq!(r.read("a.txt"), "two\n");
    assert_eq!(r.read("local.txt"), "created after uncommit\n");
    assert!(r.git(&["diff", "--cached", "--name-only"]).is_empty());
    assert!(r.git(&["status", "--porcelain"]).contains("?? local.txt"));
}

#[test]
fn undo_uncommit_fails_closed_when_branch_identity_changed() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    let child = common::commit(&r.path, "a.txt", "two\n", "two");

    let repo = r.open();
    repo.uncommit_expected_head(child.clone()).unwrap();
    r.git(&["switch", "-q", "-c", "other"]);

    let error = repo
        .undo_uncommit_expected_head(child, parent.clone(), "main".into())
        .expect_err("a stale branch-scoped action must not move another branch");
    assert!(error.to_string().contains("branch changed"));
    assert_eq!(r.git(&["rev-parse", "HEAD"]), parent);
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "other");
}

#[test]
fn undo_uncommit_restores_detached_head_with_empty_branch_identity() {
    let r = TestRepo::new();
    let parent = common::commit(&r.path, "a.txt", "one\n", "one");
    let child = common::commit(&r.path, "a.txt", "two\n", "two");
    r.git(&["checkout", "-q", "--detach", &child]);

    let repo = r.open();
    repo.uncommit_expected_head(child.clone()).unwrap();
    repo.undo_uncommit_expected_head(child.clone(), parent, "".into())
        .expect("detached undo should use an empty branch identity");

    assert_eq!(r.git(&["rev-parse", "HEAD"]), child);
    assert!(
        common::git_allow_failure(&r.path, &["symbolic-ref", "-q", "--short", "HEAD"]).is_empty()
    );
}

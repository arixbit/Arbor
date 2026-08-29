//! Log multi-selection: direct IntelliJ-style Drop Commits execution.

mod common;

use common::TestRepo;

#[test]
fn drops_non_contiguous_linear_commits_without_opening_a_todo_editor() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    let dropped_a = common::commit(&repo_fixture.path, "a.txt", "a\n", "drop a");
    common::commit(&repo_fixture.path, "b.txt", "b\n", "keep b");
    let dropped_c = common::commit(&repo_fixture.path, "c.txt", "c\n", "drop c");
    common::commit(&repo_fixture.path, "d.txt", "d\n", "keep d");

    let outcome = repo_fixture
        .open()
        .drop_selected_commits(vec![dropped_c, dropped_a])
        .expect("drop selected commits");

    assert!(!outcome.paused);
    assert!(!repo_fixture.exists("a.txt"));
    assert!(repo_fixture.exists("b.txt"));
    assert!(!repo_fixture.exists("c.txt"));
    assert!(repo_fixture.exists("d.txt"));
    assert_eq!(
        repo_fixture.git(&["log", "--format=%s", "--reverse"]),
        "base\nkeep b\nkeep d"
    );
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn direct_drop_preserves_staged_unstaged_and_untracked_local_changes() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    common::commit(&repo_fixture.path, "drop.txt", "committed\n", "drop");
    let keep = common::commit(&repo_fixture.path, "keep.txt", "keep\n", "keep");

    repo_fixture.write("base.txt", "staged local edit\n");
    repo_fixture.git(&["add", "base.txt"]);
    repo_fixture.write("keep.txt", "unstaged local edit\n");
    repo_fixture.write("scratch.txt", "untracked local file\n");

    let outcome = repo_fixture
        .open()
        .drop_selected_commits_with_policy(vec![keep], arbor_engine::LocalChangesSavePolicy::Stash)
        .expect("drop selected commit with local changes");

    assert!(!outcome.paused);
    assert_eq!(repo_fixture.read("base.txt"), "staged local edit\n");
    assert_eq!(repo_fixture.read("keep.txt"), "unstaged local edit\n");
    assert_eq!(repo_fixture.read("scratch.txt"), "untracked local file\n");
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.lines().any(|line| line.ends_with("base.txt")));
    assert!(status.lines().any(|line| line.ends_with("keep.txt")));
    assert!(status.lines().any(|line| line.ends_with("scratch.txt")));
    assert!(repo_fixture
        .open()
        .stash_list()
        .expect("stash list")
        .is_empty());
}

#[test]
fn cancelled_in_memory_drop_keeps_head_and_worktree_unchanged() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    let dropped = common::commit(&repo_fixture.path, "drop.txt", "drop\n", "drop");
    common::commit(&repo_fixture.path, "keep.txt", "keep\n", "keep");
    let original_head = repo_fixture.git(&["rev-parse", "HEAD"]);

    let cancel = arbor_engine::GitCancelHandle::new();
    cancel.cancel();
    let result = repo_fixture
        .open()
        .drop_selected_commits_with_policy_and_cancel(
            vec![dropped],
            arbor_engine::LocalChangesSavePolicy::Stash,
            cancel,
        );

    assert!(matches!(result, Err(arbor_engine::EngineError::Cancelled)));
    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), original_head);
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
    assert!(repo_fixture
        .open()
        .operation_state()
        .expect("operation state")
        .is_none());
}

#[test]
fn native_drop_retry_can_follow_an_aborted_in_memory_conflict() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "value.txt", "base\n", "base");
    let dropped = common::commit(&repo_fixture.path, "value.txt", "dropped\n", "drop");
    let kept = common::commit(&repo_fixture.path, "value.txt", "kept\n", "keep");

    repo_fixture.write("value.txt", "staged local edit\n");
    repo_fixture.git(&["add", "value.txt"]);
    repo_fixture.write("scratch.txt", "untracked local file\n");

    let repo = repo_fixture.open();
    let in_memory = repo
        .drop_selected_commits_with_policy(
            vec![dropped.clone()],
            arbor_engine::LocalChangesSavePolicy::Stash,
        )
        .expect("in-memory drop");
    assert_eq!(
        in_memory.pause_reason,
        Some(arbor_engine::RebasePauseReason::Conflict)
    );

    repo.rebase_abort().expect("abort in-memory drop");
    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), kept);
    assert_eq!(repo_fixture.read("value.txt"), "staged local edit\n");
    assert_eq!(repo_fixture.read("scratch.txt"), "untracked local file\n");
    assert!(repo_fixture
        .git(&["status", "--porcelain"])
        .lines()
        .any(|line| line.ends_with("value.txt")));

    let native = repo
        .drop_selected_commits_native_with_policy_and_cancel(
            vec![dropped],
            arbor_engine::LocalChangesSavePolicy::Stash,
            arbor_engine::GitCancelHandle::new(),
        )
        .expect("native drop retry");
    assert_eq!(
        native.pause_reason,
        Some(arbor_engine::RebasePauseReason::Conflict)
    );
    repo.rebase_abort().expect("abort native drop retry");
    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), kept);
    assert_eq!(repo_fixture.read("value.txt"), "staged local edit\n");
    assert_eq!(repo_fixture.read("scratch.txt"), "untracked local file\n");
    assert!(repo_fixture
        .git(&["status", "--porcelain"])
        .lines()
        .any(|line| line.ends_with("value.txt")));
}

#[test]
fn rejects_a_commit_outside_the_current_branch_history() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    repo_fixture.git(&["switch", "-q", "-c", "side"]);
    let side = common::commit(&repo_fixture.path, "side.txt", "side\n", "side");
    repo_fixture.git(&["switch", "-q", "main"]);
    common::commit(&repo_fixture.path, "main.txt", "main\n", "main");

    let error = repo_fixture
        .open()
        .drop_selected_commits(vec![side])
        .expect_err("side-branch commit must not be rewritten from main");
    assert!(error
        .to_string()
        .contains("not on the current branch history"));
}

#[test]
fn drops_the_root_commit_with_root_rebase() {
    let root_repo = TestRepo::new();
    let root = common::commit(&root_repo.path, "root.txt", "root\n", "root");
    common::commit(&root_repo.path, "main.txt", "main\n", "main");

    let outcome = root_repo
        .open()
        .drop_selected_commits(vec![root])
        .expect("root commit drop");
    assert!(!outcome.paused);
    assert!(!root_repo.exists("root.txt"));
    assert!(root_repo.exists("main.txt"));
    assert_eq!(root_repo.git(&["log", "--format=%s", "--reverse"]), "main");
    assert!(root_repo.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drops_a_commit_from_detached_head() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    let dropped = common::commit(&repo_fixture.path, "drop.txt", "drop\n", "drop");
    common::commit(&repo_fixture.path, "keep.txt", "keep\n", "keep");
    let detached_head = repo_fixture.git(&["rev-parse", "HEAD~1"]);
    repo_fixture.git(&["switch", "--detach", "-q", &detached_head]);

    let outcome = repo_fixture
        .open()
        .drop_selected_commits(vec![dropped])
        .expect("detached-head drop");

    assert!(!outcome.paused);
    assert!(repo_fixture.exists("base.txt"));
    assert!(!repo_fixture.exists("drop.txt"));
    assert!(!repo_fixture.exists("keep.txt"));
    assert_eq!(
        repo_fixture.git(&["log", "--format=%s", "--reverse"]),
        "base"
    );
    assert!(
        common::git_allow_failure(&repo_fixture.path, &["symbolic-ref", "-q", "HEAD"]).is_empty()
    );

    let rewritten_head = repo_fixture.git(&["rev-parse", "HEAD"]);
    repo_fixture
        .open()
        .undo_log_selected_changes_expected_head(
            detached_head,
            rewritten_head,
            "".into(),
            arbor_engine::LocalChangesSavePolicy::Stash,
        )
        .expect("detached-head drop undo");
    assert!(repo_fixture.exists("drop.txt"));
    assert_eq!(
        repo_fixture.git(&["log", "--format=%s", "--reverse"]),
        "base\ndrop"
    );
    assert!(
        common::git_allow_failure(&repo_fixture.path, &["symbolic-ref", "-q", "HEAD"]).is_empty()
    );
}

#[test]
fn rejects_merge_commits_in_the_rewrite_range() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "root.txt", "root\n", "root");
    common::commit(&repo_fixture.path, "main.txt", "main\n", "main");
    repo_fixture.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&repo_fixture.path, "feature.txt", "feature\n", "feature");
    repo_fixture.git(&["switch", "-q", "main"]);
    repo_fixture.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    let merge = repo_fixture.git(&["rev-parse", "HEAD"]);

    let merge_error = repo_fixture
        .open()
        .drop_selected_commits(vec![merge])
        .expect_err("merge commit must not be rewritten");
    assert!(merge_error.to_string().contains("merge commit"));
}

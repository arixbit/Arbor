//! v0.14 pull contract: upstream resolution, merge/rebase modes, dirty-tree
//! guard, and the explicit conflict -> finish_merge two-parent closeout.

mod common;

use std::path::Path;
use std::process::Command;

use arbor_engine::{
    ChangeKind, CredentialBroker, FetchTagsMode, GitCancelHandle, LocalChangesSavePolicy,
    MergeMode, PullOptions,
};
use common::TestRepo;

fn git_at(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git process");
    if !output.status.success() {
        panic!(
            "git {:?} failed ({}): {}",
            args,
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn configure_upstream(repo: &TestRepo, local: &str, remote_branch: &str) {
    repo.git(&["config", &format!("branch.{local}.remote"), "origin"]);
    repo.git(&[
        "config",
        &format!("branch.{local}.merge"),
        &format!("refs/heads/{remote_branch}"),
    ]);
}

#[test]
fn update_non_current_branch_fast_forwards_without_checkout() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "-u", "origin", "main"]);
    upstream.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&upstream.path, "feature.txt", "v1", "feature");
    upstream.git(&["push", "-q", "-u", "origin", "feature"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    local.git(&[
        "config",
        "remote.origin.fetch",
        "+refs/heads/main:refs/remotes/origin/main",
    ]);
    local.git(&["branch", "feature", "origin/feature"]);
    configure_upstream(&local, "feature", "feature");

    common::commit(&upstream.path, "feature.txt", "v2", "feature update");
    upstream.git(&["push", "-q", "origin", "feature"]);

    local.open().update_branch("feature".into()).unwrap();
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(local.read("base.txt"), "base");
    assert_eq!(
        local.git(&["rev-parse", "feature"]),
        local.git(&["rev-parse", "origin/feature"])
    );
    assert_eq!(local.git(&["show", "feature:feature.txt"]), "v2");
}

#[test]
fn update_non_current_branch_with_auth_and_cancel_fast_forwards_without_checkout() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "-u", "origin", "main"]);
    upstream.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&upstream.path, "feature.txt", "v1", "feature");
    upstream.git(&["push", "-q", "-u", "origin", "feature"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    local.git(&[
        "config",
        "remote.origin.fetch",
        "+refs/heads/main:refs/remotes/origin/main",
    ]);
    local.git(&["branch", "feature", "origin/feature"]);
    configure_upstream(&local, "feature", "feature");

    common::commit(&upstream.path, "feature.txt", "v2", "feature update");
    upstream.git(&["push", "-q", "origin", "feature"]);

    local
        .open()
        .update_branch_with_options_and_auth_and_cancel(
            "feature".into(),
            FetchTagsMode::Default,
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .unwrap();

    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(
        local.git(&["rev-parse", "feature"]),
        local.git(&["rev-parse", "origin/feature"])
    );
    assert_eq!(local.git(&["show", "feature:feature.txt"]), "v2");
}

#[test]
fn pull_non_current_branch_merges_into_selected_branch_without_checkout() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "-u", "origin", "main"]);
    upstream.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&upstream.path, "feature.txt", "v1", "feature");
    upstream.git(&["push", "-q", "-u", "origin", "feature"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    local.git(&["branch", "feature", "origin/feature"]);
    configure_upstream(&local, "feature", "feature");

    local.git(&["switch", "-q", "feature"]);
    common::commit(&local.path, "local.txt", "local", "local feature change");
    local.git(&["switch", "-q", "main"]);
    let current_head = local.git(&["rev-parse", "HEAD"]);

    upstream.git(&["switch", "-q", "feature"]);
    common::commit(
        &upstream.path,
        "remote.txt",
        "remote",
        "remote feature change",
    );
    upstream.git(&["push", "-q", "origin", "feature"]);

    let outcome = local.open().pull_branch("feature".into(), false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(local.git(&["rev-parse", "HEAD"]), current_head);
    assert_eq!(local.read("base.txt"), "base");
    assert_eq!(local.git(&["show", "feature:local.txt"]), "local");
    assert_eq!(local.git(&["show", "feature:remote.txt"]), "remote");
    assert_eq!(
        local
            .git(&["rev-list", "--parents", "-n", "1", "feature"])
            .split_whitespace()
            .count(),
        3
    );
}

#[test]
fn pull_non_current_branch_rebases_into_selected_branch_without_checkout() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "-u", "origin", "main"]);
    upstream.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&upstream.path, "feature.txt", "v1", "feature");
    upstream.git(&["push", "-q", "-u", "origin", "feature"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    local.git(&["branch", "feature", "origin/feature"]);
    configure_upstream(&local, "feature", "feature");
    local.git(&["switch", "-q", "feature"]);
    common::commit(&local.path, "local.txt", "local", "local feature change");
    local.git(&["switch", "-q", "main"]);
    let current_head = local.git(&["rev-parse", "HEAD"]);

    upstream.git(&["switch", "-q", "feature"]);
    common::commit(
        &upstream.path,
        "remote.txt",
        "remote",
        "remote feature change",
    );
    upstream.git(&["push", "-q", "origin", "feature"]);

    local.open().pull_branch("feature".into(), true).unwrap();
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(local.git(&["rev-parse", "HEAD"]), current_head);
    assert_eq!(local.git(&["show", "feature:local.txt"]), "local");
    assert_eq!(local.git(&["show", "feature:remote.txt"]), "remote");
    assert_eq!(
        local
            .git(&["rev-list", "--parents", "-n", "1", "feature"])
            .split_whitespace()
            .count(),
        2
    );
}

#[test]
fn pull_selected_remote_branch_into_current_branch() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "-u", "origin", "main"]);
    upstream.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&upstream.path, "feature.txt", "feature", "feature");
    upstream.git(&["push", "-q", "-u", "origin", "feature"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    let outcome = local
        .open()
        .pull_remote_branch("origin/feature".into(), false)
        .unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(local.read("feature.txt"), "feature");
}

#[test]
fn pull_with_auth_uses_broker_for_fetch_and_keeps_pull_semantics() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let broker = arbor_engine::CredentialBroker::new();
    let outcome = local.open().pull_with_auth(None, false, broker).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.read("remote.txt"), "remote");
}

fn remote_repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("remote tempdir");
    git_at(dir.path(), &["init", "--bare", "-q"]);
    dir
}

fn add_origin(repo: &TestRepo, remote: &tempfile::TempDir) {
    repo.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
}

fn seed_remote(repo: &TestRepo, remote: &tempfile::TempDir) {
    add_origin(repo, remote);
    repo.git(&["push", "-q", "-u", "origin", "main"]);
}

#[test]
fn pull_merge_creates_clean_two_parent_commit_from_merge_tree() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    common::commit(&local.path, "local.txt", "local", "local");
    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local.open().pull(None, false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.read("local.txt"), "local");
    assert_eq!(local.read("remote.txt"), "remote");
    assert!(local.git(&["status", "--porcelain"]).is_empty());
    assert_eq!(
        local
            .git(&["rev-list", "--parents", "-1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );
}

#[test]
fn pull_options_no_fast_forward_creates_explicit_merge_commit() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    common::commit(&local.path, "local.txt", "local", "local");
    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local
        .open()
        .pull_with_settings_and_auth_and_cancel(
            None,
            PullOptions {
                rebase: false,
                mode: MergeMode::NoFastForward,
                no_commit: false,
                no_verify: false,
            },
            FetchTagsMode::Default,
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .unwrap();
    assert!(outcome.conflicts.is_empty());
    assert!(outcome.completed);
    assert!(!outcome.squashed);
    assert_eq!(
        local
            .git(&["rev-list", "--parents", "-1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );
}

#[test]
fn pull_options_squash_no_commit_finishes_as_single_parent_commit() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    common::commit(&local.path, "local.txt", "local", "local");
    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let repo = local.open();
    let outcome = repo
        .pull_with_settings_and_auth_and_cancel(
            None,
            PullOptions {
                rebase: false,
                mode: MergeMode::Squash,
                no_commit: true,
                no_verify: false,
            },
            FetchTagsMode::Default,
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .unwrap();
    assert!(outcome.conflicts.is_empty());
    assert!(!outcome.completed);
    assert!(outcome.requires_finish);
    assert!(outcome.squashed);
    assert!(repo.merge_in_progress());

    repo.finish_merge(None).unwrap();
    assert_eq!(
        local
            .git(&["rev-list", "--parents", "-1", "HEAD"])
            .split_whitespace()
            .count(),
        2
    );
}

#[test]
fn pull_rebase_replays_local_commit_without_merge_commit() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    common::commit(&local.path, "local.txt", "local", "local");
    let old_local = local.git(&["rev-parse", "HEAD"]);
    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local.open().pull(None, true).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_ne!(local.git(&["rev-parse", "HEAD"]), old_local);
    assert_eq!(local.git(&["rev-list", "--merges", "--count", "HEAD"]), "0");
    assert_eq!(local.git(&["log", "-2", "--format=%s"]), "local\nremote");
    assert!(local.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn pull_resolves_upstream_when_local_and_remote_branch_names_differ() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "origin", "main:release"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin", "release"]);
    local.git(&["switch", "-q", "-c", "topic", "--track", "origin/release"]);
    configure_upstream(&local, "topic", "release");
    common::commit(&upstream.path, "release.txt", "release", "release");
    upstream.git(&["push", "-q", "origin", "main:release"]);

    let outcome = local.open().pull(None, false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.read("release.txt"), "release");
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "topic");
}

#[test]
fn current_branch_update_keeps_local_and_remote_branch_names_distinct() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "origin", "main:release"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin", "release"]);
    local.git(&["switch", "-q", "-c", "topic", "--track", "origin/release"]);
    configure_upstream(&local, "topic", "release");

    common::commit(&upstream.path, "release.txt", "release", "release");
    upstream.git(&["push", "-q", "origin", "main:release"]);

    let result = arbor_engine::run_root_update_for_current_branch_with_options(
        local.path.to_string_lossy().into_owned(),
        "origin".into(),
        "topic".into(),
        "release".into(),
        false,
        FetchTagsMode::Default,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .unwrap();

    assert!(result.success);
    assert!(result.message.contains("origin/release"));
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "topic");
    assert_eq!(local.read("release.txt"), "release");
}

#[test]
fn pull_conflict_resolve_then_finish_merge_creates_two_parents() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "value.txt", "base\n", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");
    common::commit(&local.path, "value.txt", "local\n", "local");
    common::commit(&upstream.path, "value.txt", "remote\n", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let repo = local.open();
    let outcome = repo.pull(None, false).unwrap();
    assert_eq!(outcome.conflicts, vec!["value.txt"]);
    assert!(repo
        .status()
        .unwrap()
        .iter()
        .any(|entry| entry.staged == ChangeKind::Conflicted
            || entry.unstaged == ChangeKind::Conflicted));
    repo.resolve_edited("value.txt".into(), "resolved\n".into())
        .unwrap();
    let merge_id = repo.finish_merge(None).unwrap();
    assert_eq!(local.git(&["rev-parse", "HEAD"]), merge_id);
    assert_eq!(
        local
            .git(&["rev-list", "--parents", "-1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );
    assert!(local.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn pull_rebase_conflict_uses_rebase_continue_after_resolution() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "value.txt", "base\n", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");
    common::commit(&local.path, "value.txt", "local\n", "local");
    common::commit(&upstream.path, "value.txt", "remote\n", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let repo = local.open();
    let outcome = repo.pull(None, true).unwrap();
    assert_eq!(outcome.conflicts, vec!["value.txt"]);
    repo.resolve_edited("value.txt".into(), "resolved\n".into())
        .unwrap();
    let continued = repo.rebase_continue().unwrap();
    assert!(!continued.paused);
    assert_eq!(local.git(&["log", "-1", "--format=%s"]), "local");
    assert_eq!(local.git(&["rev-list", "--merges", "--count", "HEAD"]), "0");
    assert!(local.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn pull_rejects_dirty_tree_with_actionable_stash_guidance() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);
    let local = TestRepo::new();
    add_origin(&local, &remote);
    configure_upstream(&local, "main", "main");
    common::commit(&local.path, "base.txt", "base", "base");
    local.write("base.txt", "dirty");

    let error = local.open().pull(None, false).unwrap_err();
    let message = error.to_string();
    assert!(message.contains("clean worktree"));
    assert!(message.contains("stash"));
}

#[test]
fn pull_preserves_untracked_file_during_fast_forward() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    local.write("notes.txt", "keep me");
    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local.open().pull(None, false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.read("notes.txt"), "keep me");
    assert_eq!(local.read("remote.txt"), "remote");
    assert!(local
        .git(&["status", "--porcelain"])
        .contains("?? notes.txt"));
}

#[test]
fn pull_ignores_ignored_files_when_checking_dirty_tree() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    local.write(".gitignore", "build/\n");
    local.write("build/cache.db", "keep me");
    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local.open().pull(None, false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.read("build/cache.db"), "keep me");
    assert!(local
        .open()
        .status()
        .unwrap()
        .iter()
        .any(|entry| entry.path == "build/cache.db" && entry.unstaged == ChangeKind::Ignored));
}

#[test]
fn pull_rejects_untracked_file_when_fast_forward_would_overwrite_it() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    local.write("collision.txt", "local file");
    common::commit(&upstream.path, "collision.txt", "remote file", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let error = local.open().pull(None, false).unwrap_err();
    assert!(matches!(
        error,
        arbor_engine::EngineError::UntrackedWouldBeOverwritten { .. }
    ));
    assert_eq!(local.read("collision.txt"), "local file");
}

#[test]
fn pull_rejects_untracked_parent_file_when_remote_adds_nested_path() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    local.write("nested", "local file");
    let head_before = local.git(&["rev-parse", "HEAD"]);
    common::commit(&upstream.path, "nested/remote.txt", "remote file", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let error = local.open().pull(None, false).unwrap_err();
    assert!(matches!(
        error,
        arbor_engine::EngineError::UntrackedWouldBeOverwritten { .. }
    ));
    assert_eq!(local.read("nested"), "local file");
    assert_eq!(local.git(&["rev-parse", "HEAD"]), head_before);
}

#[test]
fn pull_rebase_rejects_untracked_file_when_remote_tree_would_overwrite_it() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    common::commit(&local.path, "local.txt", "local", "local");
    local.write("collision.txt", "local file");
    common::commit(&upstream.path, "collision.txt", "remote file", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let error = local.open().pull(None, true).unwrap_err();
    assert!(matches!(
        error,
        arbor_engine::EngineError::UntrackedWouldBeOverwritten { .. }
    ));
    assert_eq!(local.read("collision.txt"), "local file");
    assert_eq!(local.git(&["symbolic-ref", "--short", "HEAD"]), "main");
}

#[test]
fn pull_remote_branch_policy_restores_dirty_tracked_and_untracked_files() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");
    local.write("base.txt", "dirty local");
    local.write("notes.txt", "keep me");

    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local
        .open()
        .pull_remote_branch_with_settings_and_policy(
            "origin/main".into(),
            PullOptions {
                rebase: false,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            FetchTagsMode::Default,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            LocalChangesSavePolicy::Stash,
        )
        .unwrap();
    assert!(outcome.conflicts.is_empty());
    assert_eq!(local.read("base.txt"), "dirty local");
    assert_eq!(local.read("notes.txt"), "keep me");
    assert_eq!(local.read("remote.txt"), "remote");
    assert!(local
        .open()
        .apply_local_changes_restore_info()
        .unwrap()
        .is_none());
}

#[test]
fn pull_policy_restores_dirty_files_after_merge_conflict_is_finished() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "value.txt", "base\n", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");
    common::commit(&local.path, "value.txt", "local\n", "local");
    local.write("notes.txt", "keep me");
    common::commit(&upstream.path, "value.txt", "remote\n", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let repo = local.open();
    let outcome = repo
        .pull_with_settings_and_policy(
            None,
            PullOptions {
                rebase: false,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            FetchTagsMode::Default,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            LocalChangesSavePolicy::Shelve,
        )
        .unwrap();
    assert_eq!(outcome.conflicts, vec!["value.txt"]);
    assert_eq!(
        repo.apply_local_changes_restore_info()
            .unwrap()
            .map(|info| info.operation),
        Some("pull".into())
    );

    repo.resolve_edited("value.txt".into(), "resolved\n".into())
        .unwrap();
    repo.finish_merge(None).unwrap();
    assert_eq!(local.read("notes.txt"), "keep me");
    assert!(repo.apply_local_changes_restore_info().unwrap().is_none());
}

#[test]
fn pull_policy_restores_dirty_files_after_rebase_abort() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "value.txt", "base\n", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");
    common::commit(&local.path, "value.txt", "local\n", "local");
    local.write("notes.txt", "keep me");
    common::commit(&upstream.path, "value.txt", "remote\n", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let repo = local.open();
    let outcome = repo
        .pull_remote_branch_with_settings_and_policy(
            "origin/main".into(),
            PullOptions {
                rebase: true,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            FetchTagsMode::Default,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            LocalChangesSavePolicy::Stash,
        )
        .unwrap();
    assert_eq!(outcome.conflicts, vec!["value.txt"]);
    assert_eq!(
        repo.apply_local_changes_restore_info()
            .unwrap()
            .map(|info| info.operation),
        Some("pull".into())
    );

    repo.rebase_abort().unwrap();
    assert_eq!(local.read("notes.txt"), "keep me");
    assert!(repo.apply_local_changes_restore_info().unwrap().is_none());
}

#[test]
fn pull_materializes_file_to_directory_type_change() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "module", "old file", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    std::fs::remove_file(upstream.path.join("module")).unwrap();
    common::commit(&upstream.path, "module/child.txt", "new file", "directory");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local.open().pull(None, false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert!(local.path.join("module").is_dir());
    assert_eq!(local.read("module/child.txt"), "new file");
}

#[test]
fn pull_materializes_directory_to_file_type_change() {
    let remote = remote_repo();
    let upstream = TestRepo::new();
    common::commit(&upstream.path, "module/child.txt", "old file", "base");
    seed_remote(&upstream, &remote);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local, "main", "main");

    std::fs::remove_dir_all(upstream.path.join("module")).unwrap();
    common::commit(&upstream.path, "module", "new file", "file");
    upstream.git(&["push", "-q", "origin", "main"]);

    let outcome = local.open().pull(None, false).unwrap();
    assert!(outcome.conflicts.is_empty());
    assert!(local.path.join("module").is_file());
    assert_eq!(local.read("module"), "new file");
}

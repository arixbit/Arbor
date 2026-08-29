//! v0.16 remote-tracking refs：远程分支进入 log 数据，但不污染本地分支列表。

mod common;

use common::TestRepo;

use arbor_engine::{CredentialBroker, EngineError, GitCancelHandle};

#[test]
fn lists_remote_refs_and_preserves_ref_kinds_in_log() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    let commit_id = common::commit(&upstream.path, "README.md", "base", "base");
    upstream.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    upstream.git(&["push", "-q", "origin", "main"]);

    let local = TestRepo::new();
    local.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    local.git(&["tag", "v1"]);

    let repo = local.open();
    let remote_branches = repo.remote_branch_list().unwrap();
    let remote_main = remote_branches
        .iter()
        .find(|branch| branch.name == "origin/main")
        .expect("origin/main remote branch");
    assert_eq!(remote_main.short_id, &commit_id[..7]);

    let ref_snapshot = repo.ref_tip_snapshot().unwrap();
    assert!(ref_snapshot.iter().any(|value| {
        value.starts_with("local\u{1f}main\u{1f}")
            && value.ends_with(&format!("\u{1f}{commit_id}\u{1f}true"))
    }));
    assert!(ref_snapshot.iter().any(|value| {
        value.starts_with("remote\u{1f}origin/main\u{1f}origin\u{1f}")
            && value.ends_with(&format!("\u{1f}{commit_id}"))
    }));
    assert!(ref_snapshot.iter().any(|value| {
        value.starts_with("tag\u{1f}v1\u{1f}")
            && value.ends_with(&format!("\u{1f}{commit_id}\u{1f}true"))
    }));

    let local_branches = repo.branch_list().unwrap();
    assert!(local_branches
        .iter()
        .all(|branch| branch.name != "origin/main"));

    let commit = repo
        .log(None, 10, false, None)
        .unwrap()
        .first()
        .unwrap()
        .clone();
    assert!(commit.refs.iter().any(|reference| reference == "main"));
    assert!(commit.tag_refs.iter().any(|reference| reference == "v1"));
    assert!(commit
        .remote_refs
        .iter()
        .any(|reference| reference == "origin/main"));
}

#[test]
fn fetch_updates_remote_refs_without_a_configured_committer() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    let commit_id = common::commit(&upstream.path, "README.md", "base", "base");
    upstream.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    upstream.git(&["push", "-q", "origin", "main"]);

    let local = TestRepo::new();
    local.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    local.git(&["config", "--local", "--unset-all", "user.name"]);
    local.git(&["config", "--local", "--unset-all", "user.email"]);

    let outcome = local
        .open()
        .fetch(Some("origin".into()))
        .expect("fetch should not require commit identity");
    assert!(outcome
        .updated
        .iter()
        .any(|ref_name| ref_name == "origin/main"));
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/main"]),
        commit_id
    );
}

#[test]
fn fetch_with_auth_uses_system_git_and_refreshes_gix_refs() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    let commit_id = common::commit(&upstream.path, "README.md", "base", "base");
    upstream.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    upstream.git(&["push", "-q", "origin", "main"]);

    let local = TestRepo::new();
    local.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    let broker = CredentialBroker::new();
    let outcome = local
        .open()
        .fetch_with_auth(Some("origin".into()), broker)
        .expect("authenticated fetch");
    assert!(outcome.updated.iter().any(|name| name == "origin/main"));
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/main"]),
        commit_id
    );
}

#[test]
fn ls_remote_incoming_check_detects_unfetched_upstream_without_refreshing_refs() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    let base = common::commit(&upstream.path, "README.md", "base", "base");
    upstream.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    upstream.git(&["push", "-q", "origin", "main"]);

    let local = TestRepo::new();
    local.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    local.git(&["branch", "--set-upstream-to=origin/main", "main"]);
    assert_eq!(local.git(&["rev-parse", "refs/remotes/origin/main"]), base);

    let remote_tip = common::commit(&upstream.path, "README.md", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);

    let repo = local.open();
    let incoming = repo
        .remote_incoming_branches_with_auth_and_cancel(
            "origin".into(),
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .expect("ls-remote incoming check");
    assert_eq!(incoming, vec!["main"]);
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/main"]),
        base,
        "LS_REMOTE must not update local tracking refs"
    );
    assert_ne!(remote_tip, base);

    local.git(&["fetch", "-q", "origin"]);
    assert!(repo
        .remote_incoming_branches_with_auth_and_cancel(
            "origin".into(),
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .expect("clean ls-remote incoming check")
        .is_empty());
}

#[test]
fn fetch_remote_branch_updates_only_the_selected_remote_tracking_ref() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    let main_initial = common::commit(&upstream.path, "main.txt", "main-1", "main 1");
    upstream.git(&["remote", "add", "origin", remote.path().to_str().unwrap()]);
    upstream.git(&["push", "-q", "origin", "main"]);
    upstream.git(&["switch", "-c", "feature"]);
    let feature_initial = common::commit(&upstream.path, "feature.txt", "feature-1", "feature 1");
    upstream.git(&["push", "-q", "origin", "feature"]);

    let local = TestRepo::new();
    local.git(&["remote", "add", "origin", remote.path().to_str().unwrap()]);
    // The branch-popup action must still update the selected tracking ref when
    // the remote has a custom fetch mapping that excludes that branch.
    local.git(&[
        "config",
        "remote.origin.fetch",
        "+refs/heads/main:refs/remotes/origin/main",
    ]);
    local.git(&[
        "fetch",
        "-q",
        "origin",
        "refs/heads/main:refs/remotes/origin/main",
    ]);
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/main"]),
        main_initial
    );

    upstream.git(&["switch", "main"]);
    let main_updated = common::commit(&upstream.path, "main.txt", "main-2", "main 2");
    upstream.git(&["push", "-q", "origin", "main"]);
    upstream.git(&["switch", "feature"]);
    let feature_updated = common::commit(&upstream.path, "feature.txt", "feature-2", "feature 2");
    upstream.git(&["push", "-q", "origin", "feature"]);

    let outcome = local
        .open()
        .fetch_remote_branch("origin".into(), "origin/feature".into())
        .expect("fetch selected remote branch");
    assert!(outcome.updated.iter().any(|name| name == "origin/feature"));
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/feature"]),
        feature_updated
    );
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/main"]),
        main_initial
    );

    let feature_final = common::commit(&upstream.path, "feature.txt", "feature-3", "feature 3");
    upstream.git(&["push", "-q", "origin", "feature"]);
    let outcome = local
        .open()
        .fetch_remote_branch("origin".into(), "refs/heads/feature".into())
        .expect("fetch refs/heads remote branch");
    assert!(outcome.updated.iter().any(|name| name == "origin/feature"));
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/feature"]),
        feature_final
    );
    assert_eq!(
        local.git(&["rev-parse", "refs/remotes/origin/main"]),
        main_initial
    );
    assert_ne!(main_updated, main_initial);
    assert_ne!(feature_initial, feature_updated);
}

#[test]
fn prepare_add_commits_to_remote_branch_is_object_only_and_skips_existing_changes() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let repo_dir = TestRepo::new();
    common::commit(&repo_dir.path, "base.txt", "base", "base");
    repo_dir.git(&["remote", "add", "origin", remote.path().to_str().unwrap()]);
    repo_dir.git(&["push", "-q", "origin", "HEAD:main"]);
    repo_dir.git(&["fetch", "-q", "origin"]);
    repo_dir.git(&["switch", "-q", "-c", "feature"]);
    let first = common::commit(&repo_dir.path, "first.txt", "first", "first");
    let second = common::commit(&repo_dir.path, "second.txt", "second", "second");
    repo_dir.git(&["switch", "-q", "main"]);
    let head_before = repo_dir.git(&["rev-parse", "HEAD"]);
    let status_before = repo_dir.git(&["status", "--porcelain"]);

    let repo = repo_dir.open();
    let new_tip = repo
        .prepare_add_commits_to_remote_branch("origin".into(), "main".into(), vec![first, second])
        .unwrap()
        .expect("new remote tip");

    assert_eq!(repo_dir.git(&["rev-parse", "HEAD"]), head_before);
    assert_eq!(repo_dir.git(&["status", "--porcelain"]), status_before);
    assert_eq!(
        repo_dir.git(&["show", "-s", "--format=%s", &new_tip]),
        "second"
    );
    assert_eq!(
        repo_dir
            .git(&["show", "-s", "--format=%P", &new_tip])
            .split_whitespace()
            .count(),
        1
    );

    // Simulate the remote-tracking ref being refreshed to the tip just
    // prepared. The same source commits must then be treated as empty.
    repo_dir.git(&["update-ref", "refs/remotes/origin/main", &new_tip]);
    assert!(repo
        .prepare_add_commits_to_remote_branch(
            "origin".into(),
            "main".into(),
            vec![
                repo_dir.git(&["rev-parse", "feature~1"]),
                repo_dir.git(&["rev-parse", "feature"]),
            ],
        )
        .unwrap()
        .is_none());
}

#[test]
fn delete_remote_branch_removes_remote_and_tracking_refs() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let local = TestRepo::new();
    common::commit(&local.path, "README.md", "base", "base");
    let repo = local.open();
    repo.remote_add(
        "origin".into(),
        remote.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.push_refspec("origin".into(), "HEAD:refs/heads/feature".into(), false)
        .unwrap();
    local.git(&["fetch", "-q", "origin"]);
    assert!(repo
        .remote_branch_list()
        .unwrap()
        .iter()
        .any(|branch| branch.name == "origin/feature"));

    repo.delete_remote_branch_with_auth_and_cancel(
        "origin/feature".into(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("delete remote branch");
    assert!(!repo
        .remote_branch_list()
        .unwrap()
        .iter()
        .any(|branch| branch.name == "origin/feature"));
    let tracking_exists = std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/remotes/origin/feature",
        ])
        .current_dir(&local.path)
        .status()
        .unwrap()
        .success();
    assert!(!tracking_exists);
    let remote_exists = std::process::Command::new("git")
        .args(["show-ref", "--verify", "--quiet", "refs/heads/feature"])
        .current_dir(remote.path())
        .status()
        .unwrap()
        .success();
    assert!(!remote_exists);

    repo.push_refspec("origin".into(), "HEAD:refs/heads/stale".into(), false)
        .unwrap();
    local.git(&["fetch", "-q", "origin"]);
    common::git(remote.path(), &["update-ref", "-d", "refs/heads/stale"]);
    repo.delete_remote_branch("origin/stale".into())
        .expect("prune a remote branch deleted before confirmation");
    assert!(!repo
        .remote_branch_list()
        .unwrap()
        .iter()
        .any(|branch| branch.name == "origin/stale"));
}

#[cfg(unix)]
#[test]
fn remote_branch_delete_with_auth_cancellation_returns_cancelled() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    let r = TestRepo::new();
    let slow_ssh = r.path.join("slow-ssh.sh");
    std::fs::write(&slow_ssh, "#!/bin/sh\nsleep 30\n").unwrap();
    let mut permissions = std::fs::metadata(&slow_ssh).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&slow_ssh, permissions).unwrap();
    r.git(&[
        "config",
        "core.sshCommand",
        &format!("sh {}", slow_ssh.display()),
    ]);
    r.git(&[
        "remote",
        "add",
        "origin",
        "ssh://example.invalid/repository.git",
    ]);

    let repo = r.open();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.delete_remote_branch_with_auth_and_cancel(
            "origin/feature".into(),
            CredentialBroker::new(),
            worker_cancel,
        )
    });
    std::thread::sleep(Duration::from_millis(300));
    cancel.cancel();

    let result = worker.join().expect("remote branch delete worker");
    assert!(matches!(result, Err(EngineError::Cancelled)));
}

//! v0.16 configured upstream 的 ahead/behind 与 tracking ref 缺失状态。

mod common;

use arbor_engine::SyncStatus;
use common::TestRepo;

fn add_origin(repo: &TestRepo, remote: &tempfile::TempDir) {
    repo.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
}

fn configure_upstream(repo: &TestRepo) {
    repo.git(&["config", "branch.main.remote", "origin"]);
    repo.git(&["config", "branch.main.merge", "refs/heads/main"]);
}

fn find_main(statuses: &[SyncStatus]) -> &SyncStatus {
    statuses
        .iter()
        .find(|status| status.branch == "main")
        .expect("main sync status")
}

#[test]
fn reports_ahead_and_behind_against_remote_tracking_branch() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    common::commit(&upstream.path, "base.txt", "base", "base");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "-u", "origin", "main"]);

    let local = TestRepo::new();
    add_origin(&local, &remote);
    local.git(&["fetch", "-q", "origin"]);
    local.git(&["reset", "-q", "--hard", "origin/main"]);
    configure_upstream(&local);
    common::commit(&local.path, "local.txt", "local", "local");

    let first_statuses = local.open().sync_status().unwrap();
    let first = find_main(&first_statuses);
    assert_eq!(
        (first.ahead, first.behind, first.tracking_exists),
        (1, 0, true)
    );
    assert_eq!(first.upstream, "origin/main");

    common::commit(&upstream.path, "remote.txt", "remote", "remote");
    upstream.git(&["push", "-q", "origin", "main"]);
    local.git(&["fetch", "-q", "origin"]);

    let diverged_statuses = local.open().sync_status().unwrap();
    let diverged = find_main(&diverged_statuses);
    assert_eq!(
        (diverged.ahead, diverged.behind, diverged.tracking_exists),
        (1, 1, true)
    );
}

#[test]
fn reports_missing_tracking_ref_without_faking_counts() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    common::commit(&upstream.path, "release.txt", "release", "release");
    add_origin(&upstream, &remote);
    upstream.git(&["push", "-q", "origin", "main:release"]);

    let local = TestRepo::new();
    common::commit(&local.path, "local.txt", "local", "local");
    add_origin(&local, &remote);
    configure_upstream(&local);

    let statuses = local.open().sync_status().unwrap();
    let status = find_main(&statuses);
    assert_eq!(status.upstream, "origin/main");
    assert_eq!(
        (status.ahead, status.behind, status.tracking_exists),
        (0, 0, false)
    );
}

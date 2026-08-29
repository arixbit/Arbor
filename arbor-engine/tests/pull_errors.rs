//! v0.16 pull 错误应区分没有 upstream 与 tracking ref 缺失。

mod common;

use arbor_engine::EngineError;
use common::TestRepo;

#[test]
fn pull_without_upstream_returns_structured_error() {
    let local = TestRepo::new();
    common::commit(&local.path, "README.md", "base", "base");

    let error = local
        .open()
        .pull(None, false)
        .expect_err("pull should require upstream");
    match error {
        EngineError::NoUpstream { branch } => assert_eq!(branch, "main"),
        other => panic!("expected NoUpstream, got {other:?}"),
    }
}

#[test]
fn pull_with_missing_tracking_ref_returns_structured_error() {
    let remote = tempfile::tempdir().expect("remote tempdir");
    common::git(remote.path(), &["init", "--bare", "-q"]);

    let upstream = TestRepo::new();
    common::commit(&upstream.path, "release.txt", "release", "release");
    upstream.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    upstream.git(&["push", "-q", "origin", "main:release"]);

    let local = TestRepo::new();
    common::commit(&local.path, "local.txt", "local", "local");
    local.git(&[
        "remote",
        "add",
        "origin",
        remote.path().to_str().expect("remote path"),
    ]);
    local.git(&["config", "branch.main.remote", "origin"]);
    local.git(&["config", "branch.main.merge", "refs/heads/main"]);

    let error = local
        .open()
        .pull(None, false)
        .expect_err("tracking ref should be missing");
    match error {
        EngineError::TrackingMissing { branch, upstream } => {
            assert_eq!(branch, "main");
            assert_eq!(upstream, "origin/main");
        }
        other => panic!("expected TrackingMissing, got {other:?}"),
    }
}

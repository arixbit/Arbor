//! v0.5 commit-and-push 语义。

mod common;

use arbor_engine::{CredentialBroker, EngineError, PushFailureKind};
use common::TestRepo;

#[test]
fn gix_commit_paths_apply_commit_cleanup_and_comment_char() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let repo = r.open();

    r.write("strip.txt", "strip");
    repo.stage("strip.txt".into()).unwrap();
    r.git(&["config", "commit.cleanup", "strip"]);
    r.git(&["config", "core.commentChar", ";"]);
    let stripped = repo
        .commit("\n subject  \n; remove\n# keep\n\nbody  \n".into(), false)
        .unwrap();
    assert_eq!(
        common::raw_commit_message(&r.path, &stripped),
        " subject\n# keep\n\nbody\n"
    );

    r.write("space.txt", "space");
    repo.stage("space.txt".into()).unwrap();
    r.git(&["config", "commit.cleanup", "whitespace"]);
    let whitespace = repo
        .commit("\n first  \n\n\nsecond \n# keep\n".into(), false)
        .unwrap();
    assert_eq!(
        common::raw_commit_message(&r.path, &whitespace),
        " first\n\nsecond\n# keep\n"
    );

    r.write("verbatim.txt", "verbatim");
    repo.stage("verbatim.txt".into()).unwrap();
    r.git(&["config", "commit.cleanup", "verbatim"]);
    let verbatim_message = "  keep  \n# keep\n\n";
    let verbatim = repo.commit(verbatim_message.to_string(), false).unwrap();
    assert_eq!(
        common::raw_commit_message(&r.path, &verbatim),
        verbatim_message
    );
}

#[test]
fn commit_and_push_round_trip_and_no_remote() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    r.write("next.txt", "next");
    repo.stage("next.txt".into()).unwrap();
    let outcome = repo
        .commit_and_push("next".into(), None, None, false, true)
        .unwrap();
    assert!(outcome.pushed);
    assert_eq!(
        common::git(remote_dir.path(), &["rev-parse", "refs/heads/main"]),
        outcome.commit_id
    );

    let local = TestRepo::new();
    common::commit(&local.path, "base.txt", "base", "base");
    local.write("only-local.txt", "local");
    let local_repo = local.open();
    local_repo.stage("only-local.txt".into()).unwrap();
    let outcome = local_repo
        .commit_and_push("local".into(), None, None, false, true)
        .unwrap();
    assert!(!outcome.pushed);
    assert_eq!(local.git(&["log", "-1", "--format=%s"]), "local");
}

#[test]
fn push_rejected_is_structured_as_non_fast_forward() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.push_with_options(None, "main".into(), false, true)
        .unwrap();

    let clone_dir = tempfile::tempdir().unwrap();
    common::git(
        clone_dir.path(),
        &[
            "clone",
            remote_dir.path().to_string_lossy().as_ref(),
            "other",
        ],
    );
    let other = clone_dir.path().join("other");
    common::git(&other, &["config", "user.name", "Other"]);
    common::git(&other, &["config", "user.email", "other@arbor.local"]);
    common::commit(&other, "remote.txt", "remote", "remote");
    common::git(&other, &["push", "origin", "main"]);

    common::commit(&r.path, "local.txt", "local", "local");
    let error = repo
        .push_with_options(None, "main".into(), false, false)
        .unwrap_err();
    match error {
        EngineError::PushRejected { kind, .. } => assert_eq!(kind, PushFailureKind::NonFastForward),
        other => panic!("expected structured push rejection, got {other:?}"),
    }
}

#[test]
fn push_refspec_can_publish_head_to_a_selected_target() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();

    repo.push_refspec("origin".into(), "HEAD:refs/heads/release".into(), false)
        .unwrap();
    assert_eq!(
        common::git(remote_dir.path(), &["rev-parse", "refs/heads/release"]),
        r.git(&["rev-parse", "HEAD"])
    );
}

#[test]
fn push_refspec_can_publish_a_detached_commit_to_a_selected_target() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    r.git(&["checkout", "-q", "feature"]);
    let detached_commit = common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["branch", "-D", "feature"]);

    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();

    repo.push_refspec(
        "origin".into(),
        format!("{detached_commit}:refs/heads/release").into(),
        false,
    )
    .unwrap();
    assert_eq!(
        common::git(remote_dir.path(), &["rev-parse", "refs/heads/release"]),
        detached_commit
    );
}

#[test]
fn commit_and_push_with_identity_preserves_author_committer_and_signoff() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    r.write("identity.txt", "identity");
    repo.stage("identity.txt".into()).unwrap();

    let outcome = repo
        .commit_and_push_with_identity(
            "identity commit".into(),
            Some("origin".into()),
            Some("main".into()),
            false,
            true,
            true,
            Some("Author Name".into()),
            Some("author@arbor.local".into()),
            Some("Committer Name".into()),
            Some("committer@arbor.local".into()),
            None,
            true,
            vec!["Co Author <coauthor@arbor.local>".into()],
        )
        .unwrap();

    assert!(outcome.pushed);
    let metadata = r.git(&[
        "show",
        "-s",
        "--format=%an <%ae>|%cn <%ce>|%B",
        &outcome.commit_id,
    ]);
    assert!(metadata.contains("Author Name <author@arbor.local>"));
    assert!(metadata.contains("Committer Name <committer@arbor.local>"));
    assert!(metadata.contains("Signed-off-by: Committer Name <committer@arbor.local>"));
    assert!(metadata.contains("Co-authored-by: Co Author <coauthor@arbor.local>"));
    assert_eq!(
        common::git(remote_dir.path(), &["rev-parse", "refs/heads/main"]),
        outcome.commit_id
    );
}

#[test]
fn authenticated_commit_push_and_refspec_use_the_remote_path() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    r.write("authenticated.txt", "authenticated");
    repo.stage("authenticated.txt".into()).unwrap();

    let broker = CredentialBroker::new();
    let outcome = repo
        .commit_and_push_with_options_with_auth(
            "authenticated commit".into(),
            Some("origin".into()),
            Some("main".into()),
            false,
            false,
            true,
            true,
            broker.clone(),
        )
        .unwrap();

    assert!(outcome.pushed);
    repo.push_refspec_with_auth(
        "origin".into(),
        "HEAD:refs/heads/release".into(),
        false,
        false,
        broker,
    )
    .unwrap();
    assert_eq!(
        common::git(remote_dir.path(), &["rev-parse", "refs/heads/release"]),
        outcome.commit_id
    );
}

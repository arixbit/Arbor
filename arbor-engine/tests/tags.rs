//! v0.4 tag CRUD + file remote push。

mod common;

use arbor_engine::{CredentialBroker, EngineError, GitCancelHandle, TagKind};
use common::TestRepo;

#[test]
fn create_delete_restore_and_push_tag() {
    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.tag_create("v1".into(), Some(commit.clone())).unwrap();
    let tags = repo.tag_list().unwrap();
    assert_eq!(tags.len(), 1);
    assert_eq!(tags[0].name, "v1");
    assert_eq!(tags[0].id, commit);
    assert_eq!(tags[0].kind, TagKind::Lightweight);
    assert!(tags[0].is_current);
    repo.tag_push(Some("origin".into()), "v1".into()).unwrap();
    let pushed = common::git(remote_dir.path(), &["show-ref", "--verify", "refs/tags/v1"]);
    assert!(!pushed.is_empty());
    repo.tag_delete("v1".into()).unwrap();
    assert!(repo.tag_list().unwrap().is_empty());
    repo.tag_create("v1".into(), Some(tags[0].id.clone()))
        .unwrap();
    assert_eq!(repo.tag_list().unwrap()[0].id, tags[0].id);
}

#[test]
fn authenticated_tag_push_uses_the_shared_push_path() {
    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.tag_create("v-auth".into(), Some(commit)).unwrap();

    repo.tag_push_with_auth_and_cancel(
        Some("origin".into()),
        "v-auth".into(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .unwrap();

    let pushed = common::git(
        remote_dir.path(),
        &["show-ref", "--verify", "refs/tags/v-auth"],
    );
    assert!(!pushed.is_empty());
}

#[test]
fn tag_push_rejects_invalid_tag_names_before_running_git() {
    let r = TestRepo::new();
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    let result = repo.tag_push(Some("origin".into()), "-bad".into());
    assert!(
        matches!(result, Err(EngineError::GitOperation { message }) if message == "invalid tag name")
    );
}

#[cfg(unix)]
#[test]
fn authenticated_tag_push_cancellation_returns_cancelled() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    r.open()
        .tag_create("v-cancel".into(), Some(commit))
        .unwrap();
    let slow_ssh = r.path.join("slow-ssh.sh");
    std::fs::write(&slow_ssh, "#!/bin/sh\nsleep 30\n").unwrap();
    std::fs::set_permissions(&slow_ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
    r.git(&[
        "config",
        "core.sshCommand",
        &format!("sh {}", slow_ssh.display()),
    ]);
    r.open()
        .remote_add(
            "origin".into(),
            "ssh://example.invalid/repository.git".into(),
        )
        .unwrap();

    let repo = r.open();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.tag_push_with_auth_and_cancel(
            Some("origin".into()),
            "v-cancel".into(),
            CredentialBroker::new(),
            worker_cancel,
        )
    });
    std::thread::sleep(Duration::from_millis(300));
    cancel.cancel();

    let result = worker.join().expect("tag push worker");
    assert!(matches!(result, Err(EngineError::Cancelled)));
}

#[test]
fn annotated_tag_keeps_message_and_target() {
    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    r.open()
        .tag_create_with_options("v2".into(), Some(commit.clone()), "Release v2".into(), None)
        .unwrap();
    let tags = r.open().tag_list().unwrap();
    assert_eq!(tags[0].kind, TagKind::Annotated);
    assert_eq!(tags[0].id, commit);
    let tag_object_id = common::git(&r.path, &["rev-parse", "refs/tags/v2"]);
    assert_ne!(tag_object_id, commit);
    assert_eq!(tags[0].object_id, tag_object_id);
    assert_eq!(tags[0].message, "Release v2");
    assert_eq!(tags[0].short_id, &commit[..7]);
}

#[test]
fn force_tag_update_requires_explicit_opt_in_and_replaces_target() {
    let r = TestRepo::new();
    let first = common::commit(&r.path, "a.txt", "a", "first");
    let second = common::commit(&r.path, "a.txt", "b", "second");
    let repo = r.open();

    repo.tag_create("release".into(), Some(first.clone()))
        .unwrap();
    let rejected = repo.tag_create("release".into(), Some(second.clone()));
    assert!(
        rejected.is_err(),
        "existing tags must stay protected by default"
    );

    repo.tag_create_with_force("release".into(), Some(second.clone()), true)
        .unwrap();
    let tag = repo
        .tag_list()
        .unwrap()
        .into_iter()
        .find(|tag| tag.name == "release")
        .expect("forced tag remains listed");
    assert_eq!(tag.kind, TagKind::Lightweight);
    assert_eq!(tag.id, second);
}

#[test]
fn force_annotated_tag_update_replaces_object_and_message() {
    let r = TestRepo::new();
    let first = common::commit(&r.path, "a.txt", "a", "first");
    let second = common::commit(&r.path, "a.txt", "b", "second");
    let repo = r.open();

    repo.tag_create_with_options("release".into(), Some(first), "first release".into(), None)
        .unwrap();
    repo.tag_create_with_options_and_force(
        "release".into(),
        Some(second.clone()),
        "second release".into(),
        None,
        true,
    )
    .unwrap();

    let tag = repo
        .tag_list()
        .unwrap()
        .into_iter()
        .find(|tag| tag.name == "release")
        .expect("forced annotated tag remains listed");
    assert_eq!(tag.kind, TagKind::Annotated);
    assert_eq!(tag.id, second);
    assert_eq!(tag.message, "second release");
}

#[test]
fn push_all_tags_refspec_publishes_every_local_tag() {
    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.tag_create("v1".into(), Some(commit.clone())).unwrap();
    repo.tag_create("v2".into(), Some(commit)).unwrap();

    repo.push_refspec("origin".into(), "refs/tags/*:refs/tags/*".into(), false)
        .unwrap();

    for tag in ["v1", "v2"] {
        let ref_name = format!("refs/tags/{tag}");
        let pushed = common::git(remote_dir.path(), &["show-ref", "--verify", &ref_name]);
        assert!(!pushed.is_empty(), "missing pushed tag {tag}");
    }
}

#[test]
fn remote_tag_list_reads_lightweight_and_annotated_tags() {
    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.tag_create("v-light".into(), Some(commit.clone()))
        .unwrap();
    repo.tag_create_with_options(
        "v-annotated".into(),
        Some(commit.clone()),
        "release".into(),
        None,
    )
    .unwrap();
    repo.tag_push(Some("origin".into()), "v-light".into())
        .unwrap();
    repo.tag_push(Some("origin".into()), "v-annotated".into())
        .unwrap();

    let tags = repo.remote_tag_list("origin".into()).unwrap();
    assert_eq!(
        tags.iter().map(|tag| tag.name.as_str()).collect::<Vec<_>>(),
        ["v-annotated", "v-light"]
    );
    let annotated = &tags[0];
    assert_eq!(annotated.remote, "origin");
    assert_eq!(annotated.kind, TagKind::Annotated);
    assert_eq!(annotated.id, commit);
    assert_ne!(annotated.object_id, annotated.id);
    assert_eq!(annotated.short_id, &annotated.id[..7]);
    let lightweight = &tags[1];
    assert_eq!(lightweight.kind, TagKind::Lightweight);
    assert_eq!(lightweight.object_id, lightweight.id);
}

#[cfg(unix)]
#[test]
fn remote_tag_list_with_auth_cancellation_returns_cancelled() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    let r = TestRepo::new();
    let slow_ssh = r.path.join("slow-ssh.sh");
    std::fs::write(&slow_ssh, "#!/bin/sh\nsleep 30\n").unwrap();
    let mut permissions = std::fs::metadata(&slow_ssh).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&slow_ssh, permissions).unwrap();
    let ssh_command = format!("sh {}", slow_ssh.display());
    r.git(&["config", "core.sshCommand", &ssh_command]);

    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        "ssh://example.invalid/repository.git".into(),
    )
    .unwrap();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.remote_tag_list_with_auth_and_cancel(
            "origin".into(),
            CredentialBroker::new(),
            worker_cancel,
        )
    });
    std::thread::sleep(Duration::from_millis(300));
    cancel.cancel();

    let result = worker.join().expect("remote tag list worker");
    assert!(matches!(result, Err(EngineError::Cancelled)));
}

#[cfg(unix)]
#[test]
fn remote_tag_delete_with_auth_lease_cancellation_returns_cancelled() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    let r = TestRepo::new();
    let slow_ssh = r.path.join("slow-ssh.sh");
    std::fs::write(&slow_ssh, "#!/bin/sh\nsleep 30\n").unwrap();
    let mut permissions = std::fs::metadata(&slow_ssh).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&slow_ssh, permissions).unwrap();
    let ssh_command = format!("sh {}", slow_ssh.display());
    r.git(&["config", "core.sshCommand", &ssh_command]);

    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        "ssh://example.invalid/repository.git".into(),
    )
    .unwrap();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.delete_remote_tag_with_auth_lease_and_cancel(
            "origin".into(),
            "v-cancel".into(),
            "0123456789012345678901234567890123456789".into(),
            CredentialBroker::new(),
            worker_cancel,
        )
    });
    std::thread::sleep(Duration::from_millis(300));
    cancel.cancel();

    let result = worker.join().expect("remote tag delete worker");
    assert!(matches!(result, Err(EngineError::Cancelled)));
}

#[test]
fn delete_remote_tag_is_lease_protected_and_idempotent() {
    let r = TestRepo::new();
    let commit = common::commit(&r.path, "a.txt", "a", "init");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.tag_create("v-delete".into(), Some(commit.clone()))
        .unwrap();
    repo.tag_create_with_options(
        "v-delete-annotated".into(),
        Some(commit),
        "release".into(),
        None,
    )
    .unwrap();
    repo.tag_push(Some("origin".into()), "v-delete".into())
        .unwrap();
    repo.tag_push(Some("origin".into()), "v-delete-annotated".into())
        .unwrap();

    assert!(repo
        .delete_remote_tag("origin".into(), "v-delete".into())
        .unwrap());
    let deleted = std::process::Command::new("git")
        .args(["show-ref", "--verify", "--quiet", "refs/tags/v-delete"])
        .current_dir(remote_dir.path())
        .status()
        .unwrap()
        .success();
    assert!(!deleted);
    let annotated = repo
        .tag_list()
        .unwrap()
        .into_iter()
        .find(|tag| tag.name == "v-delete-annotated")
        .unwrap();
    assert!(repo
        .delete_remote_tag_with_auth_lease(
            "origin".into(),
            "v-delete-annotated".into(),
            annotated.object_id,
            CredentialBroker::new(),
        )
        .unwrap());
    let annotated_deleted = std::process::Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            "refs/tags/v-delete-annotated",
        ])
        .current_dir(remote_dir.path())
        .status()
        .unwrap()
        .success();
    assert!(!annotated_deleted);
    assert!(!repo
        .delete_remote_tag("origin".into(), "v-delete".into())
        .unwrap());
}

#[test]
fn delete_remote_tag_with_auth_lease_rejects_stale_listed_object() {
    let r = TestRepo::new();
    let first_commit = common::commit(&r.path, "a.txt", "a", "init");
    let second_commit = common::commit(&r.path, "b.txt", "b", "second");
    let remote_dir = tempfile::tempdir().unwrap();
    common::git(remote_dir.path(), &["init", "--bare", "-q"]);
    let repo = r.open();
    repo.remote_add(
        "origin".into(),
        remote_dir.path().to_string_lossy().into_owned(),
    )
    .unwrap();
    repo.tag_create("v-stale".into(), Some(first_commit.clone()))
        .unwrap();
    repo.tag_push(Some("origin".into()), "v-stale".into())
        .unwrap();

    let listed = repo.remote_tag_list("origin".into()).unwrap();
    let listed = listed.iter().find(|tag| tag.name == "v-stale").unwrap();
    assert_eq!(listed.object_id, first_commit);

    let refspec = format!("{second_commit}:refs/heads/lease-object");
    common::git(
        &r.path,
        &[
            "push",
            remote_dir.path().to_string_lossy().as_ref(),
            refspec.as_str(),
        ],
    );
    common::git(
        remote_dir.path(),
        &["update-ref", "refs/tags/v-stale", &second_commit],
    );
    let broker = arbor_engine::CredentialBroker::new();
    let error = repo
        .delete_remote_tag_with_auth_lease(
            "origin".into(),
            "v-stale".into(),
            listed.object_id.clone(),
            broker,
        )
        .unwrap_err();
    assert!(error
        .to_string()
        .contains("remote tag changed before deletion"));

    let current = repo
        .remote_tag_list("origin".into())
        .unwrap()
        .into_iter()
        .find(|tag| tag.name == "v-stale")
        .unwrap();
    assert_eq!(current.object_id, second_commit);
}

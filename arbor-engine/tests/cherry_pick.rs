//! v0.4 cherry-pick：成功落提交，冲突不移动 HEAD。

mod common;

use arbor_engine::{
    CherryPickEmptyPolicy, EngineError, LocalChangesSavePolicy, OperationKind, OperationOrigin,
    RevertMainline,
};
use common::TestRepo;

#[test]
fn cherry_pick_success_and_conflict() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    r.git(&["config", "user.name", "Feature Author"]);
    r.git(&["config", "user.email", "feature@arbor.local"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    r.git(&["config", "user.name", "Arbor Test"]);
    r.git(&["config", "user.email", "test@arbor.local"]);
    common::commit(&r.path, "main.txt", "main", "main");
    let before = r.git(&["rev-parse", "HEAD"]);
    let new_id = r.open().cherry_pick(feature.clone()).unwrap();
    assert_ne!(new_id, before);
    assert_eq!(r.read("feature.txt"), "feature");
    let message = r.git(&["log", "-1", "--format=%B"]);
    // IntelliJ's ordinary cherry-pick uses Git's default message. The
    // optional protected-branch suffix is a separate setting and is not part
    // of this engine API.
    assert_eq!(message.trim(), "feature");
    assert_eq!(
        r.git(&["log", "-1", "--format=%an <%ae>"]),
        "Feature Author <feature@arbor.local>"
    );
    assert!(r.git(&["status", "--porcelain"]).is_empty());

    let conflict = TestRepo::new();
    common::commit(&conflict.path, "same.txt", "base", "base");
    conflict.git(&["switch", "-q", "-c", "feature"]);
    let conflict_commit = common::commit(&conflict.path, "same.txt", "feature", "feature");
    conflict.git(&["switch", "-q", "main"]);
    common::commit(&conflict.path, "same.txt", "main", "main");
    let head_before = conflict.git(&["rev-parse", "HEAD"]);
    let error = conflict.open().cherry_pick(conflict_commit).unwrap_err();
    assert!(error.to_string().contains("conflict"));
    assert_eq!(conflict.git(&["rev-parse", "HEAD"]), head_before);
    assert!(conflict.read("same.txt").contains("<<<<<<<"));
    let repo = conflict.open();
    let state = repo
        .operation_state()
        .expect("state")
        .expect("cherry-pick state");
    assert_eq!(state.kind, OperationKind::CherryPick);
    assert_eq!(state.origin, OperationOrigin::Git);
    repo.cherry_pick_abort().expect("abort cherry-pick");
    assert_eq!(conflict.read("same.txt"), "main");
    assert!(conflict.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn cherry_pick_many_uses_git_sequencer_for_ordered_commits() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["switch", "-q", "-c", "feature"]);
    let first = common::commit(&repo.path, "first.txt", "first", "first");
    let second = common::commit(&repo.path, "second.txt", "second", "second");
    repo.git(&["switch", "-q", "main"]);
    common::commit(&repo.path, "main.txt", "main", "main");

    let new_id = repo
        .open()
        .cherry_pick_many(vec![first, second])
        .expect("cherry-pick sequence");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), new_id);
    assert_eq!(repo.read("first.txt"), "first");
    assert_eq!(repo.read("second.txt"), "second");
    assert!(repo.git(&["status", "--porcelain"]).is_empty());

    let conflict = TestRepo::new();
    common::commit(&conflict.path, "same.txt", "base", "base");
    conflict.git(&["switch", "-q", "-c", "feature"]);
    let clean = common::commit(&conflict.path, "clean.txt", "clean", "clean");
    let conflicting = common::commit(&conflict.path, "same.txt", "feature", "conflicting");
    conflict.git(&["switch", "-q", "main"]);
    common::commit(&conflict.path, "same.txt", "main", "main");

    let error = conflict
        .open()
        .cherry_pick_many(vec![clean, conflicting])
        .unwrap_err();
    assert!(error.to_string().contains("conflict"));
    assert!(conflict.exists("clean.txt"));
    conflict.write("same.txt", "resolved");
    conflict.git(&["add", "same.txt"]);
    let repo = conflict.open();
    repo.cherry_pick_continue()
        .expect("continue remaining sequence");
    assert!(repo.operation_state().expect("state").is_none());
    assert_eq!(conflict.read("same.txt"), "resolved");
    assert!(conflict.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn cherry_pick_empty_policy_and_published_suffix_follow_options() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "same.txt", "base", "base");
    repo.git(&["switch", "-q", "-c", "source"]);
    let source = common::commit(&repo.path, "same.txt", "source", "source");
    repo.git(&["switch", "-q", "-c", "target", "HEAD~1"]);
    common::commit(&repo.path, "same.txt", "source", "target equivalent");
    let before = repo.git(&["rev-parse", "HEAD"]);

    assert!(!repo
        .open()
        .is_commit_reachable_from(source.clone(), before.clone())
        .expect("reachability"));
    let skipped = repo
        .open()
        .cherry_pick_many_with_options(vec![source.clone()], CherryPickEmptyPolicy::Skip, false)
        .expect("skip empty cherry-pick");
    assert_eq!(skipped, before);
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), before);

    let created = repo
        .open()
        .cherry_pick_many_with_options(
            vec![source.clone()],
            CherryPickEmptyPolicy::CreateEmpty,
            false,
        )
        .expect("create empty cherry-pick");
    assert_ne!(created, before);
    assert_eq!(repo.git(&["log", "-1", "--format=%B"]).trim(), "source");
    assert!(repo.git(&["status", "--porcelain"]).is_empty());

    let sequence = TestRepo::new();
    common::commit(&sequence.path, "same.txt", "base", "base");
    sequence.git(&["switch", "-q", "-c", "source"]);
    let empty_first = common::commit(&sequence.path, "same.txt", "source", "source");
    let non_empty_second = common::commit(&sequence.path, "later.txt", "later", "later");
    sequence.git(&["switch", "-q", "-c", "target", "HEAD~2"]);
    common::commit(&sequence.path, "same.txt", "source", "target equivalent");
    sequence
        .open()
        .cherry_pick_many_with_options(
            vec![empty_first.clone(), non_empty_second.clone()],
            CherryPickEmptyPolicy::CreateEmpty,
            false,
        )
        .expect("resolve an empty step and continue the sequence");
    assert_eq!(sequence.read("same.txt"), "source");
    assert_eq!(sequence.read("later.txt"), "later");
    assert!(sequence.git(&["status", "--porcelain"]).is_empty());

    let published = TestRepo::new();
    common::commit(&published.path, "same.txt", "base", "base");
    published.git(&["switch", "-q", "-c", "source"]);
    let published_source = common::commit(&published.path, "same.txt", "source", "source");
    published.git(&["update-ref", "refs/remotes/origin/main", &published_source]);
    published.git(&["switch", "-q", "-c", "target", "HEAD~1"]);
    let published_engine = published.open();
    assert!(published_engine
        .is_commit_reachable_from(published_source.clone(), "origin/main".into())
        .expect("published reachability"));
    published_engine
        .cherry_pick_many_with_options(
            vec![published_source.clone()],
            CherryPickEmptyPolicy::Skip,
            true,
        )
        .expect("cherry-pick with published suffix");
    let message = published.git(&["log", "-1", "--format=%B"]);
    assert!(message.contains(&format!("(cherry picked from commit {published_source})")));
    assert!(published.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn apply_operations_classify_overwrite_and_restore_saved_local_changes() {
    let blocked = TestRepo::new();
    common::commit(&blocked.path, "same.txt", "base", "base");
    blocked.git(&["switch", "-q", "-c", "source"]);
    let source = common::commit(&blocked.path, "same.txt", "source", "source");
    blocked.git(&["switch", "-q", "main"]);
    blocked.write("same.txt", "local");
    let error = blocked
        .open()
        .cherry_pick_many(vec![source])
        .expect_err("dirty worktree must be classified before cherry-pick");
    assert!(matches!(
        error,
        EngineError::LocalChangesWouldBeOverwritten { paths }
            if paths == vec!["same.txt".to_string()]
    ));

    let cherry = TestRepo::new();
    common::commit(&cherry.path, "base.txt", "base", "base");
    cherry.git(&["switch", "-q", "-c", "source"]);
    let cherry_source = common::commit(&cherry.path, "source.txt", "source", "source");
    cherry.git(&["switch", "-q", "main"]);
    cherry.write("local.txt", "local");
    cherry.git(&["add", "local.txt"]);
    let cherry_repo = cherry.open();
    cherry_repo
        .cherry_pick_many_with_options_and_policy(
            vec![cherry_source],
            CherryPickEmptyPolicy::Skip,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("cherry-pick should restore stashed local changes");
    assert_eq!(cherry.read("local.txt"), "local");
    let cherry_status = cherry.git(&["status", "--porcelain"]);
    assert!(cherry_status.starts_with("A  local.txt"));
    assert!(cherry.git(&["stash", "list"]).is_empty());
    assert!(!cherry.path.join(".git/arbor-apply-local-changes").exists());

    let revert = TestRepo::new();
    common::commit(&revert.path, "base.txt", "base", "base");
    common::commit(&revert.path, "changed.txt", "changed", "changed");
    let target = revert.git(&["rev-parse", "HEAD"]);
    revert.write("local.txt", "local");
    let revert_repo = revert.open();
    revert_repo
        .revert_many_with_policy(vec![target], None, LocalChangesSavePolicy::Shelve)
        .expect("revert should restore shelved local changes");
    assert_eq!(revert.read("local.txt"), "local");
    assert!(revert.git(&["status", "--porcelain"]).contains("local.txt"));
    assert!(revert.git(&["stash", "list"]).is_empty());
    assert!(revert_repo.shelve_list().expect("shelves").is_empty());
    assert!(!revert.path.join(".git/arbor-apply-local-changes").exists());
}

#[test]
fn revert_many_replays_newest_first_and_rejects_merge_without_mainline() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "same.txt", "base", "base");
    let first = common::commit(&repo.path, "same.txt", "first", "first");
    let second = common::commit(&repo.path, "same.txt", "second", "second");

    let new_id = repo
        .open()
        .revert_many(vec![second, first], None)
        .expect("revert selected commits");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), new_id);
    assert_eq!(repo.read("same.txt"), "base");

    let merge = TestRepo::new();
    common::commit(&merge.path, "base.txt", "base", "base");
    merge.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&merge.path, "feature.txt", "feature", "feature");
    merge.git(&["switch", "-q", "main"]);
    common::commit(&merge.path, "main.txt", "main", "main");
    merge.git(&["merge", "--no-edit", "--no-ff", "feature"]);
    let merge_id = merge.git(&["rev-parse", "HEAD"]);
    let error = merge
        .open()
        .revert_many(vec![merge_id.clone()], None)
        .unwrap_err();
    assert!(error.to_string().contains("explicit mainline"));
    assert_eq!(merge.git(&["rev-parse", "HEAD"]), merge_id);

    let reverted_merge = merge
        .open()
        .revert_many(vec![merge_id], Some(RevertMainline::First))
        .expect("revert merge with explicit mainline");
    assert_eq!(merge.git(&["rev-parse", "HEAD"]), reverted_merge);
    assert!(!merge.exists("feature.txt"));
    assert!(merge.exists("main.txt"));
}

#[test]
fn revert_many_skips_an_already_empty_inverse_change() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "same.txt", "base", "base");
    let changed = common::commit(&repo.path, "same.txt", "changed", "changed");
    common::commit(&repo.path, "same.txt", "base", "restore");
    let before = repo.git(&["rev-parse", "HEAD"]);

    let result = repo
        .open()
        .revert_many(vec![changed.clone()], None)
        .expect("empty inverse change is skipped");
    assert_eq!(result, before);
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), before);
    assert_eq!(repo.read("same.txt"), "base");
    assert!(repo.git(&["status", "--porcelain"]).is_empty());

    let later = common::commit(&repo.path, "later.txt", "later", "later");
    let sequence_result = repo
        .open()
        .revert_many(vec![changed, later], None)
        .expect("skip empty inverse and continue the sequence");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), sequence_result);
    assert!(!repo.exists("later.txt"));
    assert_eq!(repo.read("same.txt"), "base");
    assert!(repo.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn revert_conflict_from_engine_preserves_recoverable_state() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "same.txt", "base", "base");
    repo_fixture.write("same.txt", "first");
    repo_fixture.git(&["add", "same.txt"]);
    common::commit(&repo_fixture.path, "same.txt", "first", "first");
    repo_fixture.write("same.txt", "second");
    repo_fixture.git(&["add", "same.txt"]);
    common::commit(&repo_fixture.path, "same.txt", "second", "second");
    let first = repo_fixture.git(&["rev-parse", "HEAD~1"]);

    let repo = repo_fixture.open();
    let error = repo.revert(first).unwrap_err();
    assert!(error.to_string().contains("conflict"));
    let state = repo
        .operation_state()
        .expect("state")
        .expect("revert state");
    assert_eq!(state.kind, OperationKind::Revert);
    assert_eq!(state.origin, OperationOrigin::Git);
    repo.revert_abort().expect("abort revert");
    assert!(repo.operation_state().expect("state").is_none());
    assert_eq!(repo_fixture.read("same.txt"), "second");
}

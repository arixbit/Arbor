//! OPS-001:操作状态检测与恢复状态机的真实 git 回归。
//! 用系统 git 构造 MERGE_HEAD / CHERRY_PICK_HEAD / REVERT_HEAD / rebase-merge
//! 中断状态,验证检测(origin/backend/conflicts)与 continue/skip/abort 恢复。

mod common;

use arbor_engine::{OperationKind, OperationOrigin, RebaseBackend};
use common::TestRepo;

/// 三方冲突 fixture:base -> main/feature 各改同一行。
fn conflicted_pair(r: &TestRepo) {
    common::commit(&r.path, "file.txt", "line1\nbase\nline3", "base");
    r.git(&["branch", "feature"]);
    r.write("file.txt", "line1\nours\nline3");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("file.txt", "line1\ntheirs\nline3");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
}

#[test]
fn detects_and_aborts_system_merge() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    let out = common::git_allow_failure(&r.path, &["merge", "feature"]);
    assert!(out.contains("CONFLICT"), "expected conflict, got: {out}");

    let repo = r.open();
    let state = repo
        .operation_state()
        .expect("state")
        .expect("merge in progress");
    assert_eq!(state.kind, OperationKind::Merge);
    assert_eq!(state.origin, OperationOrigin::Git);
    assert_eq!(state.conflicted_files, vec!["file.txt".to_string()]);

    repo.merge_abort().expect("merge abort");
    assert!(repo.operation_state().expect("state").is_none());
    // abort 后工作区回到 ours,冲突 marker 被清掉
    assert!(r.read("file.txt").contains("ours"));
    assert!(!r.read("file.txt").contains("<<<<"));
}

#[test]
fn system_merge_conflict_continue_creates_merge_commit() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    // 解决冲突并 stage,然后走引擎的 merge_continue
    r.write("file.txt", "line1\nresolved\nline3");
    r.git(&["add", "file.txt"]);
    let repo = r.open();
    let head = repo.merge_continue(None).expect("merge continue");
    assert_eq!(head, r.git(&["rev-parse", "HEAD"]));
    assert!(repo.operation_state().expect("state").is_none());
    // 双父提交
    let parents = r.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(
        parents.split_whitespace().count(),
        3,
        "merge commit has two parents: {parents}"
    );
}

#[test]
fn detects_and_recovers_system_cherry_pick() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    let theirs = r.git(&["rev-parse", "feature"]);
    let out = common::git_allow_failure(&r.path, &["cherry-pick", &theirs]);
    assert!(out.contains("CONFLICT"), "expected conflict, got: {out}");

    let repo = r.open();
    let state = repo
        .operation_state()
        .expect("state")
        .expect("cherry-pick in progress");
    assert_eq!(state.kind, OperationKind::CherryPick);
    assert_eq!(state.origin, OperationOrigin::Git);
    assert_eq!(state.conflicted_files.len(), 1);

    // continue 前未解决 -> 失败但状态保留,用户可以再选 abort
    r.write("file.txt", "line1\npicked\nline3");
    r.git(&["add", "file.txt"]);
    repo.cherry_pick_continue().expect("cherry-pick continue");
    assert!(repo.operation_state().expect("state").is_none());
    assert!(r.read("file.txt").contains("picked"));
    let subject = r.git(&["log", "-1", "--format=%s"]);
    assert_eq!(subject, "theirs");
}

#[test]
fn cherry_pick_abort_restores_head() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    let theirs = r.git(&["rev-parse", "feature"]);
    common::git_allow_failure(&r.path, &["cherry-pick", &theirs]);
    let before = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    repo.cherry_pick_abort().expect("cherry-pick abort");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), before);
    assert!(repo.operation_state().expect("state").is_none());
}

#[test]
fn detects_and_recovers_system_revert() {
    let r = TestRepo::new();
    // c1: base->a; c2: a->b;revert c1 与 HEAD(b) 冲突
    common::commit(&r.path, "file.txt", "base", "init");
    r.write("file.txt", "a");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "c1"]);
    r.write("file.txt", "b");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "c2"]);
    let c1 = r.git(&["rev-parse", "HEAD~1"]);
    let out = common::git_allow_failure(&r.path, &["revert", &c1]);
    assert!(out.contains("CONFLICT"), "expected conflict, got: {out}");

    let repo = r.open();
    let state = repo
        .operation_state()
        .expect("state")
        .expect("revert in progress");
    assert_eq!(state.kind, OperationKind::Revert);
    assert_eq!(state.origin, OperationOrigin::Git);

    repo.revert_abort().expect("revert abort");
    assert!(repo.operation_state().expect("state").is_none());
    assert_eq!(r.read("file.txt"), "b");
}

#[test]
fn revert_conflict_continue_creates_revert_commit() {
    let r = TestRepo::new();
    common::commit(&r.path, "file.txt", "base", "init");
    r.write("file.txt", "a");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "c1"]);
    r.write("file.txt", "b");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "c2"]);
    let c1 = r.git(&["rev-parse", "HEAD~1"]);
    common::git_allow_failure(&r.path, &["revert", &c1]);

    r.write("file.txt", "base");
    r.git(&["add", "file.txt"]);
    let repo = r.open();
    repo.revert_continue().expect("revert continue");
    assert!(repo.operation_state().expect("state").is_none());
    let subject = r.git(&["log", "-1", "--format=%s"]);
    assert!(
        subject.starts_with("Revert"),
        "unexpected subject: {subject}"
    );
}

#[test]
fn failed_system_recovery_keeps_the_current_operation_state() {
    // A failed Continue must not consume CHERRY_PICK_HEAD. The UI can then
    // refresh the current conflict set and still offer Continue or Abort.
    let cherry_pick_repo = TestRepo::new();
    conflicted_pair(&cherry_pick_repo);
    let theirs = cherry_pick_repo.git(&["rev-parse", "feature"]);
    common::git_allow_failure(&cherry_pick_repo.path, &["cherry-pick", &theirs]);
    let repo = cherry_pick_repo.open();
    assert!(repo.cherry_pick_continue().is_err());
    let state = repo
        .operation_state()
        .expect("state")
        .expect("cherry-pick remains paused");
    assert_eq!(state.kind, OperationKind::CherryPick);
    assert_eq!(state.conflicted_files, vec!["file.txt".to_string()]);
    repo.cherry_pick_abort().expect("cherry-pick abort");

    // Revert uses the same native sequencer state contract.
    let revert_repo = TestRepo::new();
    common::commit(&revert_repo.path, "file.txt", "base", "init");
    revert_repo.write("file.txt", "a");
    revert_repo.git(&["add", "file.txt"]);
    revert_repo.git(&["commit", "-q", "-m", "c1"]);
    revert_repo.write("file.txt", "b");
    revert_repo.git(&["add", "file.txt"]);
    revert_repo.git(&["commit", "-q", "-m", "c2"]);
    let c1 = revert_repo.git(&["rev-parse", "HEAD~1"]);
    common::git_allow_failure(&revert_repo.path, &["revert", &c1]);
    let repo = revert_repo.open();
    assert!(repo.revert_continue().is_err());
    let state = repo
        .operation_state()
        .expect("state")
        .expect("revert remains paused");
    assert_eq!(state.kind, OperationKind::Revert);
    assert_eq!(state.conflicted_files, vec!["file.txt".to_string()]);
    repo.revert_abort().expect("revert abort");

    // Native rebase --continue also keeps the rebase metadata when conflicts
    // have not been resolved, so a later Skip/Abort remains valid.
    let rebase_repo = TestRepo::new();
    common::commit(&rebase_repo.path, "file.txt", "base", "init");
    rebase_repo.git(&["branch", "feature"]);
    rebase_repo.write("file.txt", "ours");
    rebase_repo.git(&["add", "file.txt"]);
    rebase_repo.git(&["commit", "-q", "-m", "ours"]);
    rebase_repo.git(&["checkout", "-q", "feature"]);
    rebase_repo.write("file.txt", "theirs");
    rebase_repo.git(&["add", "file.txt"]);
    rebase_repo.git(&["commit", "-q", "-m", "theirs"]);
    common::git_allow_failure(&rebase_repo.path, &["rebase", "main"]);
    let repo = rebase_repo.open();
    assert!(repo.rebase_continue().is_err());
    let state = repo
        .operation_state()
        .expect("state")
        .expect("rebase remains paused");
    assert_eq!(state.kind, OperationKind::Rebase);
    assert_eq!(state.conflicted_files, vec!["file.txt".to_string()]);
    repo.rebase_abort().expect("rebase abort");
}

#[test]
fn detects_system_rebase_merge_backend_and_skips() {
    let r = TestRepo::new();
    // main 和 feature 分叉,feature rebase main 冲突
    common::commit(&r.path, "file.txt", "base", "init");
    r.git(&["branch", "feature"]);
    r.write("file.txt", "ours");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("other.txt", "theirs\n");
    r.git(&["add", "other.txt"]);
    r.git(&["commit", "-q", "-m", "feature-1"]);
    r.write("file.txt", "theirs");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "feature-2"]);
    let out = common::git_allow_failure(&r.path, &["rebase", "main"]);
    assert!(out.contains("CONFLICT"), "expected conflict, got: {out}");

    let repo = r.open();
    let state = repo
        .operation_state()
        .expect("state")
        .expect("rebase in progress");
    assert_eq!(state.kind, OperationKind::Rebase);
    assert_eq!(state.origin, OperationOrigin::Git);
    assert_eq!(state.backend, Some(RebaseBackend::Merge));
    // 现代 git 的非交互 rebase 也走 merge backend 并写 interactive 文件,
    // 该字段只表示 todo 机制在用(见 opstate.rs 字段说明)。
    assert_eq!(state.original_branch.as_deref(), Some("refs/heads/feature"));
    assert!(state.onto.is_some());

    // skip:丢弃冲突的 feature-2,保留不冲突的 feature-1
    let outcome = repo.rebase_skip().expect("rebase skip");
    assert!(
        !outcome.paused,
        "rebase should finish after skip: {outcome:?}"
    );
    assert!(repo.operation_state().expect("state").is_none());
    // feature-1 的 other.txt 被带过来,feature-2 的 file.txt 改动被丢弃
    assert!(r.exists("other.txt"));
    assert_eq!(r.read("file.txt"), "ours");
    let subjects = r.git(&["log", "--format=%s", "main..HEAD"]);
    assert_eq!(subjects, "feature-1");
}

#[test]
fn detects_interactive_rebase_todo() {
    let r = TestRepo::new();
    common::commit(&r.path, "file.txt", "base", "init");
    r.git(&["branch", "feature"]);
    r.write("file.txt", "ours");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("file.txt", "theirs");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "feature-1"]);
    // GIT_SEQUENCE_EDITOR 保持 todo 原样 -> rebase 冲突暂停
    common::git_allow_failure(
        &r.path,
        &["-c", "sequence.editor=true", "rebase", "-i", "main"],
    );

    let repo = r.open();
    let state = repo
        .operation_state()
        .expect("state")
        .expect("rebase in progress");
    assert_eq!(state.backend, Some(RebaseBackend::Merge));
    assert!(state.interactive, "interactive file should exist");

    repo.rebase_abort().expect("rebase abort");
    assert!(repo.operation_state().expect("state").is_none());
}

#[test]
fn detects_engine_managed_merge_state() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    let repo = r.open();
    repo.merge("feature".into())
        .expect("engine merge conflicts");
    let state = repo
        .operation_state()
        .expect("state")
        .expect("engine merge state");
    assert_eq!(state.kind, OperationKind::Merge);
    assert_eq!(state.origin, OperationOrigin::Engine);

    // 应用"重启":重新打开仓库,状态仍可检测、仍可 abort
    let repo2 = r.open();
    let state2 = repo2
        .operation_state()
        .expect("state")
        .expect("state after reopen");
    assert_eq!(state2.kind, OperationKind::Merge);
    repo2.merge_abort().expect("engine merge abort");
    assert!(repo2.operation_state().expect("state").is_none());
    assert!(r.read("file.txt").contains("ours"));
}

#[test]
fn recovery_not_in_progress_is_a_clear_error() {
    let r = TestRepo::new();
    common::commit(&r.path, "file.txt", "base", "init");
    let repo = r.open();
    let err = repo.cherry_pick_continue().unwrap_err().to_string();
    assert!(
        err.contains("no cherry-pick in progress"),
        "unexpected: {err}"
    );
    let err = repo.revert_abort().unwrap_err().to_string();
    assert!(err.contains("no revert in progress"), "unexpected: {err}");
    let err = repo.merge_abort().unwrap_err().to_string();
    assert!(err.contains("no merge in progress"), "unexpected: {err}");
    let err = repo.rebase_skip().unwrap_err().to_string();
    assert!(err.contains("no rebase in progress"), "unexpected: {err}");
}

#[test]
fn clean_repo_has_no_operation_state() {
    let r = TestRepo::new();
    common::commit(&r.path, "file.txt", "base", "init");
    let repo = r.open();
    assert!(repo.operation_state().expect("state").is_none());
}

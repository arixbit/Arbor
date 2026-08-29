//! D1：merge 冲突 round-trip。
//! 构造冲突 fixture -> merge -> 断言 conflicts 列表 + conflict_file 的 base/ours/theirs。
//! 附带验证按块 resolve 后 status 不再冲突（v0.1 路径回归）。

mod common;

use std::os::unix::fs::PermissionsExt;

use arbor_engine::{
    BlockDecision, ChangeKind, EngineError, LocalChangesSavePolicy, MergeMode, MergeOptions,
    PickKind,
};

use common::TestRepo;

/// 构造文本冲突 -> merge 报冲突 -> conflict_file 三方内容正确 -> resolve(ours) 后干净。
#[test]
fn merge_conflict_and_resolve() {
    let r = TestRepo::new();
    // base：三方共同祖先
    common::commit(&r.path, "file.txt", "line1\nbase\nline3", "base");
    r.git(&["branch", "feature"]);

    // main 侧（ours）
    r.write("file.txt", "line1\nours\nline3");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);

    // feature 侧（theirs）
    r.git(&["checkout", "-q", "feature"]);
    r.write("file.txt", "line1\ntheirs\nline3");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo.merge("feature".into()).unwrap();
    assert_eq!(outcome.conflicts, vec!["file.txt".to_string()]);
    assert_eq!(repo.merge_source_reference().as_deref(), Some("feature"));

    // status 应显示冲突（gix 把冲突报在 unstaged 维度；UI 的 isConflicted 取并集）
    let st = repo.status().unwrap();
    let e = st.iter().find(|e| e.path == "file.txt").expect("file.txt");
    let conflicted = e.staged == ChangeKind::Conflicted || e.unstaged == ChangeKind::Conflicted;
    assert!(
        conflicted,
        "file.txt should be conflicted (staged={:?}, unstaged={:?})",
        e.staged, e.unstaged
    );

    // conflict_file 三方内容
    let cf = repo.conflict_file("file.txt".into()).unwrap();
    assert!(cf.base.contains("base"), "base should contain base line");
    assert!(cf.ours.contains("ours"), "ours should contain ours line");
    assert!(
        cf.theirs.contains("theirs"),
        "theirs should contain theirs line"
    );
    assert!(
        cf.result.contains("<<<<<<<")
            && cf.result.contains("=======")
            && cf.result.contains(">>>>>>>"),
        "result should contain conflict markers"
    );
    // 一个冲突块，两侧各一行
    assert_eq!(cf.blocks.len(), 1, "exactly one conflict block");
    assert_eq!(cf.blocks[0].ours_lines, vec!["ours".to_string()]);
    assert_eq!(cf.blocks[0].theirs_lines, vec!["theirs".to_string()]);

    // 按块接受 ours -> 工作区无 marker，status 不再冲突
    repo.resolve(
        "file.txt".into(),
        vec![BlockDecision {
            block_index: 0,
            pick: PickKind::Ours,
        }],
    )
    .unwrap();

    let resolved = repo.conflict_file("file.txt".into()).unwrap();
    assert!(
        !resolved.result.contains("<<<<<<<"),
        "no markers after resolve"
    );
    assert_eq!(r.read("file.txt"), "line1\nours\nline3");

    // git status 干净（stage 0，无 stages 1/2/3；内容 == HEAD）
    let clean = r.git(&["status", "--porcelain"]);
    assert!(
        clean.is_empty(),
        "git status should be clean after resolve, got: {clean}"
    );

    let merge_id = repo.finish_merge(None).unwrap();
    assert!(repo.merge_source_reference().is_none());
    let parents = r.git(&["rev-list", "--parents", "-n", "1", &merge_id]);
    assert_eq!(parents.split_whitespace().count(), 3);
}

/// 无冲突合并：fast-forward 之外的真合并但内容不冲突。
#[test]
fn merge_no_conflict() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "base");
    r.git(&["branch", "feature"]);

    // main 改 a.txt
    r.write("a.txt", "ours");
    r.git(&["add", "a.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);

    // feature 改不同文件 b.txt
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "b.txt", "theirs", "theirs");
    r.git(&["checkout", "-q", "main"]);

    let outcome = r.open().merge("feature".into()).unwrap();
    assert!(outcome.conflicts.is_empty(), "no conflicts expected");

    // 两侧改动都在工作区
    assert_eq!(r.read("a.txt"), "ours");
    assert_eq!(r.read("b.txt"), "theirs");
}

#[test]
fn smart_merge_classifies_overwrite_and_restores_stashed_changes() {
    let blocked = TestRepo::new();
    common::commit(&blocked.path, "same.txt", "base", "base");
    blocked.git(&["branch", "feature"]);
    blocked.git(&["checkout", "-q", "feature"]);
    common::commit(&blocked.path, "same.txt", "feature", "feature");
    blocked.git(&["checkout", "-q", "main"]);
    blocked.write("same.txt", "local");
    let error = blocked
        .open()
        .merge("feature".into())
        .expect_err("merge must classify local overwrite protection");
    assert!(matches!(
        error,
        EngineError::LocalChangesWouldBeOverwritten { paths }
            if paths == vec!["same.txt".to_string()]
    ));

    let restored = TestRepo::new();
    common::commit(&restored.path, "same.txt", "base\nkeep\n", "base");
    restored.git(&["branch", "feature"]);
    common::commit(&restored.path, "main.txt", "main", "main");
    restored.git(&["checkout", "-q", "feature"]);
    restored.write("same.txt", "feature\nkeep\n");
    restored.git(&["add", "same.txt"]);
    restored.git(&["commit", "-q", "-m", "feature"]);
    restored.git(&["checkout", "-q", "main"]);
    restored.write("same.txt", "base\nlocal\n");
    let repo = restored.open();
    let outcome = repo
        .merge_with_settings_and_policy(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("smart merge".into()),
                no_commit: false,
                no_verify: false,
                allow_unrelated_histories: false,
            },
            LocalChangesSavePolicy::Stash,
        )
        .expect("smart merge should restore local changes");
    assert!(outcome.completed);
    assert_eq!(restored.read("same.txt"), "feature\nlocal\n");
    assert!(restored
        .git(&["status", "--porcelain"])
        .contains("same.txt"));
    assert!(restored.git(&["stash", "list"]).is_empty());
    assert!(!restored
        .path
        .join(".git/arbor-apply-local-changes")
        .exists());
}

#[test]
fn smart_merge_shelf_is_restored_after_abort() {
    let r = TestRepo::new();
    common::commit(&r.path, "same.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "same.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "same.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);
    r.write("local.txt", "local");
    let repo = r.open();
    let outcome = repo
        .merge_with_settings_and_policy(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: None,
                no_commit: false,
                no_verify: false,
                allow_unrelated_histories: false,
            },
            LocalChangesSavePolicy::Shelve,
        )
        .expect("merge conflict should remain recoverable");
    assert!(!outcome.conflicts.is_empty());
    assert!(repo.merge_in_progress());
    repo.merge_abort().expect("abort should restore the Shelf");
    assert_eq!(r.read("local.txt"), "local");
    assert!(repo.shelve_list().expect("shelves").is_empty());
    assert!(!r.path.join(".git/arbor-apply-local-changes").exists());
}

#[test]
fn merge_default_fast_forwards_and_updates_worktree() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    let feature_head = r.git(&["rev-parse", "feature"]);
    r.git(&["checkout", "-q", "main"]);

    let outcome = r.open().merge("feature".into()).unwrap();
    assert!(outcome.completed);
    assert!(!outcome.requires_finish);
    assert_eq!(r.git(&["rev-parse", "HEAD"]), feature_head);
    assert_eq!(r.read("feature.txt"), "feature");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn merge_no_fast_forward_finishes_with_two_parents() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_options("feature".into(), MergeMode::NoFastForward)
        .unwrap();
    assert!(!outcome.completed);
    assert!(outcome.requires_finish);
    let merge_id = repo.finish_merge(None).unwrap();
    let parents = r.git(&["rev-list", "--parents", "-n", "1", &merge_id]);
    assert_eq!(parents.split_whitespace().count(), 3);
}

#[test]
fn merge_settings_auto_commits_with_custom_message() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_settings(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("custom merge message".into()),
                no_commit: false,
                no_verify: true,
                allow_unrelated_histories: false,
            },
        )
        .unwrap();

    assert!(outcome.completed);
    assert!(!outcome.requires_finish);
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "custom merge message");
    assert_eq!(
        r.git(&["rev-list", "--parents", "-n", "1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );
}

#[test]
fn merge_commit_tree_applies_repository_message_cleanup() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["config", "commit.cleanup", "strip"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_settings(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("\nsubject  \n# remove\n\nbody  \n".into()),
                no_commit: false,
                no_verify: true,
                allow_unrelated_histories: false,
            },
        )
        .expect("merge should complete");
    assert!(outcome.completed);
    let head = r.git(&["rev-parse", "HEAD"]);
    assert_eq!(
        common::raw_commit_message(&r.path, &head),
        "subject\n\nbody\n"
    );
}

#[test]
fn merge_settings_no_verify_controls_auto_commit_hooks() {
    fn make_repo() -> TestRepo {
        let r = TestRepo::new();
        common::commit(&r.path, "base.txt", "base", "base");
        r.git(&["branch", "feature"]);
        common::commit(&r.path, "main.txt", "main", "main");
        r.git(&["checkout", "-q", "feature"]);
        common::commit(&r.path, "feature.txt", "feature", "feature");
        r.git(&["checkout", "-q", "main"]);
        r
    }

    let r = make_repo();
    let hook = r.path.join(".git/hooks/pre-commit");
    std::fs::write(&hook, "#!/bin/sh\necho blocked >&2\nexit 1\n").unwrap();
    let mut permissions = std::fs::metadata(&hook).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&hook, permissions).unwrap();

    let repo = r.open();
    let error = repo
        .merge_with_settings(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("blocked merge".into()),
                no_commit: false,
                no_verify: false,
                allow_unrelated_histories: false,
            },
        )
        .unwrap_err();
    assert!(error.to_string().contains("pre-commit hook failed"));
    assert!(repo.merge_in_progress());
    repo.merge_abort().unwrap();

    let r = make_repo();
    let hook = r.path.join(".git/hooks/pre-commit");
    std::fs::write(&hook, "#!/bin/sh\necho blocked >&2\nexit 1\n").unwrap();
    let mut permissions = std::fs::metadata(&hook).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&hook, permissions).unwrap();
    let repo = r.open();
    let outcome = repo
        .merge_with_settings(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("verified merge".into()),
                no_commit: false,
                no_verify: true,
                allow_unrelated_histories: false,
            },
        )
        .unwrap();
    assert!(outcome.completed);
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "verified merge");
}

#[test]
fn merge_settings_no_commit_keeps_custom_message_for_finish() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_settings(
            "feature".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("pending merge message".into()),
                no_commit: true,
                no_verify: false,
                allow_unrelated_histories: false,
            },
        )
        .unwrap();
    assert!(!outcome.completed);
    assert!(outcome.requires_finish);

    let merge_id = repo.finish_merge(None).unwrap();
    assert_eq!(
        r.git(&["show", "-s", "--format=%s", &merge_id]),
        "pending merge message"
    );
}

#[test]
fn merge_settings_allow_unrelated_histories_uses_empty_tree_ancestor() {
    let r = TestRepo::new();
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "--orphan", "unrelated"]);
    r.git(&["rm", "-q", "-rf", "."]);
    common::commit(&r.path, "other.txt", "other", "other");
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_settings(
            "unrelated".into(),
            MergeOptions {
                mode: MergeMode::NoFastForward,
                commit_message: Some("unrelated merge".into()),
                no_commit: true,
                no_verify: false,
                allow_unrelated_histories: true,
            },
        )
        .unwrap();
    assert!(outcome.conflicts.is_empty());
    assert!(outcome.requires_finish);
    let merge_id = repo.finish_merge(None).unwrap();
    assert_eq!(r.read("main.txt"), "main");
    assert_eq!(r.read("other.txt"), "other");
    assert_eq!(
        r.git(&["show", "-s", "--format=%s", &merge_id]),
        "unrelated merge"
    );
    assert_eq!(
        r.git(&["rev-list", "--parents", "-n", "1", &merge_id])
            .split_whitespace()
            .count(),
        3
    );
}

#[test]
fn merge_no_fast_forward_forces_commit_on_fast_forward_history() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_options("feature".into(), MergeMode::NoFastForward)
        .unwrap();
    assert!(outcome.requires_finish);
    let merge_id = repo.finish_merge(None).unwrap();
    let parents = r.git(&["rev-list", "--parents", "-n", "1", &merge_id]);
    assert_eq!(parents.split_whitespace().count(), 3);
}

#[test]
fn merge_squash_finishes_with_one_parent() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .merge_with_options("feature".into(), MergeMode::Squash)
        .unwrap();
    assert!(outcome.squashed);
    assert!(outcome.requires_finish);
    // The mode is persisted so closing/reopening the repository cannot turn
    // a squash into an accidental two-parent merge.
    drop(repo);
    let squash_id = r.open().finish_merge(None).unwrap();
    let parents = r.git(&["rev-list", "--parents", "-n", "1", &squash_id]);
    assert_eq!(parents.split_whitespace().count(), 2);
    assert_eq!(r.read("feature.txt"), "feature");
}

#[test]
fn merge_fast_forward_only_rejects_diverged_history() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["checkout", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["checkout", "-q", "main"]);
    let before = r.git(&["rev-parse", "HEAD"]);

    let error = r
        .open()
        .merge_with_options("feature".into(), MergeMode::FastForwardOnly)
        .expect_err("diverged histories must fail --ff-only");
    assert!(error.to_string().contains("fast-forward only"));
    assert_eq!(r.git(&["rev-parse", "HEAD"]), before);
}

/// resolve_edited：自由编辑结果文本后标记已解决 -> status 干净（stage 0，无 1/2/3）。
/// 这是 v0.2 可编辑合并的引擎侧验收：混合编辑 + 标记已解决。
#[test]
fn resolve_edited_marks_resolved() {
    let r = TestRepo::new();
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

    let repo = r.open();
    let outcome = repo.merge("feature".into()).unwrap();
    assert_eq!(outcome.conflicts, vec!["file.txt".to_string()]);

    // 自由编辑后的结果（混合 ours/theirs + 手敲内容，无 marker）
    let edited = "line1\nours+theirs mixed\nline3\nnew manual line\n";
    repo.resolve_edited("file.txt".into(), edited.into())
        .unwrap();

    // 工作区写入编辑内容
    assert_eq!(r.read("file.txt"), edited);

    // status 不再冲突
    let st = repo.status().unwrap();
    let conflicted = st.iter().any(|e| {
        e.path == "file.txt"
            && (e.staged == ChangeKind::Conflicted || e.unstaged == ChangeKind::Conflicted)
    });
    assert!(!conflicted, "file.txt should no longer be conflicted");

    // 无冲突阶段残留：ls-files -u 应无输出（stage 0，无 stages 1/2/3）
    let unmerged = r.git(&["ls-files", "-u"]);
    assert!(
        unmerged.is_empty(),
        "no unmerged stages should remain, got: {unmerged}"
    );

    // 索引 stage 0 内容 == 编辑内容（已落 stage 0，可提交）
    let staged_blob = r.git(&["show", ":file.txt"]);
    assert_eq!(staged_blob, edited.trim_end_matches('\n'));
}

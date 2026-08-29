//! REPO-001：多 root 调度——fetch/pull/push/commit 聚合,逐 root 结果,
//! 部分成功/部分失败/跳过可展示。

mod common;

use arbor_engine::{
    discover_git_roots, open_repository, restore_multi_root_checkout,
    rollback_multi_root_branch_create, rollback_multi_root_branch_create_with_state,
    run_multi_root_branch_create, run_multi_root_branch_create_with_options,
    run_multi_root_checkout, run_multi_root_checkout_and_update,
    run_multi_root_checkout_and_update_with_policy, run_multi_root_commit,
    run_multi_root_commit_selected_paths_with_options, run_multi_root_commit_with_options,
    run_multi_root_force_pushed_branch_update_with_auth_and_cancel, run_multi_root_merge,
    run_multi_root_merge_with_policy, run_multi_root_operation, run_multi_root_operation_on_roots,
    run_multi_root_push, run_multi_root_push_recovery, run_multi_root_push_with_force_options,
    run_multi_root_push_with_options, run_multi_root_rebase, run_multi_root_reset_with_policy,
    run_multi_root_reset_with_targets, run_multi_root_update,
    run_multi_root_update_selected_with_policy, run_multi_root_update_with_policy,
    run_root_update_for_push_recovery, run_submodule_update_with_policy, CredentialBroker,
    GitCancelHandle, LocalChangesSavePolicy, MergeMode, MergeOptions, MultiRootBranchCreateTarget,
    MultiRootBranchTarget, MultiRootCheckoutMode, MultiRootCommitCheck, MultiRootCommitOptions,
    MultiRootCommitSelection, MultiRootOperation, MultiRootRebaseSpec,
    MultiRootResetRollbackTarget, MultiRootResetTarget, PushTagMode, ResetMode,
    ResetRecoveryTarget, RootOperationResult, RootProtectedBranchPatterns,
};

/// 建双 root 项目(frontend/backend),各自带独立远程,返回 (project, roots, remotes)。
fn dual_root_project(
    dir: &tempfile::TempDir,
) -> (
    std::path::PathBuf,
    Vec<std::path::PathBuf>,
    Vec<std::path::PathBuf>,
) {
    let project = dir.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let mut roots = Vec::new();
    let mut remotes = Vec::new();
    for name in ["frontend", "backend"] {
        let root = project.join(name);
        std::fs::create_dir_all(&root).unwrap();
        common::git(&root, &["init", "-q"]);
        common::git(&root, &["config", "user.name", "Arbor Test"]);
        common::git(&root, &["config", "user.email", "test@arbor.local"]);
        common::git(&root, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        common::commit(&root, "init.txt", "i\n", "init");
        let remote = dir.path().join(format!("{name}.git"));
        common::git(
            dir.path(),
            &["init", "-q", "--bare", &format!("{name}.git")],
        );
        common::git(
            &root,
            &["remote", "add", "origin", &remote.display().to_string()],
        );
        common::git(&root, &["push", "-q", "-u", "origin", "main"]);
        roots.push(root);
        remotes.push(remote);
    }
    (project, roots, remotes)
}

/// 从另一个 clone 推进指定远程。
fn advance_remote(dir: &std::path::Path, remote: &std::path::Path) {
    let work = dir.join("advance");
    common::git(
        dir,
        &["clone", "-q", &remote.display().to_string(), "advance"],
    );
    common::git(&work, &["config", "user.name", "Arbor Test"]);
    common::git(&work, &["config", "user.email", "test@arbor.local"]);
    common::commit(&work, "adv.txt", "a\n", "advance");
    common::git(&work, &["push", "-q", "origin", "main"]);
    std::fs::remove_dir_all(&work).unwrap();
}

fn advance_remote_conflicting(dir: &std::path::Path, remote: &std::path::Path) {
    let work = dir.join("advance-conflicting");
    common::git(
        dir,
        &[
            "clone",
            "-q",
            &remote.display().to_string(),
            "advance-conflicting",
        ],
    );
    common::git(&work, &["config", "user.name", "Arbor Test"]);
    common::git(&work, &["config", "user.email", "test@arbor.local"]);
    common::commit(&work, "init.txt", "remote\n", "conflicting remote update");
    common::git(&work, &["push", "-q", "origin", "main"]);
    std::fs::remove_dir_all(&work).unwrap();
}

fn advance_remote_branch(dir: &std::path::Path, remote: &std::path::Path, branch: &str) {
    let work = dir.join("advance-branch");
    common::git(
        dir,
        &[
            "clone",
            "-q",
            &remote.display().to_string(),
            "advance-branch",
        ],
    );
    common::git(&work, &["switch", "-q", branch]);
    common::git(&work, &["config", "user.name", "Arbor Test"]);
    common::git(&work, &["config", "user.email", "test@arbor.local"]);
    common::commit(&work, "remote-feature.txt", "remote\n", "advance feature");
    common::git(&work, &["push", "-q", "origin", branch]);
    std::fs::remove_dir_all(&work).unwrap();
}

fn advance_remote_branch_conflicting(
    dir: &std::path::Path,
    remote: &std::path::Path,
    branch: &str,
) {
    let work = dir.join("advance-conflicting-branch");
    common::git(
        dir,
        &[
            "clone",
            "-q",
            &remote.display().to_string(),
            "advance-conflicting-branch",
        ],
    );
    common::git(&work, &["switch", "-q", branch]);
    common::git(&work, &["config", "user.name", "Arbor Test"]);
    common::git(&work, &["config", "user.email", "test@arbor.local"]);
    common::commit(
        &work,
        "init.txt",
        "remote feature\n",
        "remote feature conflict",
    );
    common::git(&work, &["push", "-q", "origin", branch]);
    std::fs::remove_dir_all(&work).unwrap();
}

fn detached_submodule_project(
    dir: &std::path::Path,
) -> (
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
) {
    let source = dir.join("submodule-source");
    let project = dir.join("project");
    let remote = dir.join("project.git");
    let submodule = project.join("vendor/lib");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    common::git(&source, &["init", "-q"]);
    common::git(&source, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::git(&source, &["config", "user.name", "Arbor Test"]);
    common::git(&source, &["config", "user.email", "test@arbor.local"]);
    common::commit(&source, "lib.txt", "initial\n", "submodule initial");
    common::git(&project, &["init", "-q"]);
    common::git(&project, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::git(&project, &["config", "user.name", "Arbor Test"]);
    common::git(&project, &["config", "user.email", "test@arbor.local"]);
    common::git(&project, &["config", "protocol.file.allow", "always"]);
    common::commit(&project, "main.txt", "main\n", "outer initial");
    common::git(
        &project,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &source.display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(&project, &["commit", "-q", "-m", "add submodule"]);
    common::git(&submodule, &["config", "user.name", "Arbor Test"]);
    common::git(&submodule, &["config", "user.email", "test@arbor.local"]);
    common::git(&submodule, &["switch", "-q", "--detach", "HEAD"]);
    common::git(dir, &["init", "-q", "--bare", "project.git"]);
    common::git(
        &project,
        &["remote", "add", "origin", &remote.display().to_string()],
    );
    common::git(&project, &["push", "-q", "-u", "origin", "main"]);
    common::git(&remote, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    (project, source, submodule, remote)
}

fn detached_nested_submodule_project(
    dir: &std::path::Path,
) -> (
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
) {
    let tool_source = dir.join("tool-source");
    let child_source = dir.join("child-source");
    let project = dir.join("project");
    let remote = dir.join("project.git");
    let child = project.join("vendor/lib");
    let tool = child.join("nested/tool");

    for repo in [&tool_source, &child_source, &project] {
        std::fs::create_dir_all(repo).unwrap();
        common::git(repo, &["init", "-q"]);
        common::git(repo, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        common::git(repo, &["config", "user.name", "Arbor Test"]);
        common::git(repo, &["config", "user.email", "test@arbor.local"]);
        common::git(repo, &["config", "protocol.file.allow", "always"]);
    }
    common::commit(&tool_source, "tool.txt", "initial\n", "tool initial");
    common::commit(&child_source, "lib.txt", "initial\n", "child initial");
    common::git(
        &child_source,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &tool_source.display().to_string(),
            "nested/tool",
        ],
    );
    common::git(&child_source, &["commit", "-q", "-m", "add nested tool"]);
    common::commit(&project, "main.txt", "main\n", "outer initial");
    common::git(
        &project,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &child_source.display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(&project, &["commit", "-q", "-m", "add child submodule"]);
    common::git(
        &project,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--init",
            "--recursive",
        ],
    );
    common::git(&child, &["config", "protocol.file.allow", "always"]);
    common::git(&child, &["switch", "-q", "--detach", "HEAD"]);
    common::git(&tool, &["switch", "-q", "--detach", "HEAD"]);

    common::git(dir, &["init", "-q", "--bare", "project.git"]);
    common::git(
        &project,
        &["remote", "add", "origin", &remote.display().to_string()],
    );
    common::git(&project, &["push", "-q", "-u", "origin", "main"]);
    common::git(&remote, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    (project, tool_source, child_source, tool, remote)
}

fn create_feature_branch(roots: &[std::path::PathBuf]) {
    for root in roots {
        common::git(root, &["switch", "-q", "-c", "feature"]);
        common::commit(root, "feature.txt", "feature\n", "feature");
        common::git(root, &["push", "-q", "-u", "origin", "feature"]);
        common::git(root, &["switch", "-q", "main"]);
    }
}

fn assert_results(
    results: &[RootOperationResult],
    expected_success: usize,
    expected_failed: usize,
    expected_skipped: usize,
) {
    let ok = results.iter().filter(|r| r.success && !r.skipped).count();
    let failed = results.iter().filter(|r| !r.success).count();
    let skipped = results.iter().filter(|r| r.skipped).count();
    assert_eq!(
        (ok, failed, skipped),
        (expected_success, expected_failed, expected_skipped),
        "results: {results:?}"
    );
}

#[test]
fn multi_root_branch_create_and_rollback_restores_each_previous_head() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);

    let results = run_multi_root_branch_create(
        project.display().to_string(),
        None,
        "topic".into(),
        None,
        true,
    )
    .expect("create branch in every root");
    assert_eq!(results.len(), roots.len());
    assert!(results.iter().all(|result| {
        result.success
            && result.branch_created
            && result.checked_out
            && result.previous_branch.as_deref() == Some("main")
    }));
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "topic"
        );
    }

    let targets = results
        .iter()
        .map(|result| MultiRootBranchTarget {
            root_path: result.root_path.clone(),
            checked_out: result.checked_out,
            previous_branch: result.previous_branch.clone(),
            previous_head: result.previous_head.clone(),
            expected_head: None,
            expected_branch: result.checked_out.then(|| "topic".into()),
            created_branch: None,
        })
        .collect();
    let rollback = rollback_multi_root_branch_create("topic".into(), targets)
        .expect("rollback branch creation");
    assert_eq!(rollback.len(), roots.len());
    assert!(rollback.iter().all(|result| result.success));
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "main"
        );
        assert!(common::git(root, &["branch", "--list", "topic"]).is_empty());
    }
}

#[test]
fn multi_root_branch_create_reports_partial_failure_and_rolls_back_successes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, _roots, _remotes) = dual_root_project(&dir);
    let discovered =
        discover_git_roots(project.display().to_string(), None).expect("discover roots");
    assert_eq!(discovered.len(), 2);

    // Force the last root in the engine's deterministic discovery order to fail
    // while the first root still has a valid create operation.
    let failed_root = discovered.last().expect("last root");
    common::git(
        std::path::Path::new(&failed_root.path),
        &["branch", "topic"],
    );
    let selected = discovered.iter().map(|root| root.path.clone()).collect();
    let results = run_multi_root_branch_create(
        project.display().to_string(),
        Some(selected),
        "topic".into(),
        None,
        false,
    )
    .expect("partial create result");
    assert_eq!(
        results
            .iter()
            .filter(|result| result.success && !result.skipped)
            .count(),
        1
    );
    assert_eq!(results.iter().filter(|result| !result.success).count(), 1);
    assert_eq!(results.iter().filter(|result| result.skipped).count(), 0);

    let successful_root = results
        .iter()
        .find(|result| result.success && result.branch_created)
        .expect("successful root");
    let rollback = rollback_multi_root_branch_create(
        "topic".into(),
        vec![MultiRootBranchTarget {
            root_path: successful_root.root_path.clone(),
            checked_out: successful_root.checked_out,
            previous_branch: successful_root.previous_branch.clone(),
            previous_head: successful_root.previous_head.clone(),
            expected_head: None,
            expected_branch: successful_root.checked_out.then(|| "topic".into()),
            created_branch: None,
        }],
    )
    .expect("rollback successful root");
    assert_eq!(rollback.len(), 1);
    assert!(rollback[0].success);
    assert!(common::git(
        std::path::Path::new(&successful_root.root_path),
        &["branch", "--list", "topic"]
    )
    .is_empty());
    assert_eq!(
        common::git(
            std::path::Path::new(&failed_root.path),
            &["branch", "--list", "topic"]
        ),
        "topic"
    );
}

fn seed_existing_topic_branches(roots: &[std::path::PathBuf]) -> Vec<String> {
    roots
        .iter()
        .map(|root| {
            common::git(root, &["branch", "topic"]);
            common::git(root, &["switch", "-q", "topic"]);
            let tip = common::commit(root, "topic.txt", "old\n", "old topic tip");
            common::git(root, &["switch", "-q", "main"]);
            tip
        })
        .collect()
}

#[test]
fn multi_root_branch_reset_restores_overwritten_non_current_tips() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let old_tips = seed_existing_topic_branches(&roots);

    let results = run_multi_root_branch_create_with_options(
        project.display().to_string(),
        None,
        "topic".into(),
        Some("main".into()),
        false,
        true,
    )
    .expect("reset branch in every root");
    assert!(results.iter().all(|result| {
        result.success
            && !result.branch_created
            && !result.checked_out
            && result.previous_branch_tip.is_some()
            && result.expected_branch_tip.is_some()
    }));
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "main"
        );
        assert_eq!(
            common::git(root, &["rev-parse", "topic"]),
            common::git(root, &["rev-parse", "main"])
        );
    }

    let targets = results
        .iter()
        .map(|result| MultiRootBranchCreateTarget {
            root_path: result.root_path.clone(),
            checked_out: result.checked_out,
            previous_branch: result.previous_branch.clone(),
            previous_head: result.previous_head.clone(),
            expected_head: result
                .checked_out
                .then(|| result.expected_branch_tip.clone())
                .flatten(),
            expected_branch: result.checked_out.then(|| "topic".into()),
            previous_branch_tip: result.previous_branch_tip.clone(),
            expected_branch_tip: result.expected_branch_tip.clone(),
        })
        .collect();
    let rollback = rollback_multi_root_branch_create_with_state("topic".into(), targets)
        .expect("restore overwritten branch tips");
    assert!(
        rollback.iter().all(|result| result.success),
        "rollback: {rollback:?}"
    );
    for (root, old_tip) in roots.iter().zip(old_tips) {
        assert_eq!(common::git(root, &["rev-parse", "topic"]), old_tip);
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "main"
        );
    }
}

#[test]
fn multi_root_branch_reset_checkout_restores_previous_branch_and_tip() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let old_tips = seed_existing_topic_branches(&roots);

    let results = run_multi_root_branch_create_with_options(
        project.display().to_string(),
        None,
        "topic".into(),
        Some("main".into()),
        true,
        true,
    )
    .expect("reset and checkout branch in every root");
    assert!(results.iter().all(|result| {
        result.success
            && !result.branch_created
            && result.checked_out
            && result.previous_branch.as_deref() == Some("main")
    }));
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "topic"
        );
    }

    let targets = results
        .iter()
        .map(|result| MultiRootBranchCreateTarget {
            root_path: result.root_path.clone(),
            checked_out: result.checked_out,
            previous_branch: result.previous_branch.clone(),
            previous_head: result.previous_head.clone(),
            expected_head: result.expected_branch_tip.clone(),
            expected_branch: Some("topic".into()),
            previous_branch_tip: result.previous_branch_tip.clone(),
            expected_branch_tip: result.expected_branch_tip.clone(),
        })
        .collect();
    let rollback = rollback_multi_root_branch_create_with_state("topic".into(), targets)
        .expect("restore checked out overwritten branch tips");
    assert!(
        rollback.iter().all(|result| result.success),
        "rollback: {rollback:?}"
    );
    for (root, old_tip) in roots.iter().zip(old_tips) {
        assert_eq!(common::git(root, &["rev-parse", "topic"]), old_tip);
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "main"
        );
    }
}

#[test]
fn multi_root_branch_reset_refuses_a_changed_branch_tip() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let old_tips = seed_existing_topic_branches(&roots);
    let results = run_multi_root_branch_create_with_options(
        project.display().to_string(),
        None,
        "topic".into(),
        Some("main".into()),
        false,
        true,
    )
    .expect("reset branch in every root");

    common::git(&roots[0], &["switch", "-q", "topic"]);
    let changed_tip = common::commit(
        &roots[0],
        "after-reset.txt",
        "changed\n",
        "changed after reset",
    );
    common::git(&roots[0], &["switch", "-q", "main"]);

    let targets = results
        .iter()
        .map(|result| MultiRootBranchCreateTarget {
            root_path: result.root_path.clone(),
            checked_out: result.checked_out,
            previous_branch: result.previous_branch.clone(),
            previous_head: result.previous_head.clone(),
            expected_head: None,
            expected_branch: None,
            previous_branch_tip: result.previous_branch_tip.clone(),
            expected_branch_tip: result.expected_branch_tip.clone(),
        })
        .collect();
    let rollback = rollback_multi_root_branch_create_with_state("topic".into(), targets)
        .expect("rollback returns per-root state refusal");
    assert!(rollback
        .iter()
        .any(|result| { !result.success && result.message.contains("expected 'topic' tip") }));
    assert_eq!(common::git(&roots[0], &["rev-parse", "topic"]), changed_tip);
    assert_ne!(changed_tip, old_tips[0]);
    assert_eq!(common::git(&roots[1], &["rev-parse", "topic"]), old_tips[1]);
}

#[test]
fn stateful_branch_rollback_refuses_missing_expected_tip_snapshot() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    seed_existing_topic_branches(&roots);

    let results = run_multi_root_branch_create_with_options(
        project.display().to_string(),
        None,
        "topic".into(),
        Some("main".into()),
        false,
        true,
    )
    .expect("reset branch in every root");
    let target = results.first().expect("first root result");
    let rollback = rollback_multi_root_branch_create_with_state(
        "topic".into(),
        vec![MultiRootBranchCreateTarget {
            root_path: target.root_path.clone(),
            checked_out: false,
            previous_branch: target.previous_branch.clone(),
            previous_head: target.previous_head.clone(),
            expected_head: None,
            expected_branch: None,
            previous_branch_tip: target.previous_branch_tip.clone(),
            expected_branch_tip: None,
        }],
    )
    .expect("rollback returns a per-root refusal");

    assert_eq!(rollback.len(), 1);
    assert!(!rollback[0].success);
    assert!(rollback[0]
        .message
        .contains("expected branch tip was not persisted"));
    assert_eq!(
        common::git(
            std::path::Path::new(&target.root_path),
            &["rev-parse", "topic"]
        ),
        common::git(
            std::path::Path::new(&target.root_path),
            &["rev-parse", "main"]
        )
    );
}

#[test]
fn multi_root_merge_stops_after_failure_and_returns_successful_heads() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let initial_head = common::git(&roots[0], &["rev-parse", "HEAD"]);
    common::git(&roots[0], &["switch", "-q", "-c", "feature"]);
    common::commit(&roots[0], "feature.txt", "feature\n", "feature");
    let feature_head = common::git(&roots[0], &["rev-parse", "HEAD"]);
    common::git(&roots[0], &["switch", "-q", "main"]);

    let options = MergeOptions {
        mode: MergeMode::FastForward,
        commit_message: None,
        no_commit: false,
        no_verify: false,
        allow_unrelated_histories: false,
    };
    let results = run_multi_root_merge(
        project.display().to_string(),
        None,
        "feature".into(),
        options,
    )
    .expect("multi-root merge result");

    assert_eq!(results.len(), 2);
    let frontend_path = std::fs::canonicalize(&roots[0]).unwrap();
    let backend_path = std::fs::canonicalize(&roots[1]).unwrap();
    let first = results
        .iter()
        .find(|result| result.root_path == frontend_path.display().to_string())
        .expect("first root result");
    assert!(first.success && !first.skipped);
    assert_eq!(first.initial_head.as_deref(), Some(initial_head.as_str()));
    assert_eq!(first.final_head.as_deref(), Some(feature_head.as_str()));
    assert!(first.completed);

    let second = results
        .iter()
        .find(|result| result.root_path == backend_path.display().to_string())
        .expect("second root result");
    assert!(!second.success);
    assert!(!second.skipped);
    assert!(second.message.contains("feature") || second.message.contains("reference"));
    assert_eq!(common::git(&roots[0], &["rev-parse", "HEAD"]), feature_head);
    assert_eq!(
        common::git(&roots[1], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
}

#[test]
fn multi_root_merge_continues_after_conflict_and_reports_each_pending_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["switch", "-q", "-c", "feature"]);
        common::commit(root, "init.txt", "feature\n", "feature conflict");
        common::git(root, &["switch", "-q", "main"]);
        common::commit(root, "init.txt", "main\n", "main conflict");
    }

    let results = run_multi_root_merge(
        project.display().to_string(),
        None,
        "feature".into(),
        MergeOptions {
            mode: MergeMode::FastForward,
            commit_message: None,
            no_commit: false,
            no_verify: false,
            allow_unrelated_histories: false,
        },
    )
    .expect("multi-root merge result");

    assert_eq!(results.len(), 2);
    assert!(results
        .iter()
        .all(|result| result.success && !result.skipped));
    assert!(results.iter().all(|result| !result.conflicts.is_empty()));
    assert!(results.iter().all(|result| result.requires_finish));
    assert!(results.iter().all(|result| !result.completed));
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "main"
        );
        open_repository(std::fs::canonicalize(root).unwrap().display().to_string())
            .expect("open conflict root")
            .merge_abort()
            .expect("abort conflict merge");
    }
}

#[test]
fn multi_root_smart_merge_preserves_each_root_independently() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::commit(root, "init.txt", "base\nkeep\n", "base");
        common::git(root, &["branch", "feature"]);
        common::git(root, &["checkout", "-q", "feature"]);
        common::commit(root, "init.txt", "feature\nkeep\n", "feature");
        common::git(root, &["checkout", "-q", "main"]);
        std::fs::write(root.join("init.txt"), "base\nlocal\n").unwrap();
    }

    let options = MergeOptions {
        mode: MergeMode::NoFastForward,
        commit_message: None,
        no_commit: false,
        no_verify: false,
        allow_unrelated_histories: false,
    };
    let results = run_multi_root_merge(
        project.display().to_string(),
        None,
        "feature".into(),
        options.clone(),
    )
    .expect("direct multi-root merge result");
    assert!(results
        .iter()
        .any(|result| { !result.success && !result.local_changes_overwrite_paths.is_empty() }));

    let results = run_multi_root_merge_with_policy(
        project.display().to_string(),
        None,
        "feature".into(),
        options,
        LocalChangesSavePolicy::Stash,
    )
    .expect("smart multi-root merge result");
    assert_eq!(results.len(), roots.len());
    assert!(results
        .iter()
        .all(|result| result.success && result.completed));
    for root in &roots {
        assert_eq!(
            std::fs::read_to_string(root.join("init.txt")).unwrap(),
            "feature\nlocal\n"
        );
        assert!(common::git(root, &["stash", "list"]).is_empty());
        assert!(!root.join(".git/arbor-apply-local-changes").exists());
    }
}

#[test]
fn multi_root_reset_reports_overwrites_then_smart_restores_each_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::commit(root, "init.txt", "head\n", "head change");
        std::fs::write(root.join("init.txt"), "local\n").unwrap();
    }

    let direct = run_multi_root_reset_with_policy(
        project.display().to_string(),
        None,
        "HEAD~1".into(),
        ResetMode::Hard,
        LocalChangesSavePolicy::Stash,
        false,
        false,
    )
    .expect("direct multi-root reset result");
    assert_eq!(direct.len(), roots.len());
    assert!(direct
        .iter()
        .all(|result| !result.success && !result.local_changes_overwrite_paths.is_empty()));

    let smart = run_multi_root_reset_with_policy(
        project.display().to_string(),
        None,
        "HEAD~1".into(),
        ResetMode::Hard,
        LocalChangesSavePolicy::Stash,
        true,
        false,
    )
    .expect("smart multi-root reset result");
    assert!(smart
        .iter()
        .all(|result| !result.success && result.message.contains("stash apply conflicts")));
    for root in &roots {
        let repo = open_repository(root.display().to_string()).unwrap();
        assert_eq!(repo.stash_list().unwrap().len(), 1);
        assert!(root.join(".git/arbor-apply-local-changes").exists());
    }
}

#[test]
fn multi_root_reset_uses_the_selected_revision_for_each_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let frontend_target = common::commit(&roots[0], "frontend.txt", "target\n", "frontend target");
    common::commit(&roots[0], "frontend.txt", "current\n", "frontend current");
    let backend_target = common::commit(&roots[1], "backend.txt", "target\n", "backend target");
    common::commit(&roots[1], "backend.txt", "current\n", "backend current");

    let results = run_multi_root_reset_with_targets(
        project.display().to_string(),
        vec![
            MultiRootResetTarget {
                root_path: roots[0].display().to_string(),
                commit_id: frontend_target.clone(),
            },
            MultiRootResetTarget {
                root_path: roots[1].display().to_string(),
                commit_id: backend_target.clone(),
            },
        ],
        ResetMode::Mixed,
        LocalChangesSavePolicy::Stash,
        false,
        false,
    )
    .expect("per-root reset result");

    assert!(results.iter().all(|result| result.success));
    assert_eq!(
        common::git(&roots[0], &["rev-parse", "HEAD"]),
        frontend_target
    );
    assert_eq!(
        common::git(&roots[1], &["rev-parse", "HEAD"]),
        backend_target
    );
}

#[test]
fn multi_root_reset_recovery_keep_releases_each_root_snapshot() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let mut targets = Vec::new();
    for (index, root) in roots.iter().enumerate() {
        let target = common::git(root, &["rev-parse", "HEAD"]);
        common::commit(root, &format!("root-{index}.txt"), "current\n", "current");
        std::fs::write(root.join("local.txt"), format!("local-{index}\n")).unwrap();
        targets.push(MultiRootResetTarget {
            root_path: root.display().to_string(),
            commit_id: target,
        });
    }

    let results = run_multi_root_reset_with_targets(
        project.display().to_string(),
        targets,
        ResetMode::Mixed,
        LocalChangesSavePolicy::Stash,
        false,
        false,
    )
    .expect("multi-root reset recovery result");
    assert!(results.iter().all(|result| result.success));
    assert!(results.iter().all(|result| result.rollback_id.is_some()));

    let recovery_targets = results
        .iter()
        .map(|result| ResetRecoveryTarget {
            root_path: result.root_path.clone(),
            display_name: result.display_name.clone(),
            initial_head: result.initial_head.clone().unwrap(),
            expected_head: result.final_head.clone().unwrap(),
            expected_head_branch: result.final_branch.clone(),
            mode: ResetMode::Mixed,
            rollback_id: result.rollback_id.clone().unwrap(),
        })
        .collect();
    let kept = arbor_engine::keep_multi_root_reset_recovery(recovery_targets)
        .expect("multi-root keep result");
    assert!(kept.iter().all(|result| result.success));
    for root in roots {
        assert!(!root.join(".git/arbor-reset-rollback").exists());
    }
}

#[test]
fn multi_root_soft_reset_exposes_ref_only_rollback_and_preserves_local_state() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let mut initial_heads = Vec::new();
    let mut status_before = Vec::new();
    for root in &roots {
        common::commit(root, "next.txt", "next\n", "next");
        initial_heads.push(common::git(root, &["rev-parse", "HEAD"]));
        std::fs::write(root.join("init.txt"), "local\n").unwrap();
        std::fs::write(root.join("staged.txt"), "staged\n").unwrap();
        common::git(root, &["add", "staged.txt"]);
        status_before.push(common::git(root, &["status", "--porcelain"]));
    }

    let results = run_multi_root_reset_with_policy(
        project.display().to_string(),
        None,
        "HEAD~1".into(),
        ResetMode::Soft,
        LocalChangesSavePolicy::Stash,
        false,
        false,
    )
    .expect("soft multi-root reset result");
    assert!(results.iter().all(|result| result.success));
    assert!(results.iter().all(|result| {
        result.initial_head.is_some()
            && result.final_head.is_some()
            && result.initial_branch.as_deref() == Some("main")
            && result.final_branch.as_deref() == Some("main")
            && result.initial_head != result.final_head
    }));

    let rollback_targets = results
        .iter()
        .map(|result| MultiRootResetRollbackTarget {
            root_path: result.root_path.clone(),
            display_name: result.display_name.clone(),
            initial_head: result.initial_head.clone().unwrap(),
            expected_head: result.final_head.clone().unwrap(),
            mode: ResetMode::Soft,
            expected_head_branch: result.final_branch.clone(),
        })
        .collect();
    let rollback = arbor_engine::rollback_multi_root_reset(rollback_targets)
        .expect("soft reset rollback result");
    assert!(rollback.iter().all(|result| result.success));

    for (index, root) in roots.iter().enumerate() {
        assert_eq!(
            common::git(root, &["rev-parse", "HEAD"]),
            initial_heads[index]
        );
        assert_eq!(
            common::git(root, &["status", "--porcelain"]),
            status_before[index]
        );
        assert_eq!(
            std::fs::read_to_string(root.join("init.txt")).unwrap(),
            "local\n"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("staged.txt")).unwrap(),
            "staged\n"
        );
        assert!(root.join("next.txt").exists());
    }
}

#[test]
fn multi_root_soft_reset_rollback_refuses_changed_head_per_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::commit(root, "next.txt", "next\n", "next");
    }

    let results = run_multi_root_reset_with_policy(
        project.display().to_string(),
        None,
        "HEAD~1".into(),
        ResetMode::Soft,
        LocalChangesSavePolicy::Stash,
        false,
        false,
    )
    .expect("soft multi-root reset result");
    let rollback_targets = results
        .iter()
        .map(|result| MultiRootResetRollbackTarget {
            root_path: result.root_path.clone(),
            display_name: result.display_name.clone(),
            initial_head: result.initial_head.clone().unwrap(),
            expected_head: result.final_head.clone().unwrap(),
            mode: ResetMode::Soft,
            expected_head_branch: result.final_branch.clone(),
        })
        .collect::<Vec<_>>();

    common::commit(&roots[0], "changed.txt", "changed\n", "changed after reset");
    let rollback = arbor_engine::rollback_multi_root_reset(rollback_targets)
        .expect("soft reset rollback result");
    let changed = &rollback[0];
    assert!(!changed.success);
    assert!(changed.message.contains("HEAD changed"));
    let restored = &rollback[1];
    assert!(restored.success);
    assert_eq!(
        common::git(&roots[1], &["rev-parse", "HEAD"]),
        results[1].initial_head.clone().unwrap()
    );
    assert_eq!(
        common::git(&roots[0], &["log", "-1", "--format=%s"]),
        "changed after reset"
    );
}

#[test]
fn multi_root_reset_rollback_rejects_non_soft_targets_before_opening_repo() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_project, roots, _remotes) = dual_root_project(&dir);
    let head = common::git(&roots[0], &["rev-parse", "HEAD"]);
    let results = arbor_engine::rollback_multi_root_reset(vec![MultiRootResetRollbackTarget {
        root_path: roots[0].display().to_string(),
        display_name: "frontend".into(),
        initial_head: head.clone(),
        expected_head: head.clone(),
        mode: ResetMode::Hard,
        expected_head_branch: Some("main".into()),
    }])
    .expect("mode guard result");
    assert_eq!(results.len(), 1);
    assert!(!results[0].success);
    assert!(results[0].message.contains("mode is not Soft"));
    assert_eq!(common::git(&roots[0], &["rev-parse", "HEAD"]), head);
}

#[test]
fn multi_root_force_pushed_update_replays_and_restores_each_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    for (index, root) in roots.iter().enumerate() {
        common::commit(
            root,
            "local.txt",
            &format!("local-{index}\n"),
            "local commit",
        );
        std::fs::write(root.join("dirty.txt"), format!("dirty-{index}\n")).unwrap();

        let work = dir.path().join(format!("force-work-{index}"));
        common::git(
            dir.path(),
            &[
                "clone",
                "-q",
                &remotes[index].display().to_string(),
                &work.display().to_string(),
            ],
        );
        common::git(&work, &["config", "user.name", "Arbor Test"]);
        common::git(&work, &["config", "user.email", "test@arbor.local"]);
        common::commit(
            &work,
            "remote.txt",
            &format!("remote-{index}\n"),
            "remote replacement",
        );
        common::git(&work, &["push", "-q", "origin", "main"]);
        std::fs::remove_dir_all(work).unwrap();
    }

    let results = run_multi_root_force_pushed_branch_update_with_auth_and_cancel(
        project.display().to_string(),
        None,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
        false,
    )
    .expect("multi-root force-pushed update result");
    assert_eq!(results.len(), roots.len());
    assert!(results.iter().all(|result| result.success));
    assert!(results.iter().all(|result| result.replayed_commits == 1));
    assert!(results
        .iter()
        .all(|result| result.received_commits_count == 1));
    assert!(results.iter().all(|result| result.updated_files_count == 1));
    for (index, root) in roots.iter().enumerate() {
        assert_eq!(
            std::fs::read_to_string(root.join("remote.txt")).unwrap(),
            format!("remote-{index}\n")
        );
        assert_eq!(
            std::fs::read_to_string(root.join("local.txt")).unwrap(),
            format!("local-{index}\n")
        );
        assert_eq!(
            std::fs::read_to_string(root.join("dirty.txt")).unwrap(),
            format!("dirty-{index}\n")
        );
        let repo = open_repository(root.display().to_string()).unwrap();
        assert!(repo.stash_list().unwrap().is_empty());
        assert!(!root.join(".git/arbor-apply-local-changes").exists());
    }
}

#[test]
fn multi_root_force_pushed_update_classifies_unavailable_roots_as_skipped() {
    let untracked = common::TestRepo::new();
    common::commit(&untracked.path, "seed.txt", "seed\n", "seed");
    let untracked_results = run_multi_root_force_pushed_branch_update_with_auth_and_cancel(
        untracked.path.display().to_string(),
        None,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
        false,
    )
    .expect("untracked root result");
    assert_eq!(untracked_results.len(), 1);
    assert!(untracked_results[0].success);
    assert!(untracked_results[0].skipped);
    assert!(
        untracked_results[0]
            .message
            .contains("no tracked remote branch"),
        "unexpected untracked result: {:?}",
        untracked_results[0]
    );

    let detached = common::TestRepo::new();
    common::commit(&detached.path, "seed.txt", "seed\n", "seed");
    common::git(&detached.path, &["checkout", "--detach", "HEAD"]);
    let detached_results = run_multi_root_force_pushed_branch_update_with_auth_and_cancel(
        detached.path.display().to_string(),
        None,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
        false,
    )
    .expect("detached root result");
    assert_eq!(detached_results.len(), 1);
    assert!(detached_results[0].success);
    assert!(detached_results[0].skipped);
    assert!(detached_results[0].message.contains("detached HEAD"));
}

#[test]
fn multi_root_checkout_switches_the_same_local_branch_in_all_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "feature.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
    }

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Normal,
    )
    .expect("checkout all roots");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "feature"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("feature.txt")).unwrap(),
            "feature\n"
        );
    }
}

#[test]
fn multi_root_checkout_skips_root_without_reference_and_continues() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    common::git(&roots[0], &["checkout", "-q", "-b", "feature"]);

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Normal,
    )
    .expect("checkout should return a partial result");

    assert_results(&results, 1, 0, 1);
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "feature"
    );
    assert_eq!(
        common::git(&roots[1], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert!(results
        .iter()
        .any(|result| { result.skipped && result.message.contains("reference not found") }));
}

#[test]
fn multi_root_checkout_detached_reference_in_all_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["tag", "target"]);
    }

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "target".into(),
        true,
        MultiRootCheckoutMode::Normal,
    )
    .expect("detached checkout all roots");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["rev-parse", "--abbrev-ref", "HEAD"]),
            "HEAD"
        );
    }
}

#[test]
fn multi_root_normal_checkout_is_partial_when_one_root_is_dirty() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "init.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
    }
    std::fs::write(roots[0].join("init.txt"), "local\n").unwrap();

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Normal,
    )
    .expect("normal checkout returns per-root results");
    assert_results(&results, 0, 1, 1);
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert_eq!(
        common::git(&roots[1], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert_eq!(
        std::fs::read_to_string(roots[0].join("init.txt")).unwrap(),
        "local\n"
    );
}

#[test]
fn multi_root_checkout_partial_success_keeps_target_until_explicit_rollback() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "feature.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
    }
    // The first root succeeds; the second fails because its worktree is dirty.
    std::fs::write(roots[1].join("feature.txt"), "local\n").unwrap();
    let discovered = discover_git_roots(project.display().to_string(), None).unwrap();

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Normal,
    )
    .expect("partial checkout result");
    assert_results(&results, 1, 1, 0);
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "feature"
    );
    assert_eq!(
        common::git(&roots[1], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );

    let first_root = discovered
        .iter()
        .find(|root| root.display_name == "frontend")
        .expect("first root snapshot");
    let checked_out_root = discover_git_roots(project.display().to_string(), None)
        .expect("discover roots after checkout")
        .into_iter()
        .find(|root| root.path == first_root.path)
        .expect("checked out root snapshot");
    let rollback = restore_multi_root_checkout(vec![MultiRootBranchTarget {
        root_path: first_root.path.clone(),
        checked_out: true,
        previous_branch: first_root.head_branch.clone(),
        previous_head: first_root.head_id.clone(),
        expected_head: checked_out_root.head_id.clone(),
        expected_branch: checked_out_root.head_branch.clone(),
        created_branch: None,
    }])
    .expect("rollback checkout");
    assert_eq!(rollback.len(), 1);
    assert!(rollback[0].success, "rollback failed: {rollback:?}");
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
}

#[test]
fn multi_root_checkout_rollback_refuses_changed_post_checkout_head() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "feature.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
    }

    let before_checkout = discover_git_roots(project.display().to_string(), None).unwrap();
    run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Normal,
    )
    .expect("checkout succeeds");
    let after_checkout = discover_git_roots(project.display().to_string(), None).unwrap();
    let before = before_checkout
        .iter()
        .find(|root| root.display_name == "frontend")
        .expect("before root");
    let after = after_checkout
        .iter()
        .find(|root| root.display_name == "frontend")
        .expect("after root");

    common::commit(&roots[0], "later.txt", "later\n", "later work");
    let rollback = restore_multi_root_checkout(vec![MultiRootBranchTarget {
        root_path: before.path.clone(),
        checked_out: true,
        previous_branch: before.head_branch.clone(),
        previous_head: before.head_id.clone(),
        expected_head: after.head_id.clone(),
        expected_branch: after.head_branch.clone(),
        created_branch: None,
    }])
    .expect("rollback returns a per-root refusal");

    assert_eq!(rollback.len(), 1);
    assert!(!rollback[0].success);
    assert!(rollback[0].message.contains("state changed"));
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "feature"
    );
}

#[test]
fn multi_root_smart_checkout_preserves_each_root_local_scene() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "feature.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
        std::fs::write(root.join("local.txt"), "local\n").unwrap();
    }

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Smart,
    )
    .expect("smart checkout all roots");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "feature"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("local.txt")).unwrap(),
            "local\n"
        );
        let repo = arbor_engine::open_repository(root.display().to_string()).expect("open root");
        assert!(repo.stash_list().expect("stash list").is_empty());
    }
}

#[test]
fn multi_root_smart_checkout_stash_policy_preserves_staged_and_unstaged_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "feature.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
        std::fs::write(root.join("init.txt"), "staged local\n").unwrap();
        common::git(root, &["add", "init.txt"]);
        std::fs::write(root.join("init.txt"), "unstaged local\n").unwrap();
    }

    let results = arbor_engine::run_multi_root_checkout_with_policy(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Smart,
        LocalChangesSavePolicy::Stash,
    )
    .expect("stash smart checkout all roots");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        let staged_diff = common::git(root, &["diff", "--cached", "--", "init.txt"]);
        assert!(staged_diff.contains("-i") && staged_diff.contains("+staged local"));
        let unstaged_diff = common::git(root, &["diff", "--", "init.txt"]);
        assert!(
            unstaged_diff.contains("-staged local") && unstaged_diff.contains("+unstaged local")
        );
        let repo = arbor_engine::open_repository(root.display().to_string()).expect("open root");
        assert!(repo.stash_list().expect("stash list").is_empty());
    }
}

#[test]
fn multi_root_smart_checkout_reports_restore_conflict_per_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        common::git(root, &["checkout", "-q", "-b", "feature"]);
        common::commit(root, "init.txt", "feature\n", "feature work");
        common::git(root, &["checkout", "-q", "main"]);
    }
    // Only frontend conflicts; backend is clean and should still complete.
    std::fs::write(roots[0].join("init.txt"), "local\n").unwrap();

    let results = run_multi_root_checkout(
        project.display().to_string(),
        "feature".into(),
        false,
        MultiRootCheckoutMode::Smart,
    )
    .expect("smart checkout returns per-root results");
    assert_results(&results, 1, 1, 0);
    let frontend = results
        .iter()
        .find(|result| result.display_name == "frontend")
        .expect("frontend result");
    assert!(!frontend.success, "frontend restore conflict: {frontend:?}");
    let backend = results
        .iter()
        .find(|result| result.display_name == "backend")
        .expect("backend result");
    assert!(backend.success, "backend should complete: {backend:?}");
    let frontend_repo = arbor_engine::open_repository(roots[0].display().to_string()).unwrap();
    assert_eq!(frontend_repo.stash_list().unwrap().len(), 1);
}

#[test]
fn multi_root_fetch_all_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, _roots, remotes) = dual_root_project(&dir);
    // 两个远程都前进
    advance_remote(dir.path(), &remotes[0]);
    advance_remote(dir.path(), &remotes[1]);

    let results = run_multi_root_operation(
        project.display().to_string(),
        MultiRootOperation::Fetch,
        None,
    )
    .expect("fetch all");
    assert_results(&results, 2, 0, 0);
    // tracking refs 都更新到远程 HEAD
    for remote in &remotes {
        let remote_head = common::git(remote, &["rev-parse", "main"]);
        let tracking = common::git(
            &project.join("frontend"),
            &["rev-parse", "refs/remotes/origin/main"],
        );
        assert_eq!(tracking, remote_head);
        break;
    }
}

#[test]
fn multi_root_retry_operation_only_touches_selected_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    advance_remote(dir.path(), &remotes[0]);
    advance_remote(dir.path(), &remotes[1]);

    let results = run_multi_root_operation_on_roots(
        project.display().to_string(),
        vec![roots[0].display().to_string()],
        MultiRootOperation::Fetch,
        None,
    )
    .expect("selected-root fetch");
    assert_results(&results, 1, 0, 0);

    let frontend_tracking = common::git(&roots[0], &["rev-parse", "refs/remotes/origin/main"]);
    let backend_tracking = common::git(&roots[1], &["rev-parse", "refs/remotes/origin/main"]);
    assert_eq!(
        frontend_tracking,
        common::git(&remotes[0], &["rev-parse", "main"])
    );
    assert_ne!(
        backend_tracking,
        common::git(&remotes[1], &["rev-parse", "main"])
    );
}

#[test]
fn multi_root_pull_merge_partial_success() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    // 只有 frontend 远程前进
    advance_remote(dir.path(), &remotes[0]);

    let results = run_multi_root_operation(
        project.display().to_string(),
        MultiRootOperation::PullMerge,
        None,
    )
    .expect("pull all");
    assert_results(&results, 2, 0, 0);
    // frontend 拉到了新提交,backend 无变化(成功但无更新)
    let fe_log = common::git(&roots[0], &["log", "--format=%s", "main"]);
    assert!(fe_log.contains("advance"), "{fe_log}");
}

#[test]
fn multi_root_update_preserves_dirty_root_and_uses_auth_cancel_path() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    advance_remote(dir.path(), &remotes[0]);
    advance_remote(dir.path(), &remotes[1]);
    std::fs::write(roots[0].join("local.txt"), "local\n").unwrap();

    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("update all roots");
    assert_results(&results, 2, 0, 0);
    assert!(common::git(&roots[0], &["log", "--format=%s", "main"]).contains("advance"));
    assert_eq!(
        std::fs::read_to_string(roots[0].join("local.txt")).unwrap(),
        "local\n"
    );
    let repo = arbor_engine::open_repository(roots[0].display().to_string()).unwrap();
    assert!(repo.stash_list().unwrap().is_empty());
}

#[test]
fn multi_root_update_shelve_preserves_staged_and_unstaged_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    advance_remote(dir.path(), &remotes[0]);
    advance_remote(dir.path(), &remotes[1]);
    for root in &roots {
        std::fs::write(root.join("init.txt"), "staged local\n").unwrap();
        common::git(root, &["add", "init.txt"]);
        std::fs::write(root.join("unstaged.txt"), "unstaged local\n").unwrap();
    }

    let results = run_multi_root_update_with_policy(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Shelve,
    )
    .expect("shelve update all roots");
    assert_results(&results, 2, 0, 0);

    for root in &roots {
        let repo = open_repository(root.display().to_string()).unwrap();
        let status = repo.status().unwrap();
        let staged = status
            .iter()
            .find(|entry| entry.path == "init.txt")
            .unwrap();
        assert_eq!(staged.staged, arbor_engine::ChangeKind::Modified);
        assert_eq!(staged.unstaged, arbor_engine::ChangeKind::Unchanged);
        let unstaged = status
            .iter()
            .find(|entry| entry.path == "unstaged.txt")
            .unwrap();
        assert_eq!(unstaged.staged, arbor_engine::ChangeKind::Unchanged);
        assert_eq!(unstaged.unstaged, arbor_engine::ChangeKind::Untracked);
        assert!(repo.shelve_list().unwrap().is_empty());
    }
}

#[test]
fn multi_root_update_selected_retries_only_requested_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    advance_remote(dir.path(), &remotes[0]);
    advance_remote(dir.path(), &remotes[1]);

    let results = run_multi_root_update_selected_with_policy(
        project.display().to_string(),
        Some(vec![roots[0].display().to_string()]),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Shelve,
    )
    .expect("selected root update");
    assert_eq!(results.len(), 1);
    assert_eq!(
        results[0].root_path,
        std::fs::canonicalize(&roots[0])
            .unwrap()
            .display()
            .to_string()
    );
    assert!(results[0].success, "selected root failed: {results:?}");
    assert!(common::git(&roots[0], &["log", "--format=%s", "main"]).contains("advance"));
    assert!(!common::git(&roots[1], &["log", "--format=%s", "main"]).contains("advance"));
}

#[test]
fn multi_root_update_keeps_stash_when_restore_conflicts() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    std::fs::write(roots[0].join("init.txt"), "local\n").unwrap();
    advance_remote_conflicting(dir.path(), &remotes[0]);

    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("update all roots");
    assert_results(&results, 1, 1, 0);

    let frontend = results
        .iter()
        .find(|result| result.display_name == "frontend")
        .expect("frontend result");
    assert!(!frontend.success, "restore conflict: {frontend:?}");
    assert!(frontend.message.contains("restore conflicted"));
    let backend = results
        .iter()
        .find(|result| result.display_name == "backend")
        .expect("backend result");
    assert!(backend.success, "backend should complete: {backend:?}");

    let repo = arbor_engine::open_repository(roots[0].display().to_string()).unwrap();
    assert_eq!(repo.stash_list().unwrap().len(), 1);
    let content = std::fs::read_to_string(roots[0].join("init.txt")).unwrap();
    assert!(content.contains("<<<<<<<") && content.contains(">>>>>>>"));
}

#[test]
fn multi_root_update_shelve_restore_conflict_is_persisted_for_recovery() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    std::fs::write(roots[0].join("init.txt"), "local\n").unwrap();
    advance_remote_conflicting(dir.path(), &remotes[0]);

    let results = run_multi_root_update_with_policy(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Shelve,
    )
    .expect("shelve update returns restore conflict");
    assert_results(&results, 1, 1, 0);

    let frontend = results
        .iter()
        .find(|result| result.display_name == "frontend")
        .expect("frontend result");
    assert!(!frontend.success, "restore conflict: {frontend:?}");
    assert!(frontend.message.contains("restore from Shelf conflicted"));

    let repo = open_repository(roots[0].display().to_string()).unwrap();
    let restore = repo
        .shelve_restore_info()
        .unwrap()
        .expect("Shelf restore marker survives conflict");
    assert!(restore.is_pop);
    assert!(!restore.paths.is_empty());
    assert!(repo
        .shelve_list()
        .unwrap()
        .iter()
        .any(|shelf| shelf.name.starts_with("Arbor: Update Project")));
}

#[test]
fn multi_root_update_skips_root_without_upstream() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    advance_remote(dir.path(), &remotes[0]);
    common::git(&roots[1], &["branch", "--unset-upstream"]);

    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("update all roots");
    assert_results(&results, 1, 0, 1);
    let skipped = results
        .iter()
        .find(|result| result.display_name == "backend")
        .expect("backend result");
    assert!(skipped.skipped);
    assert!(skipped.message.contains("upstream"));
}

#[test]
fn multi_root_update_is_globally_not_ready_before_touching_other_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);

    // Leave the frontend in a real merge-conflict state. The backend remote
    // advances independently so a per-root readiness check would otherwise
    // fetch and update it before discovering the frontend blocker.
    common::git(&roots[0], &["switch", "-q", "-c", "feature"]);
    common::commit(&roots[0], "init.txt", "feature\n", "feature change");
    common::git(&roots[0], &["switch", "-q", "main"]);
    common::commit(&roots[0], "init.txt", "main\n", "main change");
    common::git_allow_failure(&roots[0], &["merge", "feature"]);

    let frontend_head = common::git(&roots[0], &["rev-parse", "HEAD"]);
    let backend_head = common::git(&roots[1], &["rev-parse", "HEAD"]);
    let backend_tracking = common::git(&roots[1], &["rev-parse", "refs/remotes/origin/main"]);
    advance_remote(dir.path(), &remotes[1]);

    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("not-ready update returns per-root results");

    let frontend = results
        .iter()
        .find(|result| result.display_name == "frontend")
        .expect("frontend result");
    assert!(
        !frontend.success && !frontend.skipped,
        "frontend: {frontend:?}"
    );
    assert!(frontend.message.contains("update not ready"));
    let backend = results
        .iter()
        .find(|result| result.display_name == "backend")
        .expect("backend result");
    assert!(backend.success && backend.skipped, "backend: {backend:?}");
    assert!(backend.message.contains("not ready"));

    assert_eq!(
        common::git(&roots[0], &["rev-parse", "HEAD"]),
        frontend_head
    );
    assert_eq!(common::git(&roots[1], &["rev-parse", "HEAD"]), backend_head);
    assert_eq!(
        common::git(&roots[1], &["rev-parse", "refs/remotes/origin/main"]),
        backend_tracking
    );
}

#[test]
fn multi_root_update_reports_pre_cancelled_roots_as_skipped() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    let cancel = GitCancelHandle::new();
    cancel.cancel();

    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        cancel,
    )
    .expect("pre-cancelled update returns per-root results");

    assert_eq!(results.len(), roots.len());
    assert!(results.iter().all(|result| {
        result.success && result.skipped && result.message.contains("cancelled before update")
    }));
}

#[test]
fn restore_head_if_expected_rolls_back_branch_and_detached_head() {
    let repo_fixture = common::TestRepo::new();
    let initial = common::commit(&repo_fixture.path, "initial.txt", "initial\n", "initial");
    let expected = common::commit(&repo_fixture.path, "expected.txt", "expected\n", "expected");
    let repo = repo_fixture.open();

    repo.restore_head_if_expected(initial.clone(), expected.clone())
        .expect("branch rollback");
    assert_eq!(
        common::git(&repo_fixture.path, &["rev-parse", "HEAD"]),
        initial
    );

    common::git(&repo_fixture.path, &["switch", "--detach", &expected]);
    repo.restore_head_if_expected(initial.clone(), expected)
        .expect("detached rollback");
    assert_eq!(
        common::git(&repo_fixture.path, &["rev-parse", "HEAD"]),
        initial
    );

    common::git(
        &repo_fixture.path,
        &["switch", "-c", "update-target", &initial],
    );
    let branch_expected = common::commit(
        &repo_fixture.path,
        "branch-expected.txt",
        "expected\n",
        "branch expected",
    );
    common::git(
        &repo_fixture.path,
        &["branch", "same-tip", &branch_expected],
    );
    common::git(&repo_fixture.path, &["switch", "same-tip"]);
    let rollback_error = repo
        .restore_head_if_expected_with_ignored_paths_and_branch(
            initial,
            branch_expected.clone(),
            Some("update-target".into()),
            Vec::new(),
        )
        .expect_err("rollback must reject a different branch at the same commit");
    assert!(rollback_error
        .to_string()
        .contains("HEAD reference changed"));
    assert_eq!(
        common::git(&repo_fixture.path, &["rev-parse", "HEAD"]),
        branch_expected
    );
}

#[test]
fn multi_root_update_updates_detached_submodule_from_parent_and_restores_local_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, source, submodule, remote) = detached_submodule_project(dir.path());
    common::commit(&source, "next.txt", "next\n", "submodule advance");
    let publisher = dir.path().join("publisher");
    common::git(
        dir.path(),
        &[
            "clone",
            "-q",
            "-b",
            "main",
            &remote.display().to_string(),
            "publisher",
        ],
    );
    common::git(&publisher, &["config", "user.name", "Arbor Test"]);
    common::git(&publisher, &["config", "user.email", "test@arbor.local"]);
    common::git(&publisher, &["config", "protocol.file.allow", "always"]);
    common::git(
        &publisher,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--init",
            "--remote",
            "--",
            "vendor/lib",
        ],
    );
    common::git(&publisher, &["add", "vendor/lib"]);
    common::git(&publisher, &["commit", "-q", "-m", "advance submodule"]);
    common::git(&publisher, &["push", "-q", "origin", "main"]);
    std::fs::remove_dir_all(&publisher).unwrap();
    std::fs::write(submodule.join("local.txt"), "keep me\n").unwrap();
    let source_head = common::git(&source, &["rev-parse", "HEAD"]);
    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("update detached submodule");

    assert_eq!(results.len(), 2, "outer root and submodule root");
    let outer = results
        .iter()
        .find(|result| result.display_name == "project")
        .expect("outer result");
    assert!(outer.success && !outer.skipped, "outer update: {outer:?}");
    let nested = results
        .iter()
        .find(|result| result.display_name == "lib")
        .expect("submodule result");
    assert!(
        nested.success && !nested.skipped,
        "submodule update: {nested:?}"
    );
    assert!(
        nested.message.contains("detached submodule"),
        "unexpected nested message: {nested:?}"
    );
    assert_eq!(common::git(&submodule, &["rev-parse", "HEAD"]), source_head);
    assert_eq!(
        std::fs::read_to_string(submodule.join("local.txt")).unwrap(),
        "keep me\n"
    );
    let repo = arbor_engine::open_repository(submodule.display().to_string()).unwrap();
    assert!(repo.stash_list().unwrap().is_empty());
}

#[test]
fn standalone_submodule_update_is_parent_scoped_and_preserves_dirty_worktree() {
    for save_policy in [
        LocalChangesSavePolicy::Stash,
        LocalChangesSavePolicy::Shelve,
    ] {
        let dir = tempfile::tempdir().expect("tempdir");
        let (project, source, submodule, _remote) = detached_submodule_project(dir.path());
        let old_source_head = common::git(&source, &["rev-parse", "HEAD"]);
        common::commit(&source, "next.txt", "next\n", "submodule advance");
        let new_source_head = common::git(&source, &["rev-parse", "HEAD"]);

        // Advance only the parent's gitlink. The standalone updater must
        // consume this parent state, not pull the parent repository first.
        common::git(
            &project,
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "update",
                "--remote",
                "--",
                "vendor/lib",
            ],
        );
        common::git(&project, &["add", "vendor/lib"]);
        common::git(&project, &["commit", "-q", "-m", "advance submodule"]);
        common::git(&submodule, &["checkout", "-q", &old_source_head]);
        std::fs::write(submodule.join("local.txt"), "keep me\n").unwrap();
        let parent_head_before = common::git(&project, &["rev-parse", "HEAD"]);

        let result = run_submodule_update_with_policy(
            project.display().to_string(),
            "vendor/lib".into(),
            true,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            save_policy,
        )
        .expect("standalone submodule update");

        assert!(result.success && !result.skipped, "result: {result:?}");
        assert!(result.message.contains("restored local changes"));
        assert_eq!(
            common::git(&submodule, &["rev-parse", "HEAD"]),
            new_source_head
        );
        assert_eq!(
            std::fs::read_to_string(submodule.join("local.txt")).unwrap(),
            "keep me\n"
        );
        assert_eq!(
            common::git(&project, &["rev-parse", "HEAD"]),
            parent_head_before,
            "standalone update must not pull or rewrite the parent"
        );
        let submodule_repo = open_repository(submodule.display().to_string()).unwrap();
        assert!(submodule_repo.stash_list().unwrap().is_empty());
        assert!(submodule_repo.shelve_list().unwrap().is_empty());
    }
}

#[test]
fn standalone_submodule_update_preserves_recursive_descendant_worktrees() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, tool_source, child_source, tool, _remote) =
        detached_nested_submodule_project(dir.path());
    let child = project.join("vendor/lib");
    let old_child_head = common::git(&child, &["rev-parse", "HEAD"]);
    let old_tool_head = common::git(&tool, &["rev-parse", "HEAD"]);

    common::commit(&tool_source, "next.txt", "next\n", "tool advance");
    common::git(
        &child_source,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--remote",
            "--",
            "nested/tool",
        ],
    );
    common::git(&child_source, &["add", "nested/tool"]);
    common::git(
        &child_source,
        &["commit", "-q", "-m", "advance nested tool"],
    );
    let new_child_head = common::git(&child_source, &["rev-parse", "HEAD"]);
    let new_tool_head = common::git(&tool_source, &["rev-parse", "HEAD"]);
    common::git(
        &project,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--remote",
            "--recursive",
            "--",
            "vendor/lib",
        ],
    );
    common::git(&project, &["add", "vendor/lib"]);
    common::git(&project, &["commit", "-q", "-m", "advance child submodule"]);
    common::git(&child, &["checkout", "-q", &old_child_head]);
    common::git(&tool, &["checkout", "-q", &old_tool_head]);
    std::fs::write(child.join("local-child.txt"), "keep child\n").unwrap();
    std::fs::write(tool.join("local-tool.txt"), "keep tool\n").unwrap();
    let parent_head_before = common::git(&project, &["rev-parse", "HEAD"]);

    let result = run_submodule_update_with_policy(
        project.display().to_string(),
        "vendor/lib".into(),
        true,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .expect("recursive standalone submodule update");

    assert!(result.success && !result.skipped, "result: {result:?}");
    assert_eq!(common::git(&child, &["rev-parse", "HEAD"]), new_child_head);
    assert_eq!(common::git(&tool, &["rev-parse", "HEAD"]), new_tool_head);
    assert_eq!(
        std::fs::read_to_string(child.join("local-child.txt")).unwrap(),
        "keep child\n"
    );
    assert_eq!(
        std::fs::read_to_string(tool.join("local-tool.txt")).unwrap(),
        "keep tool\n"
    );
    assert_eq!(
        common::git(&project, &["rev-parse", "HEAD"]),
        parent_head_before,
        "recursive standalone update must not rewrite the parent"
    );
    for root in [&child, &tool] {
        let repo = open_repository(root.display().to_string()).unwrap();
        assert!(
            repo.stash_list().unwrap().is_empty(),
            "stash leaked in {root:?}"
        );
    }
}

#[test]
fn standalone_submodule_update_persists_restore_marker_on_restore_conflict() {
    for save_policy in [
        LocalChangesSavePolicy::Stash,
        LocalChangesSavePolicy::Shelve,
    ] {
        let dir = tempfile::tempdir().expect("tempdir");
        let (project, source, submodule, _remote) = detached_submodule_project(dir.path());
        let old_source_head = common::git(&source, &["rev-parse", "HEAD"]);
        common::commit(
            &source,
            "lib.txt",
            "remote\n",
            "conflicting submodule advance",
        );
        common::git(
            &project,
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "update",
                "--remote",
                "--",
                "vendor/lib",
            ],
        );
        common::git(&project, &["add", "vendor/lib"]);
        common::git(&project, &["commit", "-q", "-m", "advance submodule"]);
        common::git(&submodule, &["checkout", "-q", &old_source_head]);
        std::fs::write(submodule.join("lib.txt"), "local\n").unwrap();

        let result = run_submodule_update_with_policy(
            project.display().to_string(),
            "vendor/lib".into(),
            true,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            save_policy,
        );
        assert!(
            result.is_err(),
            "the conflicting local scene must not be hidden"
        );
        let submodule_repo = open_repository(submodule.display().to_string()).unwrap();
        let restore = submodule_repo
            .apply_local_changes_restore_info()
            .expect("read durable restore marker")
            .expect("restore marker after conflict");
        assert_eq!(restore.operation, "submodule-update");
        assert_eq!(
            restore.kind,
            match save_policy {
                LocalChangesSavePolicy::Stash => "stash",
                LocalChangesSavePolicy::Shelve => "shelf",
            }
        );
        assert!(!restore.identifier.is_empty());
        let second_attempt = run_submodule_update_with_policy(
            project.display().to_string(),
            "vendor/lib".into(),
            true,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            save_policy,
        );
        assert!(
            second_attempt.is_err(),
            "a pending restore marker must block replacing the saved scene"
        );
        let preserved_restore = submodule_repo
            .apply_local_changes_restore_info()
            .unwrap()
            .unwrap();
        assert_eq!(preserved_restore.identifier, restore.identifier);
        match save_policy {
            LocalChangesSavePolicy::Stash => {
                assert!(!submodule_repo.stash_list().unwrap().is_empty())
            }
            LocalChangesSavePolicy::Shelve => {
                assert!(!submodule_repo.shelve_list().unwrap().is_empty())
            }
        }
    }
}

#[test]
fn multi_root_update_keeps_detached_submodule_scene_when_parent_update_fails() {
    for save_policy in [
        LocalChangesSavePolicy::Stash,
        LocalChangesSavePolicy::Shelve,
    ] {
        let dir = tempfile::tempdir().expect("tempdir");
        let (project, _source, submodule, _remote) = detached_submodule_project(dir.path());
        let invalid_remote = dir.path().join("missing-parent.git");
        common::git(
            &project,
            &[
                "remote",
                "set-url",
                "origin",
                &invalid_remote.display().to_string(),
            ],
        );
        std::fs::write(submodule.join("local.txt"), "keep me for recovery\n").unwrap();

        let results = run_multi_root_update_with_policy(
            project.display().to_string(),
            false,
            CredentialBroker::new(),
            GitCancelHandle::new(),
            save_policy,
        )
        .expect("update returns per-root failure");

        let parent = results
            .iter()
            .find(|result| result.display_name == "project")
            .expect("parent result");
        assert!(!parent.success, "parent update should fail: {parent:?}");
        let nested = results
            .iter()
            .find(|result| result.display_name == "lib")
            .expect("submodule result");
        assert!(
            !nested.success,
            "submodule scene must be part of the failed compound update: {nested:?}"
        );
        let expected_marker = match save_policy {
            LocalChangesSavePolicy::Stash => "local changes remain in stash",
            LocalChangesSavePolicy::Shelve => "local changes remain in Shelf",
        };
        assert!(
            nested.message.contains(expected_marker),
            "nested recovery message missing: {nested:?}"
        );

        let nested_repo = open_repository(submodule.display().to_string()).unwrap();
        match save_policy {
            LocalChangesSavePolicy::Stash => {
                assert_eq!(nested_repo.stash_list().unwrap().len(), 1);
            }
            LocalChangesSavePolicy::Shelve => {
                assert!(nested_repo
                    .shelve_list()
                    .unwrap()
                    .iter()
                    .any(|shelf| shelf.name.starts_with("Arbor: Update Project (submodule)")));
            }
        }
        assert!(
            !submodule.join("local.txt").exists(),
            "the saved scene must remain out of the worktree until recovery"
        );
    }
}

#[test]
fn multi_root_update_rollback_restores_advanced_gitlinks_after_nested_failure() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, _tool_source, child_source, tool, remote) =
        detached_nested_submodule_project(dir.path());
    let child = project.join("vendor/lib");
    let initial_parent = common::git(&project, &["rev-parse", "HEAD"]);
    let initial_child = common::git(&child, &["rev-parse", "HEAD"]);
    let initial_tool = common::git(&tool, &["rev-parse", "HEAD"]);

    let missing_tool_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    let cacheinfo = format!("160000,{missing_tool_commit},nested/tool");
    common::git(
        &child_source,
        &["update-index", "--add", "--cacheinfo", &cacheinfo],
    );
    common::git(
        &child_source,
        &["commit", "-q", "-m", "point at missing nested tool"],
    );
    let advanced_child = common::git(&child_source, &["rev-parse", "HEAD"]);

    let publisher = dir.path().join("publisher");
    common::git(
        dir.path(),
        &[
            "clone",
            "-q",
            "-b",
            "main",
            &remote.display().to_string(),
            "publisher",
        ],
    );
    common::git(&publisher, &["config", "user.name", "Arbor Test"]);
    common::git(&publisher, &["config", "user.email", "test@arbor.local"]);
    common::git(&publisher, &["config", "protocol.file.allow", "always"]);
    common::git(
        &publisher,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--init",
            "--remote",
            "--",
            "vendor/lib",
        ],
    );
    assert_eq!(
        common::git(&publisher.join("vendor/lib"), &["rev-parse", "HEAD"]),
        advanced_child
    );
    common::git(&publisher, &["add", "vendor/lib"]);
    common::git(&publisher, &["commit", "-q", "-m", "advance child gitlink"]);
    common::git(&publisher, &["push", "-q", "origin", "main"]);
    std::fs::remove_dir_all(&publisher).unwrap();

    std::fs::write(child.join("local-child.txt"), "keep child\n").unwrap();
    std::fs::write(tool.join("local-tool.txt"), "keep tool\n").unwrap();

    let results = run_multi_root_update_with_policy(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .expect("nested failure returns per-root results");
    assert_eq!(results.len(), 3, "results: {results:?}");
    let parent = results
        .iter()
        .find(|result| result.display_name == "project")
        .expect("parent result");
    let child_result = results
        .iter()
        .find(|result| result.display_name == "lib")
        .expect("child result");
    let tool_result = results
        .iter()
        .find(|result| result.display_name == "tool")
        .expect("tool result");
    assert!(
        parent.success && !parent.skipped,
        "parent should advance: {parent:?}"
    );
    assert!(
        !child_result.success,
        "child scene must remain recoverable: {child_result:?}"
    );
    assert!(
        !tool_result.success,
        "nested failure should be visible: {tool_result:?}"
    );

    let advanced_parent = common::git(&project, &["rev-parse", "HEAD"]);
    assert_ne!(advanced_parent, initial_parent);
    assert_eq!(common::git(&child, &["rev-parse", "HEAD"]), advanced_child);
    assert_eq!(common::git(&tool, &["rev-parse", "HEAD"]), initial_tool);
    assert_eq!(
        open_repository(child.display().to_string())
            .unwrap()
            .stash_list()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        open_repository(tool.display().to_string())
            .unwrap()
            .stash_list()
            .unwrap()
            .len(),
        1
    );

    open_repository(child.display().to_string())
        .unwrap()
        .restore_head_if_expected_with_ignored_paths(
            initial_child.clone(),
            advanced_child.clone(),
            vec!["nested/tool".into()],
        )
        .expect("child rollback target");
    assert!(child.exists(), "child worktree must survive child rollback");
    open_repository(project.display().to_string())
        .unwrap()
        .restore_head_if_expected_with_ignored_paths(
            initial_parent.clone(),
            advanced_parent.clone(),
            vec!["vendor/lib".into(), "vendor/lib/nested/tool".into()],
        )
        .expect("parent rollback target");
    assert!(
        child.exists(),
        "child worktree must survive parent rollback"
    );

    assert_eq!(
        common::git(&project, &["rev-parse", "HEAD"]),
        initial_parent
    );
    assert_eq!(common::git(&child, &["rev-parse", "HEAD"]), initial_child);
    if tool.exists() {
        assert_eq!(common::git(&tool, &["rev-parse", "HEAD"]), initial_tool);
    }
    assert_eq!(
        open_repository(child.display().to_string())
            .unwrap()
            .stash_list()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        open_repository(tool.display().to_string())
            .unwrap()
            .stash_list()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn push_recovery_updates_parent_without_clobbering_submodule_or_parent_worktrees() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, _source, submodule, remote) = detached_submodule_project(dir.path());
    advance_remote(dir.path(), &remote);
    std::fs::write(submodule.join("local.txt"), "keep child\n").unwrap();
    std::fs::write(project.join("local.txt"), "keep parent\n").unwrap();

    let result = run_root_update_for_push_recovery(
        project.display().to_string(),
        "origin".into(),
        "main".into(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .expect("Push recovery update");

    assert!(result.success, "parent update failed: {result:?}");
    assert!(
        project.join("adv.txt").exists(),
        "parent remote commit applied"
    );
    assert_eq!(
        std::fs::read_to_string(project.join("local.txt")).unwrap(),
        "keep parent\n"
    );
    assert_eq!(
        std::fs::read_to_string(submodule.join("local.txt")).unwrap(),
        "keep child\n"
    );
    let child_repo = open_repository(submodule.display().to_string()).unwrap();
    assert!(
        child_repo
            .status()
            .unwrap()
            .iter()
            .any(|entry| entry.path == "local.txt"),
        "child worktree remains dirty after restore"
    );
}

#[test]
fn multi_root_push_recovery_updates_and_republishes_selected_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, _source, _submodule, remote) = detached_submodule_project(dir.path());
    advance_remote(dir.path(), &remote);
    common::commit(&project, "local.txt", "local\n", "local parent work");

    let results = run_multi_root_push_recovery(
        project.display().to_string(),
        Some(vec![project.display().to_string()]),
        None,
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .expect("Push recovery all");

    assert_eq!(
        results.len(),
        1,
        "only the selected superproject is recovered"
    );
    assert!(results[0].success, "recovery push failed: {:?}", results[0]);
    assert!(project.join("adv.txt").exists());
    assert_eq!(
        common::git(&project, &["rev-list", "--count", "origin/main..main"]),
        "0"
    );
}

#[test]
fn multi_root_push_recovery_updates_all_roots_but_repushes_only_rejected_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    common::commit(&roots[0], "local-frontend.txt", "local\n", "local frontend");
    common::commit(&roots[1], "local-backend.txt", "local\n", "local backend");
    advance_remote(dir.path(), &remotes[0]);

    let initial = run_multi_root_push(
        project.display().to_string(),
        None,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("initial Push All");
    let frontend = initial
        .iter()
        .find(|result| result.display_name == "frontend")
        .unwrap_or_else(|| panic!("frontend result missing: {initial:?}"));
    let backend = initial
        .iter()
        .find(|result| result.display_name == "backend")
        .unwrap_or_else(|| panic!("backend result missing: {initial:?}"));
    assert!(!frontend.success, "frontend should remain rejected");
    assert!(
        backend.success,
        "backend should already be published: {backend:?}"
    );

    let results = run_multi_root_push_recovery(
        project.display().to_string(),
        Some(vec![roots[0].display().to_string()]),
        Some(
            roots
                .iter()
                .map(|root| root.display().to_string())
                .collect(),
        ),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .expect("Push recovery");

    assert_eq!(results.len(), 2, "all project roots should be updated");
    assert!(results.iter().all(|result| result.success));
    assert_eq!(
        common::git(&roots[0], &["rev-list", "--count", "origin/main..main"]),
        "0"
    );
    assert_eq!(
        common::git(&roots[1], &["rev-list", "--count", "origin/main..main"]),
        "0"
    );
    assert_eq!(
        common::git(&roots[1], &["log", "-1", "--format=%s"]),
        "local backend"
    );
}

#[test]
fn multi_root_update_processes_nested_detached_submodules_in_parent_order() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, tool_source, child_source, tool, remote) =
        detached_nested_submodule_project(dir.path());
    common::commit(&tool_source, "next.txt", "next\n", "tool advance");
    common::git(
        &child_source,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--remote",
            "--",
            "nested/tool",
        ],
    );
    common::git(&child_source, &["add", "nested/tool"]);
    common::git(
        &child_source,
        &["commit", "-q", "-m", "advance nested tool"],
    );

    let publisher = dir.path().join("publisher");
    common::git(
        dir.path(),
        &[
            "clone",
            "-q",
            "-b",
            "main",
            &remote.display().to_string(),
            "publisher",
        ],
    );
    common::git(&publisher, &["config", "user.name", "Arbor Test"]);
    common::git(&publisher, &["config", "user.email", "test@arbor.local"]);
    common::git(&publisher, &["config", "protocol.file.allow", "always"]);
    common::git(
        &publisher,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "--init",
            "--remote",
            "--recursive",
            "--",
            "vendor/lib",
        ],
    );
    common::git(&publisher, &["add", "vendor/lib"]);
    common::git(
        &publisher,
        &["commit", "-q", "-m", "advance child submodule"],
    );
    common::git(&publisher, &["push", "-q", "origin", "main"]);
    std::fs::remove_dir_all(&publisher).unwrap();

    let child_head_before = common::git(&project.join("vendor/lib"), &["rev-parse", "HEAD"]);
    std::fs::write(project.join("vendor/lib/local.txt"), "keep child\n").unwrap();
    std::fs::write(tool.join("local.txt"), "keep tool\n").unwrap();
    let tool_head = common::git(&tool_source, &["rev-parse", "HEAD"]);
    let discovered = discover_git_roots(project.display().to_string(), None).expect("roots");
    assert_eq!(discovered.len(), 3, "discovered: {discovered:?}");

    let results = run_multi_root_update(
        project.display().to_string(),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("update nested detached submodules");

    assert_eq!(results.len(), 3, "results: {results:?}");
    assert!(
        results
            .iter()
            .all(|result| result.success && !result.skipped),
        "results: {results:?}"
    );
    assert_ne!(
        common::git(&project.join("vendor/lib"), &["rev-parse", "HEAD"]),
        child_head_before
    );
    assert_eq!(common::git(&tool, &["rev-parse", "HEAD"]), tool_head);
    assert_eq!(
        std::fs::read_to_string(project.join("vendor/lib/local.txt")).unwrap(),
        "keep child\n"
    );
    assert_eq!(
        std::fs::read_to_string(tool.join("local.txt")).unwrap(),
        "keep tool\n"
    );
    for root in [project.join("vendor/lib"), tool] {
        let repo = arbor_engine::open_repository(root.display().to_string()).unwrap();
        assert!(
            repo.stash_list().unwrap().is_empty(),
            "stash leaked in {root:?}"
        );
    }
}

#[test]
fn selected_submodule_update_retry_includes_nested_descendants() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, _tool_source, _child_source, tool, _remote) =
        detached_nested_submodule_project(dir.path());
    let child = project.join("vendor/lib");

    let results = run_multi_root_update_selected_with_policy(
        project.display().to_string(),
        Some(vec![child.display().to_string()]),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Stash,
    )
    .expect("selected submodule update");
    let project_path = std::fs::canonicalize(&project)
        .unwrap()
        .display()
        .to_string();
    let child_path = std::fs::canonicalize(&child).unwrap().display().to_string();
    let tool_path = std::fs::canonicalize(&tool).unwrap().display().to_string();

    assert_eq!(
        results.len(),
        3,
        "retrying a submodule must include its parent and nested descendants: {results:?}"
    );
    assert!(
        results
            .iter()
            .any(|result| result.root_path == project_path),
        "parent root was not included: {results:?}"
    );
    assert!(
        results.iter().any(|result| result.root_path == child_path),
        "selected submodule was not included: {results:?}"
    );
    assert!(
        results.iter().any(|result| result.root_path == tool_path),
        "nested submodule was not included: {results:?}"
    );
}

#[test]
fn multi_root_checkout_and_update_updates_only_checked_out_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    create_feature_branch(&roots);
    advance_remote_branch(dir.path(), &remotes[0], "feature");
    advance_remote_branch(dir.path(), &remotes[1], "feature");

    let results = run_multi_root_checkout_and_update(
        project.display().to_string(),
        None,
        "feature".into(),
        false,
        false,
        MultiRootCheckoutMode::Normal,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("checkout and update all roots");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "feature"
        );
        assert!(common::git(root, &["log", "--format=%s", "feature"]).contains("advance feature"));
    }
}

#[test]
fn multi_root_checkout_and_update_can_scope_to_one_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    create_feature_branch(&roots);
    advance_remote_branch(dir.path(), &remotes[0], "feature");
    advance_remote_branch(dir.path(), &remotes[1], "feature");

    let results = run_multi_root_checkout_and_update(
        project.display().to_string(),
        Some(vec![roots[0].display().to_string()]),
        "feature".into(),
        false,
        false,
        MultiRootCheckoutMode::Normal,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("checkout and update selected root");
    assert_results(&results, 1, 0, 0);
    assert_eq!(
        results[0].root_path,
        std::fs::canonicalize(&roots[0])
            .unwrap()
            .display()
            .to_string()
    );
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "feature"
    );
    assert_eq!(
        common::git(&roots[1], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert!(!common::git(&roots[1], &["log", "--format=%s", "main"]).contains("advance feature"));
}

#[test]
fn multi_root_checkout_and_update_smart_restores_local_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    create_feature_branch(&roots);
    for root in &roots {
        std::fs::write(root.join("local.txt"), "local\n").unwrap();
    }
    advance_remote_branch(dir.path(), &remotes[0], "feature");
    advance_remote_branch(dir.path(), &remotes[1], "feature");

    let results = run_multi_root_checkout_and_update(
        project.display().to_string(),
        None,
        "feature".into(),
        false,
        false,
        MultiRootCheckoutMode::Smart,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("smart checkout and update all roots");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "feature"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("local.txt")).unwrap(),
            "local\n"
        );
        let repo = arbor_engine::open_repository(root.display().to_string()).unwrap();
        assert!(repo.stash_list().unwrap().is_empty());
    }
}

#[test]
fn multi_root_checkout_and_update_shelve_preserves_staged_and_unstaged_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    create_feature_branch(&roots);
    for root in &roots {
        std::fs::write(root.join("init.txt"), "staged local\n").unwrap();
        common::git(root, &["add", "init.txt"]);
        std::fs::write(root.join("unstaged.txt"), "unstaged local\n").unwrap();
    }
    advance_remote_branch(dir.path(), &remotes[0], "feature");
    advance_remote_branch(dir.path(), &remotes[1], "feature");

    let results = run_multi_root_checkout_and_update_with_policy(
        project.display().to_string(),
        None,
        "feature".into(),
        false,
        false,
        MultiRootCheckoutMode::Smart,
        CredentialBroker::new(),
        GitCancelHandle::new(),
        LocalChangesSavePolicy::Shelve,
    )
    .expect("shelve checkout and update all roots");
    assert_results(&results, 2, 0, 0);

    for root in &roots {
        let repo = open_repository(root.display().to_string()).unwrap();
        let status = repo.status().unwrap();
        let staged = status
            .iter()
            .find(|entry| entry.path == "init.txt")
            .unwrap();
        assert_eq!(staged.staged, arbor_engine::ChangeKind::Modified);
        assert_eq!(staged.unstaged, arbor_engine::ChangeKind::Unchanged);
        let unstaged = status
            .iter()
            .find(|entry| entry.path == "unstaged.txt")
            .unwrap();
        assert_eq!(unstaged.staged, arbor_engine::ChangeKind::Unchanged);
        assert_eq!(unstaged.unstaged, arbor_engine::ChangeKind::Untracked);
        assert!(repo.shelve_list().unwrap().is_empty());
    }
}

#[test]
fn multi_root_checkout_and_update_keeps_stash_when_update_conflicts() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    create_feature_branch(&roots);

    // Diverge the selected local feature branch from its remote so Update
    // enters a merge conflict after Smart checkout has saved the outer scene.
    common::git(&roots[0], &["switch", "-q", "feature"]);
    common::commit(
        &roots[0],
        "init.txt",
        "local feature\n",
        "local feature conflict",
    );
    common::git(&roots[0], &["switch", "-q", "main"]);
    advance_remote_branch_conflicting(dir.path(), &remotes[0], "feature");
    std::fs::write(roots[0].join("init.txt"), "local workspace\n").unwrap();

    let results = run_multi_root_checkout_and_update(
        project.display().to_string(),
        Some(vec![roots[0].display().to_string()]),
        "feature".into(),
        false,
        false,
        MultiRootCheckoutMode::Smart,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("compound update returns conflict state");
    assert_results(&results, 0, 1, 0);
    assert!(results[0].message.contains("operation is active"));
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "feature"
    );
    let repo = arbor_engine::open_repository(roots[0].display().to_string()).unwrap();
    assert!(repo.operation_state().unwrap().is_some());
    assert_eq!(repo.stash_list().unwrap().len(), 1);
}

#[test]
fn multi_root_checkout_rollback_deletes_created_remote_branch() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);

    for root in &roots {
        common::git(root, &["switch", "-q", "-c", "feature-remote"]);
        common::git(root, &["push", "-q", "-u", "origin", "feature-remote"]);
        common::git(root, &["switch", "-q", "main"]);
        common::git(root, &["branch", "-D", "feature-remote"]);
    }

    let discovered = discover_git_roots(project.display().to_string(), None)
        .expect("discover roots before remote checkout");
    let results = run_multi_root_checkout(
        project.display().to_string(),
        "origin/feature-remote".into(),
        false,
        MultiRootCheckoutMode::Normal,
    )
    .expect("checkout remote branch");
    assert_results(&results, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "feature-remote"
        );
    }

    let checked_out_roots = discover_git_roots(project.display().to_string(), None)
        .expect("discover roots after remote checkout");
    let targets = discovered
        .iter()
        .map(|root| MultiRootBranchTarget {
            root_path: root.path.clone(),
            checked_out: true,
            previous_branch: root.head_branch.clone(),
            previous_head: root.head_id.clone(),
            expected_head: checked_out_roots
                .iter()
                .find(|current| current.path == root.path)
                .and_then(|current| current.head_id.clone()),
            expected_branch: checked_out_roots
                .iter()
                .find(|current| current.path == root.path)
                .and_then(|current| current.head_branch.clone()),
            created_branch: Some("feature-remote".into()),
        })
        .collect();
    let rollback = restore_multi_root_checkout(targets).expect("rollback remote checkout");
    assert_results(&rollback, 2, 0, 0);
    for root in &roots {
        assert_eq!(
            common::git(root, &["symbolic-ref", "--short", "HEAD"]),
            "main"
        );
        assert!(common::git(root, &["branch", "--list", "feature-remote"]).is_empty());
    }
}

#[test]
fn multi_root_checkout_and_update_rolls_back_checkout_phase() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    create_feature_branch(&roots[0..1]);
    std::fs::write(roots[0].join("local.txt"), "local\n").unwrap();

    let results = run_multi_root_checkout_and_update(
        project.display().to_string(),
        None,
        "feature".into(),
        false,
        false,
        MultiRootCheckoutMode::Smart,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("partial checkout should return recoverable results");
    assert_eq!(results.len(), 2);
    assert!(results.iter().all(|result| !result.success));
    assert!(results[0].message.contains("rolled back"));
    assert_eq!(
        common::git(&roots[0], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert_eq!(
        common::git(&roots[1], &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert_eq!(
        std::fs::read_to_string(roots[0].join("local.txt")).unwrap(),
        "local\n"
    );
    let repo = arbor_engine::open_repository(roots[0].display().to_string()).unwrap();
    assert!(repo.stash_list().unwrap().is_empty());
}

#[test]
fn multi_root_push_partial_failure_isolated() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    // backend 远程前进 → backend push 会被拒;frontend 正常
    advance_remote(dir.path(), &remotes[1]);
    common::commit(&roots[0], "fe.txt", "f\n", "frontend work");
    common::commit(&roots[1], "be.txt", "b\n", "backend work");

    let results = run_multi_root_push(
        project.display().to_string(),
        None,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("push all");
    assert_results(&results, 1, 1, 0);
    // frontend 推送成功,backend 失败但结果隔离可展示
    let frontend = results
        .iter()
        .find(|r| r.display_name == "frontend")
        .expect("fe");
    assert!(frontend.success, "{frontend:?}");
    let backend = results
        .iter()
        .find(|r| r.display_name == "backend")
        .expect("be");
    assert!(!backend.success, "backend 应失败: {backend:?}");
    assert!(
        backend.message.contains("non-fast-forward") || backend.message.contains("rejected"),
        "失败原因保留: {}",
        backend.message
    );
}

#[test]
fn multi_root_push_options_publish_tags_for_every_selected_root() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    for (index, root) in roots.iter().enumerate() {
        common::git(root, &["tag", &format!("v{}", index + 1)]);
    }

    let results = run_multi_root_push_with_options(
        project.display().to_string(),
        None,
        Some(PushTagMode::All),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("Push All with tags");

    assert_results(&results, 2, 0, 0);
    for (index, remote) in remotes.iter().enumerate() {
        let tag = format!("v{}", index + 1);
        let reference = format!("refs/tags/{tag}");
        assert!(
            !common::git(remote, &["show-ref", "--verify", &reference]).is_empty(),
            "missing tag {tag} on root {index}"
        );
    }
}

#[test]
fn multi_root_force_push_applies_lease_mode_and_protected_branch_guard() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    for (index, root) in roots.iter().enumerate() {
        advance_remote(dir.path(), &remotes[index]);
        common::commit(root, &format!("local-{index}.txt"), "local\n", "local work");
    }
    let remote_heads: Vec<String> = remotes
        .iter()
        .map(|remote| common::git(remote, &["rev-parse", "main"]))
        .collect();

    let protected = run_multi_root_push_with_force_options(
        project.display().to_string(),
        None,
        None,
        false,
        true,
        true,
        roots
            .iter()
            .map(|root| RootProtectedBranchPatterns {
                root_path: std::fs::canonicalize(root).unwrap().display().to_string(),
                patterns: vec!["main".into()],
            })
            .collect(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("protected force push result");
    assert_results(&protected, 0, 2, 0);
    for (index, remote) in remotes.iter().enumerate() {
        assert_eq!(
            common::git(remote, &["rev-parse", "main"]),
            remote_heads[index],
            "protected remote must remain unchanged"
        );
    }
    assert!(
        protected
            .iter()
            .all(|result| result.message.contains("force push blocked")),
        "protected roots must fail closed: {protected:?}"
    );

    let leased = run_multi_root_push_with_force_options(
        project.display().to_string(),
        None,
        None,
        false,
        true,
        true,
        Vec::new(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("stale lease result");
    assert_results(&leased, 0, 2, 0);
    assert!(
        leased.iter().all(|result| {
            result.message.contains("stale info") || result.message.contains("stale lease")
        }),
        "lease mode must preserve stale lease failures: {leased:?}"
    );
    for (index, remote) in remotes.iter().enumerate() {
        assert_eq!(
            common::git(remote, &["rev-parse", "main"]),
            remote_heads[index],
            "stale lease must not overwrite the remote"
        );
    }

    let forced = run_multi_root_push_with_force_options(
        project.display().to_string(),
        None,
        None,
        false,
        true,
        false,
        Vec::new(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("unleased force push result");
    assert_results(&forced, 2, 0, 0);
    for (index, root) in roots.iter().enumerate() {
        let local_head = common::git(root, &["rev-parse", "HEAD"]);
        let remote_head = common::git(&remotes[index], &["rev-parse", "main"]);
        assert_eq!(remote_head, local_head);
    }
}

#[test]
fn multi_root_force_push_uses_only_the_owning_root_protection_rules() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    for (index, root) in roots.iter().enumerate() {
        common::commit(root, &format!("local-{index}.txt"), "local\n", "local work");
    }

    let protected = run_multi_root_push_with_force_options(
        project.display().to_string(),
        None,
        None,
        false,
        true,
        false,
        vec![RootProtectedBranchPatterns {
            root_path: std::fs::canonicalize(&roots[0])
                .unwrap()
                .display()
                .to_string(),
            patterns: vec!["main".into()],
        }],
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("root-scoped protected force push result");

    let frontend = protected
        .iter()
        .find(|result| {
            result.root_path
                == std::fs::canonicalize(&roots[0])
                    .unwrap()
                    .display()
                    .to_string()
        })
        .expect("frontend result");
    let backend = protected
        .iter()
        .find(|result| {
            result.root_path
                == std::fs::canonicalize(&roots[1])
                    .unwrap()
                    .display()
                    .to_string()
        })
        .expect("backend result");
    assert!(!frontend.success);
    assert!(frontend.message.contains("force push blocked"));
    assert!(
        backend.success,
        "unprotected root should still push: {backend:?}"
    );
    assert_eq!(
        common::git(&remotes[1], &["rev-parse", "main"]),
        common::git(&roots[1], &["rev-parse", "HEAD"])
    );
}

#[test]
fn multi_root_push_publishes_submodule_before_superproject() {
    let dir = tempfile::tempdir().expect("tempdir");
    let child_remote = dir.path().join("child.git");
    let parent_remote = dir.path().join("parent.git");
    let project = dir.path().join("project");
    let child_source = dir.path().join("child-source");
    let submodule = project.join("vendor/lib");

    common::git(dir.path(), &["init", "-q", "--bare", "child.git"]);
    std::fs::create_dir_all(&child_source).unwrap();
    common::git(&child_source, &["init", "-q"]);
    common::git(&child_source, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::git(&child_source, &["config", "user.name", "Arbor Test"]);
    common::git(&child_source, &["config", "user.email", "test@arbor.local"]);
    common::commit(&child_source, "lib.txt", "initial\n", "child initial");
    common::git(
        &child_source,
        &[
            "remote",
            "add",
            "origin",
            &child_remote.display().to_string(),
        ],
    );
    common::git(&child_source, &["push", "-q", "-u", "origin", "main"]);

    std::fs::create_dir_all(&project).unwrap();
    common::git(&project, &["init", "-q"]);
    common::git(&project, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::git(&project, &["config", "user.name", "Arbor Test"]);
    common::git(&project, &["config", "user.email", "test@arbor.local"]);
    common::git(&project, &["config", "protocol.file.allow", "always"]);
    common::commit(&project, "main.txt", "initial\n", "parent initial");
    common::git(
        &project,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &child_remote.display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(&project, &["commit", "-q", "-m", "add child submodule"]);
    common::git(dir.path(), &["init", "-q", "--bare", "parent.git"]);
    common::git(
        &project,
        &[
            "remote",
            "add",
            "origin",
            &parent_remote.display().to_string(),
        ],
    );
    common::git(&project, &["push", "-q", "-u", "origin", "main"]);

    // The child has a local commit and a branch tracking origin/main, but the
    // commit is intentionally not in child_remote yet.  The parent gitlink
    // points at it, so a parent-first push must be rejected by this hook.
    common::git(&submodule, &["config", "user.name", "Arbor Test"]);
    common::git(&submodule, &["config", "user.email", "test@arbor.local"]);
    common::git(&submodule, &["switch", "-q", "-C", "main"]);
    common::git(
        &submodule,
        &["branch", "--set-upstream-to=origin/main", "main"],
    );
    common::commit(&submodule, "next.txt", "next\n", "child work");
    common::git(&project, &["add", "vendor/lib"]);
    common::git(&project, &["commit", "-q", "-m", "advance child gitlink"]);

    let discovered = discover_git_roots(project.display().to_string(), None).unwrap();
    assert!(
        discovered
            .iter()
            .any(|root| root.display_name == "lib" && root.is_submodule),
        "submodule root was not classified correctly: {discovered:?}"
    );
    let hook = format!(
        "#!/bin/sh\nread oldrev newrev ref\nsubmodule_id=$(git ls-tree \"$newrev\" vendor/lib | awk '{{print $3}}')\nchild_tip=$(git --git-dir='{}' rev-parse refs/heads/main)\n[ \"$submodule_id\" = \"$child_tip\" ] || exit 1\nexit 0\n",
        child_remote.display(),
    );
    let hook_path = parent_remote.join("hooks/pre-receive");
    std::fs::write(&hook_path, hook).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&hook_path, std::fs::Permissions::from_mode(0o755)).unwrap();

    let results = run_multi_root_push(
        project.display().to_string(),
        None,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("push all roots");

    let child_result = results
        .iter()
        .find(|result| result.display_name == "lib")
        .expect("child result");
    let parent_result = results
        .iter()
        .find(|result| result.display_name == "project")
        .expect("parent result");
    assert!(
        child_result.success,
        "child must be pushed first: {child_result:?}"
    );
    assert!(
        parent_result.success,
        "parent gitlink push failed: {parent_result:?}"
    );
    assert!(
        results
            .iter()
            .position(|result| result.display_name == "lib")
            < results
                .iter()
                .position(|result| result.display_name == "project")
    );
}

#[test]
fn multi_root_commit_skips_clean_roots() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    // 只有 frontend 有暂存变更
    std::fs::write(roots[0].join("new.txt"), "n\n").unwrap();
    common::git(&roots[0], &["add", "new.txt"]);

    let results = run_multi_root_operation(
        project.display().to_string(),
        MultiRootOperation::Commit,
        Some("multi root commit".into()),
    )
    .expect("commit all");
    assert_results(&results, 1, 0, 1);
    let frontend = results
        .iter()
        .find(|r| r.display_name == "frontend")
        .expect("fe");
    assert!(frontend.success);
    let backend = results
        .iter()
        .find(|r| r.display_name == "backend")
        .expect("be");
    assert!(backend.skipped, "无暂存变更跳过: {backend:?}");
    // frontend 提交生效
    let subject = common::git(&roots[0], &["log", "-1", "--format=%s"]);
    assert_eq!(subject, "multi root commit");
}

#[test]
fn multi_root_commit_commits_only_selected_roots_and_rejects_empty_message() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        std::fs::write(root.join("new.txt"), "new\n").unwrap();
        common::git(root, &["add", "new.txt"]);
    }

    let results = run_multi_root_commit(
        project.display().to_string(),
        vec![roots[0].display().to_string()],
        "selected root commit".into(),
    )
    .expect("selected commit");
    let selected = results
        .iter()
        .find(|result| result.display_name == "frontend")
        .expect("selected result");
    let skipped = results
        .iter()
        .find(|result| result.display_name == "backend")
        .expect("unselected result");
    assert!(selected.success && !selected.skipped);
    assert!(skipped.success && skipped.skipped);
    assert_eq!(skipped.message, "not selected");
    assert_eq!(
        common::git(&roots[0], &["log", "-1", "--format=%s"]),
        "selected root commit"
    );
    assert_eq!(
        common::git(&roots[1], &["diff", "--cached", "--name-only"]),
        "new.txt"
    );

    let empty = run_multi_root_commit(
        project.display().to_string(),
        vec![roots[0].display().to_string()],
        "   ".into(),
    )
    .expect_err("empty message must be rejected");
    assert!(empty.to_string().contains("non-empty commit message"));
}

#[test]
fn multi_root_selected_commit_is_root_qualified_and_preserves_unselected_staged_files() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        std::fs::write(root.join("selected.txt"), "selected\n").unwrap();
        std::fs::write(root.join("keep-staged.txt"), "keep\n").unwrap();
        common::git(root, &["add", "selected.txt", "keep-staged.txt"]);
    }

    let results = run_multi_root_commit_selected_paths_with_options(
        project.display().to_string(),
        roots
            .iter()
            .map(|root| MultiRootCommitSelection {
                root_path: root.display().to_string(),
                paths: vec!["selected.txt".into()],
            })
            .collect(),
        "selected files commit".into(),
        MultiRootCommitOptions::default(),
    )
    .expect("selected files commit");
    assert!(results
        .iter()
        .all(|result| result.success && !result.skipped));

    for root in &roots {
        assert_eq!(
            common::git(root, &["show", "--format=", "--name-only", "HEAD"]),
            "selected.txt"
        );
        assert_eq!(
            common::git(root, &["diff", "--cached", "--name-only"]),
            "keep-staged.txt"
        );
    }
}

#[test]
fn multi_root_commit_uses_each_root_message_cleanup_config() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);
    for root in &roots {
        std::fs::write(root.join("cleanup.txt"), "cleanup\n").unwrap();
        common::git(root, &["add", "cleanup.txt"]);
        common::git(root, &["config", "commit.cleanup", "strip"]);
        common::git(root, &["config", "core.commentChar", ";"]);
    }

    let results = run_multi_root_commit(
        project.display().to_string(),
        roots
            .iter()
            .map(|root| root.display().to_string())
            .collect(),
        "\nsubject  \n; remove\n# keep\n\nbody  \n".into(),
    )
    .expect("multi-root commit");
    assert!(results
        .iter()
        .all(|result| result.success && !result.skipped));
    for root in &roots {
        let head = common::git(root, &["rev-parse", "HEAD"]);
        assert_eq!(
            common::raw_commit_message(root, &head),
            "subject\n# keep\n\nbody\n"
        );
    }
}

#[test]
fn multi_root_commit_options_run_checks_identity_and_amend() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, _remotes) = dual_root_project(&dir);

    std::fs::write(roots[0].join("identity.txt"), "identity\n").unwrap();
    common::git(&roots[0], &["add", "identity.txt"]);
    let options = MultiRootCommitOptions {
        author_name: Some("Override Author".into()),
        author_email: Some("author@arbor.local".into()),
        committer_name: Some("Override Committer".into()),
        committer_email: Some("committer@arbor.local".into()),
        sign_off: true,
        co_authors: vec!["Co Author <co@arbor.local>".into()],
        ..Default::default()
    };
    let results = run_multi_root_commit_with_options(
        project.display().to_string(),
        vec![roots[0].display().to_string()],
        "options commit".into(),
        options,
    )
    .expect("options commit");
    assert!(results
        .iter()
        .find(|result| result.display_name == "frontend")
        .is_some_and(|result| result.success && !result.skipped));
    let metadata = common::git(
        &roots[0],
        &["show", "-s", "--format=%an%n%ae%n%cn%n%ce%n%B", "HEAD"],
    );
    assert!(metadata.contains("Override Author"), "{metadata}");
    assert!(metadata.contains("author@arbor.local"), "{metadata}");
    assert!(metadata.contains("Override Committer"), "{metadata}");
    assert!(metadata.contains("committer@arbor.local"), "{metadata}");
    assert!(metadata.contains("Signed-off-by: Override Committer <committer@arbor.local>"));
    assert!(metadata.contains("Co-authored-by: Co Author <co@arbor.local>"));

    std::fs::write(roots[1].join("check.txt"), "check\n").unwrap();
    common::git(&roots[1], &["add", "check.txt"]);
    let failing_check_options = MultiRootCommitOptions {
        before_commit_commands: vec![MultiRootCommitCheck {
            command: "sh".into(),
            args: vec!["-c".into(), "printf failing-check; exit 1".into()],
        }],
        ..Default::default()
    };
    let failed = run_multi_root_commit_with_options(
        project.display().to_string(),
        vec![roots[1].display().to_string()],
        "blocked commit".into(),
        failing_check_options,
    )
    .expect("check result");
    let failed_root = failed
        .iter()
        .find(|result| result.display_name == "backend")
        .expect("backend result");
    assert!(!failed_root.success);
    assert!(failed_root.message.contains("before-commit check"));
    assert_eq!(
        common::git(&roots[1], &["log", "-1", "--format=%s"]),
        "init"
    );
    assert_eq!(
        common::git(&roots[1], &["diff", "--cached", "--name-only"]),
        "check.txt"
    );

    std::fs::write(roots[0].join("amend.txt"), "amend\n").unwrap();
    common::git(&roots[0], &["add", "amend.txt"]);
    let count_before = common::git(&roots[0], &["rev-list", "--count", "HEAD"]);
    let amend_options = MultiRootCommitOptions {
        amend: true,
        ..Default::default()
    };
    let amended = run_multi_root_commit_with_options(
        project.display().to_string(),
        vec![roots[0].display().to_string()],
        "amended commit".into(),
        amend_options,
    )
    .expect("amend commit");
    assert!(amended
        .iter()
        .find(|result| result.display_name == "frontend")
        .is_some_and(|result| result.success && !result.skipped));
    assert_eq!(
        common::git(&roots[0], &["rev-list", "--count", "HEAD"]),
        count_before
    );
    assert_eq!(
        common::git(&roots[0], &["log", "-1", "--format=%s"]),
        "amended commit"
    );
}

#[test]
fn multi_root_rebase_moves_update_ref_with_reordered_commit() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_project, roots, _remotes) = dual_root_project(&dir);
    let root = &roots[0];

    let base = common::git(root, &["rev-parse", "HEAD"]);
    let a = common::commit(root, "a.txt", "a\n", "a");
    common::git(root, &["branch", "topic", &a]);
    let b = common::commit(root, "b.txt", "b\n", "b");
    let c = common::commit(root, "c.txt", "c\n", "c");
    let onto = base;

    let results = run_multi_root_rebase(vec![MultiRootRebaseSpec {
        root_path: root.display().to_string(),
        branch: "main".into(),
        onto: onto.clone(),
        actions: vec![
            arbor_engine::RebaseAction::Pick,
            arbor_engine::RebaseAction::Reword {
                message: "a rewritten".into(),
            },
            arbor_engine::RebaseAction::Pick,
        ],
        ordered_commit_ids: vec![b, a, c],
        raw_todo: None,
        preserve_merges: true,
        auto_squash: false,
        keep_empty: false,
        update_refs: true,
        root: false,
        interactive: true,
        save_policy: LocalChangesSavePolicy::Stash,
    }])
    .expect("rebase with reordered update-ref block");

    assert_eq!(results.len(), 1);
    assert!(
        results[0].success && !results[0].skipped,
        "results: {results:?}"
    );
    assert_eq!(
        common::git(root, &["log", "-1", "--format=%s", "topic"]),
        "a rewritten"
    );
    assert_eq!(
        common::git(root, &["log", "-1", "--format=%s", "topic^"]),
        "b"
    );
    assert_eq!(
        common::git(root, &["log", "--format=%s", "--reverse", "main"]),
        "init\nb\na rewritten\nc"
    );
}

#[test]
fn multi_root_pull_rebase_all() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (project, roots, remotes) = dual_root_project(&dir);
    advance_remote(dir.path(), &remotes[0]);
    advance_remote(dir.path(), &remotes[1]);

    let results = run_multi_root_operation(
        project.display().to_string(),
        MultiRootOperation::PullRebase,
        None,
    )
    .expect("pull rebase all");
    assert_results(&results, 2, 0, 0);
    let be_log = common::git(&roots[1], &["log", "--format=%s", "main"]);
    assert!(be_log.contains("advance"), "{be_log}");
}

#[test]
fn multi_root_on_non_repo_project_returns_empty() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(dir.path().join("plain.txt"), "x").unwrap();
    let results = run_multi_root_operation(
        dir.path().display().to_string(),
        MultiRootOperation::Fetch,
        None,
    )
    .expect("empty");
    assert!(results.is_empty());
}

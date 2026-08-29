//! BRANCH-001：分支弹窗数据源与 tracking 设置。
//! recent branches（reflog）、set/unset upstream、checkout with update 组合、
//! 多 root 分支聚合。真实 fixture 验证。

mod common;

use arbor_engine::{EngineError, GitCancelHandle, LocalChangesSavePolicy};
use common::TestRepo;

#[test]
fn recent_branches_follows_checkout_history() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&["branch", "feature"]);
    r.git(&["branch", "chore"]);
    r.git(&["branch", "bugfix"]);

    // 依次 checkout:feature -> chore -> feature(重复) -> bugfix
    r.git(&["checkout", "-q", "feature"]);
    r.git(&["checkout", "-q", "chore"]);
    r.git(&["checkout", "-q", "feature"]);
    r.git(&["checkout", "-q", "bugfix"]);

    let repo = r.open();
    let recent = repo.recent_branches(10).expect("recent");
    // 最近在前、去重:bugfix, feature, chore(main 是初始,不含 checkout 记录)
    assert_eq!(
        recent,
        vec!["bugfix", "feature", "chore"],
        "recent: {recent:?}"
    );
}

#[test]
fn recent_branches_respects_limit_and_skips_detached() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&["branch", "a"]);
    r.git(&["branch", "b"]);
    r.git(&["branch", "c"]);
    r.git(&["checkout", "-q", "a"]);
    r.git(&["checkout", "-q", "b"]);
    r.git(&["checkout", "-q", "c"]);
    // detached checkout(哈希)不应出现在 recent
    let head = r.git(&["rev-parse", "HEAD"]);
    r.git(&["checkout", "-q", &head]);

    let repo = r.open();
    let recent = repo.recent_branches(2).expect("recent");
    assert_eq!(recent.len(), 2, "limit 生效: {recent:?}");
    assert!(
        !recent.contains(&head),
        "detached 哈希不进 recent: {recent:?}"
    );
    assert_eq!(recent[0], "c");
}

#[test]
fn my_branch_names_require_nonempty_exclusive_commits_authored_by_user() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");

    r.git(&["checkout", "-q", "-b", "my-branch"]);
    common::commit(&r.path, "my.txt", "my\n", "my work");
    r.git(&["checkout", "-q", "main"]);

    r.git(&["checkout", "-q", "-b", "foreign-branch"]);
    r.git(&["config", "user.name", "Other Author"]);
    r.git(&["config", "user.email", "other@arbor.local"]);
    common::commit(&r.path, "foreign.txt", "foreign\n", "foreign work");
    r.git(&["checkout", "-q", "main"]);

    r.git(&["checkout", "-q", "-b", "mixed-branch"]);
    r.git(&["config", "user.name", "Arbor Test"]);
    r.git(&["config", "user.email", "test@arbor.local"]);
    common::commit(&r.path, "mixed-my.txt", "my\n", "mixed my work");
    r.git(&["config", "user.name", "Other Author"]);
    r.git(&["config", "user.email", "other@arbor.local"]);
    common::commit(
        &r.path,
        "mixed-foreign.txt",
        "foreign\n",
        "mixed foreign work",
    );
    r.git(&["checkout", "-q", "main"]);

    // The configured identity is the one used to classify branches, not the
    // identity left behind by the last commit construction step.
    r.git(&["config", "user.name", "Arbor Test"]);
    r.git(&["config", "user.email", "test@arbor.local"]);
    let my_tip = r.git(&["rev-parse", "my-branch"]);
    r.git(&["update-ref", "refs/remotes/origin/my-branch", &my_tip]);

    let names = r.open().my_branch_names().expect("my branches");
    assert_eq!(names.local, vec!["my-branch"]);
    assert_eq!(names.remote, vec!["origin/my-branch"]);

    r.git(&["config", "--unset", "user.name"]);
    r.git(&["config", "--unset", "user.email"]);
    let names_without_identity = r.open().my_branch_names().expect("empty identity");
    assert!(names_without_identity.local.is_empty());
    assert!(names_without_identity.remote.is_empty());
}

#[test]
fn smart_checkout_stashes_switches_and_restores_local_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    common::commit(&r.path, "g.txt", "base\n", "second file");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["checkout", "-q", "main"]);
    r.write("g.txt", "local\n");

    let repo = r.open();
    repo.smart_switch_branch("feature".into())
        .expect("smart checkout");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert_eq!(r.read("g.txt"), "local\n");
    assert!(r.git(&["status", "--porcelain"]).contains("g.txt"));
    assert!(repo.stash_list().expect("stash list").is_empty());
}

#[test]
fn smart_checkout_shelve_policy_switches_and_restores_local_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    common::commit(&r.path, "g.txt", "base\n", "second file");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["checkout", "-q", "main"]);
    r.write("g.txt", "local\n");
    r.write("scratch.txt", "untracked\n");

    let repo = r.open();
    repo.smart_switch_branch_with_policy("feature".into(), LocalChangesSavePolicy::Shelve)
        .expect("shelf smart checkout");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert_eq!(r.read("g.txt"), "local\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
    assert!(repo.stash_list().expect("stash list").is_empty());
    assert!(repo.shelve_list().expect("shelf list").is_empty());
}

#[test]
fn smart_checkout_shelve_policy_restores_staged_and_unstaged_boundaries() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "staged\n");
    r.git(&["add", "f.txt"]);
    r.write("f.txt", "unstaged\n");

    let repo = r.open();
    repo.smart_switch_branch_with_policy("feature".into(), LocalChangesSavePolicy::Shelve)
        .expect("shelf smart checkout with staged work");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    let staged_diff = r.git(&["diff", "--cached", "--", "f.txt"]);
    assert!(staged_diff.contains("-base") && staged_diff.contains("+staged"));
    let unstaged_diff = r.git(&["diff", "--", "f.txt"]);
    assert!(unstaged_diff.contains("-staged") && unstaged_diff.contains("+unstaged"));
    assert!(repo.shelve_list().expect("shelf list").is_empty());
}

#[test]
fn cancelled_shelf_smart_checkout_restores_the_original_scene_before_saving() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "local\n");

    let repo = r.open();
    let cancel = GitCancelHandle::new();
    cancel.cancel();
    let error = repo
        .smart_switch_branch_with_policy_and_cancel(
            "feature".into(),
            LocalChangesSavePolicy::Shelve,
            cancel,
        )
        .expect_err("pre-cancelled smart checkout must not save or switch");

    assert!(matches!(error, EngineError::Cancelled));
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(r.read("f.txt"), "local\n");
    assert!(r.git(&["status", "--porcelain"]).contains("f.txt"));
    assert!(repo.shelve_list().expect("shelf list").is_empty());
}

#[test]
fn smart_checkout_stash_policy_restores_staged_and_unstaged_boundaries() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "staged\n");
    r.git(&["add", "f.txt"]);
    r.write("f.txt", "unstaged\n");

    let repo = r.open();
    repo.smart_switch_branch_with_policy("feature".into(), LocalChangesSavePolicy::Stash)
        .expect("stash smart checkout with staged work");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    let staged_diff = r.git(&["diff", "--cached", "--", "f.txt"]);
    assert!(staged_diff.contains("-base") && staged_diff.contains("+staged"));
    let unstaged_diff = r.git(&["diff", "--", "f.txt"]);
    assert!(unstaged_diff.contains("-staged") && unstaged_diff.contains("+unstaged"));
    assert!(repo.stash_list().expect("stash list").is_empty());
}

#[test]
fn smart_checkout_leaves_stash_and_conflict_state_when_restore_conflicts() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["checkout", "-q", "main"]);
    r.write("f.txt", "local\n");

    let repo = r.open();
    let error = repo
        .smart_switch_branch("feature".into())
        .expect_err("conflicting local change should pause restore");
    let stash_id = match error {
        EngineError::StashApplyConflict { stash_id, .. } => {
            stash_id.expect("restore conflict carries the saved stash object id")
        }
        other => panic!("expected stash restore conflict, got {other:?}"),
    };
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert!(r.read("f.txt").contains("<<<<<<<"));
    let stashes = repo.stash_list().expect("stash list");
    assert_eq!(stashes.len(), 1);
    assert_eq!(stashes[0].id, stash_id);
}

#[test]
fn force_checkout_overwrites_local_changes_only_when_explicit() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["checkout", "-q", "main"]);
    r.write("f.txt", "local\n");

    let repo = r.open();
    repo.force_switch_branch("feature".into())
        .expect("force checkout");
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert_eq!(r.read("f.txt"), "feature\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn force_checkout_cannot_bypass_an_in_progress_merge() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["checkout", "-q", "main"]);
    common::commit(&r.path, "f.txt", "main\n", "main change");
    r.git(&["branch", "other"]);

    let repo = r.open();
    let merge = repo.merge("feature".into()).expect("merge starts");
    assert!(!merge.conflicts.is_empty());
    let error = repo
        .force_switch_branch("other".into())
        .expect_err("force checkout must not destroy merge state");
    assert!(error.to_string().contains("operation is in progress"));
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "main");
}

#[test]
fn smart_checkout_restores_local_changes_when_target_is_invalid() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.write("f.txt", "local\n");

    let repo = r.open();
    assert!(repo.smart_switch_branch("missing".into()).is_err());
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(r.read("f.txt"), "local\n");
    assert!(r.git(&["status", "--porcelain"]).contains("f.txt"));
    assert!(repo.stash_list().expect("stash list").is_empty());
}

#[test]
fn smart_checkout_detached_restores_local_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    common::commit(&r.path, "g.txt", "base\n", "second file");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["tag", "target", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.write("g.txt", "local\n");

    let repo = r.open();
    repo.smart_checkout_detached("target".into())
        .expect("smart detached checkout");

    assert_eq!(r.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD");
    assert_eq!(r.read("f.txt"), "feature\n");
    assert_eq!(r.read("g.txt"), "local\n");
    assert!(r.git(&["status", "--porcelain"]).contains("g.txt"));
    assert!(repo.stash_list().expect("stash list").is_empty());
}

#[test]
fn smart_checkout_detached_preserves_stash_on_restore_conflict() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["tag", "target", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.write("f.txt", "local\n");

    let repo = r.open();
    let error = repo
        .smart_checkout_detached("target".into())
        .expect_err("conflicting local change should pause restore");

    let stash_id = match error {
        EngineError::StashApplyConflict { stash_id, .. } => {
            stash_id.expect("restore conflict carries the saved stash object id")
        }
        other => panic!("expected stash restore conflict, got {other:?}"),
    };
    assert_eq!(r.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD");
    assert!(r.read("f.txt").contains("<<<<<<<"));
    let stashes = repo.stash_list().expect("stash list");
    assert_eq!(stashes.len(), 1);
    assert_eq!(stashes[0].id, stash_id);
}

#[test]
fn force_checkout_detached_overwrites_local_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["tag", "target", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.write("f.txt", "local\n");

    let repo = r.open();
    repo.force_checkout_detached("target".into())
        .expect("force detached checkout");

    assert_eq!(r.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD");
    assert_eq!(r.read("f.txt"), "feature\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn force_checkout_detached_cannot_bypass_an_in_progress_merge() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "feature\n", "feature change");
    r.git(&["tag", "target", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    common::commit(&r.path, "f.txt", "main\n", "main change");

    let repo = r.open();
    let merge = repo.merge("feature".into()).expect("merge starts");
    assert!(!merge.conflicts.is_empty());
    let error = repo
        .force_checkout_detached("target".into())
        .expect_err("force detached checkout must not destroy merge state");

    assert!(error.to_string().contains("operation is in progress"));
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "main");
}

#[test]
fn smart_checkout_detached_restores_changes_when_target_is_invalid() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.write("f.txt", "local\n");

    let repo = r.open();
    assert!(repo.smart_checkout_detached("missing".into()).is_err());
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(r.read("f.txt"), "local\n");
    assert!(r.git(&["status", "--porcelain"]).contains("f.txt"));
    assert!(repo.stash_list().expect("stash list").is_empty());
}

#[test]
fn smart_checkout_remote_branch_restores_local_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let remote_path = dir.path().join("origin.git");

    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    common::commit(&r.path, "g.txt", "base\n", "second file");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "remote feature\n", "feature work");
    r.git(&["push", "-q", "-u", "origin", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.git(&["branch", "-D", "feature"]);
    r.write("g.txt", "local\n");
    r.write("untracked.txt", "local untracked\n");

    let repo = r.open();
    repo.smart_checkout_remote_branch("origin/feature".into(), None)
        .expect("smart remote checkout");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert_eq!(r.read("f.txt"), "remote feature\n");
    assert_eq!(r.read("g.txt"), "local\n");
    assert_eq!(r.read("untracked.txt"), "local untracked\n");
    assert!(repo.stash_list().expect("stash list").is_empty());
}

#[test]
fn force_checkout_remote_branch_overwrites_local_changes() {
    let dir = tempfile::tempdir().expect("tempdir");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let remote_path = dir.path().join("origin.git");

    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "f.txt", "remote feature\n", "feature work");
    r.git(&["push", "-q", "-u", "origin", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.git(&["branch", "-D", "feature"]);
    r.write("f.txt", "local\n");

    let repo = r.open();
    repo.force_checkout_remote_branch("origin/feature".into(), None)
        .expect("force remote checkout");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert_eq!(r.read("f.txt"), "remote feature\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn set_and_unset_upstream_updates_tracking() {
    let dir = tempfile::tempdir().expect("tempdir");
    // bare 远程
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let remote_path = dir.path().join("origin.git");

    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
    // 本地分支 local-work 无 upstream
    r.git(&["branch", "local-work"]);

    let repo = r.open();
    // 设置 upstream
    repo.branch_set_upstream("local-work".into(), "origin/main".into())
        .expect("set upstream");
    let sync = repo.sync_status().expect("sync");
    let entry = sync
        .iter()
        .find(|s| s.branch == "local-work")
        .expect("entry");
    assert!(entry.tracking_exists, "tracking 已建立: {entry:?}");
    assert_eq!(entry.upstream, "origin/main");

    // 解除 upstream:sync_status 只列有 upstream 的分支,条目消失
    repo.branch_unset_upstream("local-work".into())
        .expect("unset");
    let sync = repo.sync_status().expect("sync");
    assert!(
        !sync.iter().any(|s| s.branch == "local-work"),
        "tracking 已解除: {sync:?}"
    );
}

#[test]
fn checkout_remote_then_set_upstream_enables_pull() {
    let dir = tempfile::tempdir().expect("tempdir");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let remote_path = dir.path().join("origin.git");

    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
    r.git(&["checkout", "-q", "-b", "feature"]);
    r.write("f.txt", "2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "feature work"]);
    r.git(&["push", "-q", "-u", "origin", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    // 删除本地 feature,模拟「远程有、本地无」的检出场景
    r.git(&["branch", "-D", "feature"]);

    // 从 remote-tracking 检出本地跟踪分支
    let repo = r.open();
    repo.checkout_remote_branch("origin/feature".into(), None)
        .expect("checkout remote");
    assert_eq!(r.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    // tracking 已建立 -> sync_status 有 upstream,pull 可用
    let sync = repo.sync_status().expect("sync");
    let entry = sync.iter().find(|s| s.branch == "feature").expect("entry");
    assert!(entry.tracking_exists);
}

#[test]
fn branch_list_groups_local_and_remote() {
    let dir = tempfile::tempdir().expect("tempdir");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let remote_path = dir.path().join("origin.git");

    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
    r.git(&["branch", "local-only"]);

    let repo = r.open();
    let local = repo.branch_list().expect("local");
    let names: Vec<&str> = local.iter().map(|b| b.name.as_str()).collect();
    assert!(names.contains(&"main"));
    assert!(names.contains(&"local-only"));

    let remote = repo.remote_branch_list().expect("remote");
    let remote_names: Vec<&str> = remote.iter().map(|b| b.name.as_str()).collect();
    assert!(
        remote_names.contains(&"origin/main"),
        "remote: {remote_names:?}"
    );
}

#[test]
fn multi_root_branch_aggregation() {
    // 一个项目两个独立 root,各自的分支列表互不污染(聚合数据源验证)
    let project = tempfile::tempdir().expect("tempdir");
    let project_path = project.path();
    for (dir, branch) in [("frontend", "feat-ui"), ("backend", "feat-api")] {
        let root = project_path.join(dir);
        std::fs::create_dir_all(&root).unwrap();
        common::git(&root, &["init", "-q"]);
        common::git(&root, &["config", "user.name", "Arbor Test"]);
        common::git(&root, &["config", "user.email", "test@arbor.local"]);
        common::git(&root, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        common::commit(&root, "f.txt", "1\n", "init");
        common::git(&root, &["branch", branch]);
        common::git(&root, &["tag", "v1"]);
        if dir == "frontend" {
            common::git(&root, &["remote", "add", "origin", "../remote.git"]);
        }
        common::git(&root, &["switch", "-q", branch]);
        std::fs::write(root.join("f.txt"), "stash\n").unwrap();
        common::git(&root, &["stash", "push", "-q", "-m", "root stash"]);
        common::git(&root, &["switch", "-q", "main"]);
    }

    let roots =
        arbor_engine::discover_git_roots(project_path.display().to_string(), None).expect("roots");
    assert_eq!(roots.len(), 2);
    let snapshots = arbor_engine::list_multi_root_branches(project_path.display().to_string())
        .expect("branch snapshots");
    assert_eq!(snapshots.len(), 2);
    assert!(snapshots
        .iter()
        .any(|snapshot| snapshot.display_name == "frontend"
            && snapshot
                .branches
                .iter()
                .any(|branch| branch.name == "feat-ui")));
    assert!(snapshots
        .iter()
        .any(|snapshot| snapshot.display_name == "backend"
            && snapshot
                .branches
                .iter()
                .any(|branch| branch.name == "feat-api")));
    let frontend_snapshot = snapshots
        .iter()
        .find(|snapshot| snapshot.display_name == "frontend")
        .expect("frontend snapshot");
    assert!(frontend_snapshot.tags.iter().any(|tag| tag.name == "v1"));
    assert!(frontend_snapshot
        .stashes
        .iter()
        .any(|stash| stash.message.contains("root stash")));
    assert!(frontend_snapshot
        .remotes
        .iter()
        .any(|remote| remote.name == "origin"));
    assert!(snapshots
        .iter()
        .find(|snapshot| snapshot.display_name == "backend")
        .expect("backend snapshot")
        .remotes
        .is_empty());
    assert!(frontend_snapshot
        .recent_branches
        .iter()
        .any(|name| name == "feat-ui"));
    // 每个 root 的分支独立打开查看,互不污染
    for root in &roots {
        let repo = arbor_engine::open_repository(root.path.clone()).expect("open");
        let local = repo.branch_list().expect("local");
        let names: Vec<&str> = local.iter().map(|b| b.name.as_str()).collect();
        assert!(names.contains(&"main"));
        assert!(names.iter().any(|n| n.starts_with("feat-")), "{names:?}");
    }
    let frontend = roots
        .iter()
        .find(|r| r.display_name == "frontend")
        .expect("fe");
    let backend = roots
        .iter()
        .find(|r| r.display_name == "backend")
        .expect("be");
    let fe_repo = arbor_engine::open_repository(frontend.path.clone()).expect("open fe");
    let be_repo = arbor_engine::open_repository(backend.path.clone()).expect("open be");
    let fe_names: Vec<String> = fe_repo
        .branch_list()
        .expect("fe")
        .iter()
        .map(|b| b.name.clone())
        .collect();
    let be_names: Vec<String> = be_repo
        .branch_list()
        .expect("be")
        .iter()
        .map(|b| b.name.clone())
        .collect();
    assert!(fe_names.iter().any(|n| n == "feat-ui"));
    assert!(
        !fe_names.iter().any(|n| n == "feat-api"),
        "frontend 不含 backend 分支"
    );
    assert!(be_names.iter().any(|n| n == "feat-api"));
    assert!(
        !be_names.iter().any(|n| n == "feat-ui"),
        "backend 不含 frontend 分支"
    );
}

#[test]
fn branch_snapshot_exposes_linked_worktree_for_open_worktree_action() {
    let project = tempfile::tempdir().expect("project tempdir");
    let root = project.path().join("repo");
    std::fs::create_dir_all(&root).unwrap();
    common::git(&root, &["init", "-q"]);
    common::git(&root, &["config", "user.name", "Arbor Test"]);
    common::git(&root, &["config", "user.email", "test@arbor.local"]);
    common::git(&root, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::commit(&root, "README.md", "base\n", "init");
    common::git(&root, &["branch", "feature"]);

    let linked_parent = tempfile::tempdir().expect("linked tempdir");
    let linked_path = linked_parent.path().join("feature-worktree");
    let repository = arbor_engine::open_repository(root.display().to_string()).expect("open");
    repository
        .worktree_add(
            linked_path.display().to_string(),
            None,
            Some("feature".into()),
        )
        .expect("add linked worktree");

    let snapshots = arbor_engine::list_multi_root_branches(project.path().display().to_string())
        .expect("list branch snapshots");
    let snapshot = snapshots.first().expect("root snapshot");
    let feature_worktree = snapshot
        .worktrees
        .iter()
        .find(|item| item.branch == "feature")
        .expect("feature worktree");
    assert_eq!(
        feature_worktree.path,
        std::fs::canonicalize(&linked_path)
            .unwrap()
            .display()
            .to_string()
    );
}

#[test]
fn checkout_with_update_and_rebase_paths() {
    // 分支行提供的 update 路径:checkout 后 pull(merge/rebase)由 UI 编排;
    // 引擎侧验证 pull_remote_branch 双模式可用(数据源完备)。
    let dir = tempfile::tempdir().expect("tempdir");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let remote_path = dir.path().join("origin.git");

    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
    r.git(&["checkout", "-q", "-b", "feature"]);
    r.write("f.txt", "2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "local feature"]);
    r.git(&["push", "-q", "-u", "origin", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.git(&["branch", "-D", "feature"]);

    // 远程 feature 前进
    let other = dir.path().join("other");
    common::git(
        dir.path(),
        &["clone", "-q", &remote_path.display().to_string(), "other"],
    );
    common::git(&other, &["config", "user.name", "Arbor Test"]);
    common::git(&other, &["config", "user.email", "test@arbor.local"]);
    common::git(&other, &["checkout", "-q", "feature"]);
    common::commit(&other, "g.txt", "g\n", "remote feature work");
    common::git(&other, &["push", "-q", "origin", "feature"]);

    // checkout feature 后 pull --rebase 同步远程
    let repo = r.open();
    repo.checkout_remote_branch("origin/feature".into(), None)
        .expect("checkout");
    let outcome = repo
        .pull_remote_branch("origin/feature".into(), true)
        .expect("pull with rebase");
    assert!(
        outcome.conflicts.is_empty(),
        "干净 rebase: {:?}",
        outcome.conflicts
    );
    let subjects = r.git(&["log", "--format=%s", "--reverse", "main..HEAD"]);
    assert!(
        subjects.contains("local feature"),
        "本地提交保留: {subjects}"
    );
    assert!(
        subjects.contains("remote feature work"),
        "远程提交纳入: {subjects}"
    );
}

#[test]
fn rebase_branch_on_current_checks_out_and_rebases_selected_branch() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["checkout", "-q", "-b", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["checkout", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");

    let repo = r.open();
    repo.rebase_branch_on_current("feature".into())
        .expect("rebase selected branch onto current");

    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "feature");
    assert_eq!(
        r.git(&["merge-base", "feature", "main"]),
        r.git(&["rev-parse", "main"])
    );
    assert!(r
        .git(&["log", "--format=%s", "main..feature"])
        .contains("feature"));
}

#[test]
fn rebase_branch_on_current_preserves_system_conflict_recovery() {
    let r = TestRepo::new();
    common::commit(&r.path, "same.txt", "base\n", "base");
    r.git(&["checkout", "-q", "-b", "feature"]);
    r.write("same.txt", "feature\n");
    r.git(&["add", "same.txt"]);
    r.git(&["commit", "-q", "-m", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.write("same.txt", "main\n");
    r.git(&["add", "same.txt"]);
    r.git(&["commit", "-q", "-m", "main"]);

    let repo = r.open();
    let error = repo
        .rebase_branch_on_current("feature".into())
        .expect_err("diverged changes should pause rebase");
    assert!(error.to_string().contains("rebase"));
    let state = repo
        .operation_state()
        .expect("operation state")
        .expect("system rebase state");
    assert_eq!(state.kind, arbor_engine::OperationKind::Rebase);
    assert_eq!(state.origin, arbor_engine::OperationOrigin::Git);
    assert!(!state.conflicted_files.is_empty());

    repo.rebase_abort().expect("abort system rebase");
    assert_eq!(r.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(r.read("same.txt"), "main\n");
}

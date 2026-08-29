//! 分支重命名与删除的安全语义回归测试。

mod common;

use common::{commit, git_allow_failure, TestRepo};

#[test]
fn branch_delete_requires_force_for_unmerged_tip() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["checkout", "-q", "feature"]);
    commit(&repo.path, "feature.txt", "feature", "feature work");
    repo.git(&["checkout", "-q", "main"]);

    let error = repo
        .open()
        .branch_delete("feature".into(), false)
        .unwrap_err();
    assert!(error.to_string().contains("not fully merged"));
    assert_eq!(repo.git(&["branch", "--list", "feature"]), "feature");

    repo.open().branch_delete("feature".into(), true).unwrap();
    assert!(repo.git(&["branch", "--list", "feature"]).is_empty());
}

#[test]
fn branch_delete_preview_captures_tip_unmerged_commits_and_base_branches() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["checkout", "-q", "feature"]);
    let feature_tip = commit(&repo.path, "feature.txt", "feature", "feature work");
    repo.git(&["branch", "feature-copy"]);
    repo.git(&["config", "branch.feature.remote", "."]);
    repo.git(&["config", "branch.feature.merge", "refs/heads/main"]);
    repo.git(&["checkout", "-q", "main"]);

    let preview = repo
        .open()
        .branch_delete_preview("feature".into())
        .expect("branch deletion preview");
    assert_eq!(preview.branch_name, "feature");
    assert_eq!(preview.tip_id, feature_tip);
    assert_eq!(preview.upstream.as_deref(), Some("main"));
    assert_eq!(preview.base_branches, vec!["feature-copy"]);
    assert_eq!(preview.unmerged_commits.len(), 1);
    assert_eq!(preview.unmerged_commits[0].summary, "feature work");
    assert_eq!(repo.git(&["branch", "--list", "feature"]), "feature");
}

#[test]
fn branch_delete_preview_uses_upstream_when_current_head_already_contains_tip() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "upstream"]);
    repo.git(&["branch", "feature"]);
    repo.git(&["checkout", "-q", "feature"]);
    let feature_tip = commit(&repo.path, "feature.txt", "feature", "feature work");
    repo.git(&["config", "branch.feature.remote", "."]);
    repo.git(&["config", "branch.feature.merge", "refs/heads/upstream"]);
    repo.git(&["checkout", "-q", "main"]);
    repo.git(&["merge", "--ff-only", "feature"]);

    let preview = repo
        .open()
        .branch_delete_preview("feature".into())
        .expect("branch deletion preview");
    assert_eq!(preview.tip_id, feature_tip);
    assert_eq!(preview.upstream.as_deref(), Some("upstream"));
    assert_eq!(preview.unmerged_commits.len(), 1);
    assert_eq!(preview.unmerged_commits[0].id, feature_tip);
    assert_eq!(preview.unmerged_commits[0].summary, "feature work");
}

#[test]
fn branch_delete_snapshot_restores_exact_tip_after_delete() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["checkout", "-q", "feature"]);
    let feature_tip = commit(&repo.path, "feature.txt", "feature", "feature work");
    repo.git(&["config", "branch.feature.remote", "."]);
    repo.git(&["config", "branch.feature.merge", "refs/heads/main"]);
    repo.git(&["checkout", "-q", "main"]);

    let preview = repo
        .open()
        .branch_delete_preview("feature".into())
        .expect("branch deletion preview");
    repo.open()
        .branch_delete("feature".into(), true)
        .expect("force delete branch");
    repo.open()
        .branch_create("feature".into(), Some(preview.tip_id.clone()))
        .expect("restore branch tip");
    repo.open()
        .branch_set_upstream("feature".into(), "main".into())
        .expect("restore branch upstream");

    assert_eq!(repo.git(&["rev-parse", "refs/heads/feature"]), feature_tip);
    assert_eq!(
        repo.git(&["config", "--get", "branch.feature.merge"]),
        "refs/heads/main"
    );
}

#[test]
fn branch_rename_preserves_current_head_and_upstream_config() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["config", "branch.feature.remote", "."]);
    repo.git(&["config", "branch.feature.merge", "refs/heads/main"]);
    repo.git(&["checkout", "-q", "feature"]);

    repo.open()
        .branch_rename("feature".into(), "renamed".into())
        .unwrap();

    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), "renamed");
    assert_eq!(repo.git(&["config", "--get", "branch.renamed.remote"]), ".");
    assert_eq!(
        repo.git(&["config", "--get", "branch.renamed.merge"]),
        "refs/heads/main"
    );
    assert!(
        git_allow_failure(&repo.path, &["config", "--get", "branch.feature.remote"]).is_empty()
    );
}

#[test]
fn branch_rename_rejects_existing_destination_without_moving_source() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["branch", "existing"]);

    let error = repo
        .open()
        .branch_rename("feature".into(), "existing".into())
        .unwrap_err();
    assert!(error.to_string().contains("already exists"));
    assert!(
        !git_allow_failure(&repo.path, &["show-ref", "--verify", "refs/heads/feature"]).is_empty()
    );
}

#[test]
fn branch_create_from_revision_keeps_head_and_uses_requested_tip() {
    let repo = TestRepo::new();
    let base = commit(&repo.path, "base.txt", "base", "base");
    commit(&repo.path, "second.txt", "second", "second");

    repo.open()
        .branch_create("from-base".into(), Some(base.clone()))
        .unwrap();

    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(repo.git(&["rev-parse", "from-base"]), base);
}

#[test]
fn merge_base_revision_id_resolves_common_ancestor_without_moving_head() {
    let repo = TestRepo::new();
    let base = commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    let main_tip = commit(&repo.path, "main.txt", "main", "main work");
    repo.git(&["checkout", "-q", "feature"]);
    let feature_tip = commit(&repo.path, "feature.txt", "feature", "feature work");

    let before_head = repo.git(&["symbolic-ref", "--short", "HEAD"]);
    let resolved = repo
        .open()
        .merge_base_revision_id(main_tip, feature_tip)
        .expect("merge-base revision");

    assert_eq!(resolved, base);
    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), before_head);
}

#[test]
fn branch_create_rejects_invalid_and_existing_names_before_mutation() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    let opened = repo.open();

    for name in ["", "HEAD", "-topic", "bad..name", "bad~name", "bad.lock"] {
        assert!(
            opened.validate_branch_name(name.into()).is_err(),
            "{name:?}"
        );
        assert!(opened.branch_create(name.into(), None).is_err(), "{name:?}");
    }
    assert!(repo.git(&["branch", "--list", "HEAD"]).is_empty());
    assert!(repo.git(&["branch", "--list", "bad..name"]).is_empty());

    opened.branch_create("topic".into(), None).unwrap();
    let error = opened.validate_branch_name("topic".into()).unwrap_err();
    assert!(error.to_string().contains("already exists"));
    assert!(opened.branch_create("topic".into(), None).is_err());
}

#[test]
fn branch_create_and_switch_checks_out_new_branch() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");

    let opened = repo.open();
    opened
        .branch_create_and_switch("topic".into(), None)
        .unwrap();

    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), "topic");
    assert_eq!(repo.git(&["branch", "--show-current"]), "topic");
    assert!(opened
        .branch_list()
        .unwrap()
        .iter()
        .any(|branch| branch.name == "topic" && branch.is_current));
}

#[test]
fn branch_create_or_reset_moves_existing_non_current_branch_without_checkout() {
    let repo = TestRepo::new();
    let base = commit(&repo.path, "base.txt", "base", "base");
    commit(&repo.path, "later.txt", "later", "later");
    repo.git(&["branch", "topic"]);

    repo.open()
        .branch_create_or_reset("topic".into(), Some(base.clone()), false, true)
        .unwrap();

    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(repo.git(&["rev-parse", "topic"]), base);
}

#[test]
fn branch_create_or_reset_current_branch_updates_worktree() {
    let repo = TestRepo::new();
    let base = commit(&repo.path, "base.txt", "base", "base");
    commit(&repo.path, "later.txt", "later", "later");

    repo.open()
        .branch_create_or_reset("main".into(), Some(base.clone()), true, true)
        .unwrap();

    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), base);
    assert!(!repo.path.join("later.txt").exists());
    assert!(git_allow_failure(&repo.path, &["status", "--porcelain"]).is_empty());
}

#[test]
fn branch_create_and_switch_does_not_leave_branch_after_worktree_conflict() {
    let repo = TestRepo::new();
    commit(&repo.path, "tracked.txt", "base", "base");
    commit(&repo.path, "tracked.txt", "second", "second");
    repo.write("tracked.txt", "local changes");

    let error = repo
        .open()
        .branch_create_and_switch("topic".into(), Some("HEAD~1".into()))
        .unwrap_err();

    assert!(error.to_string().contains("git switch -c failed"));
    assert_eq!(repo.git(&["symbolic-ref", "--short", "HEAD"]), "main");
    assert_eq!(repo.git(&["branch", "--list", "topic"]), "");
}

#[test]
fn commit_reachability_identifies_the_branch_that_contains_a_log_commit() {
    let repo = TestRepo::new();
    commit(&repo.path, "base.txt", "base", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["checkout", "-q", "feature"]);
    let feature_commit = commit(&repo.path, "feature.txt", "feature", "feature work");
    repo.git(&["checkout", "-q", "main"]);

    let opened = repo.open();
    assert!(opened
        .is_commit_reachable_from(feature_commit.clone(), "feature".into())
        .unwrap());
    assert!(!opened
        .is_commit_reachable_from(feature_commit, "main".into())
        .unwrap());
}

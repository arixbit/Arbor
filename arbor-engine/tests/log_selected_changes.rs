//! Log changes browser history actions: drop/extract selected paths.

mod common;

use common::TestRepo;

fn commit_two_files(repo: &TestRepo, a: &str, b: &str, message: &str) -> String {
    repo.write("a.txt", a);
    repo.write("b.txt", b);
    repo.git(&["add", "a.txt", "b.txt"]);
    repo.git(&["commit", "-q", "-m", message]);
    repo.git(&["rev-parse", "HEAD"])
}

fn gitlink_id(repo: &TestRepo, revision: &str) -> String {
    repo.git(&["ls-tree", revision, "vendor/lib"])
        .split_whitespace()
        .nth(2)
        .expect("gitlink entry")
        .to_string()
}

fn submodule_change_fixture(repo: &TestRepo) -> (std::path::PathBuf, String, String, String) {
    let source = tempfile::tempdir().expect("submodule source");
    common::git(source.path(), &["init", "-q"]);
    common::git(source.path(), &["config", "user.name", "Arbor Test"]);
    common::git(source.path(), &["config", "user.email", "test@arbor.local"]);
    common::commit(source.path(), "lib.txt", "v1\n", "sub v1");

    common::commit(&repo.path, "root.txt", "root\n", "root");
    let source_path = source.path().display().to_string();
    common::git(
        &repo.path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            source_path.as_str(),
            "vendor/lib",
        ],
    );
    common::git(&repo.path, &["commit", "-q", "-m", "sub v1"]);
    let submodule_path = repo.path.join("vendor/lib");
    common::git(&submodule_path, &["config", "user.name", "Arbor Test"]);
    common::git(
        &submodule_path,
        &["config", "user.email", "test@arbor.local"],
    );
    let first_id = common::git(&submodule_path, &["rev-parse", "HEAD"]);
    common::commit(&submodule_path, "lib.txt", "v2\n", "sub v2");
    let second_id = common::git(&submodule_path, &["rev-parse", "HEAD"]);

    repo.write("other.txt", "other\n");
    common::git(&repo.path, &["add", "vendor/lib", "other.txt"]);
    common::git(&repo.path, &["commit", "-q", "-m", "advance submodule"]);
    let target = common::git(&repo.path, &["rev-parse", "HEAD"]);
    (submodule_path, first_id, second_id, target)
}

fn merge_target_with_merge_descendant(repo: &TestRepo) -> String {
    common::commit(&repo.path, "base.txt", "base\n", "base");
    repo.git(&["branch", "feature"]);
    repo.git(&["switch", "-q", "feature"]);
    common::commit(&repo.path, "feature.txt", "feature\n", "feature");
    repo.write("feature-other.txt", "feature other\n");
    repo.git(&["add", "feature-other.txt"]);
    repo.git(&["commit", "-q", "-m", "feature other"]);
    repo.git(&["switch", "-q", "main"]);
    common::commit(&repo.path, "main.txt", "main\n", "main");
    repo.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    let target = repo.git(&["rev-parse", "HEAD"]);

    repo.git(&["branch", "side"]);
    repo.git(&["switch", "-q", "side"]);
    common::commit(&repo.path, "side.txt", "side\n", "side");
    repo.git(&["switch", "-q", "main"]);
    common::commit(&repo.path, "main-after.txt", "main after\n", "main after");
    repo.git(&["merge", "--no-ff", "-q", "side", "-m", "merge side"]);
    target
}

#[test]
fn drop_selected_changes_amends_target_head_and_keeps_other_paths() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["a.txt".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(repo_fixture.read("a.txt"), "base-a\n");
    assert_eq!(repo_fixture.read("b.txt"), "target-b\n");
    assert_eq!(repo_fixture.git(&["show", "HEAD:a.txt"]), "base-a");
    assert_eq!(repo_fixture.git(&["show", "HEAD:b.txt"]), "target-b");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drop_selected_changes_supports_a_root_commit() {
    let repo_fixture = TestRepo::new();
    repo_fixture.write("a.txt", "root-a\n");
    repo_fixture.write("b.txt", "root-b\n");
    repo_fixture.git(&["add", "a.txt", "b.txt"]);
    repo_fixture.git(&["commit", "-q", "-m", "root"]);
    let root = repo_fixture.git(&["rev-parse", "HEAD"]);

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(root, vec!["a.txt".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert!(!repo_fixture.exists("a.txt"));
    assert_eq!(repo_fixture.read("b.txt"), "root-b\n");
    assert_eq!(repo_fixture.git(&["log", "-1", "--format=%s"]), "root");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drop_selected_changes_preserves_merge_target_parents_and_replays_descendants() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    repo_fixture.git(&["branch", "feature"]);
    repo_fixture.git(&["switch", "-q", "feature"]);
    common::commit(&repo_fixture.path, "feature.txt", "feature\n", "feature");
    repo_fixture.write("feature-other.txt", "feature other\n");
    repo_fixture.git(&["add", "feature-other.txt"]);
    repo_fixture.git(&["commit", "-q", "-m", "feature other"]);
    repo_fixture.git(&["switch", "-q", "main"]);
    common::commit(&repo_fixture.path, "main.txt", "main\n", "main");
    repo_fixture.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    let target = repo_fixture.git(&["rev-parse", "HEAD"]);
    common::commit(&repo_fixture.path, "after.txt", "after\n", "after");

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["feature.txt".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert!(!repo_fixture.exists("feature.txt"));
    assert_eq!(repo_fixture.read("feature-other.txt"), "feature other\n");
    assert_eq!(repo_fixture.read("main.txt"), "main\n");
    assert_eq!(repo_fixture.read("after.txt"), "after\n");
    let rewritten_merge = repo_fixture.git(&["rev-parse", "HEAD~1"]);
    let parents = repo_fixture.git(&["rev-list", "--parents", "-n", "1", &rewritten_merge]);
    assert_eq!(
        parents.split_whitespace().count(),
        3,
        "rewritten merge lost a parent: {parents}"
    );
    assert_eq!(
        repo_fixture.git(&["show", &format!("{rewritten_merge}^2:feature.txt")]),
        "feature"
    );
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drop_selected_changes_replays_linear_descendants() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");
    common::commit(&repo_fixture.path, "c.txt", "descendant\n", "descendant");

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["a.txt".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(repo_fixture.read("a.txt"), "base-a\n");
    assert_eq!(repo_fixture.read("b.txt"), "target-b\n");
    assert_eq!(repo_fixture.read("c.txt"), "descendant\n");
    assert_eq!(
        repo_fixture.git(&["log", "-1", "--format=%s"]),
        "descendant"
    );
    assert_eq!(repo_fixture.git(&["show", "HEAD~1:a.txt"]), "base-a");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drop_selected_changes_preserves_merge_descendant_topology() {
    let repo_fixture = TestRepo::new();
    let target = merge_target_with_merge_descendant(&repo_fixture);

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["feature.txt".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert!(!repo_fixture.exists("feature.txt"));
    assert_eq!(repo_fixture.read("feature-other.txt"), "feature other\n");
    assert_eq!(repo_fixture.read("main-after.txt"), "main after\n");
    assert_eq!(repo_fixture.read("side.txt"), "side\n");
    let parents = repo_fixture.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(
        parents.split_whitespace().count(),
        3,
        "merge descendant lost a parent: {parents}"
    );
    let rewritten_target = repo_fixture.git(&["rev-parse", "HEAD^1^1"]);
    let target_parents = repo_fixture.git(&["rev-list", "--parents", "-n", "1", &rewritten_target]);
    assert_eq!(
        target_parents.split_whitespace().count(),
        3,
        "target merge was flattened below descendant: {target_parents}"
    );
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drop_selected_changes_restores_both_sides_of_a_rename() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "old.txt", "content\n", "base");
    repo_fixture.git(&["mv", "old.txt", "renamed.txt"]);
    repo_fixture.write("other.txt", "other\n");
    repo_fixture.git(&["add", "other.txt"]);
    repo_fixture.git(&["commit", "-q", "-m", "rename"]);
    let target = repo_fixture.git(&["rev-parse", "HEAD"]);

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["renamed.txt".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(repo_fixture.read("old.txt"), "content\n");
    assert!(!repo_fixture.exists("renamed.txt"));
    assert_eq!(repo_fixture.git(&["show", "HEAD:old.txt"]), "content");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn drop_selected_changes_rewrites_a_gitlink_and_updates_the_nested_worktree() {
    let repo_fixture = TestRepo::new();
    let (submodule_path, first_id, _second_id, target) = submodule_change_fixture(&repo_fixture);

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["vendor/lib".into()])
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(gitlink_id(&repo_fixture, "HEAD"), first_id);
    assert_eq!(
        common::git(&submodule_path, &["rev-parse", "HEAD"]),
        first_id
    );
    assert_eq!(
        std::fs::read_to_string(submodule_path.join("lib.txt")).unwrap(),
        "v1\n"
    );
    assert_eq!(repo_fixture.read("other.txt"), "other\n");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
    assert!(repo_fixture
        .open()
        .apply_local_changes_restore_info()
        .unwrap()
        .is_none());
}

#[test]
fn drop_selected_changes_refuses_a_dirty_nested_worktree_before_rewrite() {
    let repo_fixture = TestRepo::new();
    let (submodule_path, _first_id, _second_id, target) = submodule_change_fixture(&repo_fixture);
    let initial_head = repo_fixture.git(&["rev-parse", "HEAD"]);
    std::fs::write(submodule_path.join("lib.txt"), "nested local\n").unwrap();

    let result = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["vendor/lib".into()]);
    assert!(
        result.is_err(),
        "result={result:?}, nested status={:?}, outer status={:?}",
        common::git(&submodule_path, &["status", "--porcelain"]),
        repo_fixture.git(&["status", "--porcelain"])
    );
    let error = result.expect_err("dirty nested worktree must not be rewritten");

    assert!(error
        .to_string()
        .contains("clean nested submodule worktrees"));
    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), initial_head);
    assert_eq!(
        std::fs::read_to_string(submodule_path.join("lib.txt")).unwrap(),
        "nested local\n"
    );
    let nested_status = common::git(&submodule_path, &["status", "--porcelain"]);
    assert!(
        nested_status.contains("lib.txt"),
        "nested status: {nested_status:?}"
    );
    assert!(repo_fixture.open().stash_list().unwrap().is_empty());
}

#[test]
fn drop_selected_changes_refuses_an_uninitialized_gitlink_before_rewrite() {
    let repo_fixture = TestRepo::new();
    let (submodule_path, _first_id, _second_id, target) = submodule_change_fixture(&repo_fixture);
    let initial_head = repo_fixture.git(&["rev-parse", "HEAD"]);
    common::git(
        &repo_fixture.path,
        &["submodule", "deinit", "-f", "--", "vendor/lib"],
    );

    let error = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["vendor/lib".into()])
        .expect_err("uninitialized gitlink must fail closed");

    assert!(
        error.to_string().contains("not initialized"),
        "error: {error}"
    );
    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), initial_head);
    assert!(!submodule_path.join(".git").exists());
    assert!(repo_fixture.open().stash_list().unwrap().is_empty());
}

#[test]
fn extract_selected_changes_splits_target_and_preserves_full_target_tree() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    let outcome = repo_fixture
        .open()
        .extract_selected_changes(target, vec!["a.txt".into()], "extracted".into())
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(repo_fixture.git(&["log", "-1", "--format=%s"]), "extracted");
    assert_eq!(repo_fixture.git(&["show", "HEAD:a.txt"]), "target-a");
    assert_eq!(repo_fixture.git(&["show", "HEAD:b.txt"]), "target-b");
    assert_eq!(repo_fixture.git(&["show", "HEAD^:a.txt"]), "base-a");
    assert_eq!(repo_fixture.git(&["show", "HEAD^:b.txt"]), "target-b");
    assert_eq!(
        repo_fixture.git(&["log", "-2", "--format=%s"]),
        "extracted\ntarget"
    );
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn extract_selected_changes_preserves_merge_target_before_new_commit() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "base.txt", "base\n", "base");
    repo_fixture.git(&["branch", "feature"]);
    repo_fixture.git(&["switch", "-q", "feature"]);
    common::commit(&repo_fixture.path, "feature.txt", "feature\n", "feature");
    repo_fixture.write("feature-other.txt", "feature other\n");
    repo_fixture.git(&["add", "feature-other.txt"]);
    repo_fixture.git(&["commit", "-q", "-m", "feature other"]);
    repo_fixture.git(&["switch", "-q", "main"]);
    common::commit(&repo_fixture.path, "main.txt", "main\n", "main");
    repo_fixture.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    let target = repo_fixture.git(&["rev-parse", "HEAD"]);

    let outcome = repo_fixture
        .open()
        .extract_selected_changes(target, vec!["feature.txt".into()], "extract feature".into())
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(
        repo_fixture.git(&["log", "-1", "--format=%s"]),
        "extract feature"
    );
    assert_eq!(repo_fixture.read("feature.txt"), "feature\n");
    assert_eq!(repo_fixture.read("feature-other.txt"), "feature other\n");
    let rewritten_merge = repo_fixture.git(&["rev-parse", "HEAD^"]);
    let parents = repo_fixture.git(&["rev-list", "--parents", "-n", "1", &rewritten_merge]);
    assert_eq!(
        parents.split_whitespace().count(),
        3,
        "extract flattened the rewritten merge: {parents}"
    );
    assert_eq!(repo_fixture.git(&["show", "HEAD:feature.txt"]), "feature");
    let rewritten_paths = repo_fixture.git(&["ls-tree", "-r", "--name-only", &rewritten_merge]);
    assert!(
        !rewritten_paths.lines().any(|path| path == "feature.txt"),
        "extracted paths remained in the rewritten merge: {rewritten_paths}"
    );
    assert!(rewritten_paths
        .lines()
        .any(|path| path == "feature-other.txt"));
    assert_eq!(
        repo_fixture.git(&["show", &format!("{rewritten_merge}:main.txt")]),
        "main"
    );
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn extract_selected_changes_replays_merge_descendants_and_keeps_topology() {
    let repo_fixture = TestRepo::new();
    let target = merge_target_with_merge_descendant(&repo_fixture);

    let outcome = repo_fixture
        .open()
        .extract_selected_changes(target, vec!["feature.txt".into()], "extract feature".into())
        .unwrap();

    assert!(!outcome.paused);
    assert!(repo_fixture.exists("feature.txt"));
    assert_eq!(repo_fixture.read("feature-other.txt"), "feature other\n");
    assert_eq!(repo_fixture.read("main-after.txt"), "main after\n");
    assert_eq!(repo_fixture.read("side.txt"), "side\n");
    assert!(repo_fixture
        .git(&["log", "--first-parent", "--format=%s", "HEAD"])
        .lines()
        .any(|message| message == "extract feature"));
    let parents = repo_fixture.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(
        parents.split_whitespace().count(),
        3,
        "extract flattened merge descendant: {parents}"
    );
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn extract_selected_changes_keeps_rename_in_the_extracted_commit() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "old.txt", "content\n", "base");
    repo_fixture.git(&["mv", "old.txt", "renamed.txt"]);
    repo_fixture.write("other.txt", "other\n");
    repo_fixture.git(&["add", "other.txt"]);
    repo_fixture.git(&["commit", "-q", "-m", "rename"]);
    let target = repo_fixture.git(&["rev-parse", "HEAD"]);

    let outcome = repo_fixture
        .open()
        .extract_selected_changes(target, vec!["renamed.txt".into()], "extracted".into())
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(repo_fixture.git(&["log", "-1", "--format=%s"]), "extracted");
    assert_eq!(repo_fixture.git(&["show", "HEAD:renamed.txt"]), "content");
    assert_eq!(repo_fixture.git(&["show", "HEAD^:old.txt"]), "content");
    assert!(repo_fixture
        .git(&["cat-file", "-e", "HEAD^:old.txt"])
        .is_empty());
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn extract_selected_changes_preserves_gitlink_topology_in_the_extracted_commit() {
    let repo_fixture = TestRepo::new();
    let (submodule_path, first_id, second_id, target) = submodule_change_fixture(&repo_fixture);

    let outcome = repo_fixture
        .open()
        .extract_selected_changes(
            target,
            vec!["vendor/lib".into()],
            "extract submodule update".into(),
        )
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(gitlink_id(&repo_fixture, "HEAD~1"), first_id);
    assert_eq!(gitlink_id(&repo_fixture, "HEAD"), second_id);
    assert_eq!(
        common::git(&submodule_path, &["rev-parse", "HEAD"]),
        second_id
    );
    assert_eq!(repo_fixture.read("other.txt"), "other\n");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn extract_selected_changes_replays_linear_descendants() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");
    common::commit(&repo_fixture.path, "c.txt", "descendant\n", "descendant");

    let outcome = repo_fixture
        .open()
        .extract_selected_changes(target, vec!["a.txt".into()], "extracted".into())
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(
        repo_fixture.git(&["log", "-1", "--format=%s"]),
        "descendant"
    );
    assert_eq!(repo_fixture.git(&["show", "HEAD~1:a.txt"]), "target-a");
    assert_eq!(repo_fixture.git(&["show", "HEAD~2:a.txt"]), "base-a");
    assert_eq!(repo_fixture.read("c.txt"), "descendant\n");
    assert!(repo_fixture.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn selected_change_history_actions_preserve_staged_unstaged_and_untracked_files() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    common::commit(
        &repo_fixture.path,
        "local.txt",
        "base-local\n",
        "local base",
    );
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    repo_fixture.write("local.txt", "staged local\n");
    repo_fixture.git(&["add", "local.txt"]);
    repo_fixture.write("local.txt", "unstaged local\n");
    repo_fixture.write("untracked.txt", "keep untracked\n");
    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target.clone(), vec!["a.txt".into()])
        .unwrap();
    assert!(!outcome.paused);
    assert_eq!(repo_fixture.read("a.txt"), "base-a\n");
    assert_eq!(repo_fixture.read("local.txt"), "unstaged local\n");
    assert!(repo_fixture.exists("local.txt"));
    assert!(repo_fixture.exists("untracked.txt"));
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.contains("MM local.txt"), "status: {status}");
    assert!(status.contains("?? untracked.txt"), "status: {status}");
    assert!(repo_fixture
        .git(&["diff", "--cached", "--", "local.txt"])
        .contains("+staged local"));
    assert!(repo_fixture
        .git(&["diff", "--", "local.txt"])
        .contains("+unstaged local"));
}

#[test]
fn extract_selected_changes_preserves_local_changes() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    repo_fixture.write("local.txt", "local\n");
    repo_fixture.write("untracked.txt", "untracked\n");
    let outcome = repo_fixture
        .open()
        .extract_selected_changes(target, vec!["a.txt".into()], "extracted".into())
        .unwrap();
    assert!(!outcome.paused);
    assert_eq!(repo_fixture.git(&["log", "-1", "--format=%s"]), "extracted");
    assert_eq!(repo_fixture.read("local.txt"), "local\n");
    assert_eq!(repo_fixture.read("untracked.txt"), "untracked\n");
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.contains("?? local.txt"), "status: {status}");
    assert!(status.contains("?? untracked.txt"), "status: {status}");
}

#[test]
fn selected_change_history_undo_restores_tip_and_preserves_new_local_scene() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    common::commit(
        &repo_fixture.path,
        "local.txt",
        "base-local\n",
        "local base",
    );
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");
    let initial_head = target.clone();

    repo_fixture.write("local.txt", "staged local\n");
    repo_fixture.git(&["add", "local.txt"]);
    repo_fixture.write("local.txt", "unstaged local\n");

    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["a.txt".into()])
        .unwrap();
    assert_ne!(outcome.head_id, initial_head);

    repo_fixture
        .open()
        .undo_log_selected_changes_expected_head(
            initial_head.clone(),
            outcome.head_id,
            "main".into(),
            arbor_engine::LocalChangesSavePolicy::Stash,
        )
        .unwrap();

    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), initial_head);
    assert_eq!(repo_fixture.git(&["show", "HEAD:a.txt"]), "target-a");
    assert_eq!(repo_fixture.read("local.txt"), "unstaged local\n");
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.contains("MM local.txt"), "status: {status}");
}

#[test]
fn selected_change_history_undo_rejects_a_stale_head() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");
    let initial_head = target.clone();
    let outcome = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["a.txt".into()])
        .unwrap();

    let error = repo_fixture
        .open()
        .undo_log_selected_changes_expected_head(
            initial_head,
            "0".repeat(40),
            "main".into(),
            arbor_engine::LocalChangesSavePolicy::Stash,
        )
        .expect_err("stale selected-change undo must be rejected");
    assert!(error.to_string().contains("HEAD changed"));
    assert_eq!(repo_fixture.git(&["rev-parse", "HEAD"]), outcome.head_id);
}

#[test]
fn selected_change_history_actions_still_reject_all_paths() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    let all = repo_fixture.open().extract_selected_changes(
        target,
        vec!["a.txt".into(), "b.txt".into()],
        "all".into(),
    );
    assert!(all.is_err());
}

#[test]
fn selected_change_history_action_failure_restores_local_changes() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    repo_fixture.write("local.txt", "staged local\n");
    repo_fixture.git(&["add", "local.txt"]);
    repo_fixture.write("local.txt", "unstaged local\n");
    repo_fixture.write("untracked.txt", "keep untracked\n");

    let result = repo_fixture.open().extract_selected_changes(
        target,
        vec!["a.txt".into(), "b.txt".into()],
        "all".into(),
    );
    assert!(result.is_err());
    assert_eq!(repo_fixture.read("local.txt"), "unstaged local\n");
    assert!(repo_fixture.exists("untracked.txt"));
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.contains("AM local.txt"), "status: {status}");
    assert!(status.contains("?? untracked.txt"), "status: {status}");
    assert!(repo_fixture.open().stash_list().unwrap().is_empty());
}

#[test]
fn selected_change_history_action_keeps_stash_on_restore_conflict() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");
    repo_fixture.write("a.txt", "local-a\n");

    let result = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["a.txt".into()]);
    assert!(result.is_err());
    let restored = repo_fixture.open();
    assert_eq!(restored.stash_list().unwrap().len(), 1);
    let marker = restored
        .apply_local_changes_restore_info()
        .unwrap()
        .expect("restore conflict must leave a durable history-rewrite marker");
    assert_eq!(marker.operation, "history-rewrite");
    assert_eq!(marker.kind, "stash");
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.contains("UU a.txt"), "status: {status}");
    let content = repo_fixture.read("a.txt");
    assert!(content.contains("<<<<<<<"), "content: {content}");
    assert!(content.contains("local-a"), "content: {content}");
    assert!(content.contains("base-a"), "content: {content}");
}

#[test]
fn staged_restore_conflict_enters_conflict_state_and_keeps_stash() {
    let repo_fixture = TestRepo::new();
    common::commit(&repo_fixture.path, "a.txt", "base-a\n", "base");
    let target = commit_two_files(&repo_fixture, "target-a\n", "target-b\n", "target");

    repo_fixture.write("a.txt", "staged-a\n");
    repo_fixture.git(&["add", "a.txt"]);
    repo_fixture.write("a.txt", "target-a\n");

    let result = repo_fixture
        .open()
        .drop_selected_changes(target, vec!["a.txt".into()]);
    assert!(result.is_err());
    assert_eq!(repo_fixture.open().stash_list().unwrap().len(), 1);
    let status = repo_fixture.git(&["status", "--porcelain"]);
    assert!(status.contains("UU a.txt"), "status: {status}");
    let content = repo_fixture.read("a.txt");
    assert!(content.contains("<<<<<<<"), "content: {content}");
    assert!(content.contains("staged-a"), "content: {content}");
    assert!(content.contains("base-a"), "content: {content}");
}

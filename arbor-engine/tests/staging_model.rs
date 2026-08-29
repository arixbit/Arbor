//! IDX-001：三层 staging 模型、index tracker、忽略规则入口。
//! 真实 fixture 验证 HEAD/index/worktree 分层状态、index 特殊标志、
//! 二进制/子模块降级标记、外部 Git 修改 index 的检测。

mod common;

use arbor_engine::{DiffMode, StagingStatus};
use common::TestRepo;

#[test]
fn three_layer_classification() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    let repo = r.open();

    // 修改未暂存 -> 只有 has_unstaged
    r.write("f.txt", "base\nchanged\n");
    let model = repo.staging_model().expect("model");
    let entry = model
        .entries
        .iter()
        .find(|e| e.path == "f.txt")
        .expect("entry");
    assert!(!entry.has_staged);
    assert!(entry.has_unstaged);
    assert_eq!(entry.status, StagingStatus::Modified);
    assert!(!entry.binary);

    // 暂存 -> 两层都有
    repo.stage("f.txt".into()).expect("stage");
    let model = repo.staging_model().expect("model");
    let entry = model
        .entries
        .iter()
        .find(|e| e.path == "f.txt")
        .expect("entry");
    assert!(entry.has_staged);
    assert!(!entry.has_unstaged);

    // 提交 -> 干净
    repo.commit("m".into(), false).expect("commit");
    let model = repo.staging_model().expect("model");
    assert!(
        model.entries.is_empty() || !model.entries.iter().any(|e| e.has_staged || e.has_unstaged)
    );
}

#[test]
fn staging_file_versions_return_head_index_and_worktree_contents() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "head\n", "init");
    r.write("f.txt", "staged\n");
    let repo = r.open();
    repo.stage("f.txt".into()).expect("stage");
    r.write("f.txt", "local\n");

    let versions = repo
        .staging_file_versions("f.txt".into())
        .expect("versions");
    assert!(versions.head.present);
    assert_eq!(versions.head.text, "head\n");
    assert!(versions.staged.present);
    assert_eq!(versions.staged.text, "staged\n");
    assert!(versions.local.present);
    assert_eq!(versions.local.text, "local\n");
    assert!(!versions.head.binary && !versions.staged.binary && !versions.local.binary);
}

#[test]
fn staging_file_versions_distinguish_missing_side_from_empty_file() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "head\n", "init");
    let repo = r.open();
    std::fs::remove_file(r.path.join("f.txt")).unwrap();

    let versions = repo
        .staging_file_versions("f.txt".into())
        .expect("versions");
    assert!(versions.head.present);
    assert!(versions.staged.present);
    assert_eq!(versions.staged.text, "head\n");
    assert!(!versions.local.present);
}

#[cfg(unix)]
#[test]
fn staging_file_versions_read_symlink_as_link_content() {
    use std::os::unix::fs::symlink;

    let r = TestRepo::new();
    r.write("target.txt", "target content\n");
    symlink("target.txt", r.path.join("link.txt")).expect("symlink");
    r.git(&["add", "target.txt", "link.txt"]);
    r.git(&["commit", "-qm", "init"]);

    let repo = r.open();
    let versions = repo
        .staging_file_versions("link.txt".into())
        .expect("versions");
    assert_eq!(versions.head.text, "target.txt");
    assert_eq!(versions.staged.text, "target.txt");
    assert_eq!(versions.local.text, "target.txt");
    assert!(!versions.local.binary);
}

#[test]
fn stage_tracked_leaves_untracked_files_out_of_the_index() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "base\n", "init");
    common::commit(&r.path, "deleted.txt", "remove me\n", "second");
    r.write("tracked.txt", "changed\n");
    std::fs::remove_file(r.path.join("deleted.txt")).unwrap();
    r.write("new.txt", "untracked\n");

    let repo = r.open();
    repo.stage_tracked().expect("stage tracked");

    let model = repo.staging_model().expect("model");
    let tracked = model
        .entries
        .iter()
        .find(|entry| entry.path == "tracked.txt")
        .expect("tracked entry");
    assert!(tracked.has_staged);
    let deleted = model
        .entries
        .iter()
        .find(|entry| entry.path == "deleted.txt")
        .expect("deleted entry");
    assert!(deleted.has_staged);
    let untracked = model
        .entries
        .iter()
        .find(|entry| entry.path == "new.txt")
        .expect("untracked entry");
    assert!(!untracked.has_staged);
    assert!(untracked.has_unstaged);
}

#[test]
fn commit_all_tracked_path_preserves_untracked_files() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "base\n", "init");
    r.write("tracked.txt", "changed\n");
    r.write("new.txt", "untracked\n");

    let repo = r.open();
    repo.stage_tracked().expect("stage tracked");
    let commit_id = repo
        .commit("tracked changes".into(), false)
        .expect("commit tracked changes");

    let committed_paths = r.git(&["show", "--format=", "--name-only", &commit_id]);
    assert!(committed_paths.lines().any(|path| path == "tracked.txt"));
    assert!(!committed_paths.lines().any(|path| path == "new.txt"));
    assert!(r.path.join("new.txt").exists());
}

#[test]
fn untracked_and_deleted_classification() {
    let r = TestRepo::new();
    common::commit(&r.path, "keep.txt", "k\n", "init");
    r.write("new.txt", "n\n");
    let repo = r.open();

    let model = repo.staging_model().expect("model");
    let untracked = model
        .entries
        .iter()
        .find(|e| e.path == "new.txt")
        .expect("untracked");
    assert_eq!(untracked.status, StagingStatus::Untracked);
    assert!(untracked.has_unstaged);

    repo.stage("new.txt".into()).expect("stage new");
    // 删除已跟踪文件
    std::fs::remove_file(r.path.join("keep.txt")).unwrap();
    let model = repo.staging_model().expect("model");
    let added = model
        .entries
        .iter()
        .find(|e| e.path == "new.txt")
        .expect("added");
    assert_eq!(added.status, StagingStatus::Added);
    assert!(added.has_staged);
    let deleted = model
        .entries
        .iter()
        .find(|e| e.path == "keep.txt")
        .expect("deleted");
    assert_eq!(deleted.status, StagingStatus::Deleted);
}

#[test]
fn staging_model_reports_head_index_and_worktree_presence() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "tracked\n", "init");
    common::commit(&r.path, "deleted.txt", "deleted\n", "second");
    let repo = r.open();

    r.write("tracked.txt", "local\n");
    r.write("added.txt", "added\n");
    repo.stage("added.txt".into()).expect("stage added");
    std::fs::remove_file(r.path.join("deleted.txt")).expect("delete tracked");
    repo.stage("deleted.txt".into()).expect("stage deletion");

    let model = repo.staging_model().expect("model");
    let entry = |path: &str| {
        model
            .entries
            .iter()
            .find(|value| value.path == path)
            .unwrap_or_else(|| panic!("missing staging entry: {path}"))
    };

    let tracked = entry("tracked.txt");
    assert!(tracked.head_present);
    assert!(tracked.staged_present);
    assert!(tracked.local_present);

    let added = entry("added.txt");
    assert!(!added.head_present);
    assert!(added.staged_present);
    assert!(added.local_present);

    let deleted = entry("deleted.txt");
    assert!(deleted.head_present);
    assert!(!deleted.staged_present);
    assert!(!deleted.local_present);
}

#[test]
fn binary_and_submodule_flags() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("img.png", "\u{0}PNG\x00\x01\x02");
    let repo = r.open();
    let model = repo.staging_model().expect("model");
    let binary = model
        .entries
        .iter()
        .find(|e| e.path == "img.png")
        .expect("binary");
    assert!(
        binary.binary,
        "NUL-containing file should be flagged binary"
    );
}

#[test]
fn submodule_entry_marked() {
    let outer = tempfile::tempdir().expect("tempdir");
    let outer_path = outer.path();
    common::git(outer_path, &["init", "-q"]);
    common::git(outer_path, &["config", "user.name", "Arbor Test"]);
    common::git(outer_path, &["config", "user.email", "test@arbor.local"]);
    common::git(outer_path, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::commit(outer_path, "main.txt", "m\n", "init");
    let sub_source = tempfile::tempdir().expect("tempdir");
    common::git(sub_source.path(), &["init", "-q"]);
    common::git(sub_source.path(), &["config", "user.name", "Arbor Test"]);
    common::git(
        sub_source.path(),
        &["config", "user.email", "test@arbor.local"],
    );
    common::git(
        sub_source.path(),
        &["symbolic-ref", "HEAD", "refs/heads/main"],
    );
    common::commit(sub_source.path(), "lib.txt", "l\n", "init");
    common::git(
        outer_path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &sub_source.path().display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(outer_path, &["commit", "-q", "-m", "add submodule"]);
    // submodule 克隆的内部仓库没有身份配置:先设置再提交变更
    let sub_dir = outer_path.join("vendor/lib");
    common::git(&sub_dir, &["config", "user.name", "Arbor Test"]);
    common::git(&sub_dir, &["config", "user.email", "test@arbor.local"]);
    common::commit(&sub_dir, "lib.txt", "l2\n", "sub change");

    let repo = arbor_engine::open_repository(outer_path.display().to_string()).expect("open");
    let model = repo.staging_model().expect("model");
    let sub = model
        .entries
        .iter()
        .find(|e| e.path == "vendor/lib")
        .expect("submodule entry");
    assert!(sub.is_submodule);
    assert!(sub.has_unstaged);
}

#[test]
fn assume_unchanged_and_skip_worktree_flags() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a\n", "init");
    common::commit(&r.path, "b.txt", "b\n", "init2");
    // 外部 git 设置标志(文件未修改:标志会把它从 status 中隐藏,
    // 模型必须通过 index 扫描显式展示)
    r.git(&["update-index", "--assume-unchanged", "a.txt"]);
    r.git(&["update-index", "--skip-worktree", "b.txt"]);

    let repo = r.open();
    let model = repo.staging_model().expect("model");
    let a = model.entries.iter().find(|e| e.path == "a.txt").expect("a");
    assert!(a.assume_unchanged);
    assert!(!a.skip_worktree);
    let b = model.entries.iter().find(|e| e.path == "b.txt").expect("b");
    assert!(b.skip_worktree);
    assert!(!b.assume_unchanged);
}

#[test]
fn intent_to_add_flag() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("todo.txt", "later\n");
    r.git(&["add", "-N", "todo.txt"]);

    let repo = r.open();
    let model = repo.staging_model().expect("model");
    let todo = model
        .entries
        .iter()
        .find(|e| e.path == "todo.txt")
        .expect("todo");
    assert!(todo.intent_to_add);
}

#[test]
fn repository_can_stage_intent_to_add_without_content() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("todo.txt", "later\n");

    let repo = r.open();
    repo.stage_without_content("todo.txt".into())
        .expect("intent-to-add");

    let model = repo.staging_model().expect("model");
    let todo = model
        .entries
        .iter()
        .find(|entry| entry.path == "todo.txt")
        .expect("todo");
    assert!(todo.intent_to_add);
    assert!(!todo.has_staged);
    assert!(todo.has_unstaged);
    assert!(r.git(&["diff", "--cached", "--name-status"]).is_empty());
    assert!(r.git(&["diff", "--name-status"]).contains("todo.txt"));
}

#[test]
fn repository_can_stage_multiple_files_without_content() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("one.txt", "one\n");
    r.write("two.txt", "two\n");

    let repo = r.open();
    repo.stage_without_content_paths(vec!["one.txt".into(), "two.txt".into()])
        .expect("intent-to-add batch");

    let model = repo.staging_model().expect("model");
    for path in ["one.txt", "two.txt"] {
        let entry = model
            .entries
            .iter()
            .find(|entry| entry.path == path)
            .expect("intent-to-add entry");
        assert!(entry.intent_to_add, "{path} should be intent-to-add");
        assert!(!entry.has_staged, "{path} must not stage its content");
        assert!(entry.has_unstaged, "{path} should remain unstaged");
    }
    assert!(r.git(&["diff", "--cached", "--name-status"]).is_empty());
    let diff = r.git(&["diff", "--name-status"]);
    assert!(diff.contains("one.txt") && diff.contains("two.txt"));
}

#[test]
fn repository_can_stage_vfs_created_files_with_empty_index_blobs() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("created.txt", "created in the worktree\n");

    let repo = r.open();
    repo.stage_empty_blob_paths(vec!["created.txt".into()])
        .expect("staging-area add");

    let model = repo.staging_model().expect("model");
    let created = model
        .entries
        .iter()
        .find(|entry| entry.path == "created.txt")
        .expect("created entry");
    assert!(created.has_staged);
    assert!(created.has_unstaged);
    assert!(!created.intent_to_add);
    assert_eq!(r.git(&["status", "--short"]), "AM created.txt");
    assert_eq!(r.git(&["cat-file", "-p", ":created.txt"]), "");
    assert_eq!(
        r.git(&["diff", "--cached", "--name-status"]),
        "A\tcreated.txt"
    );
    assert!(r.git(&["diff", "--name-status"]).contains("created.txt"));
}

#[test]
fn rename_status_preserves_original_path_in_status_and_staging_models() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "rename me\n", "init");
    r.git(&["mv", "old.txt", "new.txt"]);

    let repo = r.open();
    let status = repo.status().expect("status");
    let renamed = status
        .iter()
        .find(|entry| entry.path == "new.txt")
        .expect("renamed status entry");
    assert_eq!(renamed.staged, arbor_engine::ChangeKind::Renamed);
    assert_eq!(renamed.old_path.as_deref(), Some("old.txt"));

    let model = repo.staging_model().expect("staging model");
    let staged = model
        .entries
        .iter()
        .find(|entry| entry.path == "new.txt")
        .expect("renamed staging entry");
    assert_eq!(staged.old_path.as_deref(), Some("old.txt"));
    assert!(staged.head_present, "rename must retain its HEAD side");
    assert!(staged.staged_present, "rename must retain its index side");
    assert!(staged.local_present, "rename must retain its worktree side");

    let versions = repo
        .staging_file_versions("new.txt".into())
        .expect("renamed staging versions");
    assert_eq!(versions.head.text, "rename me\n");
    assert_eq!(versions.staged.text, "rename me\n");
    assert_eq!(versions.local.text, "rename me\n");
    let diff = repo
        .staging_diff("new.txt".into(), false)
        .expect("renamed staging diff");
    assert!(
        diff.staged.is_none(),
        "pure rename has no staged content diff"
    );
}

#[test]
fn index_tracker_detects_external_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    let repo = r.open();
    let rev1 = repo.index_revision().expect("rev1");

    // 外部 git 修改 index
    r.write("f.txt", "y\n");
    r.git(&["add", "f.txt"]);
    let changed = repo.index_changed_since(rev1.clone()).expect("changed");
    assert!(changed, "external git add must change index revision");

    // 没有新写入时不变
    let rev2 = repo.index_revision().expect("rev2");
    let unchanged = repo.index_changed_since(rev2.clone()).expect("unchanged");
    assert!(!unchanged);
}

#[test]
fn repository_exposes_actual_git_dir_for_external_file_watchers() {
    let r = TestRepo::new();
    common::commit(&r.path, "README.md", "base\n", "base");
    let repo = r.open();

    assert_eq!(
        std::path::PathBuf::from(repo.git_dir()),
        r.path.join(".git")
    );

    let linked_root = tempfile::tempdir().expect("linked root");
    let linked_path = linked_root.path().join("linked");
    repo.worktree_add(
        linked_path.to_string_lossy().into_owned(),
        Some("linked-branch".into()),
        Some("HEAD".into()),
    )
    .expect("linked worktree");
    let linked_repo = arbor_engine::open_repository(linked_path.to_string_lossy().into_owned())
        .expect("open linked worktree");
    let linked_git_dir = std::path::PathBuf::from(linked_repo.git_dir());
    assert!(
        linked_git_dir.ends_with(std::path::Path::new("worktrees").join("linked")),
        "linked worktree must watch its real administrative directory: {}",
        linked_git_dir.display()
    );
}

#[test]
fn staging_diff_three_way() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "one\ntwo\nthree\n", "init");
    r.write("f.txt", "one\nTWO\nthree\n");
    r.git(&["add", "f.txt"]);
    r.write("f.txt", "one\nTWO\nTHREE\n");
    let repo = r.open();

    let diff = repo
        .staging_diff("f.txt".into(), false)
        .expect("staging diff");
    let staged = diff.staged.expect("staged diff");
    assert_eq!(staged.path, "f.txt");
    let unstaged = diff.unstaged.expect("unstaged diff");
    assert_eq!(unstaged.path, "f.txt");

    // WorktreeToHead 模式:完整三层比较
    let full = repo
        .diff_file("f.txt".into(), DiffMode::WorktreeToHead, false)
        .expect("full diff");
    assert!(!full.binary);
    assert!(!full.hunks.is_empty());
}

#[test]
fn stage_all_and_unstage_all_roundtrip() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("f.txt", "y\n");
    r.write("new.txt", "n\n");
    let repo = r.open();

    repo.stage_all().expect("stage all");
    let model = repo.staging_model().expect("model");
    for entry in &model.entries {
        assert!(entry.has_staged, "{} should be staged", entry.path);
        assert!(!entry.has_unstaged);
    }

    repo.unstage_all().expect("unstage all");
    let model = repo.staging_model().expect("model");
    for entry in &model.entries {
        assert!(!entry.has_staged);
        assert!(
            entry.has_unstaged,
            "{} should be unstaged again",
            entry.path
        );
    }
}

#[test]
fn gitignore_and_exclude_rules() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    let repo = r.open();

    let rule = repo.add_to_gitignore("*.log".into()).expect("gitignore");
    assert_eq!(rule, "*.log");
    let excluded = repo.exclude_path("secrets.txt".into()).expect("exclude");
    assert_eq!(excluded, "secrets.txt");

    // 规则生效:gitignore 的规则在 ignored_rules 中可见(Gitignore 来源)
    r.write("debug.log", "log\n");
    let rules = repo.ignored_rules().expect("ignored rules");
    assert!(
        rules.iter().any(|info| info.path == "debug.log"),
        "debug.log should be ignored: {rules:?}"
    );
}

#[test]
fn gitignore_rule_can_target_existing_ancestor_ignore_file() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("Sources/.gitignore", "# keep\n");
    common::git(&r.path, &["add", "Sources/.gitignore"]);
    common::commit(&r.path, "Sources/.gitignore", "# keep\n", "ignore file");
    r.write("Sources/new.txt", "new\n");
    let repo = r.open();

    let rule = repo
        .add_to_gitignore_at(
            "new.txt".into(),
            r.path
                .join("Sources/.gitignore")
                .to_string_lossy()
                .into_owned(),
            r.path
                .join("Sources/new.txt")
                .to_string_lossy()
                .into_owned(),
        )
        .expect("targeted gitignore");
    assert_eq!(rule, "new.txt");
    assert_eq!(
        std::fs::read_to_string(r.path.join("Sources/.gitignore")).unwrap(),
        "# keep\nnew.txt\n"
    );
    assert!(!r.path.join(".gitignore").exists());
}

#[test]
fn gitignore_rule_can_create_a_target_directory_ignore_file() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("Sources/Feature/new.txt", "new\n");
    let repo = r.open();

    let rule = repo
        .add_to_gitignore_at(
            "new.txt".into(),
            r.path
                .join("Sources/Feature/.gitignore")
                .to_string_lossy()
                .into_owned(),
            r.path
                .join("Sources/Feature/new.txt")
                .to_string_lossy()
                .into_owned(),
        )
        .expect("create targeted gitignore");
    assert_eq!(rule, "new.txt");
    assert_eq!(
        std::fs::read_to_string(r.path.join("Sources/Feature/.gitignore")).unwrap(),
        "new.txt\n"
    );
    assert!(!r.path.join(".gitignore").exists());
}

#[test]
fn gitignore_rules_can_append_multiple_targets_to_shared_file() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("Sources/.gitignore", "# keep\n");
    common::git(&r.path, &["add", "Sources/.gitignore"]);
    common::commit(&r.path, "Sources/.gitignore", "# keep\n", "ignore file");
    r.write("Sources/one.tmp", "one\n");
    r.write("Sources/two.tmp", "two\n");
    let repo = r.open();

    let rules = repo
        .add_to_gitignore_at_paths(
            vec!["one.tmp".into(), "two.tmp".into()],
            r.path
                .join("Sources/.gitignore")
                .to_string_lossy()
                .into_owned(),
            vec![
                r.path
                    .join("Sources/one.tmp")
                    .to_string_lossy()
                    .into_owned(),
                r.path
                    .join("Sources/two.tmp")
                    .to_string_lossy()
                    .into_owned(),
            ],
        )
        .expect("targeted multi-file gitignore");
    assert_eq!(rules, ["one.tmp", "two.tmp"]);
    assert_eq!(
        std::fs::read_to_string(r.path.join("Sources/.gitignore")).unwrap(),
        "# keep\none.tmp\ntwo.tmp\n"
    );
}

#[test]
fn gitignore_target_rejects_ignore_file_outside_target_ancestry() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("Sources/.gitignore", "# keep\n");
    r.write("Other/new.txt", "new\n");
    let repo = r.open();

    let error = repo
        .add_to_gitignore_at(
            "new.txt".into(),
            r.path
                .join("Sources/.gitignore")
                .to_string_lossy()
                .into_owned(),
            r.path.join("Other/new.txt").to_string_lossy().into_owned(),
        )
        .expect_err("unrelated ignore file must be rejected")
        .to_string();
    assert!(error.contains("not suitable"), "{error}");
}

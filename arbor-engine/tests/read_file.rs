mod common;

use arbor_engine::GitContentTransformMode;
use common::{commit, TestRepo};

#[test]
fn read_worktree_file_returns_text_and_binary_metadata() {
    let repo = TestRepo::new();
    repo.write("hello.txt", "hello\n世界\n");
    std::fs::write(repo.path.join("image.bin"), [0x42, 0x00, 0x10, 0xff]).unwrap();

    let engine = repo.open();
    let text = engine.read_worktree_file("hello.txt".into()).unwrap();
    assert!(!text.binary);
    assert!(!text.truncated);
    assert_eq!(text.text, "hello\n世界\n");

    let binary = engine.read_worktree_file("image.bin".into()).unwrap();
    assert!(binary.binary);
    assert!(!binary.truncated);
    assert!(binary.text.is_empty());
}

#[test]
fn read_worktree_file_truncates_large_text() {
    let repo = TestRepo::new();
    let content = "x".repeat(1024 * 1024 + 17);
    std::fs::write(repo.path.join("large.txt"), &content).unwrap();

    let result = repo.open().read_worktree_file("large.txt".into()).unwrap();
    assert!(!result.binary);
    assert!(result.truncated);
    assert_eq!(result.text.len(), 1024 * 1024);
}

#[test]
fn read_index_file_returns_the_staged_version() {
    let repo = TestRepo::new();
    commit(&repo.path, "f.txt", "head\n", "init");
    repo.write("f.txt", "staged\n");
    let engine = repo.open();
    engine.stage("f.txt".into()).unwrap();
    repo.write("f.txt", "local\n");

    let staged = engine.read_index_file("f.txt".into()).unwrap();
    assert!(!staged.binary);
    assert!(!staged.truncated);
    assert_eq!(staged.text, "staged\n");
    assert!(engine.read_index_file("missing.txt".into()).is_err());
}

#[test]
fn read_worktree_file_rejects_missing_and_unsafe_paths() {
    let repo = TestRepo::new();
    let engine = repo.open();

    assert!(engine.read_worktree_file("missing.txt".into()).is_err());
    assert!(engine.read_worktree_file("../outside.txt".into()).is_err());
    assert!(engine.read_worktree_file(".git/config".into()).is_err());
    assert!(engine.read_worktree_file("".into()).is_err());
}

#[test]
fn revision_browser_lists_tree_and_reads_blob() {
    let repo = TestRepo::new();
    let revision = commit(&repo.path, "src/main.rs", "fn main() {}\n", "root");
    let latest = commit(&repo.path, "README.md", "read me\n", "second");
    let engine = repo.open();

    let root = engine.list_revision_dir(latest, String::new()).unwrap();
    assert!(root.iter().any(|entry| entry.name == "src" && entry.is_dir));
    assert!(root
        .iter()
        .any(|entry| entry.name == "README.md" && !entry.is_dir));

    let src = engine
        .list_revision_dir(revision.clone(), "src".into())
        .unwrap();
    assert_eq!(src.len(), 1);
    assert_eq!(src[0].path, "src/main.rs");
    assert!(!src[0].is_dir);

    let file = engine
        .read_revision_file(revision, "src/main.rs".into())
        .unwrap();
    assert!(!file.binary);
    assert!(!file.truncated);
    assert_eq!(file.text, "fn main() {}\n");
}

#[test]
fn revision_file_content_honors_none_filters_and_textconv_modes() {
    let repo = TestRepo::new();
    repo.git(&["config", "filter.upper.clean", "tr A-Z a-z"]);
    repo.git(&["config", "filter.upper.smudge", "tr a-z A-Z"]);
    repo.git(&[
        "config",
        "diff.upper.textconv",
        "sh -c 'tr a-z A-Z < \"$1\"' _",
    ]);
    repo.write(
        ".gitattributes",
        "filtered.txt filter=upper\nconverted.txt diff=upper\n",
    );
    repo.write("filtered.txt", "hello\n");
    repo.write("converted.txt", "world\n");
    repo.git(&["add", ".gitattributes", "filtered.txt", "converted.txt"]);
    repo.git(&["commit", "-q", "-m", "content modes"]);
    let revision = repo.git(&["rev-parse", "HEAD"]);
    let engine = repo.open();

    let raw = engine
        .read_revision_file_with_mode(
            revision.clone(),
            "filtered.txt".into(),
            GitContentTransformMode::None,
        )
        .unwrap();
    assert_eq!(raw.text, "hello\n");

    let filtered = engine
        .read_revision_file_with_mode(
            revision.clone(),
            "filtered.txt".into(),
            GitContentTransformMode::Filters,
        )
        .unwrap();
    assert_eq!(filtered.text, "HELLO\n");

    let textconv = engine
        .read_revision_file_with_mode(
            revision,
            "converted.txt".into(),
            GitContentTransformMode::Textconv,
        )
        .unwrap();
    assert_eq!(textconv.text, "WORLD\n");
}

mod common;

use common::TestRepo;

#[test]
fn list_dir_is_incremental_and_excludes_git_metadata() {
    let repo = TestRepo::new();
    repo.write("README.md", "# Arbor\n");
    repo.write("src/main.rs", "fn main() {}\n");
    repo.write(".env", "ARBOR=1\n");
    std::fs::create_dir(repo.path.join("empty")).unwrap();

    let engine = repo.open();
    let root = engine.list_dir(String::new()).unwrap();
    assert!(root.iter().all(|entry| entry.name != ".git"));
    assert!(root.iter().any(|entry| entry.name == "src" && entry.is_dir));
    assert!(root
        .iter()
        .any(|entry| entry.name == "README.md" && !entry.is_dir));
    assert!(root
        .iter()
        .any(|entry| entry.name == ".env" && !entry.is_dir));
    assert!(root
        .iter()
        .any(|entry| entry.name == "empty" && entry.is_dir));

    let children = engine.list_dir("src".into()).unwrap();
    assert_eq!(children.len(), 1);
    assert_eq!(children[0].name, "main.rs");
    assert_eq!(children[0].path, "src/main.rs");

    let empty = engine.list_dir("empty".into()).unwrap();
    assert!(empty.is_empty());
}

#[test]
fn list_dir_is_sorted_with_directories_first() {
    let repo = TestRepo::new();
    repo.write("z.txt", "");
    repo.write("a.txt", "");
    repo.write("B/file.txt", "");
    repo.write("a-dir/file.txt", "");

    let entries = repo.open().list_dir("".into()).unwrap();
    let actual: Vec<(&str, bool)> = entries
        .iter()
        .map(|entry| (entry.name.as_str(), entry.is_dir))
        .collect();
    assert_eq!(
        actual,
        vec![
            ("a-dir", true),
            ("B", true),
            ("a.txt", false),
            ("z.txt", false),
        ]
    );
}

#[test]
fn list_dir_rejects_paths_outside_worktree() {
    let repo = TestRepo::new();
    let engine = repo.open();

    assert!(engine.list_dir("../".into()).is_err());
    assert!(engine.list_dir(".git".into()).is_err());
}

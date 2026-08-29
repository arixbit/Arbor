//! Git worktree porcelain API。

mod common;

use common::TestRepo;

#[test]
fn lists_and_manages_linked_worktree() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "README.md", "base", "base");
    let linked = tempfile::tempdir().unwrap();
    let linked_path = linked.path().join("linked");
    repo.open()
        .worktree_add(
            linked_path.to_string_lossy().into_owned(),
            Some("linked-branch".into()),
            Some("HEAD".into()),
        )
        .unwrap();

    let worktrees = repo.open().worktree_list().unwrap();
    assert_eq!(worktrees.len(), 2);
    assert!(worktrees.iter().any(|item| item.branch == "linked-branch"));

    repo.open()
        .worktree_remove(linked_path.to_string_lossy().into_owned(), false)
        .unwrap();
    assert_eq!(repo.open().worktree_list().unwrap().len(), 1);
}

#[test]
fn worktree_snapshot_preserves_locked_state_for_branch_actions() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "README.md", "base", "base");
    let linked = tempfile::tempdir().unwrap();
    let linked_path = linked.path().join("linked");
    repo.open()
        .worktree_add(
            linked_path.to_string_lossy().into_owned(),
            Some("linked-branch".into()),
            Some("HEAD".into()),
        )
        .unwrap();
    repo.open()
        .worktree_lock(linked_path.to_string_lossy().into_owned())
        .unwrap();

    let item = repo
        .open()
        .worktree_list()
        .unwrap()
        .into_iter()
        .find(|item| item.branch == "linked-branch")
        .expect("linked worktree");
    assert_eq!(
        item.path,
        std::fs::canonicalize(&linked_path)
            .unwrap()
            .to_string_lossy()
    );
    assert!(item.locked);
}

#[test]
fn worktree_lock_unlock_and_prune_update_porcelain_state() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "README.md", "base", "base");
    let linked_root = tempfile::tempdir().unwrap();
    let linked_path = linked_root.path().join("linked");
    repo.open()
        .worktree_add(
            linked_path.to_string_lossy().into_owned(),
            Some("linked-branch".into()),
            Some("HEAD".into()),
        )
        .unwrap();

    let handle = repo.open();
    handle
        .worktree_lock(linked_path.to_string_lossy().into_owned())
        .unwrap();
    assert!(handle
        .worktree_list()
        .unwrap()
        .iter()
        .any(|item| item.branch == "linked-branch" && item.locked));

    handle
        .worktree_unlock(linked_path.to_string_lossy().into_owned())
        .unwrap();
    assert!(handle
        .worktree_list()
        .unwrap()
        .iter()
        .any(|item| item.branch == "linked-branch" && !item.locked));

    std::fs::remove_dir_all(&linked_path).unwrap();
    assert!(handle
        .worktree_list()
        .unwrap()
        .iter()
        .any(|item| item.branch == "linked-branch" && item.prunable));
    handle.worktree_prune().unwrap();
    assert_eq!(handle.worktree_list().unwrap().len(), 1);
}

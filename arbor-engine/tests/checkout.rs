//! Log context menu 的 detached checkout 回归测试。

mod common;

use common::TestRepo;

#[test]
fn checkout_detaches_at_selected_commit_and_restores_worktree() {
    let repo = TestRepo::new();
    let first = common::commit(&repo.path, "note.txt", "first\n", "first");
    let _second = common::commit(&repo.path, "note.txt", "second\n", "second");

    repo.open().checkout_detached(first.clone()).unwrap();

    assert_eq!(repo.git(&["rev-parse", "HEAD"]), first);
    assert_eq!(repo.read("note.txt"), "first\n");
    let symbolic = std::process::Command::new("git")
        .args(["symbolic-ref", "--short", "-q", "HEAD"])
        .current_dir(&repo.path)
        .output()
        .unwrap();
    assert!(!symbolic.status.success());
}

#[test]
fn checkout_detached_rejects_option_like_reference() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "note.txt", "first\n", "first");

    let error = repo
        .open()
        .checkout_detached("--help".into())
        .expect_err("option-like checkout reference must be rejected");
    assert!(error
        .to_string()
        .contains("checkout reference must not be empty or start with '-'"));
}

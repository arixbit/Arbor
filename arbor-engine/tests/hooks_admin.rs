//! HOOKS-001：hook 管理界面所需的磁盘状态 API。

mod common;

use std::os::unix::fs::PermissionsExt;

use arbor_engine::GitHookState;
use common::TestRepo;

fn hook_path(repo: &TestRepo, name: &str) -> std::path::PathBuf {
    repo.path.join(".git/hooks").join(name)
}

fn write_executable(path: &std::path::Path, body: &str) {
    std::fs::write(path, body).unwrap();
    let mut permissions = std::fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).unwrap();
}

fn find<'a>(
    hooks: &'a [arbor_engine::GitHookInfo],
    name: &str,
) -> &'a arbor_engine::GitHookInfo {
    hooks.iter().find(|hook| hook.name == name).expect(name)
}

#[test]
fn pristine_repository_offers_samples() {
    let repo = TestRepo::new();
    // `git init` 会写入 *.sample 模板（macOS 上来自 templateDir）。
    let hooks = repo.open().git_hooks().unwrap();
    assert!(hooks.len() >= 20, "expected the built-in hook list");

    let pre_commit = find(&hooks, "pre-commit");
    assert!(pre_commit.has_sample);
    assert_eq!(pre_commit.state, GitHookState::Sample);
    assert!(pre_commit.path.ends_with(".git/hooks/pre-commit"));

    // 没有 sample 的条目仍然是 Missing，界面据此隐藏「安装」。
    let location = repo.open().git_hooks_location();
    assert!(location.directory.ends_with(".git/hooks"));
    assert!(location.custom_path.is_none());
}

#[test]
fn install_sample_then_disable_and_enable() {
    let repo = TestRepo::new();
    let path = hook_path(&repo, "pre-commit");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    write_executable(&path.with_extension("sample"), "#!/bin/sh\nexit 0\n");

    let installed = repo.open().install_git_hook_sample("pre-commit".into()).unwrap();
    assert_eq!(installed.state, GitHookState::Enabled);
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o111,
        0o111
    );

    let disabled = repo
        .open()
        .set_git_hook_enabled("pre-commit".into(), false)
        .unwrap();
    assert_eq!(disabled.state, GitHookState::Disabled);
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o111,
        0
    );

    let enabled = repo
        .open()
        .set_git_hook_enabled("pre-commit".into(), true)
        .unwrap();
    assert_eq!(enabled.state, GitHookState::Enabled);
}

#[test]
fn save_read_and_delete_hook_round_trip() {
    let repo = TestRepo::new();
    let body = "#!/bin/sh\necho from arbor\n";
    let saved = repo
        .open()
        .save_git_hook("pre-push".into(), body.into())
        .unwrap();
    assert_eq!(saved.state, GitHookState::Enabled);
    assert!(!saved.is_binary);
    assert_eq!(saved.size_bytes, body.len() as u64);

    let contents = repo.open().git_hook_contents("pre-push".into()).unwrap();
    assert_eq!(contents.content, body);
    assert!(!contents.truncated);

    repo.open().delete_git_hook("pre-push".into()).unwrap();
    assert!(!hook_path(&repo, "pre-push").exists());
    let hooks = repo.open().git_hooks().unwrap();
    assert_ne!(find(&hooks, "pre-push").state, GitHookState::Enabled);
}

#[test]
fn disabled_hook_is_not_executed_on_commit() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "base.txt", "base", "base");
    let path = hook_path(&repo, "pre-commit");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    // 没有可执行位：Git 忽略它，提交必须成功。
    std::fs::write(&path, "#!/bin/sh\necho blocked >&2\nexit 1\n").unwrap();

    repo.write("next.txt", "next");
    let handle = repo.open();
    handle.stage("next.txt".into()).unwrap();
    handle.commit("allowed".into(), false).unwrap();
    assert_eq!(repo.git(&["log", "-1", "--format=%s"]), "allowed");

    // 启用后同一个 hook 会阻塞提交。
    repo.open()
        .set_git_hook_enabled("pre-commit".into(), true)
        .unwrap();
    repo.write("another.txt", "another");
    let handle = repo.open();
    handle.stage("another.txt".into()).unwrap();
    let error = handle.commit("blocked".into(), false).unwrap_err();
    assert!(error.to_string().contains("blocked"));
}

#[test]
fn custom_hooks_path_is_honoured() {
    let repo = TestRepo::new();
    let custom = repo.path.join(".githooks");
    std::fs::create_dir_all(&custom).unwrap();
    repo.git(&["config", "core.hooksPath", ".githooks"]);

    let location = repo.open().git_hooks_location();
    assert_eq!(location.custom_path.as_deref(), Some(".githooks"));
    assert!(location.directory.ends_with(".githooks"));

    let saved = repo
        .open()
        .save_git_hook("post-checkout".into(), "#!/bin/sh\nexit 0\n".into())
        .unwrap();
    assert!(saved.path.ends_with(".githooks/post-checkout"));
    assert!(custom.join("post-checkout").exists());
    // 默认目录不受影响。
    assert!(!repo.path.join(".git/hooks/post-checkout").exists());
}

#[test]
fn invalid_hook_names_are_rejected() {
    let repo = TestRepo::new();
    for name in ["", "../escape", "nested/pre-commit", "pre-commit.sample"] {
        assert!(
            repo.open().save_git_hook(name.into(), "x".into()).is_err(),
            "name {name:?} should be rejected"
        );
    }
    assert!(
        repo.open().git_hook_contents("../etc/passwd".into()).is_err(),
        "reading outside the hooks directory must fail"
    );
}

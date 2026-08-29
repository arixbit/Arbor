//! Phase 5：长尾能力——submodule 操作、tag rename、ignore 编辑、缓存失效。

mod common;

use arbor_engine::{
    CredentialBroker, GitCancelHandle, SubmoduleAddUndoTarget, SubmoduleRemoveUndoTarget,
    SubmoduleState, TreeChangeKind,
};
use common::TestRepo;

/// 建含一个子模块的外层仓库,返回 (外层 TestRepo, 子模块路径)。
fn repo_with_submodule(outer: &TestRepo) -> std::path::PathBuf {
    let source = tempfile::tempdir().expect("tempdir");
    common::git(source.path(), &["init", "-q"]);
    common::git(source.path(), &["config", "user.name", "Arbor Test"]);
    common::git(source.path(), &["config", "user.email", "test@arbor.local"]);
    common::commit(source.path(), "lib.txt", "l1\n", "init");
    common::commit(&outer.path, "main.txt", "m\n", "init");
    common::git(
        &outer.path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &source.path().display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(&outer.path, &["commit", "-q", "-m", "add submodule"]);
    common::git(&outer.path, &["config", "protocol.file.allow", "always"]);
    outer.path.join("vendor").join("lib")
}

#[test]
fn submodule_deinit_and_update_roundtrip() {
    let outer = TestRepo::new();
    let sub_path = repo_with_submodule(&outer);
    let repo = outer.open();

    // deinit:清空工作区内容,配置保留
    repo.submodule_deinit_with_auth_and_cancel(
        "vendor/lib".into(),
        true,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("deinit");
    let lib = sub_path.join("lib.txt");
    assert!(!lib.exists(), "deinit 清空子模块工作区");
    let deinitialized = repo.submodule_list().expect("list after deinit");
    assert_eq!(deinitialized.len(), 1);
    assert_eq!(deinitialized[0].state, SubmoduleState::Uninitialized);

    // update --init:恢复内容
    repo.submodule_update_with_options_with_auth_and_cancel(
        true,
        false,
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("update");
    assert!(lib.exists(), "update --init 恢复内容");
    assert_eq!(std::fs::read_to_string(&lib).unwrap(), "l1\n");
}

#[test]
fn submodule_remove_undo_restores_clean_expected_state() {
    let outer = TestRepo::new();
    let sub_path = repo_with_submodule(&outer);
    let repo = outer.open();
    let parent_head = repo.head_commit_id().expect("parent HEAD");
    let before_gitmodules = std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap();
    let module = repo
        .submodule_list()
        .unwrap()
        .into_iter()
        .find(|module| module.path == "vendor/lib")
        .expect("module");
    assert_eq!(module.state, SubmoduleState::Clean);
    assert!(!module.dirty);

    repo.submodule_remove("vendor/lib".into()).expect("remove");
    let expected_gitmodules = outer.path.join(".gitmodules");
    let expected_gitmodules_contents = std::fs::read_to_string(&expected_gitmodules).unwrap();
    assert!(!sub_path.exists());
    assert!(
        repo.run_git_command(
            "ls-files".into(),
            vec!["--error-unmatch".into(), "--".into(), "vendor/lib".into()]
        )
        .unwrap()
        .exit_code
            != 0
    );

    repo.submodule_remove_undo_with_auth_and_cancel(
        SubmoduleRemoveUndoTarget {
            path: "vendor/lib".into(),
            expected_parent_head_id: parent_head,
            restore_gitlink_id: module.head_id,
            expected_gitmodules_present: true,
            expected_gitmodules_contents: Some(expected_gitmodules_contents),
            restore_gitmodules_present: true,
            restore_gitmodules_contents: Some(before_gitmodules.clone()),
        },
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("undo remove");

    assert!(sub_path.join("lib.txt").exists());
    assert_eq!(
        std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap(),
        before_gitmodules
    );
    assert_eq!(
        repo.submodule_list().unwrap()[0].state,
        SubmoduleState::Clean
    );
    assert_eq!(outer.git(&["diff", "--cached", "--name-only"]), "");
}

#[test]
fn submodule_remove_undo_refuses_new_worktree_files() {
    let outer = TestRepo::new();
    let sub_path = repo_with_submodule(&outer);
    let repo = outer.open();
    let parent_head = repo.head_commit_id().expect("parent HEAD");
    let before_gitmodules = std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap();
    let module = repo.submodule_list().unwrap().remove(0);
    repo.submodule_remove("vendor/lib".into()).expect("remove");
    let expected_gitmodules_contents =
        std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap();
    std::fs::create_dir_all(&sub_path).unwrap();
    std::fs::write(sub_path.join("created-after-remove.txt"), "keep me").unwrap();

    let error = repo
        .submodule_remove_undo_with_auth_and_cancel(
            SubmoduleRemoveUndoTarget {
                path: "vendor/lib".into(),
                expected_parent_head_id: parent_head,
                restore_gitlink_id: module.head_id,
                expected_gitmodules_present: true,
                expected_gitmodules_contents: Some(expected_gitmodules_contents.clone()),
                restore_gitmodules_present: true,
                restore_gitmodules_contents: Some(before_gitmodules),
            },
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .unwrap_err();
    assert!(error.to_string().contains("new files"));
    assert_eq!(
        std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap(),
        expected_gitmodules_contents
    );
    assert!(sub_path.join("created-after-remove.txt").exists());
}

#[test]
fn submodule_worktree_status_counts_ignored_files_as_unsafe() {
    let outer = TestRepo::new();
    let sub_path = repo_with_submodule(&outer);
    let repo = outer.open();

    assert!(!repo
        .submodule_worktree_has_untracked_or_ignored_files("vendor/lib".into())
        .expect("clean nested worktree"));

    common::git(&sub_path, &["config", "user.name", "Arbor Test"]);
    common::git(&sub_path, &["config", "user.email", "test@arbor.local"]);
    std::fs::write(sub_path.join(".gitignore"), "ignored.txt\n").unwrap();
    common::git(&sub_path, &["add", ".gitignore"]);
    common::git(&sub_path, &["commit", "-q", "-m", "ignore generated file"]);
    std::fs::write(sub_path.join("ignored.txt"), "must survive").unwrap();

    assert!(repo
        .submodule_worktree_has_untracked_or_ignored_files("vendor/lib".into())
        .expect("inspect ignored nested worktree"));
}

#[test]
fn submodule_log_reads_nested_repository_history() {
    let outer = TestRepo::new();
    repo_with_submodule(&outer);
    let repo = outer.open();

    let commits = repo
        .submodule_log("vendor/lib".into(), 10)
        .expect("nested submodule log");
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].summary, "init");
    assert_eq!(commits[0].parent_ids, Vec::<String>::new());
}

#[test]
fn submodule_log_rejects_uninitialized_worktree() {
    let outer = TestRepo::new();
    repo_with_submodule(&outer);
    let repo = outer.open();
    let parent = outer.git(&["rev-parse", "HEAD"]);
    repo.submodule_deinit("vendor/lib".into(), true)
        .expect("deinit");

    let error = repo.submodule_log("vendor/lib".into(), 10).unwrap_err();
    assert!(error.to_string().contains("not initialized"));

    let change = repo
        .submodule_change(parent.clone(), parent.clone(), "vendor/lib".into(), 10)
        .expect("gitlink state without initialized worktree");
    assert!(change.old_commit.is_some());
    assert_eq!(change.old_commit, change.new_commit);
    assert!(change.current_commit.is_none());
    assert!(!change.initialized);
    assert!(!change.dirty);
    assert!(change.commits.is_empty());

    let non_gitlink = repo
        .submodule_change(parent.clone(), parent, "main.txt".into(), 10)
        .unwrap_err();
    assert!(non_gitlink.to_string().contains("not a gitlink"));
}

#[test]
fn submodule_change_exposes_gitlink_range_and_nested_worktree_state() {
    let outer = TestRepo::new();
    let sub_path = repo_with_submodule(&outer);
    let old_parent = outer.git(&["rev-parse", "HEAD"]);
    let old_submodule = common::git(&sub_path, &["rev-parse", "HEAD"]);
    common::git(&sub_path, &["config", "user.name", "Arbor Test"]);
    common::git(&sub_path, &["config", "user.email", "test@arbor.local"]);
    common::commit(&sub_path, "lib.txt", "l2\n", "advance submodule");
    let new_submodule = common::commit(&sub_path, "new.txt", "new\n", "add nested file");
    outer.git(&["add", "vendor/lib"]);
    outer.git(&["commit", "-q", "-m", "advance gitlink"]);
    let new_parent = outer.git(&["rev-parse", "HEAD"]);

    let change = outer
        .open()
        .submodule_change(old_parent, new_parent, "vendor/lib".into(), 10)
        .expect("submodule change");
    assert_eq!(change.path, "vendor/lib");
    assert_eq!(change.old_commit.as_deref(), Some(old_submodule.as_str()));
    assert_eq!(change.new_commit.as_deref(), Some(new_submodule.as_str()));
    assert_eq!(
        change.current_commit.as_deref(),
        Some(new_submodule.as_str())
    );
    assert!(change.initialized);
    assert!(!change.dirty);
    assert_eq!(change.commits.len(), 2);
    assert_eq!(change.commits[0].id, new_submodule);
    assert_eq!(change.nested_changes.len(), 2);
    assert!(change
        .nested_changes
        .iter()
        .any(|item| item.path == "lib.txt" && item.kind == TreeChangeKind::Modified));
    assert!(change
        .nested_changes
        .iter()
        .any(|item| item.path == "new.txt" && item.kind == TreeChangeKind::Added));

    std::fs::write(sub_path.join("local.txt"), "uncommitted\n").unwrap();
    let dirty = outer
        .open()
        .submodule_change(
            outer.git(&["rev-parse", "HEAD~1"]),
            outer.git(&["rev-parse", "HEAD"]),
            "vendor/lib".into(),
            10,
        )
        .expect("dirty submodule change");
    assert!(dirty.dirty);
}

#[test]
fn submodule_add_list_sync_and_remove_roundtrip() {
    let source = TestRepo::new();
    common::commit(&source.path, "lib.txt", "source\n", "source");
    let outer = TestRepo::new();
    outer.git(&["config", "protocol.file.allow", "always"]);
    let repo = outer.open();

    repo.submodule_add_with_auth_and_cancel(
        source.path.to_string_lossy().into_owned(),
        "vendor/lib".into(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("add");

    let modules = repo.submodule_list().expect("list");
    assert_eq!(modules.len(), 1);
    assert_eq!(modules[0].path, "vendor/lib");
    assert_eq!(modules[0].head_id, source.git(&["rev-parse", "HEAD"]));
    assert_eq!(modules[0].state, SubmoduleState::Clean);
    assert!(!modules[0].dirty);

    let alternate_url = format!(
        "{}/{}",
        source.path.parent().unwrap().display(),
        source.path.file_name().unwrap().to_string_lossy()
    );
    outer.git(&[
        "config",
        "-f",
        ".gitmodules",
        "submodule.vendor/lib.url",
        &alternate_url,
    ]);
    repo.submodule_sync_with_auth_and_cancel(CredentialBroker::new(), GitCancelHandle::new())
        .expect("sync");
    assert_eq!(
        outer.git(&["config", "--get", "submodule.vendor/lib.url"]),
        alternate_url
    );

    repo.submodule_remove_with_auth_and_cancel(
        "vendor/lib".into(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("remove");
    assert!(
        !outer.exists("vendor/lib"),
        "remove cleans the checked out submodule"
    );
    assert!(!std::fs::read_to_string(outer.path.join(".gitmodules"))
        .unwrap_or_default()
        .contains("vendor/lib"));
    assert!(repo.submodule_list().expect("list after remove").is_empty());
}

#[test]
fn submodule_add_undo_restores_clean_pre_add_state() {
    let source = TestRepo::new();
    common::commit(&source.path, "lib.txt", "source\n", "source");
    let outer = TestRepo::new();
    common::commit(&outer.path, "main.txt", "main\n", "main");
    let repo = outer.open();
    let parent_head = repo.head_commit_id().expect("parent HEAD");

    repo.submodule_add_with_auth_and_cancel(
        source.path.to_string_lossy().into_owned(),
        "vendor/lib".into(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("add");
    let module = repo
        .submodule_list()
        .unwrap()
        .into_iter()
        .find(|module| module.path == "vendor/lib")
        .expect("added module");
    let expected_gitmodules = std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap();

    repo.submodule_add_undo_with_auth_and_cancel(
        SubmoduleAddUndoTarget {
            path: "vendor/lib".into(),
            expected_parent_head_id: parent_head,
            expected_submodule_head_id: module.head_id,
            expected_gitmodules_present: true,
            expected_gitmodules_contents: Some(expected_gitmodules),
            restore_gitmodules_present: false,
            restore_gitmodules_contents: None,
        },
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("undo add");

    assert!(!outer.path.join("vendor/lib").exists());
    assert!(!outer.path.join(".gitmodules").exists());
    assert!(repo.submodule_list().unwrap().is_empty());
    assert_eq!(outer.git(&["diff", "--cached", "--name-only"]), "");
}

#[test]
fn submodule_add_undo_refuses_new_nested_files() {
    let source = TestRepo::new();
    common::commit(&source.path, "lib.txt", "source\n", "source");
    let outer = TestRepo::new();
    common::commit(&outer.path, "main.txt", "main\n", "main");
    let repo = outer.open();
    let parent_head = repo.head_commit_id().expect("parent HEAD");

    repo.submodule_add_with_auth_and_cancel(
        source.path.to_string_lossy().into_owned(),
        "vendor/lib".into(),
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("add");
    let module = repo.submodule_list().unwrap().remove(0);
    let expected_gitmodules = std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap();
    std::fs::write(
        outer.path.join("vendor/lib/created-after-add.txt"),
        "keep me",
    )
    .unwrap();

    let error = repo
        .submodule_add_undo_with_auth_and_cancel(
            SubmoduleAddUndoTarget {
                path: "vendor/lib".into(),
                expected_parent_head_id: parent_head,
                expected_submodule_head_id: module.head_id,
                expected_gitmodules_present: true,
                expected_gitmodules_contents: Some(expected_gitmodules),
                restore_gitmodules_present: false,
                restore_gitmodules_contents: None,
            },
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .unwrap_err();
    assert!(error.to_string().contains("nested worktree has changes"));
    assert!(outer.path.join("vendor/lib/created-after-add.txt").exists());
    assert!(outer.path.join(".gitmodules").exists());
}

#[cfg(unix)]
#[test]
fn submodule_add_with_auth_cancellation_stops_nested_clone() {
    use std::os::unix::fs::PermissionsExt;
    use std::thread;
    use std::time::Duration;

    let outer = TestRepo::new();
    let script = outer.path.join("slow-ssh.sh");
    std::fs::write(&script, "#!/bin/sh\nsleep 30\n").expect("slow ssh script");
    let mut permissions = std::fs::metadata(&script)
        .expect("script metadata")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&script, permissions).expect("script permissions");
    let ssh_command = format!("sh {}", script.display());
    outer.git(&["config", "core.sshCommand", &ssh_command]);

    let repo = outer.open();
    let broker = CredentialBroker::new();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = thread::spawn(move || {
        worker_repo.submodule_add_with_auth_and_cancel(
            "ssh://example.invalid/repository.git".into(),
            "vendor/slow".into(),
            broker,
            worker_cancel,
        )
    });
    thread::sleep(Duration::from_millis(300));
    cancel.cancel();

    let result = worker.join().expect("submodule worker");
    assert!(matches!(result, Err(arbor_engine::EngineError::Cancelled)));
}

#[test]
fn submodule_set_branch_writes_gitmodules() {
    let outer = TestRepo::new();
    repo_with_submodule(&outer);
    let repo = outer.open();
    repo.submodule_set_branch("vendor/lib".into(), "develop".into())
        .expect("set branch");
    let gitmodules = std::fs::read_to_string(outer.path.join(".gitmodules")).unwrap();
    assert!(gitmodules.contains("branch = develop"), "{gitmodules}");
}

#[test]
fn tag_rename_points_to_same_commit() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&["tag", "v1.0"]);
    let target = r.git(&["rev-parse", "v1.0"]);

    let repo = r.open();
    repo.tag_rename("v1.0".into(), "v2.0".into())
        .expect("rename");
    assert_eq!(r.git(&["rev-parse", "v2.0"]), target, "新 tag 指向同一提交");
    // 旧 tag 删除
    assert!(r.git(&["tag", "-l", "v1.0"]).is_empty());
    // 重复名拒绝
    let err = repo
        .tag_rename("v2.0".into(), "v2.0".into())
        .unwrap_err()
        .to_string();
    assert!(
        err.contains("already exists") || err.contains("tag"),
        "{err}"
    );
}

#[test]
fn quick_ignore_and_exclude_show_in_ignored_rules() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write("cache.tmp", "c\n");
    let repo = r.open();

    // 快捷忽略(右键路径 -> .gitignore)
    repo.add_to_gitignore("cache.tmp".into()).expect("ignore");
    // exclude(.git/info/exclude)
    repo.exclude_path("secrets.tmp".into()).expect("exclude");
    r.write("secrets.tmp", "s\n");

    let rules = repo.ignored_rules().expect("rules");
    assert!(
        rules.iter().any(|info| info.path == "cache.tmp"),
        "{rules:?}"
    );
    assert!(
        rules.iter().any(|info| info.path == "secrets.tmp"),
        "{rules:?}"
    );
    // 两个来源不同
    let gitignore_rule = rules
        .iter()
        .find(|info| info.path == "cache.tmp")
        .expect("gi");
    let exclude_rule = rules
        .iter()
        .find(|info| info.path == "secrets.tmp")
        .expect("ex");
    assert_ne!(gitignore_rule.source, exclude_rule.source);
}

#[test]
fn log_cache_invalidation_on_new_commit() {
    // 进程内 log 缓存(引擎层不做持久化;验证数据源一致):
    // 提交前后 log 长度变化(UI 的 generation 取消由 Swift 层负责)
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let repo = r.open();
    assert_eq!(repo.log(None, 10, false, None).expect("log").len(), 1);
    common::commit(&r.path, "g.txt", "2\n", "second");
    assert_eq!(repo.log(None, 10, false, None).expect("log2").len(), 2);
}

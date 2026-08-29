//! REMOTE-001：远程配置与高级传输。
//! 真实 fixture：本地 bare 仓库 + 工作仓库，验证 remote 配置 CRUD、
//! force-with-lease 拒绝/成功、fetch prune、rejected push 的错误分类。

mod common;

use arbor_engine::{
    CredentialBroker, FetchTagsMode, GitCancelHandle, LocalChangesSavePolicy, PushFailureKind,
    PushTagMode, SshAgentState, SshAuthMethod, SshHostKeyPolicy,
};
use common::TestRepo;

/// 给 clone 出来的仓库配置身份（clone 不继承本地的 user.name/email）。
fn configure_identity(dir: &std::path::Path) {
    common::git(dir, &["config", "user.name", "Arbor Test"]);
    common::git(dir, &["config", "user.email", "test@arbor.local"]);
}

/// 建一个带初始提交的 bare 远程仓库,返回其路径。
fn bare_remote(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    let path = dir.join(name);
    common::git(dir, &["init", "-q", "--bare", name]);
    path
}

/// 工作仓库 + origin 指向 bare 远程(带一个初始提交)。
fn repo_with_origin(r: &TestRepo, remote_path: &std::path::Path) {
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&[
        "remote",
        "add",
        "origin",
        &remote_path.display().to_string(),
    ]);
    r.git(&["push", "-q", "-u", "origin", "main"]);
}

#[test]
fn remote_info_includes_push_url_and_refspecs() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.git(&["remote", "add", "origin", "https://example.com/repo.git"]);
    r.git(&[
        "config",
        "remote.origin.pushurl",
        "https://example.com/push.git",
    ]);
    r.git(&["config", "remote.origin.push", "HEAD:refs/heads/main"]);

    let repo = r.open();
    let remotes = repo.remote_list().expect("list");
    let origin = remotes.iter().find(|r| r.name == "origin").expect("origin");
    assert_eq!(origin.url, "https://example.com/repo.git");
    assert_eq!(
        origin.push_url.as_deref(),
        Some("https://example.com/push.git")
    );
    assert_eq!(
        origin.fetch_refspec.as_deref(),
        Some("+refs/heads/*:refs/remotes/origin/*")
    );
    assert_eq!(origin.push_refspec.as_deref(), Some("HEAD:refs/heads/main"));
}

#[test]
fn ssh_command_is_stored_in_local_config_and_can_be_cleared() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    let repo = r.open();

    repo.set_ssh_command("ssh -i ~/.ssh/arbor_test".into())
        .expect("set ssh command");
    assert_eq!(
        repo.config_value("core.sshCommand".into())
            .expect("read ssh command")
            .as_deref(),
        Some("ssh -i ~/.ssh/arbor_test")
    );

    repo.set_ssh_command("  ".into())
        .expect("clear ssh command");
    assert_eq!(
        repo.config_value("core.sshCommand".into())
            .expect("read cleared ssh command"),
        None
    );
    assert!(repo.set_ssh_command("ssh\n-i key".into()).is_err());
}

#[test]
fn structured_ssh_settings_compile_into_transport_command() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    let repo = r.open();

    repo.set_ssh_connection_settings(
        "ssh -F ~/.ssh/config".into(),
        "~/.ssh/known_hosts.arbor".into(),
        "~/.ssh/id_ed25519".into(),
        SshHostKeyPolicy::AcceptNew,
        SshAuthMethod::PublicKey,
    )
    .expect("set structured SSH settings");

    let settings = repo.ssh_connection_settings().expect("read SSH settings");
    assert_eq!(settings.command, "ssh -F ~/.ssh/config");
    assert_eq!(settings.known_hosts_file, "~/.ssh/known_hosts.arbor");
    assert_eq!(settings.identity_file, "~/.ssh/id_ed25519");
    assert_eq!(settings.host_key_policy, SshHostKeyPolicy::AcceptNew);
    assert_eq!(settings.auth_method, SshAuthMethod::PublicKey);

    let command = repo
        .config_value("core.sshCommand".into())
        .expect("read compiled SSH command")
        .expect("compiled SSH command");
    assert!(command.starts_with("ssh -F ~/.ssh/config"));
    assert!(command.contains("StrictHostKeyChecking=accept-new"));
    assert!(command.contains("UserKnownHostsFile="));
    assert!(command.contains("IdentitiesOnly=yes"));
    assert!(command.contains("PreferredAuthentications=publickey"));

    repo.set_ssh_connection_settings(
        "ssh -F ~/.ssh/config".into(),
        "~/.ssh/known_hosts.arbor".into(),
        "~/.ssh/id_ed25519".into(),
        SshHostKeyPolicy::AcceptNew,
        SshAuthMethod::PublicKey,
    )
    .expect("save structured SSH settings twice");
    let repeated = repo
        .config_value("core.sshCommand".into())
        .expect("read repeated SSH command")
        .expect("repeated SSH command");
    assert_eq!(repeated.matches("StrictHostKeyChecking=").count(), 1);
    assert_eq!(repeated.matches("IdentitiesOnly=yes").count(), 1);
    assert_eq!(repeated.matches("PreferredAuthentications=").count(), 1);

    repo.set_ssh_connection_settings(
        "ssh -F ~/.ssh/config".into(),
        "~/.ssh/known_hosts.arbor".into(),
        "~/.ssh/id_ed25519".into(),
        SshHostKeyPolicy::Ask,
        SshAuthMethod::Auto,
    )
    .expect("save ask-before-trusting SSH settings");
    let ask_command = repo
        .config_value("core.sshCommand".into())
        .expect("read ask SSH command")
        .expect("ask SSH command");
    assert!(ask_command.contains("StrictHostKeyChecking=ask"));
    assert!(!ask_command.contains("PreferredAuthentications="));
    assert_eq!(
        repo.ssh_connection_settings()
            .expect("read ask SSH settings")
            .host_key_policy,
        SshHostKeyPolicy::Ask
    );

    repo.set_ssh_connection_settings(
        String::new(),
        String::new(),
        String::new(),
        SshHostKeyPolicy::Strict,
        SshAuthMethod::Auto,
    )
    .expect("clear structured SSH settings");
    assert!(repo
        .config_value("core.sshCommand".into())
        .expect("read cleared SSH command")
        .is_none());
    assert!(repo
        .set_ssh_connection_settings(
            "ssh\n-o StrictHostKeyChecking=no".into(),
            String::new(),
            String::new(),
            SshHostKeyPolicy::Strict,
            SshAuthMethod::Auto,
        )
        .is_err());
}

#[test]
fn credential_helpers_report_local_helpers_without_shell_entries() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.git(&["config", "credential.helper", "store"]);
    r.git(&["config", "--add", "credential.helper", "!custom-helper"]);

    let helpers = r.open().credential_helpers().expect("credential helpers");
    assert!(helpers.iter().any(|helper| helper.name == "store"));
    assert!(!helpers.iter().any(|helper| helper.name == "!custom-helper"));
}

#[test]
fn ssh_agent_diagnostics_never_returns_identity_material() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");

    let diagnostics = r
        .open()
        .ssh_agent_diagnostics()
        .expect("SSH agent diagnostics");
    assert!(matches!(
        diagnostics.state,
        SshAgentState::NotConfigured
            | SshAgentState::Unreachable
            | SshAgentState::NoIdentities
            | SshAgentState::Ready
            | SshAgentState::Error
    ));
    assert!(diagnostics.identity_count < 10_000);
    assert!(!diagnostics.detail_code.contains("ssh-rsa"));
    assert!(!diagnostics.detail_code.contains("SHA256:"));
}

#[test]
fn credential_helper_local_config_can_be_replaced_and_cleared() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    let repo = r.open();

    assert!(repo
        .credential_helper_config()
        .expect("read empty local helper config")
        .is_empty());

    repo.set_credential_helper_config(vec![
        "osxkeychain".into(),
        "store --file ~/.git-credentials".into(),
    ])
    .expect("set local credential helpers");
    assert_eq!(
        repo.credential_helper_config()
            .expect("read local helper config"),
        vec![
            "osxkeychain".to_string(),
            "store --file ~/.git-credentials".to_string()
        ]
    );

    repo.set_credential_helper_config(vec!["manager-core".into()])
        .expect("replace local credential helpers");
    assert_eq!(
        repo.credential_helper_config()
            .expect("read replaced local helper config"),
        vec!["manager-core".to_string()]
    );

    repo.set_credential_helper_config(Vec::new())
        .expect("clear local credential helpers");
    assert!(repo
        .credential_helper_config()
        .expect("read cleared local helper config")
        .is_empty());

    assert!(repo
        .set_credential_helper_config(vec!["helper\n-injected".into()])
        .is_err());
}

#[test]
fn remote_crud_set_url_push_url_refspecs_rename() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.git(&["remote", "add", "origin", "https://example.com/a.git"]);
    let repo = r.open();

    // set-url
    repo.remote_set_url("origin".into(), "https://example.com/b.git".into())
        .expect("set url");
    let remotes = repo.remote_list().expect("list");
    assert_eq!(remotes[0].url, "https://example.com/b.git");

    // set push-url
    repo.remote_set_push_url("origin".into(), "https://example.com/push.git".into())
        .expect("push url");
    let remotes = repo.remote_list().expect("list");
    assert_eq!(
        remotes[0].push_url.as_deref(),
        Some("https://example.com/push.git")
    );

    // 清空 push-url
    repo.remote_set_push_url("origin".into(), String::new())
        .expect("clear push url");
    let remotes = repo.remote_list().expect("list");
    assert_eq!(remotes[0].push_url, None);

    // refspec 编辑
    repo.remote_set_refspecs(
        "origin".into(),
        Some("+refs/heads/*:refs/remotes/origin/*".into()),
        Some("HEAD:refs/heads/main".into()),
    )
    .expect("refspecs");
    let remotes = repo.remote_list().expect("list");
    assert_eq!(
        remotes[0].push_refspec.as_deref(),
        Some("HEAD:refs/heads/main")
    );

    // rename(config + refs/remotes 一并处理)
    repo.remote_rename("origin".into(), "upstream".into())
        .expect("rename");
    let remotes = repo.remote_list().expect("list");
    assert_eq!(remotes[0].name, "upstream");
    assert_eq!(remotes[0].url, "https://example.com/b.git");

    // 非法名拒绝
    assert!(repo.remote_set_url("bad name".into(), "x".into()).is_err());
    assert!(repo.remote_set_url("-evil".into(), "x".into()).is_err());
}

#[test]
fn remote_add_and_remove_use_git_crud_and_clean_tracking_refs() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    let repo = r.open();

    repo.remote_add("origin".into(), "https://example.com/repo.git".into())
        .expect("add remote");
    let remotes = repo.remote_list().expect("list added remote");
    let origin = remotes
        .iter()
        .find(|remote| remote.name == "origin")
        .expect("origin");
    assert_eq!(origin.url, "https://example.com/repo.git");
    assert_eq!(
        origin.fetch_refspec.as_deref(),
        Some("+refs/heads/*:refs/remotes/origin/*")
    );

    let head = r.git(&["rev-parse", "HEAD"]);
    r.git(&["update-ref", "refs/remotes/origin/main", &head]);
    assert_eq!(
        r.git(&["for-each-ref", "--format=%(refname)", "refs/remotes/origin"]),
        "refs/remotes/origin/main"
    );

    repo.remote_remove("origin".into()).expect("remove remote");
    assert!(repo.remote_list().expect("list after removal").is_empty());
    assert!(
        r.git(&["for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
            .is_empty(),
        "remote-tracking refs must be removed with the remote"
    );
    assert!(repo
        .remote_add("bad name".into(), "https://example.com/repo.git".into())
        .is_err());
    assert!(repo.remote_add("origin".into(), "  ".into()).is_err());
}

#[test]
fn force_with_lease_rejects_remote_updates() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");

    // 本地仓库 A 推送 init
    let a = TestRepo::new();
    repo_with_origin(&a, &remote_path);

    // 第二个工作仓库 B clone 远程并推送新提交(远程前进)
    let b_path = dir.path().join("b");
    common::git(
        dir.path(),
        &["clone", "-q", &remote_path.display().to_string(), "b"],
    );
    configure_identity(&b_path);
    common::commit(&b_path, "g.txt", "g\n", "remote update");
    common::git(&b_path, &["push", "-q", "origin", "main"]);

    // A 本地前进(不 fetch),force-with-lease 必须拒绝
    common::commit(&a.path, "h.txt", "h\n", "local update");
    let repo = a.open();
    let err = repo
        .push_force_with_lease(Some("origin".into()), "main".into())
        .unwrap_err();
    match &err {
        arbor_engine::EngineError::PushRejected { kind, branch, .. } => {
            assert_eq!(*kind, PushFailureKind::StaleInfo, "lease 必须拒绝: {err}");
            assert_eq!(branch, "main");
        }
        other => panic!("expected PushRejected, got {other}"),
    }
    // 远程未被覆盖:远程 HEAD 仍是 B 的提交
    let remote_head = common::git(&remote_path, &["rev-parse", "main"]);
    let b_head = common::git(&b_path, &["rev-parse", "HEAD"]);
    assert_eq!(remote_head, b_head);

    // fetch 后 lease 通过(本地有了远程引用)
    repo.fetch(Some("origin".into())).expect("fetch");
    repo.push_force_with_lease(Some("origin".into()), "main".into())
        .expect("lease after fetch");
    let remote_head = common::git(&remote_path, &["rev-parse", "main"]);
    let a_head = common::git(&a.path, &["rev-parse", "HEAD"]);
    assert_eq!(remote_head, a_head);
}

#[test]
fn plain_force_overwrites_remote() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let a = TestRepo::new();
    repo_with_origin(&a, &remote_path);

    let b_path = dir.path().join("b");
    common::git(
        dir.path(),
        &["clone", "-q", &remote_path.display().to_string(), "b"],
    );
    configure_identity(&b_path);
    common::commit(&b_path, "g.txt", "g\n", "remote update");
    common::git(&b_path, &["push", "-q", "origin", "main"]);

    // 普通 --force 覆盖(无 lease 保护)
    common::commit(&a.path, "h.txt", "h\n", "local update");
    let repo = a.open();
    repo.push_with_options(Some("origin".into()), "main".into(), true, false)
        .expect("plain force");
    let remote_head = common::git(&remote_path, &["rev-parse", "main"]);
    let a_head = common::git(&a.path, &["rev-parse", "HEAD"]);
    assert_eq!(remote_head, a_head);
}

#[test]
fn push_options_include_all_tags_and_follow_tags_only_annotated() {
    let dir = tempfile::tempdir().expect("remote tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let local = TestRepo::new();
    repo_with_origin(&local, &remote_path);
    common::commit(&local.path, "tagged.txt", "tagged\n", "tagged commit");
    local.git(&["tag", "-a", "v-annotated", "-m", "annotated"]);
    local.git(&["tag", "v-lightweight"]);

    let repo = local.open();
    repo.push_with_options_and_auth_and_cancel(
        Some("origin".into()),
        "main".into(),
        false,
        false,
        false,
        Some(PushTagMode::Follow),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("follow tags push");
    assert!(common::git(
        &remote_path,
        &[
            "for-each-ref",
            "--format=%(refname)",
            "refs/tags/v-lightweight"
        ]
    )
    .is_empty());
    assert_eq!(
        common::git(
            &remote_path,
            &[
                "for-each-ref",
                "--format=%(refname)",
                "refs/tags/v-annotated"
            ]
        ),
        "refs/tags/v-annotated"
    );

    common::commit(&local.path, "all-tags.txt", "all\n", "all tags commit");
    local.git(&["tag", "v-second-lightweight"]);
    repo.push_with_options_and_auth_and_cancel(
        Some("origin".into()),
        "main".into(),
        false,
        false,
        false,
        Some(PushTagMode::All),
        false,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("all tags push");
    assert_eq!(
        common::git(
            &remote_path,
            &[
                "for-each-ref",
                "--format=%(refname)",
                "refs/tags/v-lightweight"
            ]
        ),
        "refs/tags/v-lightweight"
    );
    assert_eq!(
        common::git(
            &remote_path,
            &[
                "for-each-ref",
                "--format=%(refname)",
                "refs/tags/v-second-lightweight",
            ]
        ),
        "refs/tags/v-second-lightweight"
    );
}

#[cfg(unix)]
#[test]
fn push_options_can_skip_pre_push_hook() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().expect("remote tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let local = TestRepo::new();
    repo_with_origin(&local, &remote_path);
    common::commit(&local.path, "hook.txt", "hook\n", "hook commit");
    let hook = local.path.join(".git/hooks/pre-push");
    std::fs::write(&hook, "#!/bin/sh\nexit 1\n").expect("write pre-push hook");
    let mut permissions = std::fs::metadata(&hook)
        .expect("hook metadata")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&hook, permissions).expect("make hook executable");

    let repo = local.open();
    let rejected = repo
        .push_with_options_and_auth_and_cancel(
            Some("origin".into()),
            "main".into(),
            false,
            false,
            false,
            None,
            false,
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .expect_err("pre-push hook must reject normal push");
    assert!(matches!(
        rejected,
        arbor_engine::EngineError::PushRejected { .. }
    ));

    repo.push_with_options_and_auth_and_cancel(
        Some("origin".into()),
        "main".into(),
        false,
        false,
        false,
        None,
        true,
        CredentialBroker::new(),
        GitCancelHandle::new(),
    )
    .expect("--no-verify push");
    assert_eq!(
        common::git(&remote_path, &["rev-parse", "main"]),
        common::git(&local.path, &["rev-parse", "HEAD"])
    );
}

#[test]
fn force_pushed_branch_update_replays_local_commits_and_restores_dirty_files() {
    let dir = tempfile::tempdir().expect("remote tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let local = TestRepo::new();
    repo_with_origin(&local, &remote_path);
    common::commit(&local.path, "local.txt", "local\n", "local commit");

    let remote_work = dir.path().join("remote-work");
    common::git(
        dir.path(),
        &[
            "clone",
            "-q",
            &remote_path.display().to_string(),
            "remote-work",
        ],
    );
    configure_identity(&remote_work);
    common::commit(&remote_work, "remote.txt", "remote\n", "remote replacement");
    common::git(&remote_work, &["push", "-q", "origin", "main"]);

    local.write("dirty.txt", "keep me\n");
    let outcome = local
        .open()
        .force_pushed_branch_update_with_auth_and_cancel(
            LocalChangesSavePolicy::Stash,
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .expect("force-pushed branch update");

    assert_eq!(outcome.replayed_commits, 1);
    assert!(!outcome.used_merge_update);
    assert_eq!(outcome.received_commits_count, 1);
    assert_eq!(outcome.updated_files_count, 1);
    assert!(outcome.update_range_start.is_some());
    assert!(!outcome.new_upstream_tip.is_empty());
    assert_eq!(local.read("remote.txt"), "remote\n");
    assert_eq!(local.read("local.txt"), "local\n");
    assert_eq!(local.read("dirty.txt"), "keep me\n");
    assert!(local.git(&["stash", "list"]).is_empty());
    assert!(!local.path.join(".git/arbor-apply-local-changes").exists());
    assert!(local
        .git(&["branch", "--list", "arbor-force-pushed-backup-*"])
        .is_empty());
}

#[test]
fn force_pushed_branch_update_keeps_named_backup_after_replay_conflict() {
    let dir = tempfile::tempdir().expect("remote tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let local = TestRepo::new();
    repo_with_origin(&local, &remote_path);
    common::commit(
        &local.path,
        "same.txt",
        "local\n",
        "local conflicting commit",
    );

    let remote_work = dir.path().join("remote-work");
    common::git(
        dir.path(),
        &[
            "clone",
            "-q",
            &remote_path.display().to_string(),
            "remote-work",
        ],
    );
    configure_identity(&remote_work);
    common::commit(&remote_work, "same.txt", "remote\n", "remote replacement");
    common::git(&remote_work, &["push", "-q", "origin", "main"]);

    let error = local
        .open()
        .force_pushed_branch_update_with_auth_and_cancel(
            LocalChangesSavePolicy::Stash,
            CredentialBroker::new(),
            GitCancelHandle::new(),
        )
        .expect_err("conflicting replay should pause");

    let message = error.to_string();
    assert!(message.contains("force-pushed update incomplete"));
    assert!(message.contains("backup branch 'arbor-force-pushed-backup-"));
    let backups = local.git(&[
        "branch",
        "--format=%(refname:short)",
        "--list",
        "arbor-force-pushed-backup-*",
    ]);
    assert!(
        backups.starts_with("arbor-force-pushed-backup-"),
        "{backups}"
    );
    let status = local.git(&["status", "--porcelain"]);
    assert!(
        status.starts_with("AA") || status.contains('U'),
        "expected an unresolved replay conflict: {status}"
    );
}

#[test]
fn fetch_prune_removes_stale_tracking_ref() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let r = TestRepo::new();
    repo_with_origin(&r, &remote_path);

    // 推一个 feature 分支再删除
    r.git(&["checkout", "-q", "-b", "feature"]);
    r.write("feat.txt", "f\n");
    r.git(&["add", "feat.txt"]);
    r.git(&["commit", "-q", "-m", "feature"]);
    r.git(&["push", "-q", "origin", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    common::git(&remote_path, &["branch", "-D", "feature"]);

    // 有 stale tracking ref
    let before = r.git(&["for-each-ref", "--format=%(refname)", "refs/remotes/origin"]);
    assert!(before.contains("refs/remotes/origin/feature"));

    let repo = r.open();
    repo.fetch_prune(Some("origin".into()))
        .expect("fetch --prune");
    let after = r.git(&["for-each-ref", "--format=%(refname)", "refs/remotes/origin"]);
    assert!(
        !after.contains("refs/remotes/origin/feature"),
        "prune 后应移除: {after}"
    );
}

#[test]
fn fetch_all_fetches_every_remote() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_a = bare_remote(dir.path(), "a.git");
    let remote_b = bare_remote(dir.path(), "b.git");
    let r = TestRepo::new();
    repo_with_origin(&r, &remote_a);
    r.git(&["remote", "add", "second", &remote_b.display().to_string()]);
    r.git(&["push", "-q", "second", "main"]);

    // 两个远程各前进一次
    let other = dir.path().join("other");
    common::git(
        dir.path(),
        &["clone", "-q", &remote_a.display().to_string(), "other"],
    );
    configure_identity(&other);
    common::commit(&other, "x.txt", "x\n", "advance");
    common::git(&other, &["push", "-q", "origin", "main"]);
    common::git(
        &other,
        &["remote", "add", "second", &remote_b.display().to_string()],
    );
    common::git(&other, &["push", "-q", "second", "main"]);

    let repo = r.open();
    let outcomes = repo.fetch_all().expect("fetch all");
    assert_eq!(outcomes.len(), 2, "每个 remote 一个结果");
    // 两个 remote 的 tracking ref 都更新了
    let a_ref = r.git(&["rev-parse", "refs/remotes/origin/main"]);
    let b_ref = r.git(&["rev-parse", "refs/remotes/second/main"]);
    let remote_a_head = common::git(&remote_a, &["rev-parse", "main"]);
    let remote_b_head = common::git(&remote_b, &["rev-parse", "main"]);
    assert_eq!(a_ref, remote_a_head);
    assert_eq!(b_ref, remote_b_head);
}

#[test]
fn fetch_tag_modes_control_tag_download_and_pruning() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let r = TestRepo::new();
    repo_with_origin(&r, &remote_path);

    r.git(&["tag", "release-1"]);
    r.git(&["push", "-q", "origin", "refs/tags/release-1"]);
    r.git(&["tag", "-d", "release-1"]);

    let repo = r.open();
    repo.fetch_with_options(Some("origin".into()), FetchTagsMode::NoTags)
        .expect("fetch without tags");
    assert!(
        r.git(&["for-each-ref", "--format=%(refname:short)", "refs/tags"])
            .is_empty(),
        "--no-tags must not create local tags"
    );

    repo.fetch_with_options(Some("origin".into()), FetchTagsMode::AllTags)
        .expect("fetch all tags");
    assert_eq!(
        r.git(&["for-each-ref", "--format=%(refname:short)", "refs/tags"]),
        "release-1"
    );

    common::git(&remote_path, &["update-ref", "-d", "refs/tags/release-1"]);
    repo.fetch_with_options(Some("origin".into()), FetchTagsMode::PruneTags)
        .expect("prune tags");
    assert!(
        r.git(&["for-each-ref", "--format=%(refname:short)", "refs/tags"])
            .is_empty(),
        "--prune-tags must remove tags deleted from the remote"
    );
}

#[test]
fn fetch_unshallow_downloads_full_history() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let source = TestRepo::new();
    repo_with_origin(&source, &remote_path);
    common::commit(&source.path, "f.txt", "2\n", "second");
    source.git(&["push", "-q", "origin", "main"]);
    common::git(&remote_path, &["symbolic-ref", "HEAD", "refs/heads/main"]);

    let shallow_path = dir.path().join("shallow");
    let remote_url = format!("file://{}", remote_path.display());
    common::git(
        dir.path(),
        &["clone", "-q", "--depth", "1", &remote_url, "shallow"],
    );
    assert_eq!(
        common::git(&shallow_path, &["rev-list", "--count", "HEAD"]),
        "1"
    );

    let repo = arbor_engine::open_repository(shallow_path.to_string_lossy().into_owned())
        .expect("open shallow repository");
    assert!(
        repo.is_shallow(),
        "shallow clone must expose the shallow state"
    );
    repo.fetch_unshallow(Some("origin".into()))
        .expect("fetch --unshallow");
    assert!(!repo.is_shallow(), "unshallow must clear the shallow state");

    assert_eq!(
        common::git(&shallow_path, &["rev-parse", "--is-shallow-repository"]),
        "false"
    );
    assert_eq!(
        common::git(&shallow_path, &["rev-list", "--count", "HEAD"]),
        "2"
    );
}

#[test]
fn rejected_push_classifies_non_fast_forward() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote_path = bare_remote(dir.path(), "origin.git");
    let a = TestRepo::new();
    repo_with_origin(&a, &remote_path);

    let b_path = dir.path().join("b");
    common::git(
        dir.path(),
        &["clone", "-q", &remote_path.display().to_string(), "b"],
    );
    configure_identity(&b_path);
    common::commit(&b_path, "g.txt", "g\n", "remote update");
    common::git(&b_path, &["push", "-q", "origin", "main"]);

    // 普通 push 被拒:分类 non-fast-forward(UI 据此提供 merge/rebase 引导)
    common::commit(&a.path, "h.txt", "h\n", "local update");
    let repo = a.open();
    let err = repo
        .push_with_options(Some("origin".into()), "main".into(), false, false)
        .unwrap_err();
    match err {
        arbor_engine::EngineError::PushRejected { kind, .. } => {
            assert_eq!(kind, PushFailureKind::NonFastForward);
        }
        other => panic!("expected PushRejected, got {other}"),
    }
}

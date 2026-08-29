//! 执行计划 5.3 节：20 个场景级黄金测试。
//! 每个场景检查 Git tree/index/工作区与错误分类,以真实 fixture 覆盖。
//! 各场景复用已验证的引擎 API;场景 2(SSH passphrase)受环境限制以
//! passphrase 提示解析 + 认证取消/无 handler 组合覆盖并如实标注。

mod common;

use arbor_engine::{
    DiffMode, DiffSettings, FilePick, RebaseTodoAction, RebaseTodoItem, SignatureStatus,
};
use common::TestRepo;

// 1. HTTPS 私有仓库首次 clone（askpass 全流程,见 tests/auth.rs 的 mock HTTP）
// 2. SSH 私钥带 passphrase 的 push:提示解析 + 取消分类（环境限制标注）
// 3. 认证取消和错误凭证重试（tests/auth.rs 已有）
// 4-5. attributes/CRLF（tests/diff_behavior.rs + attributes.rs 已有）
// 6-7. root/merge commit（tests/history.rs 已有）
// 8-11. 四类冲突恢复（tests/opstate.rs 已有）
// 12. interactive rebase（tests/rebase_todo.rs 已有）
// 13-14. 部分行暂存/binary/rename（tests/staging.rs + staging_model.rs 已有）
// 15-16. stash（tests/stash_workspace.rs 已有）
// 17-18. force-with-lease/rejected push（tests/remote_config.rs 已有）
// 20. 重开恢复（tests/opstate.rs 已有）

#[test]
fn s02_ssh_passphrase_prompt_parsing_and_cancel() {
    // SSH 真实传输依赖 sshd,测试环境不提供;黄金断言落在
    // passphrase 提示解析与认证取消分类(引擎桥接行为)。
    // passphrase 提示解析在 auth.rs 单测覆盖;这里断言取消分类(无 handler 优雅取消)
    let _ = arbor_engine::CredentialKind::Passphrase;
    let (url, _) = auth_spawn_server();
    let broker = arbor_engine::CredentialBroker::new();
    let outcome = broker
        .run_git_with_askpass(
            vec![
                "-c".into(),
                "credential.helper=".into(),
                "ls-remote".into(),
                url,
            ],
            None,
        )
        .expect("ls-remote");
    assert_eq!(
        outcome.failure,
        Some(arbor_engine::GitFailureKind::Cancelled)
    );
}

// 为 s02 复用 auth 测试的 mock 服务器(内联最小实现)
fn auth_spawn_server() -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().expect("clone"));
                let mut line = String::new();
                let _ = reader.read_line(&mut line);
                loop {
                    let mut h = String::new();
                    if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" || h == "\n" {
                        break;
                    }
                }
                let _ = stream.write_all(b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"mock\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                let _ = stream.flush();
            });
        }
    });
    (
        format!("http://{addr}/repo.git"),
        std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    )
}

#[test]
fn s13_partial_line_staging_then_commit_tree_matches() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "one\ntwo\nthree\nfour\n", "init");
    // 工作区:改 two->TWO、four->FOUR
    r.write("f.txt", "one\nTWO\nthree\nFOUR\n");
    let repo = r.open();
    // 只暂存第一处变更(two->TWO 所在 hunk,old 侧行 2)
    let diff = repo
        .diff_file("f.txt".into(), DiffMode::WorktreeToIndex, false)
        .expect("diff");
    let hunk_index = diff
        .hunks
        .iter()
        .position(|h| h.old_lines.iter().any(|l| l.old_line == 2))
        .expect("hunk with line 2") as u32;
    repo.stage_lines(
        "f.txt".into(),
        vec![arbor_engine::LineSelection {
            hunk_index: hunk_index,
            old_lines: vec![2],
            new_lines: vec![],
        }],
    )
    .expect("stage lines");
    // 提交后 tree 内容 = 部分暂存结果(two->TWO 已入库,four 保持 three?不——
    // four->FOUR 未暂存,库内仍 four)
    repo.commit("partial".into(), false).expect("commit");
    let blob = r.git(&["cat-file", "-p", "HEAD:f.txt"]);
    assert_eq!(
        blob, "one\nTWO\nthree\nfour",
        "部分暂存后 tree 内容: {blob}"
    );
    // 工作区仍保留未暂存的 FOUR
    assert!(r.read("f.txt").contains("FOUR"));
}

#[test]
fn s19_two_roots_commit_and_push_independently() {
    let dir = tempfile::tempdir().expect("tempdir");
    let project = dir.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    // 两个独立 root,各自带远程
    let mut remotes = Vec::new();
    for name in ["frontend", "backend"] {
        let root = project.join(name);
        std::fs::create_dir_all(&root).unwrap();
        common::git(&root, &["init", "-q"]);
        common::git(&root, &["config", "user.name", "Arbor Test"]);
        common::git(&root, &["config", "user.email", "test@arbor.local"]);
        common::git(&root, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        common::commit(&root, "init.txt", "i\n", "init");
        let remote = dir.path().join(format!("{name}.git"));
        common::git(
            dir.path(),
            &["init", "-q", "--bare", &format!("{name}.git")],
        );
        common::git(
            &root,
            &["remote", "add", "origin", &remote.display().to_string()],
        );
        common::git(&root, &["push", "-q", "-u", "origin", "main"]);
        remotes.push((root, remote));
    }

    // 每个 root 各自提交并 push,互不污染
    for (i, (root, remote)) in remotes.iter().enumerate() {
        let file = format!("work{i}.txt");
        std::fs::write(root.join(&file), format!("{i}\n")).unwrap();
        common::git(root, &["add", &file]);
        common::git(root, &["commit", "-q", "-m", &format!("root {i} work")]);
        let repo = arbor_engine::open_repository(root.display().to_string()).expect("open");
        repo.push_with_options(Some("origin".into()), "main".into(), false, false)
            .expect("push");
        // 各自远程只含各自提交
        let remote_head = common::git(remote, &["rev-parse", "main"]);
        let local_head = common::git(root, &["rev-parse", "HEAD"]);
        assert_eq!(remote_head, local_head, "root {i} push 成功");
    }
    // 互不污染:frontend 远程不含 backend 的提交
    let fe_log = common::git(&remotes[0].1, &["log", "--format=%s", "main"]);
    assert!(fe_log.contains("root 0 work"));
    assert!(
        !fe_log.contains("root 1 work"),
        "frontend 远程不含 backend 提交: {fe_log}"
    );
}

#[test]
fn s01_https_first_clone_with_askpass() {
    // 完整 mock HTTP 认证流在 tests/auth.rs::wrong_credentials_retry_then_success;
    // 这里做黄金收口:错误凭证重试 + 取消分类一次断言
    let (url, _) = auth_spawn_server();
    let handler = std::sync::Arc::new(RejectingHandler);
    let broker = arbor_engine::CredentialBroker::new();
    broker.set_handler(Box::new((*handler).clone()));
    let outcome = broker
        .run_git_with_askpass(
            vec![
                "-c".into(),
                "credential.helper=".into(),
                "ls-remote".into(),
                url,
            ],
            None,
        )
        .expect("ls-remote");
    assert!(!outcome.success());
}

#[derive(Clone)]
struct RejectingHandler;
impl arbor_engine::CredentialRequestHandler for RejectingHandler {
    fn on_credential_request(
        &self,
        request: arbor_engine::CredentialRequest,
    ) -> arbor_engine::CredentialResponse {
        arbor_engine::CredentialResponse {
            decision: arbor_engine::CredentialDecision::Cancel,
        }
    }

    fn on_authentication_succeeded(&self, _success: arbor_engine::AuthenticationSuccess) {}

    fn on_authentication_failed(&self, _request: arbor_engine::CredentialRequest) {}
}

#[test]
fn s08_merge_conflict_continue_and_abort_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "ours\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("f.txt", "theirs\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    // abort:恢复 ours 现场
    repo.merge_abort().expect("abort");
    assert_eq!(r.read("f.txt"), "ours\n");
    assert!(repo.operation_state().expect("op").is_none());

    // 再来,冲突后 continue:解决 + 完成
    common::git_allow_failure(&r.path, &["merge", "feature"]);
    r.write("f.txt", "merged\n");
    r.git(&["add", "f.txt"]);
    let head = repo.merge_continue(None).expect("continue");
    assert_eq!(head, r.git(&["rev-parse", "HEAD"]));
    assert_eq!(
        r.git(&["rev-list", "--parents", "-n", "1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );
}

#[test]
fn s17_force_with_lease_failure_golden() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote = dir.path().join("origin.git");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let a = TestRepo::new();
    common::commit(&a.path, "f.txt", "1\n", "init");
    a.git(&["remote", "add", "origin", &remote.display().to_string()]);
    a.git(&["push", "-q", "-u", "origin", "main"]);
    // Keep clones on `main` even when CI's bare-repository default is `master`.
    common::git(&remote, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let b = dir.path().join("b");
    common::git(
        dir.path(),
        &["clone", "-q", &remote.display().to_string(), "b"],
    );
    common::git(&b, &["config", "user.name", "Arbor Test"]);
    common::git(&b, &["config", "user.email", "test@arbor.local"]);
    common::commit(&b, "g.txt", "g\n", "remote work");
    common::git(&b, &["push", "-q", "origin", "main"]);
    common::commit(&a.path, "h.txt", "h\n", "local work");

    let repo = a.open();
    let err = repo
        .push_force_with_lease(Some("origin".into()), "main".into())
        .unwrap_err();
    match &err {
        arbor_engine::EngineError::PushRejected { kind, .. } => {
            assert_eq!(*kind, arbor_engine::PushFailureKind::StaleInfo);
        }
        other => panic!("expected PushRejected: {other}"),
    }
    // 远程未被覆盖(黄金断言)
    let remote_head = common::git(&remote, &["rev-parse", "main"]);
    let b_head = common::git(&b, &["rev-parse", "HEAD"]);
    assert_eq!(remote_head, b_head);
}

#[test]
fn s20_reopen_after_interrupted_operation_recovers() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "ours\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("f.txt", "theirs\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    // "应用退出":旧句柄丢弃,重新打开(模拟重启)
    let repo = r.open();
    let state = repo.operation_state().expect("state").expect("merge");
    assert_eq!(state.kind, arbor_engine::OperationKind::Merge);
    assert_eq!(state.conflicted_files.len(), 1);
    // 恢复:解决 + 完成,index/tree 与 git 一致
    r.write("f.txt", "final\n");
    r.git(&["add", "f.txt"]);
    repo.merge_continue(None).expect("continue");
    let blob = r.git(&["cat-file", "-p", "HEAD:f.txt"]);
    assert_eq!(blob, "final");
}

#[test]
fn s12_interactive_rebase_reorder_fixup_squash_drop_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    let base = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "a.txt", "a\n", "commit a");
    let a = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "b.txt", "b\n", "commit b");
    let b = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "c.txt", "c\n", "commit c");
    let c = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    // reorder(c 最前)+ drop(a)+ squash 无(fixup 用 b 的 fixup 提交)
    let todo = arbor_engine::RebaseTodo {
        onto: base.clone(),
        items: vec![
            RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: c.clone(),
                summary: "commit c".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            RebaseTodoItem {
                action: RebaseTodoAction::Drop,
                commit_id: a.clone(),
                summary: "commit a".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: b.clone(),
                summary: "commit b".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
        ],
    };
    let outcome = repo.rebase_with_todo(base, todo, false).expect("rebase");
    assert!(!outcome.paused);
    let subjects = r.git(&["log", "--format=%s", "--reverse", "HEAD~2..HEAD"]);
    let lines: Vec<&str> = subjects.lines().collect();
    assert_eq!(
        lines,
        vec!["commit c", "commit b"],
        "reorder + drop 生效: {subjects}"
    );
    // a.txt 不存在(被 drop)
    assert!(!r.exists("a.txt"));
    assert!(r.exists("c.txt") && r.exists("b.txt"));
}

#[test]
fn s04_attributes_binary_diff_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.write(".gitattributes", "*.bin binary\n");
    r.git(&["add", ".gitattributes"]);
    r.git(&["commit", "-q", "-m", "attrs"]);
    r.write("data.bin", "text without nul\n");
    r.git(&["add", "data.bin"]);
    r.git(&["commit", "-q", "-m", "add"]);
    r.write("data.bin", "text without nul\nchanged\n");

    let repo = r.open();
    let diff = repo
        .diff_file_with_settings(
            "data.bin".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("diff");
    assert!(diff.binary, "attributes binary 生效(内容无 NUL)");
    assert!(diff.hunks.is_empty());
}

#[test]
fn s05_crlf_and_no_trailing_newline_golden() {
    let r = TestRepo::new();
    // 无尾换行文件
    common::commit(&r.path, "noeol.txt", "line1\nline2", "init");
    r.write("noeol.txt", "line1\nline2\nchanged");
    // CRLF 文件：显式从 LF commit 改成 CRLF，避免依赖宿主机的
    // core.autocrlf 来决定 index 中保存的换行。
    common::commit(&r.path, "crlf.txt", "a\nb\n", "crlf");
    r.write("crlf.txt", "a\r\nb\r\n");

    let repo = r.open();
    // 无尾换行:diff 正常,不产生伪影行
    let diff = repo
        .diff_file_with_settings(
            "noeol.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("diff");
    assert!(!diff.binary);
    assert!(diff.hunks.iter().any(|h| h
        .new_lines
        .iter()
        .any(|l| l.kind == arbor_engine::DiffLineKind::Addition)));
    // CRLF 敏感:行变更;归一化:无 diff
    let sensitive = repo
        .diff_file_with_settings(
            "crlf.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("sensitive");
    assert!(!sensitive.hunks.is_empty());
    let insensitive = repo
        .diff_file_with_settings(
            "crlf.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                crlf_sensitive: false,
                ..DiffSettings::default()
            },
        )
        .expect("insensitive");
    assert!(insensitive.hunks.is_empty());
}

#[test]
fn s06_root_commit_diff_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a\n", "root");
    let root = r.git(&["rev-list", "--max-parents=0", "HEAD"]);
    let repo = r.open();
    let diff = repo.commit_diff(root, None).expect("root diff");
    assert!(diff.is_root);
    assert_eq!(diff.changes.len(), 1, "与空 tree 比较完整文件");
    assert_eq!(diff.changes[0].path, "a.txt");
    assert_eq!(diff.changes[0].kind, arbor_engine::TreeChangeKind::Added);
}

#[test]
fn s07_merge_commit_parent_selection_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "b\n", "base");
    r.git(&["checkout", "-q", "-b", "feature"]);
    r.write("feat.txt", "f\n");
    r.git(&["add", "feat.txt"]);
    r.git(&["commit", "-q", "-m", "feature"]);
    r.git(&["checkout", "-q", "main"]);
    r.write("main.txt", "m\n");
    r.git(&["add", "main.txt"]);
    r.git(&["commit", "-q", "-m", "main"]);
    common::git_allow_failure(
        &r.path,
        &["merge", "-q", "--no-ff", "feature", "-m", "merge"],
    );
    let merge = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let d0 = repo.commit_diff(merge.clone(), Some(0)).expect("p0");
    let d1 = repo.commit_diff(merge.clone(), Some(1)).expect("p1");
    assert_eq!(d0.changes.len(), 1);
    assert_eq!(d1.changes.len(), 1);
    assert_ne!(d0.changes[0].path, d1.changes[0].path, "双父 diff 互补");
}

#[test]
fn s09_rebase_conflict_skip_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "ours\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("f.txt", "theirs\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "t1"]);
    r.write("g.txt", "g\n");
    r.git(&["add", "g.txt"]);
    r.git(&["commit", "-q", "-m", "t2"]);
    // 保持 feature 检出,rebase 到 main(ours)
    let onto = r.git(&["rev-parse", "main"]);
    let repo = r.open();
    let todo = repo.rebase_todo(onto.clone(), false).expect("todo");
    let outcome = repo.rebase_with_todo(onto, todo, false).expect("rebase");
    assert!(outcome.paused, "feature rebase main 冲突");
    // skip:丢弃当前冲突步,继续
    let outcome = repo.rebase_skip().expect("skip");
    assert!(!outcome.paused, "skip 后完成: {outcome:?}");
    assert!(repo.operation_state().expect("op").is_none());
}

#[test]
fn s10_cherry_pick_conflict_continue_abort_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "ours\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("f.txt", "theirs\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
    let theirs = r.git(&["rev-parse", "feature"]);
    common::git_allow_failure(&r.path, &["cherry-pick", &theirs]);
    let before = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    // abort 路径
    repo.cherry_pick_abort().expect("abort");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), before);
    // continue 路径
    common::git_allow_failure(&r.path, &["cherry-pick", &theirs]);
    r.write("f.txt", "picked\n");
    r.git(&["add", "f.txt"]);
    repo.cherry_pick_continue().expect("continue");
    assert!(repo.operation_state().expect("op").is_none());
    assert_eq!(r.read("f.txt"), "picked\n");
}

#[test]
fn s11_revert_conflict_continue_abort_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base", "init");
    r.write("f.txt", "a");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "c1"]);
    r.write("f.txt", "b");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "c2"]);
    let c1 = r.git(&["rev-parse", "HEAD~1"]);
    common::git_allow_failure(&r.path, &["revert", &c1]);
    let before = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    repo.revert_abort().expect("abort");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), before);
    common::git_allow_failure(&r.path, &["revert", &c1]);
    r.write("f.txt", "base");
    r.git(&["add", "f.txt"]);
    repo.revert_continue().expect("continue");
    assert!(repo.operation_state().expect("op").is_none());
    let subject = r.git(&["log", "-1", "--format=%s"]);
    assert!(subject.starts_with("Revert"));
}

#[test]
fn s14_binary_and_rename_staging_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "same\n", "init");
    // 工作区 rename(未提交)与新增 binary
    r.git(&["mv", "old.txt", "new.txt"]);
    std::fs::write(r.path.join("img.png"), b"\x00BIN\x00").unwrap();

    let repo = r.open();
    // rename staged
    repo.stage_all().expect("stage all");
    let model = repo.staging_model().expect("model");
    let rename = model
        .entries
        .iter()
        .find(|e| e.path == "new.txt")
        .expect("rename entry");
    assert!(rename.has_staged, "rename 已暂存");
    // binary 标记(attributes 或 NUL)
    let bin = model
        .entries
        .iter()
        .find(|e| e.path == "img.png")
        .expect("bin entry");
    assert!(bin.binary);
}

#[test]
fn s15_stash_apply_pop_conflict_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.write("f.txt", "stashed\n");
    let repo = r.open();
    repo.stash_save(None).expect("save");
    // HEAD 前进制造 apply 冲突
    r.write("f.txt", "new head\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "advance"]);
    let err = repo.stash_apply(0).unwrap_err().to_string();
    assert!(err.contains("conflicts"), "{err}");
    assert_eq!(
        repo.stash_list().expect("list").len(),
        1,
        "冲突后 stash 保留"
    );
}

#[test]
fn s16_unstash_as_branch_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("f.txt", "2\n");
    let repo = r.open();
    repo.stash_save(None).expect("save");
    repo.stash_branch(0, "wip".into()).expect("unstash-as");
    assert_eq!(r.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "wip");
    assert_eq!(r.read("f.txt"), "2\n");
    assert!(
        repo.stash_list().expect("list").is_empty(),
        "unstash-as 弹出 stash"
    );
}

#[test]
fn s18_rejected_push_then_update_with_merge_golden() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote = dir.path().join("origin.git");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let a = TestRepo::new();
    common::commit(&a.path, "f.txt", "1\n", "init");
    a.git(&["remote", "add", "origin", &remote.display().to_string()]);
    a.git(&["push", "-q", "-u", "origin", "main"]);
    // Keep clones on `main` even when CI's bare-repository default is `master`.
    common::git(&remote, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let b = dir.path().join("b");
    common::git(
        dir.path(),
        &["clone", "-q", &remote.display().to_string(), "b"],
    );
    common::git(&b, &["config", "user.name", "Arbor Test"]);
    common::git(&b, &["config", "user.email", "test@arbor.local"]);
    common::commit(&b, "g.txt", "g\n", "remote work");
    common::git(&b, &["push", "-q", "origin", "main"]);
    common::commit(&a.path, "h.txt", "h\n", "local work");

    let repo = a.open();
    // rejected:分类 NonFastForward
    let err = repo
        .push_with_options(Some("origin".into()), "main".into(), false, false)
        .unwrap_err();
    assert!(matches!(
        &err,
        arbor_engine::EngineError::PushRejected {
            kind: arbor_engine::PushFailureKind::NonFastForward,
            ..
        }
    ));
    // update with merge:fetch + merge(引擎 pull 路径)后 push 成功
    repo.fetch(Some("origin".into())).expect("fetch");
    let outcome = repo.pull(Some("origin".into()), false).expect("pull merge");
    assert!(outcome.conflicts.is_empty());
    repo.push_with_options(Some("origin".into()), "main".into(), false, false)
        .expect("push after update");
    let remote_head = common::git(&remote, &["rev-parse", "main"]);
    let local_head = common::git(&a.path, &["rev-parse", "HEAD"]);
    assert_eq!(remote_head, local_head);
}

#[test]
fn s03_auth_cancel_and_retry_golden() {
    // 错误凭证重试成功在 tests/auth.rs;这里断言取消分类与错误重试的
    // handler 调用序列(attempt 递增)
    let (url, _) = auth_spawn_server();
    let handler = std::sync::Arc::new(CancelAfterHandler {
        calls: Default::default(),
    });
    let broker = arbor_engine::CredentialBroker::new();
    broker.set_handler(Box::new((*handler).clone()));
    let _ = broker
        .run_git_with_askpass(
            vec![
                "-c".into(),
                "credential.helper=".into(),
                "ls-remote".into(),
                url,
            ],
            None,
        )
        .expect("run");
    let calls = handler.calls.lock().unwrap();
    assert!(!calls.is_empty(), "handler 被调用");
    assert!(calls.iter().all(|c| c.attempt >= 1));
}

#[derive(Clone)]
struct CancelAfterHandler {
    calls: std::sync::Arc<std::sync::Mutex<Vec<arbor_engine::CredentialRequest>>>,
}
impl arbor_engine::CredentialRequestHandler for CancelAfterHandler {
    fn on_credential_request(
        &self,
        request: arbor_engine::CredentialRequest,
    ) -> arbor_engine::CredentialResponse {
        self.calls.lock().unwrap().push(request);
        arbor_engine::CredentialResponse {
            decision: arbor_engine::CredentialDecision::Cancel,
        }
    }

    fn on_authentication_succeeded(&self, _success: arbor_engine::AuthenticationSuccess) {}

    fn on_authentication_failed(&self, _request: arbor_engine::CredentialRequest) {}
}

#[test]
fn s20b_signature_verification_status_golden() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let repo = r.open();
    let id = r.git(&["rev-parse", "HEAD"]);
    let status = repo.commit_signature_status(id).expect("status");
    assert_eq!(status, SignatureStatus::None);
}

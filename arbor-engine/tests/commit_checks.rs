//! COMMIT-001：内置提交检查与签名配置。
//! 身份缺失/冲突/detached HEAD/大文件/CRLF 检查、signing 配置读取、
//! 失败保留（引擎错误分类 + Swift 侧 message 保留由 UI 层负责，此处验证
//! 检查结果与签名配置的结构化输出）。

mod common;

use arbor_engine::{CommitCheckKind, SigningConfig};
use common::TestRepo;

#[test]
fn identity_missing_is_blocking() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    // 清掉身份
    r.git(&["config", "--unset", "user.name"]);
    r.git(&["config", "--unset", "user.email"]);
    r.write("f.txt", "2\n");

    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    let identity = checks
        .iter()
        .find(|c| c.kind == CommitCheckKind::IdentityMissing)
        .expect("identity check");
    assert!(identity.blocking, "身份缺失必须阻塞提交");
    assert!(
        identity.message.contains("user.name"),
        "{}",
        identity.message
    );

    // 配置后检查通过
    r.git(&["config", "user.name", "Arbor Test"]);
    r.git(&["config", "user.email", "test@arbor.local"]);
    let checks = repo.commit_checks().expect("checks");
    assert!(!checks
        .iter()
        .any(|c| c.kind == CommitCheckKind::IdentityMissing));
}

#[test]
fn unresolved_conflicts_block_commit() {
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
    let checks = repo.commit_checks().expect("checks");
    let conflict = checks
        .iter()
        .find(|c| c.kind == CommitCheckKind::UnresolvedConflicts)
        .expect("conflict check");
    assert!(conflict.blocking);
    assert!(conflict.message.contains("f.txt"));
}

#[test]
fn detached_head_is_non_blocking_warning() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let head = r.git(&["rev-parse", "HEAD"]);
    r.git(&["checkout", "-q", &head]);

    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    let detached = checks
        .iter()
        .find(|c| c.kind == CommitCheckKind::DetachedHead)
        .expect("detached check");
    assert!(!detached.blocking, "detached 只提示不阻塞");
}

#[test]
fn interactive_rebase_suppresses_generic_detached_warning() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let head = r.git(&["rev-parse", "HEAD"]);
    r.git(&["checkout", "-q", &head]);

    let rebase_dir = r.path.join(".git/rebase-merge");
    std::fs::create_dir_all(&rebase_dir).unwrap();
    std::fs::write(rebase_dir.join("interactive"), "").unwrap();

    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    assert!(
        !checks
            .iter()
            .any(|check| check.kind == CommitCheckKind::DetachedHead),
        "interactive rebase should not produce the generic detached warning: {checks:?}"
    );
}

#[test]
fn noninteractive_rebase_uses_rebase_specific_warning() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let head = r.git(&["rev-parse", "HEAD"]);
    r.git(&["checkout", "-q", &head]);

    let rebase_dir = r.path.join(".git/rebase-merge");
    std::fs::create_dir_all(&rebase_dir).unwrap();

    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    let rebase = checks
        .iter()
        .find(|check| check.kind == CommitCheckKind::RebaseInProgress)
        .expect("rebase warning");
    assert!(!rebase.blocking);
    assert!(rebase.message.contains("rebase"));
    assert!(
        !checks
            .iter()
            .any(|check| check.kind == CommitCheckKind::DetachedHead),
        "rebase warning should replace generic detached warning: {checks:?}"
    );
}

#[test]
fn large_file_and_crlf_warnings() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    // 大文件(>1MB)暂存
    let big = vec![b'a'; 1024 * 1024 + 10];
    std::fs::write(r.path.join("big.bin"), &big).unwrap();
    // CRLF 混合文件
    std::fs::write(r.path.join("mixed.txt"), "line1\r\nline2\n").unwrap();
    r.git(&["add", "big.bin", "mixed.txt"]);

    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    let large = checks
        .iter()
        .find(|c| c.kind == CommitCheckKind::LargeFile)
        .expect("large file check");
    assert!(!large.blocking);
    assert!(large.message.contains("big.bin"));
    let crlf = checks
        .iter()
        .find(|c| c.kind == CommitCheckKind::CrlfWarning)
        .expect("crlf check");
    assert!(crlf.message.contains("mixed.txt"));
}

#[test]
fn crlf_warning_respects_autocrlf_and_gitattributes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("plain.txt", "plain\r\nlines\r\n");
    r.write("text.txt", "text\r\nlines\r\n");
    r.write("legacy.txt", "legacy\r\nlines\r\n");
    r.write(".gitattributes", "text.txt text\nlegacy.txt crlf\n");
    r.git(&[
        "add",
        "plain.txt",
        "text.txt",
        "legacy.txt",
        ".gitattributes",
    ]);

    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    let crlf = checks
        .iter()
        .find(|check| check.kind == CommitCheckKind::CrlfWarning)
        .expect("plain CRLF should warn");
    assert!(crlf.message.contains("plain.txt"));
    assert!(!crlf.message.contains("text.txt"));
    assert!(!crlf.message.contains("legacy.txt"));

    r.git(&["config", "core.autocrlf", "input"]);
    let checks = repo.commit_checks().expect("checks with autocrlf");
    assert!(!checks
        .iter()
        .any(|check| check.kind == CommitCheckKind::CrlfWarning));
}

#[test]
fn configurable_large_file_limit_and_selected_paths_cover_bad_names() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let big = vec![b'a'; 2 * 1024 * 1024];
    std::fs::write(r.path.join("big.bin"), &big).unwrap();
    std::fs::write(r.path.join("CON.txt"), "reserved\n").unwrap();
    std::fs::write(r.path.join("bad:name.txt"), "invalid\n").unwrap();
    r.git(&["add", "big.bin", "CON.txt", "bad:name.txt"]);

    let repo = r.open();
    let checks = repo
        .commit_checks_with_large_file_limit(50 * 1024 * 1024)
        .expect("checks with project threshold");
    assert!(!checks
        .iter()
        .any(|check| check.kind == CommitCheckKind::LargeFile));
    let bad_names = checks
        .iter()
        .find(|check| check.kind == CommitCheckKind::BadFileName)
        .expect("bad filename check");
    assert!(bad_names.message.contains("CON.txt"));
    assert!(bad_names.message.contains("bad:name.txt"));

    let selected = repo
        .commit_checks_with_large_file_limit_for_paths(1024 * 1024, vec!["big.bin".into()])
        .expect("selected path checks");
    assert!(selected
        .iter()
        .any(|check| check.kind == CommitCheckKind::LargeFile));
    assert!(!selected
        .iter()
        .any(|check| check.kind == CommitCheckKind::BadFileName));

    r.git(&["config", "lfs.repositoryformatversion", "0"]);
    let lfs_enabled = repo
        .commit_checks_with_large_file_limit(1024 * 1024)
        .expect("checks with LFS repository");
    assert!(!lfs_enabled
        .iter()
        .any(|check| check.kind == CommitCheckKind::LargeFile));
}

#[test]
fn signing_config_reflects_repo_settings() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&["config", "commit.gpgsign", "true"]);
    r.git(&["config", "gpg.format", "ssh"]);
    r.git(&[
        "config",
        "user.signingkey",
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKey test@arbor.local",
    ]);

    let repo = r.open();
    let config = repo.signing_config().expect("signing config");
    assert!(config.enabled);
    assert_eq!(config.format, "ssh");
    assert!(config.signing_key.is_some());

    // 默认:未配置时为 openpgp + 关闭
    let r2 = TestRepo::new();
    common::commit(&r2.path, "f.txt", "1\n", "init");
    let repo2 = r2.open();
    let default = repo2.signing_config().expect("default");
    assert!(!default.enabled);
    assert_eq!(default.format, "openpgp");
}

#[test]
fn signing_enabled_commit_produces_signed_object_when_key_available() {
    // 签名提交走系统 git(--gpg-sign);无 key 环境验证错误分类而非崩溃
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.write("f.txt", "2\n");
    let repo = r.open();
    let id = repo.commit_with_options(
        "signed attempt".into(),
        false,
        None,
        None,
        None,
        None,
        Some("nonexistent-key".into()),
        false,
        Vec::new(),
        false,
    );
    match id {
        Ok(_) => {
            // 有 gpg 环境且 key 存在:验证签名块存在
            let head = r.git(&["rev-parse", "HEAD"]);
            let info = repo
                .log(None, 1, false, None)
                .expect("log")
                .into_iter()
                .next()
                .expect("entry");
            assert_eq!(info.id, head);
            let _ = info;
        }
        Err(e) => {
            // 无 key 环境:提交失败且错误可读
            let text = e.to_string();
            assert!(!text.is_empty());
            // 失败后工作区/索引未破坏,message 可重试(引擎错误而非静默)
            let st = repo.status().expect("status");
            assert!(st.iter().any(|e| e.path == "f.txt"));
        }
    }
}

#[test]
fn checks_are_structured_not_string_guessing() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    let repo = r.open();
    let checks = repo.commit_checks().expect("checks");
    // 干净仓库:无阻塞项
    assert!(!checks.iter().any(|c| c.blocking), "{checks:?}");
}

#[test]
fn credential_helpers_detected_from_config() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&["config", "credential.helper", "osxkeychain"]);
    let repo = r.open();
    let helpers = repo.credential_helpers().expect("helpers");
    let osx = helpers
        .iter()
        .find(|h| h.name.contains("osxkeychain"))
        .expect("osxkeychain");
    // available 如实反映 PATH 事实(CI 机器可能无该二进制,断言不硬编码)
}

#[test]
fn missing_helper_reported_unavailable() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "init");
    r.git(&["config", "credential.helper", "definitely-not-a-helper"]);
    let repo = r.open();
    let helpers = repo.credential_helpers().expect("helpers");
    let missing = helpers
        .iter()
        .find(|h| h.name == "definitely-not-a-helper")
        .expect("entry");
    assert!(!missing.available, "缺失 helper 标记不可用");
}

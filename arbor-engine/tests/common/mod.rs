//! 回归测试共用工具：用 tempfile 自建隔离 repo，用系统 git 构造已知状态。
//!
//! 每个 TestRepo 独立临时目录；本地 config 固定身份/关 gpgsign，避免全局配置干扰。

use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

/// 一个隔离的测试仓库（临时目录 + 工作区路径）。
pub struct TestRepo {
    _dir: TempDir,
    pub path: PathBuf,
}

impl TestRepo {
    /// `git init` + 固定身份 + 关 gpgsign，返回可调用引擎的测试仓库。
    pub fn new() -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().to_path_buf();
        git(&path, &["init", "-q"]);
        // 固定身份（gix 的 commit 读 config；无身份会 AuthorMissing）
        git(&path, &["config", "user.name", "Arbor Test"]);
        git(&path, &["config", "user.email", "test@arbor.local"]);
        // 关 gpg 签名（全局可能开启，测试环境无 key 会失败）
        git(&path, &["config", "commit.gpgsign", "false"]);
        git(&path, &["config", "tag.gpgsign", "false"]);
        // 隔离宿主机的 line-ending policy；属性/CRLF tests explicitly
        // override this local value when they exercise autocrlf=true/input.
        git(&path, &["config", "core.autocrlf", "false"]);
        // 默认分支统一为 main，避免依赖全局 init.defaultBranch
        git(&path, &["symbolic-ref", "HEAD", "refs/heads/main"]);
        TestRepo { _dir: dir, path }
    }

    /// 工作区写文件（建父目录）。
    pub fn write(&self, name: &str, content: &str) {
        let p = self.path.join(name);
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(p, content).unwrap();
    }

    /// 读工作区文件。
    pub fn read(&self, name: &str) -> String {
        std::fs::read_to_string(self.path.join(name)).unwrap()
    }

    /// 工作区文件是否存在。
    pub fn exists(&self, name: &str) -> bool {
        self.path.join(name).exists()
    }

    /// 在工作区跑 git（返回 stdout trim）。
    pub fn git(&self, args: &[&str]) -> String {
        git(&self.path, args)
    }

    /// 引擎打开当前仓库（每次返回新句柄，可模拟跨进程重开）。
    pub fn open(&self) -> std::sync::Arc<arbor_engine::Repository> {
        arbor_engine::open_repository(self.path.to_string_lossy().into_owned())
            .expect("open_repository")
    }
}

/// 跑 git（校验退出码，失败 panic 带 stderr）。
pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("git {:?}: {e}", args));
    if !out.status.success() {
        panic!(
            "git {:?} failed ({}): {}",
            args,
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Read a commit object's message without trimming intentional leading or
/// trailing whitespace. This is used by message-cleanup parity tests.
pub fn raw_commit_message(dir: &Path, commit_id: &str) -> String {
    let output = Command::new("git")
        .args(["cat-file", "commit", commit_id])
        .current_dir(dir)
        .output()
        .expect("read commit object");
    assert!(output.status.success());
    let separator = output
        .stdout
        .windows(2)
        .position(|window| window == b"\n\n")
        .expect("commit header separator");
    String::from_utf8(output.stdout[separator + 2..].to_vec()).expect("UTF-8 commit message")
}

/// 跑预期可能失败的 git（如产生冲突的 merge/rebase），返回合并的 stdout+stderr。
pub fn git_allow_failure(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("git {:?}: {e}", args));
    let mut text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if !text.is_empty() && !stderr.is_empty() {
        text.push('\n');
    }
    text.push_str(&stderr);
    text
}

/// 造一个提交：写文件 + git add + git commit，返回 commit id（hex）。
pub fn commit(dir: &Path, filename: &str, content: &str, message: &str) -> String {
    let p = dir.join(filename);
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(p, content).unwrap();
    git(dir, &["add", filename]);
    git(dir, &["commit", "-q", "-m", message]);
    git(dir, &["rev-parse", "HEAD"])
}

//! Git hooks 的执行兼容层（管理 API 见 `hookadmin.rs`）。
//!
//! 只跑 pre-commit / commit-msg，并且遵守两条 Git 语义：
//! - `core.hooksPath` 生效时 hook 定义在该目录，而不是 `.git/hooks`；
//! - 没有可执行位的 hook 文件会被 Git 忽略（等价于未安装）。
//!
//! 内置名单 `HOOK_NAMES` 供管理界面列出可安装的 sample。

use std::path::{Path, PathBuf};

use gix::bstr::ByteSlice;
use std::process::Command;

use crate::error::EngineError;

/// Git 认识的 hook 名单（客户端 + 服务端），管理界面用它列出可安装项。
pub(crate) const HOOK_NAMES: [&str; 29] = [
    "pre-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-merge-commit",
    "pre-rebase",
    "post-checkout",
    "post-merge",
    "pre-push",
    "post-rewrite",
    "applypatch-msg",
    "pre-applypatch",
    "post-applypatch",
    "pre-auto-gc",
    "post-index-change",
    "reference-transaction",
    "fsmonitor-watchman",
    "p4-changelist",
    "p4-prepare-changelist",
    "p4-post-changelist",
    "p4-pre-submit",
    "sendemail-validate",
    "pre-receive",
    "update",
    "proc-receive",
    "post-receive",
    "post-update",
    "push-to-checkout",
    "post-update",
];

fn workdir(repo: &gix::Repository) -> Result<&Path, EngineError> {
    repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "hook cannot run in a bare repository".into(),
    })
}

/// `core.hooksPath` 生效时 hook 定义在该目录，可以是绝对路径、`~/...`
/// 或相对工作区根的路径；未配置时回退到 `.git/hooks`。
pub(crate) fn hooks_directory(repo: &gix::Repository) -> PathBuf {
    let custom = repo
        .config_snapshot()
        .string("core.hooksPath")
        .map(|value| value.to_str_lossy().into_owned())
        .filter(|value| !value.trim().is_empty());
    let Some(raw) = custom else {
        return repo.git_dir().join("hooks");
    };
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    let candidate = PathBuf::from(&raw);
    if candidate.is_absolute() {
        return candidate;
    }
    repo.workdir()
        .unwrap_or_else(|| repo.git_dir())
        .join(candidate)
}

/// Git 忽略没有可执行位的 hook 文件；这里保持同一语义，避免界面显示
/// 「已启用」但提交时实际没跑。
fn active_hook_path(repo: &gix::Repository, name: &str) -> Option<PathBuf> {
    let path = hooks_directory(repo).join(name);
    if !path.is_file() {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let executable = std::fs::metadata(&path)
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
        if !executable {
            return None;
        }
    }
    Some(path)
}

fn output_text(output: &std::process::Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    match (stdout.trim(), stderr.trim()) {
        ("", "") => String::new(),
        (out, "") => out.to_owned(),
        ("", err) => err.to_owned(),
        (out, err) => format!("{out}\n{err}"),
    }
}

fn run_hook(
    repo: &gix::Repository,
    path: &Path,
    args: &[&Path],
) -> Result<std::process::Output, EngineError> {
    let workdir = workdir(repo)?;
    let git_dir = repo.git_dir();
    let mut command = Command::new(path);
    command
        .args(args)
        .current_dir(workdir)
        .env("GIT_DIR", git_dir)
        .env("GIT_WORK_TREE", workdir);
    command.output().map_err(EngineError::from_gix)
}

/// 执行 pre-commit；None 表示没有 hook 或 hook 成功，Some 是失败输出。
pub(crate) fn run_pre_commit_hook(
    repo: &gix::Repository,
    skip: bool,
) -> Result<Option<String>, EngineError> {
    if skip {
        return Ok(None);
    }
    let Some(path) = active_hook_path(repo, "pre-commit") else {
        return Ok(None);
    };
    let output = run_hook(repo, &path, &[])?;
    if output.status.success() {
        Ok(None)
    } else {
        let text = output_text(&output);
        Ok(Some(if text.is_empty() {
            format!("pre-commit exited with {}", output.status)
        } else {
            text
        }))
    }
}

/// 执行 commit-msg；hook 可以原地修改消息文件，返回修改后的内容。
pub(crate) fn run_commit_msg_hook(
    repo: &gix::Repository,
    message: &str,
    skip: bool,
) -> Result<String, EngineError> {
    if skip {
        return Ok(message.to_owned());
    }
    let Some(path) = active_hook_path(repo, "commit-msg") else {
        return Ok(message.to_owned());
    };
    let message_path = repo.git_dir().join("ARBOR_COMMIT_EDITMSG");
    std::fs::write(&message_path, message).map_err(EngineError::from_gix)?;
    let output = run_hook(repo, &path, &[&message_path]);
    let result = match output {
        Ok(output) if output.status.success() => {
            std::fs::read_to_string(&message_path).map_err(EngineError::from_gix)
        }
        Ok(output) => {
            let text = output_text(&output);
            Err(EngineError::GitOperation {
                message: if text.is_empty() {
                    format!("commit-msg exited with {}", output.status)
                } else {
                    text
                },
            })
        }
        Err(error) => Err(error),
    };
    let _ = std::fs::remove_file(&message_path);
    result
}

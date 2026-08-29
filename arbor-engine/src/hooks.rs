//! Git hooks 的最小兼容层。

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::error::EngineError;

fn workdir(repo: &gix::Repository) -> Result<&Path, EngineError> {
    repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "hook cannot run in a bare repository".into(),
    })
}

fn hook_path(repo: &gix::Repository, name: &str) -> PathBuf {
    repo.git_dir().join("hooks").join(name)
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
    let path = hook_path(repo, "pre-commit");
    if !path.is_file() {
        return Ok(None);
    }
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
    let path = hook_path(repo, "commit-msg");
    if !path.is_file() {
        return Ok(message.to_owned());
    }
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

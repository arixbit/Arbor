//! blame：逐行归属（模块 3 🟡 内联 blame 的基础）。
//!
//! 通过统一的 system Git runner 执行 `git blame --line-porcelain`，保留每行
//! 的提交、作者、日期和工作区文本，再展开成逐行 `BlameLine`。

use crate::error::EngineError;
use crate::highlight::{line_spans_for_content, spec_for_path, HighlightSpan};

/// Git's annotation movement modes. These map to IntelliJ's
/// `AnnotateDetectMovementsOption`: no movement detection, movement within a
/// file, or movement across files.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlameMovement {
    None,
    Inner,
    Outer,
}

/// User-visible options for Git annotate/blame.
///
/// The defaults intentionally match the fork's application settings:
/// whitespace is ignored, movement detection is disabled, and the author
/// date is shown unless the user explicitly prefers the committer date.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlameOptions {
    pub ignore_whitespaces: bool,
    pub movement: BlameMovement,
    pub prefer_commit_date: bool,
}

impl Default for BlameOptions {
    fn default() -> Self {
        Self {
            ignore_whitespaces: true,
            movement: BlameMovement::None,
            prefer_commit_date: false,
        }
    }
}

/// 一行的 blame 归属。
#[derive(uniffi::Record, Clone, Debug)]
pub struct BlameLine {
    /// 1-based 行号
    pub line: u32,
    pub commit_id: String,
    pub short_id: String,
    pub author: String,
    /// unix 秒
    pub time: i64,
    pub summary: String,
    pub text: String,
    /// 语法高亮行内局部 span（语言未知/失败时为空）
    pub highlights: Vec<HighlightSpan>,
}

/// 计算 HEAD 版本文件的逐行 blame。
pub(crate) fn blame(
    repo: &gix::Repository,
    path: &str,
    options: BlameOptions,
) -> Result<Vec<BlameLine>, EngineError> {
    run_git_blame(repo, path, Some("HEAD"), options)
}

/// 计算工作区文件的逐行 blame。
///
/// IntelliJ 的 annotate 入口针对用户当前看到的文件内容，而不是固定的
/// HEAD blob。系统 Git 的 porcelain 输出能保留未提交行、移动行和每行文本，
/// 因此这里专门走 `git blame --line-porcelain`；命令仍经过统一的 Git executable
/// 选择入口，并且路径作为 `--` 后的独立 argv 传递。
pub(crate) fn blame_worktree(
    repo: &gix::Repository,
    path: &str,
    options: BlameOptions,
) -> Result<Vec<BlameLine>, EngineError> {
    run_git_blame(repo, path, None, options)
}

fn run_git_blame(
    repo: &gix::Repository,
    path: &str,
    revision: Option<&str>,
    options: BlameOptions,
) -> Result<Vec<BlameLine>, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "blame requires a non-bare worktree".into(),
    })?;
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.current_dir(workdir).args([
        "blame",
        "--line-porcelain",
        "-l",
        "-t",
        "--encoding=UTF-8",
    ]);
    if options.ignore_whitespaces {
        command.arg("-w");
    }
    match options.movement {
        BlameMovement::None => {}
        BlameMovement::Inner => {
            command.arg("-M");
        }
        BlameMovement::Outer => {
            command.arg("-C");
        }
    }
    if let Some(revision) = revision {
        command.arg(revision);
    }
    let output =
        command
            .args(["--", path])
            .output()
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot start git blame: {error}"),
            })?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(EngineError::GitOperation {
            message: if detail.is_empty() {
                "git blame failed".into()
            } else {
                format!("git blame failed: {detail}")
            },
        });
    }

    parse_porcelain_blame(path, &output.stdout, options.prefer_commit_date)
}

struct RawWorktreeBlameLine {
    line: u32,
    commit_id: String,
    author: String,
    author_time: i64,
    committer_time: i64,
    summary: String,
    text: String,
}

fn parse_porcelain_blame(
    path: &str,
    bytes: &[u8],
    prefer_commit_date: bool,
) -> Result<Vec<BlameLine>, EngineError> {
    let output = String::from_utf8_lossy(bytes);
    let mut iter = output.lines();
    let mut raw = Vec::new();

    while let Some(header) = iter.next() {
        let mut fields = header.split_whitespace();
        let commit_id = fields
            .next()
            .map(|value| value.trim_start_matches('^').to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| blame_parse_error("missing commit id"))?;
        let _original_line = fields
            .next()
            .and_then(|value| value.parse::<u32>().ok())
            .ok_or_else(|| blame_parse_error("missing original line number"))?;
        let line = fields
            .next()
            .and_then(|value| value.parse::<u32>().ok())
            .ok_or_else(|| blame_parse_error("missing final line number"))?;

        let mut author = String::new();
        let mut author_time = 0;
        let mut committer_time = 0;
        let mut summary = String::new();
        let text = loop {
            let metadata = iter
                .next()
                .ok_or_else(|| blame_parse_error("missing line content"))?;
            if let Some(text) = metadata.strip_prefix('\t') {
                break text.to_string();
            }
            if let Some(value) = metadata.strip_prefix("author ") {
                author = value.to_string();
            } else if let Some(value) = metadata.strip_prefix("author-time ") {
                author_time = value.parse::<i64>().unwrap_or_default();
            } else if let Some(value) = metadata.strip_prefix("committer-time ") {
                committer_time = value.parse::<i64>().unwrap_or_default();
            } else if let Some(value) = metadata.strip_prefix("summary ") {
                summary = value.to_string();
            }
        };

        raw.push(RawWorktreeBlameLine {
            line,
            commit_id,
            author,
            author_time,
            committer_time,
            summary,
            text,
        });
    }

    let content = raw
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let line_map = spec_for_path(path).map(|(language, query_src)| {
        let language = language.into();
        line_spans_for_content(content.as_bytes(), &language, &query_src)
    });

    Ok(raw
        .into_iter()
        .map(|line| {
            let short_id = line.commit_id.chars().take(7).collect();
            let highlights = line_map
                .as_ref()
                .and_then(|map| map.get(&line.line))
                .cloned()
                .unwrap_or_default();
            BlameLine {
                line: line.line,
                commit_id: line.commit_id,
                short_id,
                author: line.author,
                time: if prefer_commit_date {
                    line.committer_time
                } else {
                    line.author_time
                },
                summary: line.summary,
                text: line.text,
                highlights,
            }
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::{BlameMovement, BlameOptions};

    #[test]
    fn blame_options_match_intellij_defaults() {
        assert_eq!(BlameOptions::default().ignore_whitespaces, true);
        assert_eq!(BlameOptions::default().movement, BlameMovement::None);
        assert_eq!(BlameOptions::default().prefer_commit_date, false);
    }

    #[test]
    fn blame_options_are_independent() {
        let options = BlameOptions {
            ignore_whitespaces: false,
            movement: BlameMovement::Outer,
            prefer_commit_date: true,
        };
        assert!(!options.ignore_whitespaces);
        assert_eq!(options.movement, BlameMovement::Outer);
        assert!(options.prefer_commit_date);
    }
}

fn blame_parse_error(detail: &str) -> EngineError {
    EngineError::GitOperation {
        message: format!("invalid git blame porcelain output: {detail}"),
    }
}

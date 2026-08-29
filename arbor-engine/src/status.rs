//! status 的 FFI 数据模型与 gix -> FFI 映射。
//!
//! 双维度模型（IntelliJ 忠实）：每个文件一条 FileEntry，staged 与 unstaged 各占一维。
//! gix 的 status 迭代器同时产出 TreeIndex（staged）与 IndexWorktree（unstaged/untracked）
//! 两类 item，按 path 合并成一条。

use crate::error::EngineError;

/// 单个维度的变更种类（staged 或 unstaged）。
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum ChangeKind {
    Unchanged,
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    TypeChanged,
    Untracked,
    Ignored,
    Conflicted,
}

/// 一个文件的状态条目：路径 + staged 维度 + unstaged 维度。
#[derive(uniffi::Record, Clone, PartialEq, Eq, Debug)]
pub struct FileEntry {
    pub path: String,
    /// Rename/copy 的来源路径。Git porcelain `-z` 会把它作为下一段
    /// NUL 字段返回；保留它才能复刻 IntelliJ `GitFileStatus.origPath`。
    pub old_path: Option<String>,
    pub staged: ChangeKind,
    pub unstaged: ChangeKind,
}

/// ignored 路径命中的规则来源。路径和 pattern 保留 Git 的原始值，
/// UI 可以明确解释它为什么没有出现在 Changes 中。
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum IgnoreRuleSource {
    Gitignore,
    InfoExclude,
    Global,
    Other,
}

#[derive(uniffi::Record, Clone, PartialEq, Eq, Debug)]
pub struct IgnoreRuleInfo {
    pub path: String,
    pub source: IgnoreRuleSource,
    pub source_path: String,
    pub line: u32,
    pub pattern: String,
}

/// 计算工作区状态（staged + unstaged + untracked，按 path 排序）。
/// Repository::status() 与未提交变更保护共用。
pub(crate) fn compute_status(repo: &gix::Repository) -> Result<Vec<FileEntry>, EngineError> {
    // Git itself is the authority for checkout/pull protection. Using the
    // same porcelain status here prevents the UI from saying "clean" while
    // `git switch` still sees an index/worktree difference (notably with
    // filters, line endings, file modes, or skip-worktree entries).
    compute_status_git(repo, &[])
}

/// 使用 Git 的 pathspec 状态查询为单文件/目录刷新提供真正的增量边界。
pub(crate) fn compute_status_paths(
    repo: &gix::Repository,
    paths: &[String],
) -> Result<Vec<FileEntry>, EngineError> {
    compute_status_git(repo, paths)
}

fn compute_status_git(
    repo: &gix::Repository,
    paths: &[String],
) -> Result<Vec<FileEntry>, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "status requires a non-bare worktree".into(),
    })?;
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args([
        "status",
        "--ignored",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--",
    ]);
    for path in paths {
        if path.is_empty() || path.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "status path must not be empty or start with '-'".into(),
            });
        }
        command.arg(path);
    }
    let output = command
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git status failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    let mut entries = std::collections::BTreeMap::<String, FileEntry>::new();
    let records: Vec<&[u8]> = output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .collect();
    let mut index = 0;
    while index < records.len() {
        let record = records[index];
        if record.len() < 4 {
            index += 1;
            continue;
        }
        // '?' and '!' are worktree-only states. Treating them as staged
        // changes would make untracked/ignored files incorrectly block pull.
        let mut staged = if matches!(record[0], b'?' | b'!') {
            ChangeKind::Unchanged
        } else {
            map_porcelain_kind(record[0])
        };
        let mut unstaged = map_porcelain_kind(record[1]);
        // AA / DD（双方都新增/删除，内容不同）是 git 语义的冲突条目：
        // 归一为 Conflicted，冲突工作台/恢复状态机才能识别二进制冲突。
        if matches!((record[0], record[1]), (b'A', b'A') | (b'D', b'D')) {
            staged = ChangeKind::Conflicted;
            unstaged = ChangeKind::Conflicted;
        }
        let path = String::from_utf8_lossy(&record[3..]).into_owned();
        let old_path = if matches!(record[0], b'R' | b'C') || matches!(record[1], b'R' | b'C') {
            records
                .get(index + 1)
                .map(|old| String::from_utf8_lossy(old).into_owned())
        } else {
            None
        };
        entries.insert(
            path.clone(),
            FileEntry {
                path,
                old_path,
                staged,
                unstaged,
            },
        );
        // With -z, rename/copy records carry the old path as the following
        // NUL field. The new path (the record above) is the user-visible one.
        if matches!(record[0], b'R' | b'C') || matches!(record[1], b'R' | b'C') {
            index += 1;
        }
        index += 1;
    }
    Ok(entries.into_values().collect())
}

fn map_porcelain_kind(code: u8) -> ChangeKind {
    match code {
        b' ' => ChangeKind::Unchanged,
        b'M' => ChangeKind::Modified,
        b'A' => ChangeKind::Added,
        b'D' => ChangeKind::Deleted,
        b'R' => ChangeKind::Renamed,
        b'C' => ChangeKind::Copied,
        b'T' => ChangeKind::TypeChanged,
        b'U' => ChangeKind::Conflicted,
        b'?' => ChangeKind::Untracked,
        b'!' => ChangeKind::Ignored,
        _ => ChangeKind::Unchanged,
    }
}

/// Return ignored paths using Git's stable porcelain format. This is a small
/// compatibility bridge: gix exposes the normal status stream, but does not
/// currently expose ignored entries in that stream.
fn ignored_paths(repo: &gix::Repository) -> Result<Vec<String>, EngineError> {
    let Some(workdir) = repo.workdir() else {
        return Ok(Vec::new());
    };

    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args([
            "status",
            "--ignored",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
        ])
        .current_dir(workdir)
        .output()
        .map_err(|e| EngineError::GitOperation {
            message: format!("failed to inspect ignored paths: {e}"),
        })?;

    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git status --ignored failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }

    Ok(output
        .stdout
        .split(|byte| *byte == 0)
        .filter_map(|record| {
            record
                .strip_prefix(b"!! ")
                .or_else(|| record.strip_prefix(b"!!\t"))
        })
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .collect())
}

/// 返回每个 ignored 路径命中的第一条规则，等价于 `git check-ignore -v`。
/// 每条路径单独查询，避免 `-z` 输出在不同 Git 版本中的字段布局差异。
pub(crate) fn ignored_rule_info(
    repo: &gix::Repository,
) -> Result<Vec<IgnoreRuleInfo>, EngineError> {
    let Some(workdir) = repo.workdir() else {
        return Ok(Vec::new());
    };
    let paths = ignored_paths(repo)?;
    let mut result = Vec::new();
    for path in paths {
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["check-ignore", "-v", "--no-index", "--", path.as_str()])
            .current_dir(workdir)
            .output()
            .map_err(|error| EngineError::GitOperation {
                message: format!("failed to inspect ignore rule for {path}: {error}"),
            })?;
        if !output.status.success() {
            continue;
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let Some(record) = text.lines().next() else {
            continue;
        };
        let Some((metadata, _matched_path)) = record.split_once('\t') else {
            continue;
        };
        let fields: Vec<&str> = metadata.splitn(3, ':').collect();
        if fields.len() != 3 {
            continue;
        }
        let line = fields[1].parse::<u32>().unwrap_or(0);
        let source_path = fields[0].to_string();
        let source = if source_path.ends_with(".gitignore") {
            IgnoreRuleSource::Gitignore
        } else if source_path.ends_with(".git/info/exclude") {
            IgnoreRuleSource::InfoExclude
        } else if source_path.contains("exclude") || source_path.contains("ignore") {
            IgnoreRuleSource::Global
        } else {
            IgnoreRuleSource::Other
        };
        result.push(IgnoreRuleInfo {
            path,
            source,
            source_path,
            line,
            pattern: fields[2].to_string(),
        });
    }
    Ok(result)
}

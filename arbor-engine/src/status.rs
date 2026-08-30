//! status 的 FFI 数据模型与 gix -> FFI 映射。
//!
//! 双维度模型（IntelliJ 忠实）：每个文件一条 FileEntry，staged 与 unstaged 各占一维。
//! gix 的 status 迭代器同时产出 TreeIndex（staged）与 IndexWorktree（unstaged/untracked）
//! 两类 item，按 path 合并成一条。

use crate::error::EngineError;
use std::path::Path;

// Keep ordinary ignored directories file-visible, but never recursively walk
// a build product or IDE metadata directory during a status refresh.
const MAX_IGNORED_DIRECTORY_ENTRIES: usize = 2_048;

fn is_generated_directory_name(name: &str) -> bool {
    name == ".build"
        || name.starts_with(".build")
        || matches!(
            name,
            ".gradle" | ".swiftpm" | "DerivedData" | "target" | "xcuserdata"
        )
}

fn is_generated_status_path(path: &str) -> bool {
    Path::new(path.trim_end_matches('/'))
        .components()
        .any(|component| {
            component
                .as_os_str()
                .to_str()
                .map(is_generated_directory_name)
                .unwrap_or(false)
        })
}

fn ignored_directory_is_small(workdir: &Path, relative_path: &str) -> bool {
    let mut pending = vec![workdir.join(relative_path.trim_end_matches('/'))];
    let mut count = 0;
    while let Some(directory) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(directory) else {
            return false;
        };
        for entry in entries {
            let Ok(entry) = entry else { return false };
            count += 1;
            if count > MAX_IGNORED_DIRECTORY_ENTRIES {
                return false;
            }
            let Ok(file_type) = entry.file_type() else {
                return false;
            };
            if file_type.is_dir() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if is_generated_directory_name(&name) {
                    return false;
                }
                pending.push(entry.path());
            }
        }
    }
    true
}

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
        // Matching mode collapses ignored directories, avoiding an expensive
        // recursive walk of build products. Ordinary small ignored directories
        // are expanded below to preserve the existing UI contract.
        "--ignored=matching",
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
    let mut entries = parse_status_output(&output.stdout);
    if paths.is_empty() {
        let ignored_directories: Vec<String> = entries
            .values()
            .filter(|entry| {
                entry.unstaged == ChangeKind::Ignored
                    && entry.path.ends_with('/')
                    && !is_generated_status_path(&entry.path)
            })
            .map(|entry| entry.path.clone())
            .collect();
        for directory in ignored_directories {
            if !ignored_directory_is_small(workdir, &directory) {
                continue;
            }
            let mut expansion = crate::gitprocess::git_command_for_working_dir(workdir);
            expansion.args([
                "status",
                "--ignored",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                directory.as_str(),
            ]);
            let Ok(expanded) = expansion.current_dir(workdir).output() else {
                continue;
            };
            if !expanded.status.success() {
                continue;
            }
            let ignored_entries = parse_status_output(&expanded.stdout)
                .into_values()
                .filter(|entry| entry.unstaged == ChangeKind::Ignored)
                .collect::<Vec<_>>();
            if ignored_entries.is_empty() {
                continue;
            }
            entries.remove(&directory);
            for entry in ignored_entries {
                entries.insert(entry.path.clone(), entry);
            }
        }
    }
    Ok(entries.into_values().collect())
}

fn parse_status_output(stdout: &[u8]) -> std::collections::BTreeMap<String, FileEntry> {
    let mut entries = std::collections::BTreeMap::<String, FileEntry>::new();
    let records: Vec<&[u8]> = stdout
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
    entries
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
fn ignored_paths(workdir: &Path) -> Result<Vec<String>, EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args([
            "status",
            "--ignored=matching",
            "--porcelain=v1",
            "-z",
            "--untracked-files=normal",
            "--",
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
pub(crate) fn ignored_rule_info(workdir: &Path) -> Result<Vec<IgnoreRuleInfo>, EngineError> {
    let paths = ignored_paths(workdir)?;
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

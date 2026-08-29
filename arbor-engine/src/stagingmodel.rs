//! IDX-001：三层 staging 模型（HEAD / index / worktree）+ index tracker。
//!
//! - `StagingModel`：每个变更文件的层级状态（has_staged / has_unstaged）、
//!   二进制/子模块标记、assume-unchanged / skip-worktree / intent-to-add
//!   标志，以及 index 修订（tracker 数据源）；
//! - `index_changed_since`：检测外部 Git 对 index 的修改（mtime + size），
//!   UI 据此增量刷新而不是全量猜测；
//! - 二进制与子模块在模型层给出明确降级标记，diff/staging 共用同一事实。

use std::path::{Path, PathBuf};

use crate::error::EngineError;
use crate::status::ChangeKind;
use gix::bstr::{BStr, ByteSlice};

/// 单个文件的三层状态分类（staged/unstaged 合成）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum StagingStatus {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    TypeChanged,
    Conflicted,
    Untracked,
    Unchanged,
}

/// 一个变更文件的完整 staging 信息。
#[derive(uniffi::Record, Clone, Debug)]
pub struct StagingEntry {
    pub path: String,
    /// Rename/copy 的来源路径，对齐 IntelliJ `GitFileStatus.origPath`。
    pub old_path: Option<String>,
    /// HEAD 版本是否存在（rename 时按 old_path 解析）。
    pub head_present: bool,
    /// index/staged 版本是否存在；staged deletion 为 false。
    pub staged_present: bool,
    /// 当前 worktree/local 版本是否存在；本地删除为 false。
    pub local_present: bool,
    pub status: StagingStatus,
    /// index 与 HEAD 不同（已暂存）。
    pub has_staged: bool,
    /// worktree 与 index 不同（未暂存）。
    pub has_unstaged: bool,
    /// 任一侧内容是二进制：diff/staging 按降级策略处理。
    pub binary: bool,
    /// `git update-index --assume-unchanged`。
    pub assume_unchanged: bool,
    /// `git update-index --skip-worktree`。
    pub skip_worktree: bool,
    /// `git add -N`（intent-to-add）。
    pub intent_to_add: bool,
    /// index 条目是 submodule commit。
    pub is_submodule: bool,
}

/// index 文件修订（mtime ns + size）；外部 Git 写入会同时改变两者。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct IndexRevision {
    pub mtime_ns: u64,
    pub size: u64,
}

/// 单文件三层 diff：未暂存 + 已暂存（任一侧二进制时 binary=true，hunks 空）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct StagingFileDiff {
    pub path: String,
    pub unstaged: Option<crate::diff::FileDiff>,
    pub staged: Option<crate::diff::FileDiff>,
}

/// 全量 staging 模型。
#[derive(uniffi::Record, Clone, Debug)]
pub struct StagingModel {
    pub entries: Vec<StagingEntry>,
    pub index_revision: IndexRevision,
}

/// 构建三层模型。`status` 由调用方传入（避免重复计算）。
pub(crate) fn build_model(
    repo: &gix::Repository,
    status: &[crate::status::FileEntry],
) -> Result<StagingModel, EngineError> {
    let index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();

    let mut entries: Vec<StagingEntry> = Vec::with_capacity(status.len() + 8);
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for entry in status {
        let path_bstr = entry.path.as_bytes().as_bstr();
        let (has_staged, has_unstaged) = match (entry.staged, entry.unstaged) {
            (ChangeKind::Unchanged, ChangeKind::Unchanged) | (ChangeKind::Ignored, _) => {
                (false, false)
            }
            (staged, unstaged) => (
                staged != ChangeKind::Unchanged,
                unstaged != ChangeKind::Unchanged,
            ),
        };
        let index_entry = index.entry_by_path(path_bstr);
        let flags = index_entry
            .map(|e| e.flags)
            .unwrap_or(gix::index::entry::Flags::empty());
        let is_submodule = index_entry
            .map(|e| e.mode.contains(gix::index::entry::Mode::COMMIT))
            .unwrap_or(false);
        let binary = detect_binary(repo, &index, &entry.path, has_staged, has_unstaged);
        let (head_present, staged_present, local_present) = version_presence(repo, &index, entry);
        seen.insert(entry.path.clone());
        entries.push(StagingEntry {
            path: entry.path.clone(),
            old_path: entry.old_path.clone(),
            head_present,
            staged_present,
            local_present,
            status: classify(entry.staged, entry.unstaged),
            has_staged,
            has_unstaged,
            binary,
            assume_unchanged: flags.contains(gix::index::entry::Flags::ASSUME_VALID),
            skip_worktree: flags.contains(gix::index::entry::Flags::SKIP_WORKTREE),
            intent_to_add: flags.contains(gix::index::entry::Flags::INTENT_TO_ADD),
            is_submodule,
        });
    }
    // assume-unchanged / skip-worktree 的文件会被 status 隐藏,但 IDX-001
    // 要求明确展示:扫描 index 特殊标志条目补进模型(状态为 Unchanged)。
    for index_entry in index.entries() {
        let path = index_entry.path(&index).to_string();
        if seen.contains(&path) {
            continue;
        }
        let special = index_entry
            .flags
            .contains(gix::index::entry::Flags::ASSUME_VALID)
            || index_entry
                .flags
                .contains(gix::index::entry::Flags::SKIP_WORKTREE)
            || index_entry
                .flags
                .contains(gix::index::entry::Flags::INTENT_TO_ADD);
        if !special {
            continue;
        }
        let synthetic = crate::status::FileEntry {
            path: path.clone(),
            old_path: None,
            staged: ChangeKind::Unchanged,
            unstaged: ChangeKind::Unchanged,
        };
        let (head_present, staged_present, local_present) =
            version_presence(repo, &index, &synthetic);
        entries.push(StagingEntry {
            path,
            old_path: None,
            head_present,
            staged_present,
            local_present,
            status: StagingStatus::Unchanged,
            has_staged: false,
            has_unstaged: false,
            binary: false,
            assume_unchanged: index_entry
                .flags
                .contains(gix::index::entry::Flags::ASSUME_VALID),
            skip_worktree: index_entry
                .flags
                .contains(gix::index::entry::Flags::SKIP_WORKTREE),
            intent_to_add: index_entry
                .flags
                .contains(gix::index::entry::Flags::INTENT_TO_ADD),
            is_submodule: index_entry.mode.contains(gix::index::entry::Mode::COMMIT),
        });
    }
    Ok(StagingModel {
        entries,
        index_revision: index_revision_of(repo)?,
    })
}

/// IntelliJ `GitFileStatus.has(ContentVersion)` 的事实层投影。
///
/// 不能从 ChangeKind 单独推断版本是否存在：例如 staged deletion 的 index
/// 侧为空、rename 的 HEAD 侧仍使用 old_path，而 intent-to-add 具有 index
/// 条目但不应把 HEAD 误报为存在。
fn version_presence(
    repo: &gix::Repository,
    index: &gix::index::File,
    entry: &crate::status::FileEntry,
) -> (bool, bool, bool) {
    let index_entry = index.entry_by_path(entry.path.as_bytes().as_bstr());
    let index_flags = index_entry
        .map(|value| value.flags)
        .unwrap_or(gix::index::entry::Flags::empty());
    let staged_present = index_entry.is_some()
        && entry.staged != ChangeKind::Deleted
        && entry.staged != ChangeKind::Conflicted;

    let head_present = [Some(entry.path.as_str()), entry.old_path.as_deref()]
        .into_iter()
        .flatten()
        .any(|path| {
            let spec = format!("HEAD:{path}");
            repo.rev_parse_single(BStr::new(spec.as_bytes())).is_ok()
        })
        && !index_flags.contains(gix::index::entry::Flags::INTENT_TO_ADD)
        && entry.staged != ChangeKind::Added
        && entry.staged != ChangeKind::Untracked;

    let local_present = repo
        .workdir()
        .map(|workdir| std::fs::symlink_metadata(workdir.join(&entry.path)).is_ok())
        .unwrap_or(false);

    (head_present, staged_present, local_present)
}

fn classify(staged: ChangeKind, unstaged: ChangeKind) -> StagingStatus {
    let primary = if staged != ChangeKind::Unchanged {
        staged
    } else {
        unstaged
    };
    match primary {
        ChangeKind::Unchanged => StagingStatus::Unchanged,
        ChangeKind::Added => StagingStatus::Added,
        ChangeKind::Modified => StagingStatus::Modified,
        ChangeKind::Deleted => StagingStatus::Deleted,
        ChangeKind::Renamed => StagingStatus::Renamed,
        ChangeKind::Copied => StagingStatus::Copied,
        ChangeKind::TypeChanged => StagingStatus::TypeChanged,
        ChangeKind::Conflicted => StagingStatus::Conflicted,
        ChangeKind::Untracked => StagingStatus::Untracked,
        ChangeKind::Ignored => StagingStatus::Unchanged,
    }
}

/// 二进制判定（降级策略的数据源）：任一侧存在且含 NUL 即视为二进制；
/// 删除场景两侧都缺失时取 index blob。
fn detect_binary(
    repo: &gix::Repository,
    index: &gix::index::File,
    path: &str,
    has_staged: bool,
    has_unstaged: bool,
) -> bool {
    let workdir = repo.workdir();
    let file_path = workdir.map(|w| w.join(path));
    let worktree_bytes = file_path.as_deref().and_then(|p| std::fs::read(p).ok());
    if let Some(bytes) = &worktree_bytes {
        if crate::diff::is_binary(bytes) {
            return true;
        }
    }
    let index_id = index.entry_by_path(path.as_bytes().as_bstr()).map(|e| e.id);
    if let Some(id) = index_id {
        if blob_is_binary(repo, id) {
            return true;
        }
    }
    // staged 变更时比较 HEAD 侧（tree 查找二进制标记）
    if has_staged && !has_unstaged {
        if let Ok(head_id) = repo.head_tree_id_or_empty() {
            if let Ok(tree) = repo.find_tree(head_id) {
                let head_is_binary =
                    gix::objs::TreeRefIter::from_bytes(&tree.data, repo.object_hash())
                        .filter_map(Result::ok)
                        .any(|entry| {
                            entry.filename.as_bstr() == path.as_bytes().as_bstr()
                                && blob_is_binary(repo, entry.oid.to_owned())
                        });
                if head_is_binary {
                    return true;
                }
            }
        }
    }
    false
}

fn blob_is_binary(repo: &gix::Repository, id: gix::hash::ObjectId) -> bool {
    repo.find_blob(id)
        .map(|blob| crate::diff::is_binary(&blob.data))
        .unwrap_or(false)
}

/// 读取 `.git/index` 的修订（mtime ns + size）。
pub(crate) fn index_revision_of(repo: &gix::Repository) -> Result<IndexRevision, EngineError> {
    use std::os::unix::fs::MetadataExt;
    let path = repo.git_dir().join("index");
    match std::fs::metadata(&path) {
        Ok(meta) => Ok(IndexRevision {
            // macOS 的 MetadataExt 无 mtime_ns(那是 Linux API):秒+纳秒合成
            mtime_ns: (meta.mtime() * 1_000_000_000 + meta.mtime_nsec()) as u64,
            size: meta.len(),
        }),
        Err(_) => Ok(IndexRevision {
            mtime_ns: 0,
            size: 0,
        }),
    }
}

/// 外部 Git 是否改写了 index（mtime 或 size 变化）。
/// 引擎自身的 gix 写入也会反映在这里，UI 以「上次看到的值」为基准即可。
pub(crate) fn index_changed_since(
    repo: &gix::Repository,
    previous: &IndexRevision,
) -> Result<bool, EngineError> {
    Ok(index_revision_of(repo)? != *previous)
}

/// 追加一条 ignore 规则到 `.gitignore`（不存在则创建）。
/// 校验：非空、单行。返回实际写入的规则文本。
pub(crate) fn append_gitignore(repo: &gix::Repository, rule: &str) -> Result<String, EngineError> {
    let rules = append_gitignore_rules(repo, &[rule.to_string()])?;
    Ok(rules
        .into_iter()
        .next()
        .expect("one normalized ignore rule"))
}

pub(crate) fn append_gitignore_rules(
    repo: &gix::Repository,
    rules: &[String],
) -> Result<Vec<String>, EngineError> {
    if rules.is_empty() {
        return Err(EngineError::GitOperation {
            message: "ignore rules must not be empty".into(),
        });
    }
    let rules = rules
        .iter()
        .map(|rule| normalize_rule(rule))
        .collect::<Result<Vec<_>, _>>()?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "gitignore requires a non-bare worktree".into(),
    })?;
    append_rules(&workdir.join(".gitignore"), &rules)?;
    Ok(rules)
}

/// Append a rule to a selected or newly-created `.gitignore` for a specific
/// target. The file must live inside this worktree and its directory must
/// contain the target path, matching IntelliJ's suitable-ignore-file ancestry
/// rule.
pub(crate) fn append_gitignore_at(
    repo: &gix::Repository,
    rule: &str,
    ignore_file: &str,
    target_path: &str,
) -> Result<String, EngineError> {
    let rules = vec![rule.to_string()];
    let target_paths = vec![target_path.to_string()];
    let mut rules = append_gitignore_rules_at(repo, &rules, ignore_file, &target_paths)?;
    Ok(rules.remove(0))
}

/// Append several rules to one suitable `.gitignore` after validating every
/// target first. This is the multi-selection counterpart of
/// `append_gitignore_at` and keeps a single ignore-file choice for all paths.
pub(crate) fn append_gitignore_rules_at(
    repo: &gix::Repository,
    rules: &[String],
    ignore_file: &str,
    target_paths: &[String],
) -> Result<Vec<String>, EngineError> {
    if rules.is_empty() || rules.len() != target_paths.len() {
        return Err(EngineError::GitOperation {
            message: "ignore rules and target paths must have the same non-zero length".into(),
        });
    }
    let rules = rules
        .iter()
        .map(|rule| normalize_rule(rule))
        .collect::<Result<Vec<_>, _>>()?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "gitignore requires a non-bare worktree".into(),
    })?;
    let workdir = workdir.canonicalize().map_err(EngineError::from_gix)?;
    let requested_ignore_path = resolve_worktree_path(&workdir, ignore_file);
    let ignore_parent = requested_ignore_path
        .parent()
        .ok_or_else(|| EngineError::GitOperation {
            message: "ignore file has no parent directory".into(),
        })?
        .canonicalize()
        .map_err(|_| EngineError::GitOperation {
            message: format!("path does not exist: {}", requested_ignore_path.display()),
        })?;
    let ignore_path = if requested_ignore_path.exists() {
        requested_ignore_path
            .canonicalize()
            .map_err(EngineError::from_gix)?
    } else {
        ignore_parent.join(".gitignore")
    };
    let valid_name = Path::new(ignore_file)
        .file_name()
        .and_then(|name| name.to_str())
        == Some(".gitignore");
    let ignore_scope_parent = ignore_path
        .parent()
        .ok_or_else(|| EngineError::GitOperation {
            message: "ignore file has no parent directory".into(),
        })?;
    let targets = target_paths
        .iter()
        .map(|target_path| resolve_existing_worktree_path(&workdir, target_path))
        .collect::<Result<Vec<_>, _>>()?;
    let valid_scope = targets.iter().all(|target| {
        let target_parent = if target.is_dir() {
            target.as_path()
        } else {
            match target.parent() {
                Some(parent) => parent,
                None => return false,
            }
        };
        target.starts_with(&workdir) && target_parent.starts_with(ignore_scope_parent)
    });
    if !valid_name
        || !ignore_path.starts_with(&workdir)
        || !valid_scope
        || (ignore_path.exists() && !ignore_path.is_file())
    {
        return Err(EngineError::GitOperation {
            message: "selected .gitignore is not suitable for the target path".into(),
        });
    }
    if !ignore_path.exists() {
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&ignore_path)
            .map_err(EngineError::from_gix)?;
    }
    append_rules(&ignore_path, &rules)?;
    Ok(rules)
}

/// 追加一条规则到 `.git/info/exclude`（仓库本地、不入库）。
pub(crate) fn append_info_exclude(
    repo: &gix::Repository,
    rule: &str,
) -> Result<String, EngineError> {
    let rule = normalize_rule(rule)?;
    let path = repo.git_dir().join("info").join("exclude");
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(EngineError::from_gix)?;
    }
    append_rule(&path, &rule)?;
    Ok(rule)
}

fn normalize_rule(rule: &str) -> Result<String, EngineError> {
    let rule = rule.trim();
    if rule.is_empty() || rule.contains('\n') {
        return Err(EngineError::GitOperation {
            message: "ignore rule must be a single non-empty line".into(),
        });
    }
    // 去掉以 `/` 结尾的目录写法差异：保持原样追加即可，git 自己解释。
    Ok(rule.to_string())
}

fn resolve_existing_worktree_path(workdir: &Path, input: &str) -> Result<PathBuf, EngineError> {
    resolve_worktree_path(workdir, input)
        .canonicalize()
        .map_err(|_| EngineError::GitOperation {
            message: format!("path does not exist: {input}"),
        })
}

fn resolve_worktree_path(workdir: &Path, input: &str) -> PathBuf {
    let input_path = Path::new(input);
    if input_path.is_absolute() {
        input_path.to_path_buf()
    } else {
        workdir.join(input_path)
    }
}

fn append_rule(path: &Path, rule: &str) -> Result<(), EngineError> {
    append_rules(path, &[rule.to_string()])
}

fn append_rules(path: &Path, rules: &[String]) -> Result<(), EngineError> {
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let mut text = existing;
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    for rule in rules {
        text.push_str(rule);
        text.push('\n');
    }
    std::fs::write(path, text).map_err(EngineError::from_gix)
}

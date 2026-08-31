//! REPO-001：多 Git root 发现与嵌套仓库策略。
//!
//! 给定项目目录：
//! 1. 若目录本身位于某个 git 仓库内，向上发现该仓库作为第一个 root；
//! 2. 在 root 内做有界扫描，发现嵌套 git 仓库（子目录含 `.git`）；
//! 3. 嵌套仓库若登记在父仓库 `.gitmodules` 中标记为 submodule，
//!    否则是独立嵌套仓库（IntelliJ 语义）；
//! 4. 每个 root 附带 HEAD、dirty 状态与进行中操作，UI 可展示部分成功/
//!    部分失败与待处理 root。
//!
//! 嵌套仓库永远作为独立 root 报告，不会被父仓库当成普通文件吞掉。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use regex::Regex;

use crate::branch::{BranchInfo, RemoteBranchInfo, SyncStatus, TagInfo};
use crate::error::EngineError;
use crate::merge::MergeOptions;
use crate::opstate::{self, OperationKind};
use crate::remote::RemoteInfo;
use crate::repo::{
    ForcePushedBranchUpdateOutcome, LocalChangesSavePolicy, ResetMode, ResetRecoveryTarget,
    WorktreeInfo,
};
use crate::shelve::ShelveInfo;
use crate::stash::StashInfo;

/// 扫描时跳过的目录（构建产物/依赖缓存，不可能有有意义的 git root）。
const SKIP_DIRS: [&str; 9] = [
    "node_modules",
    "target",
    "build",
    "dist",
    ".build",
    "DerivedData",
    ".venv",
    "venv",
    "__pycache__",
];

/// 默认扫描深度（root 之下）。
const DEFAULT_MAX_DEPTH: u32 = 6;

/// 发现的一个 git root。
#[derive(uniffi::Record, Clone, Debug)]
pub struct GitRootInfo {
    /// 工作区绝对路径。
    pub path: String,
    /// 显示名（目录 basename）。
    pub display_name: String,
    /// 相对扫描根的路径（扫描根本身为 "."）。
    pub relative_path: String,
    /// 是否登记在父仓库 .gitmodules 中。
    pub is_submodule: bool,
    /// 当前分支名（detached HEAD 为 None）。
    pub head_branch: Option<String>,
    /// HEAD 提交（无提交时 None）。
    pub head_id: Option<String>,
    /// 工作区或索引是否有变更。
    pub dirty: bool,
    /// 进行中的操作（merge/rebase/…）。
    pub operation: Option<OperationKind>,
}

/// 发现项目下的 git roots。`scan_root` 可以是仓库内任意目录：
/// 先向上发现所属仓库，再向下扫描嵌套仓库。
#[uniffi::export]
pub fn discover_git_roots(
    scan_root: String,
    max_depth: Option<u32>,
) -> Result<Vec<GitRootInfo>, EngineError> {
    let scan_root = Path::new(&scan_root);
    // macOS 上 UI 传入的 /var/... 与 gix 返回的 /private/var/... 不一致,
    // 统一 canonicalize 后再比较/剥离前缀。
    let scan_root: PathBuf =
        std::fs::canonicalize(scan_root).unwrap_or_else(|_| scan_root.to_path_buf());
    let scan_root = scan_root.as_path();
    if !scan_root.is_dir() {
        return Err(EngineError::GitOperation {
            message: format!(
                "discover_git_roots: not a directory: {}",
                scan_root.display()
            ),
        });
    }
    let max_depth = max_depth.unwrap_or(DEFAULT_MAX_DEPTH);

    // 1. 向上发现所在仓库（没有也不算错：项目可能只是还没 init）。
    let base: Option<PathBuf> = match gix::discover(scan_root) {
        Ok(repo) => repo.workdir().map(Path::to_path_buf),
        Err(_) => None,
    };

    let mut roots: Vec<GitRootInfo> = Vec::new();
    let outer = match &base {
        Some(workdir) => {
            let info = root_info(workdir, scan_root, None)?;
            roots.push(info);
            workdir.clone()
        }
        None => scan_root.to_path_buf(),
    };

    // 2. 有界向下扫描嵌套仓库（root 自身若是裸仓库则无 workdir，跳过）。
    let mut nested: Vec<PathBuf> = Vec::new();
    scan_nested(&outer, 0, max_depth, &mut nested);
    let mut all_paths = Vec::with_capacity(nested.len() + 1);
    all_paths.push(outer.clone());
    all_paths.extend(nested.iter().cloned());
    for path in nested {
        let is_submodule = nearest_submodule_parent(&all_paths, &path).is_some();
        let info = root_info(&path, scan_root, Some(is_submodule))?;
        roots.push(info);
    }
    Ok(roots)
}

/// 递归扫描嵌套 .git（目录或 gitfile）。嵌套仓库本身仍是一个 root，
/// 但要继续扫描其工作区，以发现更深层的 submodule。
fn scan_nested(dir: &Path, depth: u32, max_depth: u32, found: &mut Vec<PathBuf>) {
    if depth >= max_depth {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        // 隐藏目录（含 .git）不递归；其他隐藏目录保守跳过。
        if name.starts_with('.') {
            continue;
        }
        if SKIP_DIRS.contains(&name) {
            continue;
        }
        if !path.is_dir() {
            continue;
        }
        if path.join(".git").exists() {
            // 记录后继续下探：IntelliJ 会把嵌套 submodule 作为独立 root
            // 纳入 Update Project，而不是因祖先 root 的存在而吞掉它。
            found.push(path.clone());
            scan_nested(&path, depth + 1, max_depth, found);
            continue;
        }
        scan_nested(&path, depth + 1, max_depth, found);
    }
}

/// 读取父仓库 .gitmodules 中登记的子模块路径（绝对化后比较）。
fn parent_submodule_paths(parent: &Path) -> Vec<PathBuf> {
    let text = std::fs::read_to_string(parent.join(".gitmodules")).unwrap_or_default();
    let mut paths = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.trim().strip_prefix("path =") {
            let value = value.trim();
            if !value.is_empty() {
                paths.push(parent.join(value));
            }
        }
    }
    paths
}

/// 返回登记当前 root 的最近父仓库。只用于发现阶段的 submodule 标记；
/// 更新阶段仍通过 gix 的 submodule 列表确认 gitlink，避免把普通嵌套仓库
/// 误当成 submodule。
fn nearest_submodule_parent(roots: &[PathBuf], root: &Path) -> Option<PathBuf> {
    let mut candidates = roots
        .iter()
        .filter(|candidate| candidate.as_path() != root && root.starts_with(candidate))
        .cloned()
        .collect::<Vec<_>>();
    candidates.sort_by_key(|candidate| candidate.components().count());
    candidates.into_iter().rev().find(|candidate| {
        parent_submodule_paths(candidate)
            .iter()
            .any(|path| path == root)
    })
}

/// 打开 root 收集 HEAD/dirty/operation 信息。
fn root_info(
    workdir: &Path,
    scan_root: &Path,
    is_submodule: Option<bool>,
) -> Result<GitRootInfo, EngineError> {
    let repo = gix::open(workdir).map_err(EngineError::from_gix)?;
    let head_branch = repo
        .head_ref()
        .ok()
        .flatten()
        .map(|r| r.name().shorten().to_string());
    let head_id = repo.head_commit().ok().map(|c| c.id().to_hex().to_string());
    let dirty = crate::status::compute_status(&repo)
        .map(|entries| {
            entries.iter().any(|e| {
                e.staged != crate::status::ChangeKind::Unchanged
                    || (e.unstaged != crate::status::ChangeKind::Unchanged
                        && e.unstaged != crate::status::ChangeKind::Ignored)
            })
        })
        .unwrap_or(false);
    let operation = opstate::detect(&repo)?.map(|state| state.kind);
    let display_name = workdir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| workdir.display().to_string());
    // 外层 root 位于扫描目录之上(仓库包含扫描点):相对项目根就是 "."。
    // 嵌套 root 在扫描目录之内:相对路径来自 strip_prefix。
    let relative_path = if scan_root.starts_with(workdir) {
        ".".to_string()
    } else {
        workdir
            .strip_prefix(scan_root)
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| workdir.display().to_string())
    };
    Ok(GitRootInfo {
        path: workdir.display().to_string(),
        display_name,
        relative_path,
        // 独立嵌套仓库在 .gitmodules 之外；外层 root 无该属性。
        is_submodule: is_submodule.unwrap_or(false),
        head_branch,
        head_id,
        dirty,
        operation,
    })
}

/// 一个 Git root 的分支快照。Branches Popup 的多 root 视图必须保留
/// root 边界，不能把同名分支错误合并成一个全局分支。
#[derive(uniffi::Record, Clone, Debug)]
pub struct GitRootBranchSnapshot {
    pub root_path: String,
    pub display_name: String,
    pub relative_path: String,
    pub head_branch: Option<String>,
    /// HEAD commit when resolvable. A detached HEAD still has this value;
    /// fresh/unborn repositories have no commit. The UI treats a missing
    /// value conservatively as unable to create a branch from HEAD.
    pub head_id: Option<String>,
    pub branches: Vec<BranchInfo>,
    pub remote_branches: Vec<RemoteBranchInfo>,
    pub remotes: Vec<RemoteInfo>,
    pub sync_statuses: Vec<SyncStatus>,
    pub recent_branches: Vec<String>,
    pub tags: Vec<TagInfo>,
    pub stashes: Vec<StashInfo>,
    /// Named shelves, including temporary shelves created by preserving
    /// processes. The UI uses this to reconstruct recovery after relaunch.
    pub shelves: Vec<ShelveInfo>,
    /// Linked worktrees, used by the branch popup to offer IntelliJ's
    /// "Open Worktree…" action for a branch checked out elsewhere.
    pub worktrees: Vec<WorktreeInfo>,
}

/// 返回项目下每个 Git root 独立的 Branches Popup 数据。
///
/// 分支、remote-tracking 分支和 upstream 状态都在各自 root 内计算；
/// 这样同名分支可以按仓库分组、过滤和执行 root 定向操作。
#[uniffi::export]
pub fn list_multi_root_branches(
    scan_root: String,
) -> Result<Vec<GitRootBranchSnapshot>, EngineError> {
    let roots = discover_git_roots(scan_root, None)?;
    let mut snapshots = Vec::with_capacity(roots.len());
    for root in roots {
        let repo = crate::repo::open_repository(root.path.clone())?;
        snapshots.push(GitRootBranchSnapshot {
            root_path: root.path,
            display_name: root.display_name,
            relative_path: root.relative_path,
            head_branch: root.head_branch,
            head_id: root.head_id,
            branches: repo.branch_list()?,
            remote_branches: repo.remote_branch_list()?,
            remotes: repo.remote_list()?,
            sync_statuses: repo.sync_status()?,
            recent_branches: repo.recent_branches(12)?,
            tags: repo.tag_list()?,
            stashes: repo.stash_list()?,
            shelves: repo.shelve_list()?,
            worktrees: repo.worktree_list()?,
        });
    }
    Ok(snapshots)
}

// MARK: REPO-001 多 root 调度

/// 聚合操作类别（对项目下每个 Git root 执行同一操作）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MultiRootOperation {
    /// 每个 root 拉取默认远程更新。
    Fetch,
    /// 每个 root pull（merge 模式）。
    PullMerge,
    /// 每个 root pull（rebase 模式）。
    PullRebase,
    /// 每个 root 推送当前分支。
    Push,
    /// 每个 root 提交已暂存变更（无暂存变更 -> Skipped）。
    Commit,
}

/// 单个 root 的操作结果。
#[derive(uniffi::Record, Clone, Debug)]
pub struct RootOperationResult {
    pub root_path: String,
    pub display_name: String,
    /// Success / Failed。
    pub success: bool,
    /// 跳过（无暂存变更、无远程等）。
    pub skipped: bool,
    /// 失败或跳过原因（结构化消息,UI 本地化）。
    pub message: String,
}

/// Protected branch patterns are scoped to the Git root that owns the push.
/// A project can contain several independent hosted repositories, so a single
/// project-wide list would either miss a root's remote rules or over-block a
/// similarly named branch in another root.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RootProtectedBranchPatterns {
    pub root_path: String,
    pub patterns: Vec<String>,
}

/// Push target selected for one Git root. The source is always that root's
/// current branch; the remote and target branch are independently editable.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootPushTarget {
    pub root_path: String,
    pub remote: String,
    pub target_branch: String,
}

/// The fetch-only first phase of Update Project. IntelliJ fetches all update
/// roots before deciding whether a rebase would replay a non-empty merge
/// commit; keeping the fetched paths lets the integration phase reuse those
/// refs instead of silently inspecting stale remote-tracking branches.
#[derive(uniffi::Record, Clone, Debug)]
pub struct UpdateProjectPreflight {
    pub results: Vec<RootOperationResult>,
    pub fetched_root_paths: Vec<String>,
    pub problematic_root_paths: Vec<String>,
}

/// One project-configured command that runs before each selected root commit.
/// Arguments are passed directly to the executable; no shell is involved.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct MultiRootCommitCheck {
    pub command: String,
    pub args: Vec<String>,
}

/// Commit options shared by every selected Git root.
///
/// Repository-local signing configuration is read from each root. The
/// author/committer fields are one-shot overrides, matching the single-root
/// Commit workspace.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootCommitOptions {
    pub skip_hooks: bool,
    pub author_name: Option<String>,
    pub author_email: Option<String>,
    pub committer_name: Option<String>,
    pub committer_email: Option<String>,
    pub sign_off: bool,
    pub co_authors: Vec<String>,
    pub amend: bool,
    pub run_before_commit_checks: bool,
    pub before_commit_commands: Vec<MultiRootCommitCheck>,
}

impl Default for MultiRootCommitOptions {
    fn default() -> Self {
        Self {
            skip_hooks: false,
            author_name: None,
            author_email: None,
            committer_name: None,
            committer_email: None,
            sign_off: false,
            co_authors: Vec::new(),
            amend: false,
            run_before_commit_checks: true,
            before_commit_commands: Vec::new(),
        }
    }
}

/// Root-qualified file selection for a Changes Browser selected commit.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootCommitSelection {
    pub root_path: String,
    pub paths: Vec<String>,
}

/// 一个多 root 新建分支操作的逐仓库结果。
///
/// `previous_*` 用于 IntelliJ 风格的部分失败回滚：创建并 checkout 时，
/// 回滚必须先恢复每个已成功 root 的原始 HEAD，再删除新分支。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootBranchResult {
    pub root_path: String,
    pub display_name: String,
    pub success: bool,
    pub skipped: bool,
    pub message: String,
    pub branch_created: bool,
    pub checked_out: bool,
    pub previous_branch: Option<String>,
    pub previous_head: Option<String>,
    /// Tip of the named branch before the operation. Present only when an
    /// existing branch was explicitly overwritten.
    pub previous_branch_tip: Option<String>,
    /// Tip of the named branch after the operation. Rollback verifies this
    /// before moving any ref, including when the branch was not checked out.
    pub expected_branch_tip: Option<String>,
}

/// 传给多 root 新建分支或 checkout 回滚入口的最小状态。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootBranchTarget {
    pub root_path: String,
    pub checked_out: bool,
    pub previous_branch: Option<String>,
    pub previous_head: Option<String>,
    /// HEAD and current branch immediately after the forward checkout. When
    /// populated, a checkout rollback must match both before it changes
    /// repository state; branch-create rollback at least verifies the branch.
    pub expected_head: Option<String>,
    pub expected_branch: Option<String>,
    /// checkout 远程分支时由 Git 创建的本地分支；普通已有分支 checkout 为 None。
    pub created_branch: Option<String>,
}

/// Multi-root branch creation rollback state. This is intentionally separate
/// from `MultiRootBranchTarget`, which is also used by checkout rollback and
/// must retain its original create/delete semantics.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootBranchCreateTarget {
    pub root_path: String,
    pub checked_out: bool,
    pub previous_branch: Option<String>,
    pub previous_head: Option<String>,
    pub expected_head: Option<String>,
    pub expected_branch: Option<String>,
    pub previous_branch_tip: Option<String>,
    pub expected_branch_tip: Option<String>,
}

/// 一个多 root merge 的逐仓库结果。
///
/// Merge 与普通聚合操作不同：冲突会暂停但仍算作已处理 root，后续 root
/// 继续执行；致命失败则停止后续 root，UI 使用 initial/final HEAD 提供
/// IntelliJ 风格的部分成功回滚选择。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootMergeResult {
    pub root_path: String,
    pub display_name: String,
    pub success: bool,
    pub skipped: bool,
    pub message: String,
    pub initial_head: Option<String>,
    pub final_head: Option<String>,
    pub completed: bool,
    pub requires_finish: bool,
    pub conflicts: Vec<String>,
    /// Structured direct-merge guard details. Swift uses this field to offer
    /// Smart Merge only for roots that were actually blocked by local edits.
    pub local_changes_overwrite_paths: Vec<String>,
}

/// 一个多 root Reset 的逐仓库结果。Reset 先走直接路径以复刻
/// IntelliJ 的 affected-changes 决策；只有 Swift 明确选择 Smart/Force
/// 后才会保存本地变更或丢弃 Hard Reset 的工作区内容。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootResetResult {
    pub root_path: String,
    pub display_name: String,
    pub success: bool,
    pub skipped: bool,
    pub message: String,
    pub local_changes_overwrite_paths: Vec<String>,
    /// Snapshot values used only for safe soft-reset rollback. `Some("")`
    /// represents detached HEAD; `None` means the snapshot was unavailable.
    pub initial_head: Option<String>,
    pub final_head: Option<String>,
    pub initial_branch: Option<String>,
    pub final_branch: Option<String>,
    /// Durable full-scene undo marker. `None` means this root either failed or
    /// the reset was a true no-op; soft legacy callers may still use the
    /// ref-only rollback target below.
    pub rollback_id: Option<String>,
}

/// Expected-HEAD state for a ref-only rollback of a soft reset. The operation
/// never restores the index/worktree because soft reset never changed them.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootResetRollbackTarget {
    pub root_path: String,
    pub display_name: String,
    pub initial_head: String,
    pub expected_head: String,
    pub mode: ResetMode,
    /// Empty string means detached HEAD. `None` is accepted for compatibility
    /// with callers that do not have a branch snapshot, but new UI actions
    /// always persist this guard.
    pub expected_head_branch: Option<String>,
}

/// A Log Reset target. IntelliJ's one-commit-per-repository action can carry
/// a different selected revision for each Git root in one invocation.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootResetTarget {
    pub root_path: String,
    pub commit_id: String,
}

/// 一个多 root force-pushed branch update 的逐仓库结果。每个 root 保留
/// 自己的分支/upstream/replay 结果，避免把同名分支的状态错误合并。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootForcePushedBranchUpdateResult {
    pub root_path: String,
    pub display_name: String,
    pub success: bool,
    pub skipped: bool,
    pub message: String,
    pub branch: String,
    pub upstream: String,
    pub replayed_commits: u32,
    pub used_merge_update: bool,
    pub received_commits_count: u32,
    pub updated_files_count: u32,
    pub update_range_start: Option<String>,
    pub new_upstream_tip: String,
    /// Snapshot of dirty paths before the operation. The UI uses this for the
    /// affected-changes decision and retains it in partial failure feedback.
    pub local_changes_overwrite_paths: Vec<String>,
}

/// 一个多 root Rebase 的逐仓库输入。
///
/// 每个 root 独立携带 branch/onto/actions：不同仓库的提交范围通常不同，
/// 不能把一个 root 的 todo 列表错误复用到另一个 root。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootRebaseSpec {
    pub root_path: String,
    pub branch: String,
    pub onto: String,
    pub actions: Vec<crate::remote::RebaseAction>,
    /// Commit identities in the caller's visible structured todo order.
    /// An empty list preserves the legacy native order mapping; a non-empty
    /// list is used only for structured preserve-merges execution so actions
    /// cannot be detached from the rows the user edited.
    pub ordered_commit_ids: Vec<String>,
    /// Optional caller-edited native Git todo. When present, this root uses
    /// Git's sequence editor directly instead of the structured action list.
    /// The field is intentionally per-root because native control rows and
    /// commit ranges are repository-specific.
    pub raw_todo: Option<String>,
    pub preserve_merges: bool,
    pub auto_squash: bool,
    pub keep_empty: bool,
    pub update_refs: bool,
    pub root: bool,
    /// When false, run Git's native non-interactive rebase without a todo.
    pub interactive: bool,
    /// IntelliJ GitSaveChangesPolicy used while switching/rebasing each root.
    pub save_policy: LocalChangesSavePolicy,
}

/// 多 root Rebase 的逐仓库结果。
///
/// `completed=false` 且 `requires_finish=true` 表示该 root 已进入 Git 的
/// conflict/edit 暂停状态；后续 root 的 `skipped=true` 表示本次没有执行，
/// 这样 UI 可以准确呈现 IntelliJ 的部分完成而不是伪装成一次整体失败。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MultiRootRebaseResult {
    pub root_path: String,
    pub display_name: String,
    pub success: bool,
    pub skipped: bool,
    pub message: String,
    pub initial_head: Option<String>,
    pub final_head: Option<String>,
    pub initial_branch: Option<String>,
    pub final_branch: Option<String>,
    pub completed: bool,
    pub requires_finish: bool,
    pub conflicts: Vec<String>,
}

/// 多 root checkout 的保存策略。Normal 只执行安全 checkout；Smart 在所有
/// root 先保存现场再统一 checkout；Force 明确允许覆盖各 root 工作区。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MultiRootCheckoutMode {
    Normal,
    Smart,
    Force,
}

/// A preserving process may use either Git's stash stack or Arbor's named
/// Shelf store. Keep the reference so restore never depends on a UI-only
/// in-memory flag.
#[derive(Clone, Debug)]
enum SavedLocalChanges {
    Stash(gix::hash::ObjectId),
    Shelf(String),
}

fn dirty_paths_for_preservation(
    repo: &crate::repo::Repository,
    ignored_submodule_paths: &[String],
) -> Result<Vec<String>, EngineError> {
    let mut paths = Vec::new();
    for entry in repo.status()? {
        if path_is_covered_by_submodule(entry.path.as_str(), ignored_submodule_paths) {
            continue;
        }
        let dirty = entry.staged != crate::status::ChangeKind::Unchanged
            || (entry.unstaged != crate::status::ChangeKind::Unchanged
                && entry.unstaged != crate::status::ChangeKind::Ignored);
        if dirty && !paths.contains(&entry.path) {
            paths.push(entry.path);
        }
    }
    Ok(paths)
}

fn unique_preservation_shelf_name(
    repo: &crate::repo::Repository,
    label: &str,
    root_name: &str,
) -> Result<String, EngineError> {
    let existing = repo
        .shelve_list()?
        .into_iter()
        .map(|shelf| shelf.name)
        .collect::<std::collections::HashSet<_>>();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| EngineError::GitOperation {
            message: format!("could not create temporary Shelf name: {error}"),
        })?
        .as_nanos();
    let base = format!("{label} [{root_name}]");
    let mut name = format!("{base} #{nanos}");
    let mut suffix = 1u32;
    while existing.contains(&name) {
        name = format!("{base} #{nanos}-{suffix}");
        suffix += 1;
    }
    Ok(name)
}

fn save_local_changes_for_preservation(
    repo: &crate::repo::Repository,
    label: &str,
    root_name: &str,
    save_policy: LocalChangesSavePolicy,
    ignored_submodule_paths: &[String],
) -> Result<SavedLocalChanges, EngineError> {
    match save_policy {
        LocalChangesSavePolicy::Stash => {
            let stash_id = if ignored_submodule_paths.is_empty() {
                repo.stash_save_with_options(Some(label.to_string()), true, false)?
            } else {
                let paths = dirty_paths_for_preservation(repo, ignored_submodule_paths)?;
                if paths.is_empty() {
                    return Err(EngineError::GitOperation {
                        message: "no local changes remain outside nested submodules".into(),
                    });
                }
                repo.stash_save_paths(Some(label.to_string()), paths, true)?
            };
            let stash_id = gix::hash::ObjectId::from_hex(stash_id.as_bytes())
                .map_err(EngineError::from_gix)?;
            Ok(SavedLocalChanges::Stash(stash_id))
        }
        LocalChangesSavePolicy::Shelve => {
            let paths = dirty_paths_for_preservation(repo, ignored_submodule_paths)?;
            let name = unique_preservation_shelf_name(repo, label, root_name)?;
            repo.shelve_for_preservation(name.clone(), paths)?;
            Ok(SavedLocalChanges::Shelf(name))
        }
    }
}

fn restore_saved_local_changes(
    repo: &crate::repo::Repository,
    saved: &SavedLocalChanges,
) -> Result<(), EngineError> {
    match saved {
        SavedLocalChanges::Stash(stash_id) => crate::repo::stash_pop_with_id(repo, *stash_id, true),
        SavedLocalChanges::Shelf(name) => repo.shelve_pop_preservation(name.clone()),
    }
}

fn saved_local_changes_message(saved: &SavedLocalChanges) -> &'static str {
    match saved {
        SavedLocalChanges::Stash(_) => "stash",
        SavedLocalChanges::Shelf(_) => "Shelf",
    }
}

fn restore_submodule_saved_scenes(
    saved: &mut Vec<(String, Arc<crate::repo::Repository>, SavedLocalChanges)>,
) -> Vec<String> {
    let mut remaining = Vec::new();
    let mut failures = Vec::new();
    for (display_name, repo, changes) in saved.drain(..).rev() {
        if let Err(error) = restore_saved_local_changes(&repo, &changes) {
            failures.push(format!(
                "{display_name}: local changes remain in {} ({error})",
                saved_local_changes_message(&changes)
            ));
            remaining.push((display_name, repo, changes));
        } else {
            // The marker is deliberately cleared only after the exact saved
            // artifact has been restored. If the process dies before this
            // point, startup recovery can still find the same root-scoped
            // stash/Shelf and offer the normal conflict workbench.
            repo.clear_apply_local_changes_restore();
        }
    }
    *saved = remaining;
    failures
}

fn submodule_update_error_with_restore(
    message: String,
    saved: &mut Vec<(String, Arc<crate::repo::Repository>, SavedLocalChanges)>,
) -> EngineError {
    let restore_failures = restore_submodule_saved_scenes(saved);
    if restore_failures.is_empty() {
        return EngineError::GitOperation { message };
    }
    EngineError::GitOperation {
        message: format!("{message}; {}", restore_failures.join("; ")),
    }
}

/// IntelliJ's standalone submodule updater: update one gitlink from its
/// parent repository while preserving dirty worktrees in the selected
/// submodule and every recursively affected descendant.
///
/// This deliberately does not pull the parent repository. The parent gitlink
/// is authoritative for the selected path, matching `GitSubmoduleUpdater`'s
/// `git submodule update --recursive -- <path>` command and `isSaveNeeded()`
/// behavior in the reference implementation.
#[uniffi::export]
pub fn run_submodule_update_with_policy(
    parent_path: String,
    path: String,
    recursive: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<RootOperationResult, EngineError> {
    let parent_path =
        std::fs::canonicalize(&parent_path).unwrap_or_else(|_| PathBuf::from(&parent_path));
    let relative_path = path.trim();
    if relative_path.is_empty()
        || Path::new(relative_path).is_absolute()
        || Path::new(relative_path)
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(EngineError::GitOperation {
            message: "submodule update path must be a non-empty parent-relative path".into(),
        });
    }

    let parent_path_string = parent_path.display().to_string();
    let parent_repo = crate::repo::open_repository(parent_path_string.clone())?;
    if !parent_repo
        .submodule_list()?
        .iter()
        .any(|module| module.path == relative_path)
    {
        return Err(EngineError::GitOperation {
            message: format!("submodule path is not registered in the parent: {relative_path}"),
        });
    }

    let target_path = std::fs::canonicalize(parent_path.join(relative_path)).map_err(|_| {
        EngineError::GitOperation {
            message: format!(
                "submodule is not initialized: {relative_path}; use the global Update action with init enabled"
            ),
        }
    })?;
    let discovered_roots = discover_git_roots(parent_path_string, None)?;
    let target_path_string = target_path.display().to_string();
    let mut affected_roots = discovered_roots
        .into_iter()
        .filter(|root| {
            root.path == target_path_string
                || (recursive
                    && root.is_submodule
                    && Path::new(&root.path).starts_with(&target_path))
        })
        .collect::<Vec<_>>();
    if affected_roots
        .iter()
        .all(|root| root.path != target_path_string)
    {
        return Err(EngineError::GitOperation {
            message: format!("initialized submodule root was not discovered: {relative_path}"),
        });
    }
    affected_roots
        .sort_by_key(|root| std::cmp::Reverse(Path::new(&root.path).components().count()));

    let mut saved = Vec::new();
    for root in &affected_roots {
        let root_repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                return Err(submodule_update_error_with_restore(
                    format!(
                        "could not open submodule root '{}': {error}",
                        root.display_name
                    ),
                    &mut saved,
                ));
            }
        };
        let operation_state = match root_repo.operation_state() {
            Ok(state) => state,
            Err(error) => {
                return Err(submodule_update_error_with_restore(
                    format!(
                        "could not inspect submodule root '{}': {error}",
                        root.display_name
                    ),
                    &mut saved,
                ));
            }
        };
        if operation_state.is_some() {
            return Err(submodule_update_error_with_restore(
                format!(
                    "submodule update cannot run while '{}' has another Git operation in progress",
                    root.display_name
                ),
                &mut saved,
            ));
        }
        if root_repo.apply_local_changes_restore_info()?.is_some() {
            return Err(submodule_update_error_with_restore(
                format!(
                    "submodule update cannot replace pending saved local changes in '{}'; resolve or abort the previous restore first",
                    root.display_name
                ),
                &mut saved,
            ));
        }

        let ignored_submodule_paths = affected_roots
            .iter()
            .filter_map(|descendant| {
                if descendant.path == root.path {
                    return None;
                }
                Path::new(&descendant.path)
                    .strip_prefix(Path::new(&root.path))
                    .ok()
                    .map(|path| path.to_string_lossy().into_owned())
            })
            .filter(|path| !path.is_empty())
            .collect::<Vec<_>>();
        let dirty_paths = match dirty_paths_for_preservation(&root_repo, &ignored_submodule_paths) {
            Ok(paths) => paths,
            Err(error) => {
                return Err(submodule_update_error_with_restore(
                    format!(
                        "could not inspect local changes in '{}': {error}",
                        root.display_name
                    ),
                    &mut saved,
                ));
            }
        };
        if dirty_paths.is_empty() {
            continue;
        }
        match save_local_changes_for_preservation(
            &root_repo,
            "Arbor: Update Submodule",
            &root.display_name,
            save_policy,
            &ignored_submodule_paths,
        ) {
            Ok(changes) => {
                let (kind, identifier) = match &changes {
                    SavedLocalChanges::Stash(stash_id) => ("stash", stash_id.to_hex().to_string()),
                    SavedLocalChanges::Shelf(name) => ("shelf", name.clone()),
                };
                if let Err(marker_error) = root_repo.persist_apply_local_changes_restore(
                    "submodule-update",
                    kind,
                    &identifier,
                ) {
                    root_repo.clear_apply_local_changes_restore();
                    let restore_error = restore_saved_local_changes(&root_repo, &changes).err();
                    let detail = match restore_error {
                        Some(restore_error) => {
                            format!("{marker_error}; restoring local changes also failed: {restore_error}")
                        }
                        None => marker_error.to_string(),
                    };
                    return Err(submodule_update_error_with_restore(
                        format!(
                            "could not record submodule Update recovery for '{}': {detail}",
                            root.display_name
                        ),
                        &mut saved,
                    ));
                }
                saved.push((root.display_name.clone(), root_repo, changes));
            }
            Err(error) => {
                return Err(submodule_update_error_with_restore(
                    format!(
                        "could not preserve local changes in '{}': {error}",
                        root.display_name
                    ),
                    &mut saved,
                ));
            }
        }
    }

    let had_saved_local_changes = !saved.is_empty();
    let operation = if cancel.is_cancelled() {
        Err(EngineError::Cancelled)
    } else {
        parent_repo.submodule_update_path_with_auth_and_cancel(
            relative_path.to_string(),
            recursive,
            broker,
            cancel,
        )
    };
    let restore_failures = restore_submodule_saved_scenes(&mut saved);
    if !restore_failures.is_empty() {
        let operation_detail = operation
            .as_ref()
            .err()
            .map(ToString::to_string)
            .unwrap_or_else(|| "update completed".into());
        return Err(EngineError::GitOperation {
            message: format!("{operation_detail}; {}", restore_failures.join("; ")),
        });
    }
    operation?;

    let display_name = affected_roots
        .iter()
        .find(|root| root.path == target_path_string)
        .map(|root| root.display_name.clone())
        .unwrap_or_else(|| relative_path.to_string());
    let detail = if had_saved_local_changes {
        format!("updated submodule '{relative_path}' and restored local changes")
    } else {
        format!("updated submodule '{relative_path}'")
    };
    Ok(RootOperationResult {
        root_path: target_path_string,
        display_name,
        success: true,
        skipped: false,
        message: detail,
    })
}

/// 在项目发现的所有 Git root 上执行同一个 checkout reference。
///
/// `detach=false` 时优先切换同名本地分支，其次把 remote-tracking 分支创建为
/// 本地跟踪分支；其它 reference（tag/hash）进入 detached HEAD。Smart 模式
/// 遵循 IntelliJ 的 preserving-process：先在所有 root 保存 tracked/untracked
/// 现场，再执行 checkout，最后逐 root 恢复并返回部分成功/冲突结果。
#[uniffi::export]
pub fn run_multi_root_checkout(
    scan_root: String,
    reference: String,
    detach: bool,
    mode: MultiRootCheckoutMode,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_checkout_with_policy(
        scan_root,
        reference,
        detach,
        mode,
        LocalChangesSavePolicy::Stash,
    )
}

/// Multi-root checkout with IntelliJ's persisted local-change save policy.
#[uniffi::export]
pub fn run_multi_root_checkout_with_policy(
    scan_root: String,
    reference: String,
    detach: bool,
    mode: MultiRootCheckoutMode,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let reference = reference.trim().to_string();
    if reference.is_empty() || reference.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "checkout reference must not be empty or start with '-'".into(),
        });
    }

    let roots = discover_git_roots(scan_root, None)?;
    let mut contexts = Vec::with_capacity(roots.len());
    for root in roots {
        let repo = crate::repo::open_repository(root.path.clone())?;
        let dirty = if mode == MultiRootCheckoutMode::Smart {
            repo.status()?.iter().any(|entry| {
                entry.staged != crate::status::ChangeKind::Unchanged
                    || !matches!(
                        entry.unstaged,
                        crate::status::ChangeKind::Unchanged | crate::status::ChangeKind::Ignored
                    )
            })
        } else {
            false
        };
        if mode == MultiRootCheckoutMode::Smart && repo.operation_state()?.is_some() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "checkout: Git operation already in progress in root '{}'",
                    root.display_name
                ),
            });
        }
        contexts.push((root, repo, dirty));
    }

    let mut saved: Vec<(usize, Arc<crate::repo::Repository>, SavedLocalChanges)> = Vec::new();
    if mode == MultiRootCheckoutMode::Smart {
        for (index, (root, repo, dirty)) in contexts.iter().enumerate() {
            if !dirty {
                continue;
            }
            let label = format!("Arbor: Smart Checkout to {reference}");
            let saved_changes = match save_local_changes_for_preservation(
                repo,
                &label,
                &root.display_name,
                save_policy,
                &[],
            ) {
                Ok(saved_changes) => saved_changes,
                Err(error) => {
                    for (_, previous, saved_changes) in saved.drain(..).rev() {
                        let _ = restore_saved_local_changes(&previous, &saved_changes);
                    }
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "multi-root Smart Checkout could not save '{}': {error}",
                            root.display_name
                        ),
                    });
                }
            };
            saved.push((index, Arc::clone(repo), saved_changes));
        }
    }

    let total_roots = contexts.len();
    let mut results = Vec::with_capacity(total_roots);
    for (index, (root, repo, _)) in contexts.iter().enumerate() {
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            index,
            total_roots,
            root.path.clone(),
            root.display_name.clone(),
        );
        if !crate::repo::can_resolve_reference(repo, &reference) {
            results.push(root_skipped_result(
                root,
                "reference not found in this root; checkout skipped",
            ));
            crate::gitprocess::update_root_operation_progress(
                progress_generation,
                index + 1,
                "skipped".to_string(),
            );
            crate::gitprocess::end_root_operation_progress(progress_generation);
            continue;
        }
        let action_mode = if mode == MultiRootCheckoutMode::Smart {
            MultiRootCheckoutMode::Normal
        } else {
            mode
        };
        match checkout_reference(repo, &reference, detach, action_mode) {
            Ok(()) => {
                results.push(RootOperationResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: true,
                    skipped: false,
                    message: String::new(),
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    index + 1,
                    "completed".to_string(),
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
            }
            Err(error) => {
                results.push(RootOperationResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    index + 1,
                    "failed".to_string(),
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                for (skipped_index, (skipped_root, _, _)) in
                    contexts.iter().enumerate().skip(index + 1)
                {
                    results.push(root_skipped_result(
                        skipped_root,
                        "not attempted after checkout failure",
                    ));
                    let skipped_generation = crate::gitprocess::begin_root_operation_progress(
                        skipped_index,
                        total_roots,
                        skipped_root.path.clone(),
                        skipped_root.display_name.clone(),
                    );
                    crate::gitprocess::update_root_operation_progress(
                        skipped_generation,
                        skipped_index + 1,
                        "skipped".to_string(),
                    );
                    crate::gitprocess::end_root_operation_progress(skipped_generation);
                }
                break;
            }
        }
    }

    for (index, repo, saved_changes) in saved {
        let root = &contexts[index].0;
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            index,
            total_roots,
            root.path.clone(),
            root.display_name.clone(),
        );
        let result = results
            .iter_mut()
            .find(|item| item.root_path == root.path)
            .expect("checkout result exists for every root");
        if let Err(error) = restore_saved_local_changes(&repo, &saved_changes) {
            result.success = false;
            if result.message.is_empty() {
                result.message = format!(
                    "Smart Checkout restore from {} failed: {error}",
                    saved_local_changes_message(&saved_changes)
                );
            } else {
                result.message = format!("{}; restore failed: {error}", result.message);
            }
        }
        let state = if result.success {
            if result.skipped {
                "skipped"
            } else {
                "completed"
            }
        } else {
            "failed"
        };
        crate::gitprocess::update_root_operation_progress(
            progress_generation,
            index + 1,
            state.to_string(),
        );
        crate::gitprocess::end_root_operation_progress(progress_generation);
    }

    Ok(results)
}

/// 回滚多 root checkout 已成功的 root。
///
/// 该动作先恢复原始 branch/detached HEAD，再删除 checkout 过程中创建的
/// 本地分支，保持 IntelliJ checkout rollback 的范围。
#[uniffi::export]
pub fn restore_multi_root_checkout(
    targets: Vec<MultiRootBranchTarget>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let mut results = Vec::with_capacity(targets.len());
    for target in targets {
        let display_name = Path::new(&target.root_path)
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| target.root_path.clone());
        let repo = match crate::repo::open_repository(target.root_path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(RootOperationResult {
                    root_path: target.root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                });
                continue;
            }
        };

        if target.checked_out {
            let current_head = match repo.revision_commit_id("HEAD".into()) {
                Ok(head) => head,
                Err(error) => {
                    results.push(RootOperationResult {
                        root_path: target.root_path,
                        display_name,
                        success: false,
                        skipped: false,
                        message: format!("cannot verify checkout rollback state: {error}"),
                    });
                    continue;
                }
            };
            let current_branch = match repo.branch_list() {
                Ok(branches) => branches
                    .into_iter()
                    .find(|branch| branch.is_current)
                    .map(|branch| branch.name),
                Err(error) => {
                    results.push(RootOperationResult {
                        root_path: target.root_path,
                        display_name,
                        success: false,
                        skipped: false,
                        message: format!("cannot verify checkout rollback branch: {error}"),
                    });
                    continue;
                }
            };
            let expected_head = match target.expected_head.as_deref() {
                Some(head) => head,
                None => {
                    results.push(RootOperationResult {
                        root_path: target.root_path,
                        display_name,
                        success: false,
                        skipped: false,
                        message: "checkout rollback is unavailable because its expected HEAD was not persisted".into(),
                    });
                    continue;
                }
            };
            if current_head != expected_head || current_branch != target.expected_branch {
                results.push(RootOperationResult {
                    root_path: target.root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!(
                        "checkout rollback refused: repository state changed since checkout (expected branch {:?} at {}, found branch {:?} at {})",
                        target.expected_branch, expected_head, current_branch, current_head
                    ),
                });
                continue;
            }
        }

        let restore = match target.previous_branch {
            Some(branch) => repo.switch_branch(branch),
            None => target
                .previous_head
                .ok_or_else(|| EngineError::GitOperation {
                    message: "cannot restore detached HEAD: original commit is missing".into(),
                })
                .and_then(|head| repo.checkout_detached(head)),
        };
        if let Err(error) = restore {
            results.push(RootOperationResult {
                root_path: target.root_path,
                display_name,
                success: false,
                skipped: false,
                message: format!("restore previous HEAD failed: {error}"),
            });
            continue;
        }

        if let Some(created_branch) = target.created_branch {
            if let Err(error) = repo.branch_delete(created_branch, true) {
                results.push(RootOperationResult {
                    root_path: target.root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!("delete checkout branch during rollback failed: {error}"),
                });
                continue;
            }
        }

        results.push(RootOperationResult {
            root_path: target.root_path,
            display_name,
            success: true,
            skipped: false,
            message: "checkout rollback completed".into(),
        });
    }
    Ok(results)
}

/// 多 root 的 Checkout and Update / Checkout with Rebase 复合入口。
///
/// 语义对齐 IntelliJ `GitOperationsApi.checkoutAndUpdate`：先在所有 root
/// 尝试 checkout，只有 checkout 成功的 root 才进入 configured-upstream update。
/// Normal/Smart 模式在 checkout 阶段失败时会补偿回滚已经切换的 root；
/// update 已经进入 merge/rebase operation 后不做强制历史回退，而是保留该
/// root 的恢复状态并返回逐 root 结果。
#[uniffi::export]
pub fn run_multi_root_checkout_and_update(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    reference: String,
    detach: bool,
    rebase: bool,
    mode: MultiRootCheckoutMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_checkout_and_update_with_policy(
        scan_root,
        selected_root_paths,
        reference,
        detach,
        rebase,
        mode,
        broker,
        cancel,
        LocalChangesSavePolicy::Stash,
    )
}

/// Checkout and Update with IntelliJ's persisted local-change save policy.
#[uniffi::export]
pub fn run_multi_root_checkout_and_update_with_policy(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    reference: String,
    detach: bool,
    rebase: bool,
    mode: MultiRootCheckoutMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_checkout_and_update_with_policy_and_options(
        scan_root,
        selected_root_paths,
        reference,
        detach,
        rebase,
        mode,
        crate::remote::FetchTagsMode::Default,
        broker,
        cancel,
        save_policy,
    )
}

/// Checkout and Update with an explicit project fetch tag policy.
#[uniffi::export]
pub fn run_multi_root_checkout_and_update_with_policy_and_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    reference: String,
    detach: bool,
    rebase: bool,
    mode: MultiRootCheckoutMode,
    tag_mode: crate::remote::FetchTagsMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let reference = reference.trim().to_string();
    if reference.is_empty() || reference.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "checkout reference must not be empty or start with '-'".into(),
        });
    }

    let roots = discover_git_roots(scan_root, None)?;
    let roots = if let Some(selected_root_paths) = selected_root_paths {
        let selected_root_paths = selected_root_paths
            .iter()
            .map(|path| {
                std::fs::canonicalize(path)
                    .unwrap_or_else(|_| std::path::PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<Vec<_>>();
        let selected_roots = roots
            .into_iter()
            .filter(|root| selected_root_paths.iter().any(|path| path == &root.path))
            .collect::<Vec<_>>();
        if selected_roots.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected Git root was not found".into(),
            });
        }
        selected_roots
    } else {
        roots
    };
    if cancel.is_cancelled() {
        return Ok(roots
            .into_iter()
            .map(|root| RootOperationResult {
                root_path: root.path,
                display_name: root.display_name,
                success: true,
                skipped: true,
                message: "cancelled before checkout".into(),
            })
            .collect());
    }

    let mut contexts = Vec::with_capacity(roots.len());
    for root in roots {
        let repo = crate::repo::open_repository(root.path.clone())?;
        if repo.operation_state()?.is_some() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "checkout and update: Git operation already in progress in root '{}'",
                    root.display_name
                ),
            });
        }
        let original_branch = root.head_branch.clone();
        let original_head = root.head_id.clone();
        let dirty = repo.status()?.iter().any(|entry| {
            entry.staged != crate::status::ChangeKind::Unchanged
                || !matches!(
                    entry.unstaged,
                    crate::status::ChangeKind::Unchanged | crate::status::ChangeKind::Ignored
                )
        });
        contexts.push(CheckoutUpdateContext {
            root,
            repo,
            original_branch,
            original_head,
            dirty,
            saved: None,
            checkout_succeeded: false,
        });
    }

    if mode == MultiRootCheckoutMode::Smart {
        for index in 0..contexts.len() {
            if !contexts[index].dirty {
                continue;
            }
            let label = format!("Arbor: Checkout and Update to {reference}");
            let saved_changes = match save_local_changes_for_preservation(
                &contexts[index].repo,
                &label,
                &contexts[index].root.display_name,
                save_policy,
                &[],
            ) {
                Ok(saved_changes) => saved_changes,
                Err(error) => {
                    let cleanup = restore_checkout_update_stashes(&mut contexts, true);
                    let display_name = contexts[index].root.display_name.clone();
                    return Err(EngineError::GitOperation {
                        message: if let Some(cleanup_error) = cleanup {
                            format!(
                            "could not save local changes in '{}': {error}; local-change cleanup failed in '{}': {}",
                            display_name, cleanup_error.0, cleanup_error.1
                        )
                        } else {
                            format!(
                                "could not save local changes in '{}': {error}",
                                display_name
                            )
                        },
                    });
                }
            };
            contexts[index].saved = Some(saved_changes);
        }
    }

    let mut results = Vec::with_capacity(contexts.len());
    let mut checkout_failure: Option<usize> = None;
    for index in 0..contexts.len() {
        if cancel.is_cancelled() {
            checkout_failure = Some(index);
            results.push(root_skipped_result(
                &contexts[index].root,
                "cancelled before checkout",
            ));
            break;
        }
        let action_mode = if mode == MultiRootCheckoutMode::Smart {
            MultiRootCheckoutMode::Normal
        } else {
            mode
        };
        match checkout_reference(&contexts[index].repo, &reference, detach, action_mode) {
            Ok(()) => {
                contexts[index].checkout_succeeded = true;
                results.push(root_success_result(&contexts[index].root, String::new()));
            }
            Err(error) => {
                checkout_failure = Some(index);
                results.push(root_failure_result(
                    &contexts[index].root,
                    error.to_string(),
                ));
                break;
            }
        }
    }

    if let Some(failed_index) = checkout_failure {
        let cleanup = if mode == MultiRootCheckoutMode::Smart {
            restore_checkout_update_stashes(&mut contexts, true)
        } else if mode != MultiRootCheckoutMode::Force {
            let mut rollback_error = None;
            for index in 0..failed_index {
                if contexts[index].checkout_succeeded {
                    if let Err(error) = restore_original_checkout_state(&contexts[index]) {
                        rollback_error =
                            Some((contexts[index].root.path.clone(), error.to_string()));
                    }
                }
            }
            rollback_error
        } else {
            None
        };
        for index in 0..failed_index {
            if contexts[index].checkout_succeeded && mode != MultiRootCheckoutMode::Force {
                results[index].success = false;
                results[index].message = "checkout rolled back after another root failed".into();
            }
        }
        for index in (failed_index + 1)..contexts.len() {
            results.push(root_skipped_result(
                &contexts[index].root,
                "not attempted after checkout failure",
            ));
        }
        if let Some(error) = cleanup {
            if let Some(result) = results
                .iter_mut()
                .find(|result| result.root_path == error.0)
            {
                result.success = false;
                result.message =
                    format!("{}; rollback/restore failed: {}", result.message, error.1);
            }
        }
        return Ok(results);
    }

    // Every root was checked out successfully. Update each selected branch in
    // order, retaining operation state when merge/rebase has paused.
    for index in 0..contexts.len() {
        if cancel.is_cancelled() {
            results[index] = root_skipped_result(&contexts[index].root, "cancelled before update");
            if mode != MultiRootCheckoutMode::Force {
                let _ = restore_original_checkout_state(&contexts[index]);
            }
            continue;
        }
        if detach {
            results[index] =
                root_skipped_result(&contexts[index].root, "detached checkout; update skipped");
            continue;
        }

        match run_single_root_update_with_policy(
            &contexts[index].root.path,
            rebase,
            true,
            &broker,
            &cancel,
            &[],
            tag_mode,
            save_policy,
        ) {
            Ok(message) => {
                results[index] = root_success_result(&contexts[index].root, message);
            }
            Err(RootError::Skip(message)) => {
                results[index] = root_skipped_result(&contexts[index].root, &message);
            }
            Err(RootError::Fail(error)) => {
                let operation_active = contexts[index]
                    .repo
                    .operation_state()
                    .ok()
                    .flatten()
                    .is_some();
                results[index] = root_failure_result(&contexts[index].root, error.to_string());
                if !operation_active && mode != MultiRootCheckoutMode::Force {
                    match restore_original_checkout_state(&contexts[index]) {
                        Ok(()) => {
                            results[index].message.push_str("; checkout rolled back");
                        }
                        Err(rollback_error) => {
                            results[index]
                                .message
                                .push_str(&format!("; checkout rollback failed: {rollback_error}"));
                        }
                    }
                }
            }
        }

        let operation_active = contexts[index]
            .repo
            .operation_state()
            .ok()
            .flatten()
            .is_some();
        if contexts[index].saved.is_some() && !operation_active {
            let saved_changes = contexts[index]
                .saved
                .take()
                .expect("saved local changes exist");
            match restore_saved_local_changes(&contexts[index].repo, &saved_changes) {
                Ok(()) => {}
                Err(error) => {
                    results[index].success = false;
                    results[index]
                        .message
                        .push_str(&format!("; local restore conflicted: {error}"));
                }
            }
        } else if contexts[index].saved.is_some() && operation_active {
            let save_kind = contexts[index]
                .saved
                .as_ref()
                .map(saved_local_changes_message)
                .unwrap_or("stash");
            results[index].message.push_str(&format!(
                "; local changes remain in {save_kind} while Git operation is active"
            ));
        }
    }

    Ok(results)
}

struct CheckoutUpdateContext {
    root: GitRootInfo,
    repo: Arc<crate::repo::Repository>,
    original_branch: Option<String>,
    original_head: Option<String>,
    dirty: bool,
    saved: Option<SavedLocalChanges>,
    checkout_succeeded: bool,
}

fn root_success_result(root: &GitRootInfo, message: String) -> RootOperationResult {
    RootOperationResult {
        root_path: root.path.clone(),
        display_name: root.display_name.clone(),
        success: true,
        skipped: false,
        message,
    }
}

fn root_failure_result(root: &GitRootInfo, message: String) -> RootOperationResult {
    RootOperationResult {
        root_path: root.path.clone(),
        display_name: root.display_name.clone(),
        success: false,
        skipped: false,
        message,
    }
}

fn root_skipped_result(root: &GitRootInfo, message: &str) -> RootOperationResult {
    RootOperationResult {
        root_path: root.path.clone(),
        display_name: root.display_name.clone(),
        success: true,
        skipped: true,
        message: message.into(),
    }
}

/// Match IntelliJ's project-level Update Project readiness check. A root with
/// an in-progress operation or an unresolved index conflict blocks the whole
/// compound update before fetch, preservation, or integration mutates any
/// worktree. Non-blocking roots stay visible as skipped rows so the UI can
/// explain why they were not touched.
fn update_not_ready_results(
    roots: &[GitRootInfo],
) -> Result<Option<Vec<RootOperationResult>>, EngineError> {
    let mut blockers = vec![None; roots.len()];
    for (index, root) in roots.iter().enumerate() {
        let repo = crate::repo::open_repository(root.path.clone())?;
        let operation_in_progress = repo.operation_state()?.is_some();
        let unresolved_conflicts = repo.status()?.iter().any(|entry| {
            entry.staged == crate::status::ChangeKind::Conflicted
                || entry.unstaged == crate::status::ChangeKind::Conflicted
        });
        let mut reasons = Vec::new();
        if operation_in_progress {
            reasons.push("another Git operation is already in progress");
        }
        if unresolved_conflicts {
            reasons.push("unresolved conflicts remain");
        }
        if !reasons.is_empty() {
            blockers[index] = Some(reasons.join("; "));
        }
    }

    if blockers.iter().all(Option::is_none) {
        return Ok(None);
    }

    let project_reason = "another Git root is not ready for Update Project";
    let results = roots
        .iter()
        .enumerate()
        .map(|(index, root)| match blockers[index].as_deref() {
            Some(reason) => root_failure_result(root, format!("update not ready: {reason}")),
            None => root_skipped_result(root, project_reason),
        })
        .collect();
    Ok(Some(results))
}

fn restore_original_checkout_state(context: &CheckoutUpdateContext) -> Result<(), EngineError> {
    if let Some(branch) = context.original_branch.as_deref() {
        return context.repo.switch_branch(branch.to_string());
    }
    let head = context
        .original_head
        .clone()
        .ok_or_else(|| EngineError::GitOperation {
            message: format!(
                "root '{}' has no original HEAD to restore",
                context.root.display_name
            ),
        })?;
    context.repo.checkout_detached(head)
}

/// Restore all temporary local-change saves after a failed pre-update phase.
/// The first error is returned together with its root so the caller can keep
/// the result visibly recoverable instead of silently dropping the save.
fn restore_checkout_update_stashes(
    contexts: &mut [CheckoutUpdateContext],
    rollback_checkout: bool,
) -> Option<(String, String)> {
    let mut first_error = None;
    for context in contexts.iter_mut().rev() {
        if rollback_checkout && context.checkout_succeeded {
            if let Err(error) = restore_original_checkout_state(context) {
                if first_error.is_none() {
                    first_error = Some((context.root.path.clone(), error.to_string()));
                }
                continue;
            }
        }
        if let Some(saved_changes) = context.saved.take() {
            match restore_saved_local_changes(&context.repo, &saved_changes) {
                Ok(()) => {}
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some((context.root.path.clone(), error.to_string()));
                    }
                }
            }
        }
    }
    first_error
}

fn checkout_reference(
    repo: &Arc<crate::repo::Repository>,
    reference: &str,
    detach: bool,
    mode: MultiRootCheckoutMode,
) -> Result<(), EngineError> {
    let is_local_branch = repo
        .branch_list()?
        .iter()
        .any(|branch| branch.name == reference);
    let is_remote_branch = repo
        .remote_branch_list()?
        .iter()
        .any(|branch| branch.name == reference);

    if detach || (!is_local_branch && !is_remote_branch) {
        return match mode {
            MultiRootCheckoutMode::Normal => repo.checkout_detached(reference.to_string()),
            MultiRootCheckoutMode::Smart => repo.smart_checkout_detached(reference.to_string()),
            MultiRootCheckoutMode::Force => repo.force_checkout_detached(reference.to_string()),
        };
    }
    if is_local_branch {
        return match mode {
            MultiRootCheckoutMode::Normal => repo.switch_branch(reference.to_string()),
            MultiRootCheckoutMode::Smart => repo.smart_switch_branch(reference.to_string()),
            MultiRootCheckoutMode::Force => repo.force_switch_branch(reference.to_string()),
        };
    }
    match mode {
        MultiRootCheckoutMode::Normal => repo.checkout_remote_branch(reference.to_string(), None),
        MultiRootCheckoutMode::Smart => {
            repo.smart_checkout_remote_branch(reference.to_string(), None)
        }
        MultiRootCheckoutMode::Force => {
            repo.force_checkout_remote_branch(reference.to_string(), None)
        }
    }
}

/// 对项目下所有 Git root 执行聚合操作：逐 root 独立执行,
/// 单个 root 失败不影响其他（部分成功/部分失败可展示）。
#[uniffi::export]
pub fn run_multi_root_operation(
    scan_root: String,
    operation: MultiRootOperation,
    commit_message: Option<String>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_operation_internal(scan_root, None, operation, commit_message)
}

/// Retry a generic project-level operation only for the roots that failed or
/// were otherwise left pending in the previous aggregate run. Re-running the
/// whole project would repeat successful Pull/Fetch side effects and diverge
/// from IntelliJ's root-scoped retry semantics.
#[uniffi::export]
pub fn run_multi_root_operation_on_roots(
    scan_root: String,
    selected_root_paths: Vec<String>,
    operation: MultiRootOperation,
    commit_message: Option<String>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    if selected_root_paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "multi-root retry requires at least one selected Git root".into(),
        });
    }
    run_multi_root_operation_internal(
        scan_root,
        Some(selected_root_paths),
        operation,
        commit_message,
    )
}

fn run_multi_root_operation_internal(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    operation: MultiRootOperation,
    commit_message: Option<String>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let roots = discover_git_roots(scan_root, None)?;
    let roots = if let Some(selected_root_paths) = selected_root_paths {
        let selected_paths: HashSet<PathBuf> = selected_root_paths
            .iter()
            .map(|path| std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path)))
            .collect();
        let discovered_paths: HashSet<PathBuf> = roots
            .iter()
            .map(|root| {
                std::fs::canonicalize(&root.path).unwrap_or_else(|_| PathBuf::from(&root.path))
            })
            .collect();
        if let Some(unknown) = selected_paths
            .iter()
            .find(|path| !discovered_paths.contains(*path))
        {
            return Err(EngineError::GitOperation {
                message: format!(
                    "selected Git root is not in the project: {}",
                    unknown.display()
                ),
            });
        }
        roots
            .into_iter()
            .filter(|root| {
                let path =
                    std::fs::canonicalize(&root.path).unwrap_or_else(|_| PathBuf::from(&root.path));
                selected_paths.contains(&path)
            })
            .collect()
    } else {
        roots
    };
    let mut results = Vec::with_capacity(roots.len());
    // A superproject's gitlink can point at a commit that has not reached the
    // submodule remote yet.  IntelliJ therefore processes submodule roots
    // before their superprojects for check-in/push operations.  Keep the
    // discovery order for unrelated roots and for pull/fetch, where the
    // parent-first update orchestration has different semantics.
    let mut root_indices: Vec<usize> = (0..roots.len()).collect();
    if matches!(
        operation,
        MultiRootOperation::Push | MultiRootOperation::Commit
    ) {
        root_indices.sort_by(|left, right| {
            let left_root = &roots[*left];
            let right_root = &roots[*right];
            let left_is_superproject = !left_root.is_submodule;
            let right_is_superproject = !right_root.is_submodule;
            left_is_superproject
                .cmp(&right_is_superproject)
                .then_with(|| {
                    // Among submodules, deepest dependencies must be
                    // published first (nested submodule before its parent).
                    if left_root.is_submodule && right_root.is_submodule {
                        std::path::Path::new(&right_root.path)
                            .components()
                            .count()
                            .cmp(&std::path::Path::new(&left_root.path).components().count())
                    } else {
                        std::cmp::Ordering::Equal
                    }
                })
                .then_with(|| left.cmp(right))
        });
    }
    let total_roots = root_indices.len();
    for (position, index) in root_indices.into_iter().enumerate() {
        let root = &roots[index];
        let path = root.path.clone();
        let name = root.display_name.clone();
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            position,
            total_roots,
            path.clone(),
            name.clone(),
        );
        let result = match run_single_root(&path, operation, commit_message.as_deref()) {
            Ok(()) => RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: false,
                message: String::new(),
            },
            Err(RootError::Skip(msg)) => RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: true,
                message: msg,
            },
            Err(RootError::Fail(e)) => RootOperationResult {
                root_path: path,
                display_name: name,
                success: false,
                skipped: false,
                message: e.to_string(),
            },
        };
        let state = if result.success {
            if result.skipped {
                "skipped"
            } else {
                "completed"
            }
        } else {
            "failed"
        };
        crate::gitprocess::update_root_operation_progress(
            progress_generation,
            position + 1,
            state.to_string(),
        );
        results.push(result);
        crate::gitprocess::end_root_operation_progress(progress_generation);
    }
    Ok(results)
}

/// Commit only the explicitly selected roots with one validated message.
///
/// The generic aggregate operation remains for legacy callers, but its
/// optional message is intentionally not used by the UI commit workflow: a
/// project-level Commit action must never silently turn an empty message into
/// a WIP commit or commit an unselected nested repository.
#[uniffi::export]
pub fn run_multi_root_commit(
    scan_root: String,
    root_paths: Vec<String>,
    commit_message: String,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_commit_with_options(
        scan_root,
        root_paths,
        commit_message,
        MultiRootCommitOptions::default(),
    )
}

/// Commit selected roots with the same validated workflow options as the
/// single-root Commit workspace. Each root is checked and committed
/// independently so one failing root produces a partial result instead of
/// mutating unrelated repositories.
#[uniffi::export]
pub fn run_multi_root_commit_with_options(
    scan_root: String,
    root_paths: Vec<String>,
    commit_message: String,
    options: MultiRootCommitOptions,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let message = commit_message.trim();
    if message.is_empty() {
        return Err(EngineError::GitOperation {
            message: "multi-root commit requires a non-empty commit message".into(),
        });
    }

    let selected_paths: HashSet<PathBuf> = root_paths
        .iter()
        .map(|path| std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path)))
        .collect();
    if selected_paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "multi-root commit requires at least one selected root".into(),
        });
    }

    let roots = discover_git_roots(scan_root, None)?;
    let discovered_paths: HashSet<PathBuf> = roots
        .iter()
        .map(|root| std::fs::canonicalize(&root.path).unwrap_or_else(|_| PathBuf::from(&root.path)))
        .collect();
    if let Some(unknown) = selected_paths
        .iter()
        .find(|path| !discovered_paths.contains(*path))
    {
        return Err(EngineError::GitOperation {
            message: format!(
                "selected Git root is not in the project: {}",
                unknown.display()
            ),
        });
    }

    let mut root_indices: Vec<usize> = (0..roots.len()).collect();
    sort_push_root_indices(&roots, &mut root_indices);
    let mut results = Vec::with_capacity(roots.len());
    for index in root_indices {
        let root = &roots[index];
        let path = root.path.clone();
        let name = root.display_name.clone();
        let normalized_path = std::fs::canonicalize(&path).unwrap_or_else(|_| PathBuf::from(&path));
        if !selected_paths.contains(&normalized_path) {
            results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: true,
                message: "not selected".into(),
            });
            continue;
        }
        match run_single_root_commit(&path, message, &options) {
            Ok(()) => results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: false,
                message: String::new(),
            }),
            Err(RootError::Skip(reason)) => results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: true,
                message: reason,
            }),
            Err(RootError::Fail(error)) => results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: false,
                skipped: false,
                message: error.to_string(),
            }),
        }
    }
    Ok(results)
}

#[uniffi::export]
pub fn run_multi_root_commit_selected_paths_with_options(
    scan_root: String,
    selections: Vec<MultiRootCommitSelection>,
    commit_message: String,
    options: MultiRootCommitOptions,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let message = commit_message.trim();
    if message.is_empty() {
        return Err(EngineError::GitOperation {
            message: "selected multi-root commit requires a non-empty commit message".into(),
        });
    }
    if selections.is_empty() {
        return Err(EngineError::GitOperation {
            message: "selected multi-root commit requires at least one root".into(),
        });
    }

    let roots = discover_git_roots(scan_root, None)?;
    let discovered_paths: HashSet<PathBuf> = roots
        .iter()
        .map(|root| std::fs::canonicalize(&root.path).unwrap_or_else(|_| PathBuf::from(&root.path)))
        .collect();
    let mut selected_by_root: HashMap<PathBuf, Vec<String>> = HashMap::new();
    for selection in selections {
        if selection.paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "selected multi-root commit has no paths for root {}",
                    selection.root_path
                ),
            });
        }
        let root_path = std::fs::canonicalize(&selection.root_path)
            .unwrap_or_else(|_| PathBuf::from(&selection.root_path));
        if !discovered_paths.contains(&root_path) {
            return Err(EngineError::GitOperation {
                message: format!(
                    "selected Git root is not in the project: {}",
                    root_path.display()
                ),
            });
        }
        selected_by_root
            .entry(root_path)
            .or_default()
            .extend(selection.paths);
    }

    let mut root_indices: Vec<usize> = (0..roots.len()).collect();
    sort_push_root_indices(&roots, &mut root_indices);
    let mut results = Vec::with_capacity(roots.len());
    for index in root_indices {
        let root = &roots[index];
        let path = root.path.clone();
        let name = root.display_name.clone();
        let normalized_path = std::fs::canonicalize(&path).unwrap_or_else(|_| PathBuf::from(&path));
        let Some(paths) = selected_by_root.get(&normalized_path) else {
            results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: true,
                message: "not selected".into(),
            });
            continue;
        };
        match run_single_root_commit_selected_paths(&path, message, paths, &options) {
            Ok(()) => results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: false,
                message: String::new(),
            }),
            Err(RootError::Skip(reason)) => results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: true,
                skipped: true,
                message: reason,
            }),
            Err(RootError::Fail(error)) => results.push(RootOperationResult {
                root_path: path,
                display_name: name,
                success: false,
                skipped: false,
                message: error.to_string(),
            }),
        }
    }
    Ok(results)
}

fn run_single_root_commit_selected_paths(
    path: &str,
    message: &str,
    paths: &[String],
    options: &MultiRootCommitOptions,
) -> Result<(), RootError> {
    let repo = crate::repo::open_repository(path.to_string()).map_err(RootError::Fail)?;
    let status = repo.status().map_err(RootError::Fail)?;
    let requested_paths = paths
        .iter()
        .map(|value| {
            crate::repo::worktree_relative_path(value)
                .map(|path| path.to_string_lossy().into_owned())
                .map_err(RootError::Fail)
        })
        .collect::<Result<HashSet<_>, _>>()?;
    if requested_paths.is_empty() {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: "selected commit requires one or more paths".into(),
        }));
    }

    let mut commit_paths = requested_paths.clone();
    let mut matched = 0usize;
    for entry in &status {
        let selected = requested_paths.contains(&entry.path)
            || entry
                .old_path
                .as_ref()
                .is_some_and(|old_path| requested_paths.contains(old_path));
        if !selected {
            continue;
        }
        matched += 1;
        if entry.staged == crate::status::ChangeKind::Unchanged
            || entry.staged == crate::status::ChangeKind::Ignored
        {
            return Err(RootError::Fail(EngineError::GitOperation {
                message: format!("selected path has no staged changes: {}", entry.path),
            }));
        }
        if entry.staged == crate::status::ChangeKind::Conflicted
            || entry.unstaged == crate::status::ChangeKind::Conflicted
        {
            return Err(RootError::Fail(EngineError::GitOperation {
                message: format!("selected path has unresolved conflicts: {}", entry.path),
            }));
        }
        if let Some(old_path) = &entry.old_path {
            commit_paths.insert(old_path.clone());
        }
        commit_paths.insert(entry.path.clone());
    }
    if matched == 0 {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: "selected paths are no longer present in the Git Changes Browser".into(),
        }));
    }

    let blocking = repo
        .commit_checks()
        .map_err(RootError::Fail)?
        .into_iter()
        .filter(|check| {
            check.blocking && check.kind == crate::checks::CommitCheckKind::IdentityMissing
        })
        .map(|check| check.message)
        .collect::<Vec<_>>();
    if !blocking.is_empty() {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: format!("commit blocked by checks: {}", blocking.join("; ")),
        }));
    }

    if options.run_before_commit_checks {
        for check in &options.before_commit_commands {
            let outcome = repo
                .run_check_command(check.command.clone(), check.args.clone())
                .map_err(RootError::Fail)?;
            if !outcome.success {
                let output = outcome.output.trim();
                let suffix = if output.is_empty() {
                    String::new()
                } else {
                    format!(": {output}")
                };
                return Err(RootError::Fail(EngineError::GitOperation {
                    message: format!("before-commit check '{}' failed{suffix}", check.command),
                }));
            }
        }
    }

    let identity = repo.git_identity().ok();
    let author_name = non_empty_option(options.author_name.clone());
    let author_email = non_empty_option(options.author_email.clone());
    let committer_name = non_empty_option(options.committer_name.clone());
    let committer_email = non_empty_option(options.committer_email.clone());
    if author_name.is_some() != author_email.is_some()
        || committer_name.is_some() != committer_email.is_some()
    {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: "author and committer require both name and email".into(),
        }));
    }

    repo.commit_with_options_paths(
        message.to_string(),
        commit_paths.into_iter().collect(),
        options.skip_hooks,
        author_name,
        author_email,
        committer_name,
        committer_email,
        identity.and_then(|value| value.signing_key),
        options.sign_off,
        options.co_authors.clone(),
        options.amend,
    )
    .map(|_| ())
    .map_err(RootError::Fail)
}

fn sort_push_root_indices(roots: &[GitRootInfo], root_indices: &mut [usize]) {
    root_indices.sort_by(|left, right| {
        let left_root = &roots[*left];
        let right_root = &roots[*right];
        let left_is_superproject = !left_root.is_submodule;
        let right_is_superproject = !right_root.is_submodule;
        left_is_superproject
            .cmp(&right_is_superproject)
            .then_with(|| {
                if left_root.is_submodule && right_root.is_submodule {
                    Path::new(&right_root.path)
                        .components()
                        .count()
                        .cmp(&Path::new(&left_root.path).components().count())
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .then_with(|| left.cmp(right))
    });
}

fn push_root_indices(roots: &[GitRootInfo], selected_root_paths: Option<&[String]>) -> Vec<usize> {
    let selected_root_paths = selected_root_paths.map(|paths| {
        paths
            .iter()
            .map(|path| std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path)))
            .collect::<Vec<_>>()
    });
    let mut root_indices = roots
        .iter()
        .enumerate()
        .filter(|(_, root)| {
            selected_root_paths.as_ref().map_or(true, |paths| {
                let root_path =
                    std::fs::canonicalize(&root.path).unwrap_or_else(|_| PathBuf::from(&root.path));
                paths.iter().any(|path| path == &root_path)
            })
        })
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    sort_push_root_indices(roots, &mut root_indices);
    root_indices
}

fn blocked_by_submodule_push(
    root: &GitRootInfo,
    roots: &[GitRootInfo],
    results: &[RootOperationResult],
) -> Option<String> {
    results.iter().find_map(|result| {
        let child = roots
            .iter()
            .find(|candidate| candidate.path == result.root_path)?;
        let child_blocked = !result.success
            || (result.skipped && result.message.starts_with("skipped because a submodule"));
        if !child_blocked
            || !child.is_submodule
            || child.path == root.path
            || !Path::new(&child.path).starts_with(Path::new(&root.path))
        {
            return None;
        }
        Some(format!(
            "skipped because a submodule push failed: {}",
            child.display_name
        ))
    })
}

fn blocked_by_submodule_update(
    root: &GitRootInfo,
    roots: &[GitRootInfo],
    results: &[RootOperationResult],
) -> Option<String> {
    results.iter().find_map(|result| {
        let child = roots
            .iter()
            .find(|candidate| candidate.path == result.root_path)?;
        if !child.is_submodule
            || child.path == root.path
            || !Path::new(&child.path).starts_with(Path::new(&root.path))
        {
            return None;
        }
        if result.success && !result.message.to_ascii_lowercase().contains("cancelled") {
            return None;
        }
        Some(format!(
            "skipped because a submodule update failed: {}",
            child.display_name
        ))
    })
}

/// Execute project-level Push with IntelliJ's dependency-aware semantics.
///
/// This is intentionally separate from the generic operation API: Push needs
/// the credential broker and cancellation handle, and a superproject must not
/// publish a gitlink when a nested submodule push has failed or been cancelled.
#[uniffi::export]
pub fn run_multi_root_push(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_push_with_options(scan_root, selected_root_paths, None, false, broker, cancel)
}

/// Execute project-level Push with the options shown by IntelliJ's standard
/// Push dialog. The selected tag mode and hook policy apply to every root
/// that is actually pushed, including nested repositories.
#[uniffi::export]
pub fn run_multi_root_push_with_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_push_with_force_options_internal(
        scan_root,
        selected_root_paths,
        None,
        tag_mode,
        skip_hooks,
        false,
        false,
        Vec::new(),
        broker,
        cancel,
    )
}

/// Execute project-level Push with an explicit force mode. The protected
/// patterns are supplied by the Swift project settings for the Git root that
/// owns each push, including nested submodules.
#[uniffi::export]
pub fn run_multi_root_push_with_force_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    force: bool,
    force_with_lease: bool,
    protected_branch_patterns: Vec<RootProtectedBranchPatterns>,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_push_with_force_options_internal(
        scan_root,
        selected_root_paths,
        None,
        tag_mode,
        skip_hooks,
        force,
        force_with_lease,
        protected_branch_patterns,
        broker,
        cancel,
    )
}

/// Execute project-level Push with one explicit remote/target per root.
/// Targets are root-qualified so equal branch names in independent
/// repositories cannot accidentally share a destination.
#[uniffi::export]
pub fn run_multi_root_push_with_targets(
    scan_root: String,
    targets: Vec<MultiRootPushTarget>,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    force: bool,
    force_with_lease: bool,
    protected_branch_patterns: Vec<RootProtectedBranchPatterns>,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let selected_root_paths = Some(
        targets
            .iter()
            .map(|target| target.root_path.clone())
            .collect(),
    );
    run_multi_root_push_with_force_options_internal(
        scan_root,
        selected_root_paths,
        Some(&targets),
        tag_mode,
        skip_hooks,
        force,
        force_with_lease,
        protected_branch_patterns,
        broker,
        cancel,
    )
}

fn run_multi_root_push_with_force_options_internal(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    explicit_targets: Option<&[MultiRootPushTarget]>,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    force: bool,
    force_with_lease: bool,
    protected_branch_patterns: Vec<RootProtectedBranchPatterns>,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let roots = discover_git_roots(scan_root, None)?;
    let root_indices = push_root_indices(&roots, selected_root_paths.as_deref());
    let mut results = Vec::with_capacity(root_indices.len());

    let total_roots = root_indices.len();
    for (position, index) in root_indices.into_iter().enumerate() {
        let root = &roots[index];
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            position,
            total_roots,
            root.path.clone(),
            root.display_name.clone(),
        );
        let result = run_single_multi_root_push(
            root,
            &roots,
            &results,
            tag_mode,
            skip_hooks,
            force,
            force_with_lease,
            explicit_targets.and_then(|targets| {
                targets.iter().find(|target| {
                    target.root_path == root.path
                        || canonical_root_path(&target.root_path) == canonical_root_path(&root.path)
                })
            }),
            root_protected_branch_patterns(root.path.as_str(), &protected_branch_patterns),
            &broker,
            &cancel,
        );
        let state = if result.success {
            if result.skipped {
                "skipped"
            } else {
                "completed"
            }
        } else {
            "failed"
        };
        crate::gitprocess::update_root_operation_progress(
            progress_generation,
            position + 1,
            state.to_string(),
        );
        results.push(result);
        crate::gitprocess::end_root_operation_progress(progress_generation);
    }

    Ok(results)
}

fn root_protected_branch_patterns<'a>(
    root_path: &str,
    patterns_by_root: &'a [RootProtectedBranchPatterns],
) -> &'a [String] {
    patterns_by_root
        .iter()
        .find(|entry| entry.root_path == root_path)
        .map(|entry| entry.patterns.as_slice())
        .unwrap_or(&[])
}

fn canonical_root_path(path: &str) -> String {
    std::fs::canonicalize(path)
        .unwrap_or_else(|_| PathBuf::from(path))
        .to_string_lossy()
        .into_owned()
}

fn run_single_multi_root_push(
    root: &GitRootInfo,
    roots: &[GitRootInfo],
    results: &[RootOperationResult],
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    force: bool,
    force_with_lease: bool,
    explicit_target: Option<&MultiRootPushTarget>,
    protected_branch_patterns: &[String],
    broker: &Arc<crate::auth::CredentialBroker>,
    cancel: &Arc<crate::gitprocess::GitCancelHandle>,
) -> RootOperationResult {
    if cancel.is_cancelled() {
        return root_skipped_result(root, "cancelled before push");
    }
    if let Some(message) = blocked_by_submodule_push(root, roots, results) {
        return root_skipped_result(root, &message);
    }

    let repo = match crate::repo::open_repository(root.path.clone()) {
        Ok(repo) => repo,
        Err(error) => return root_failure_result(root, error.to_string()),
    };
    let current_branch = match repo.branch_list() {
        Ok(branches) => branches,
        Err(error) => return root_failure_result(root, error.to_string()),
    }
    .into_iter()
    .find(|branch| branch.is_current)
    .map(|branch| branch.name);
    let Some(current_branch) = current_branch else {
        return root_skipped_result(root, "detached HEAD");
    };
    let remotes = match repo.remote_list() {
        Ok(remotes) if remotes.is_empty() => {
            return root_skipped_result(root, "no configured remote")
        }
        Ok(remotes) => remotes,
        Err(error) => return root_failure_result(root, error.to_string()),
    };
    let (remote_name, target_branch) = if let Some(target) = explicit_target {
        let remote = target.remote.trim();
        let branch = target.target_branch.trim();
        if remote.is_empty() || branch.is_empty() {
            return root_failure_result(
                root,
                "push target remote and branch must not be empty".to_string(),
            );
        }
        if !remotes.iter().any(|configured| configured.name == remote) {
            return root_failure_result(root, format!("remote does not exist: {remote}"));
        }
        (Some(remote.to_string()), branch.to_string())
    } else {
        (None, current_branch.clone())
    };
    if force && protected_branch_matches(&target_branch, protected_branch_patterns) {
        return root_failure_result(
            root,
            format!("force push blocked: {target_branch} is protected by Git settings"),
        );
    }
    let push_result = if explicit_target.is_some() && target_branch != current_branch {
        repo.push_refspec_with_options_and_auth_and_cancel(
            remote_name.unwrap_or_default(),
            format!("{current_branch}:refs/heads/{target_branch}"),
            force,
            force && force_with_lease,
            tag_mode,
            skip_hooks,
            Arc::clone(broker),
            Arc::clone(cancel),
        )
    } else {
        repo.push_with_options_and_auth_and_cancel(
            remote_name,
            current_branch,
            force,
            force && force_with_lease,
            false,
            tag_mode,
            skip_hooks,
            Arc::clone(broker),
            Arc::clone(cancel),
        )
    };
    match push_result {
        Ok(()) => root_success_result(root, format!("pushed {}", root.display_name)),
        Err(EngineError::Cancelled) => root_skipped_result(root, "cancelled during push"),
        Err(error) => root_failure_result(root, error.to_string()),
    }
}

fn protected_branch_matches(branch: &str, patterns: &[String]) -> bool {
    let normalized = branch
        .trim()
        .strip_prefix("refs/heads/")
        .unwrap_or(branch.trim());
    !normalized.is_empty()
        && patterns.iter().any(|pattern| {
            Regex::new(&format!("^(?:{pattern})$"))
                .map(|expression| expression.is_match(normalized))
                .unwrap_or(false)
        })
}

/// 按给定依赖顺序逐 root 执行 Rebase，并在第一个暂停/失败的 root 停止。
///
/// IntelliJ 的 RebaseSpec 会保存每个 root 的初始状态，并允许稍后从暂停的
/// root 继续；这里把同样的状态边界直接返回给 SwiftUI。`specs` 应由 UI
/// 按用户选中的 roots 构造；函数仍会把更深的嵌套仓库排在父仓库之前，避免
/// 在 submodule 尚未完成时先改写 superproject 的 gitlink。
#[uniffi::export]
pub fn run_multi_root_rebase(
    specs: Vec<MultiRootRebaseSpec>,
) -> Result<Vec<MultiRootRebaseResult>, EngineError> {
    run_multi_root_rebase_internal(specs, None)
}

/// Cancellable project-level Rebase. The same handle is passed to every
/// repository in dependency order, so cancelling a native todo or structured
/// rebase kills only the active Git process group and leaves later roots as
/// explicit skipped results. A root that already entered Git's rebase state
/// remains recoverable through Continue/Skip/Abort.
#[uniffi::export]
pub fn run_multi_root_rebase_with_cancel(
    specs: Vec<MultiRootRebaseSpec>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<MultiRootRebaseResult>, EngineError> {
    run_multi_root_rebase_internal(specs, Some(cancel))
}

fn run_multi_root_rebase_internal(
    mut specs: Vec<MultiRootRebaseSpec>,
    cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
) -> Result<Vec<MultiRootRebaseResult>, EngineError> {
    if specs.is_empty() {
        return Err(EngineError::GitOperation {
            message: "multi-root rebase requires at least one Git root".into(),
        });
    }
    specs.sort_by(|left, right| {
        std::path::Path::new(&right.root_path)
            .components()
            .count()
            .cmp(&std::path::Path::new(&left.root_path).components().count())
    });

    let total_roots = specs.len();
    let mut results = Vec::with_capacity(total_roots);
    let mut halted = false;
    for (position, spec) in specs.into_iter().enumerate() {
        let display_name = std::path::Path::new(&spec.root_path)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| spec.root_path.clone());
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            position,
            total_roots,
            spec.root_path.clone(),
            display_name.clone(),
        );
        if halted {
            results.push(MultiRootRebaseResult {
                root_path: spec.root_path,
                display_name,
                success: true,
                skipped: true,
                message: "not attempted after a previous rebase paused or failed".into(),
                initial_head: None,
                final_head: None,
                initial_branch: None,
                final_branch: None,
                completed: false,
                requires_finish: false,
                conflicts: Vec::new(),
            });
            crate::gitprocess::update_root_operation_progress(
                progress_generation,
                position + 1,
                "skipped".to_string(),
            );
            crate::gitprocess::end_root_operation_progress(progress_generation);
            continue;
        }
        if cancel.as_ref().is_some_and(|handle| handle.is_cancelled()) {
            results.push(MultiRootRebaseResult {
                root_path: spec.root_path,
                display_name,
                success: false,
                skipped: false,
                message: "rebase cancelled before this root started".into(),
                initial_head: None,
                final_head: None,
                initial_branch: None,
                final_branch: None,
                completed: false,
                requires_finish: false,
                conflicts: Vec::new(),
            });
            crate::gitprocess::update_root_operation_progress(
                progress_generation,
                position + 1,
                "cancelled".to_string(),
            );
            crate::gitprocess::end_root_operation_progress(progress_generation);
            halted = true;
            continue;
        }

        let repo = match crate::repo::open_repository(spec.root_path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(MultiRootRebaseResult {
                    root_path: spec.root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    initial_head: None,
                    final_head: None,
                    initial_branch: None,
                    final_branch: None,
                    completed: false,
                    requires_finish: false,
                    conflicts: Vec::new(),
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    position + 1,
                    "failed".to_string(),
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                halted = true;
                continue;
            }
        };
        let initial_head = repo
            .revision_commit_id(spec.branch.clone())
            .ok()
            .or_else(|| repo.head_commit_id());
        let initial_branch = repo
            .branch_list()
            .ok()
            .and_then(|branches| branches.into_iter().find(|branch| branch.is_current))
            .map(|branch| branch.name);

        let result = if let Some(raw_todo) = spec.raw_todo {
            match cancel.as_ref() {
                Some(cancel) => repo.rebase_branch_with_raw_todo_and_policy_and_cancel(
                    spec.onto,
                    spec.branch.clone(),
                    raw_todo,
                    spec.preserve_merges,
                    spec.auto_squash,
                    spec.keep_empty,
                    spec.update_refs,
                    spec.root,
                    spec.save_policy,
                    Arc::clone(cancel),
                ),
                None => repo.rebase_branch_with_raw_todo_and_policy(
                    spec.onto,
                    spec.branch.clone(),
                    raw_todo,
                    spec.preserve_merges,
                    spec.auto_squash,
                    spec.keep_empty,
                    spec.update_refs,
                    spec.root,
                    spec.save_policy,
                ),
            }
        } else if spec.interactive {
            match cancel.as_ref() {
                Some(cancel) if spec.preserve_merges && !spec.ordered_commit_ids.is_empty() => repo
                    .rebase_branch_with_ordered_merge_todo_and_policy_and_cancel(
                        spec.onto,
                        spec.branch.clone(),
                        spec.actions,
                        spec.ordered_commit_ids,
                        spec.auto_squash,
                        spec.keep_empty,
                        spec.update_refs,
                        spec.root,
                        spec.save_policy,
                        Arc::clone(cancel),
                    ),
                None if spec.preserve_merges && !spec.ordered_commit_ids.is_empty() => repo
                    .rebase_branch_with_ordered_merge_todo_and_policy(
                        spec.onto,
                        spec.branch.clone(),
                        spec.actions,
                        spec.ordered_commit_ids,
                        spec.auto_squash,
                        spec.keep_empty,
                        spec.update_refs,
                        spec.root,
                        spec.save_policy,
                    ),
                Some(cancel) => repo.rebase_branch_with_advanced_options_and_policy_and_cancel(
                    spec.onto,
                    spec.branch.clone(),
                    spec.actions,
                    spec.preserve_merges,
                    spec.auto_squash,
                    spec.keep_empty,
                    spec.update_refs,
                    spec.root,
                    spec.save_policy,
                    Arc::clone(cancel),
                ),
                None => repo.rebase_branch_with_advanced_options_and_policy(
                    spec.onto,
                    spec.branch.clone(),
                    spec.actions,
                    spec.preserve_merges,
                    spec.auto_squash,
                    spec.keep_empty,
                    spec.update_refs,
                    spec.root,
                    spec.save_policy,
                ),
            }
        } else {
            match cancel.as_ref() {
                Some(cancel) => repo.rebase_branch_with_options_and_policy_and_cancel(
                    spec.onto,
                    spec.branch.clone(),
                    spec.preserve_merges,
                    spec.auto_squash,
                    spec.keep_empty,
                    spec.update_refs,
                    spec.root,
                    spec.save_policy,
                    Arc::clone(cancel),
                ),
                None => repo.rebase_branch_with_options_and_policy(
                    spec.onto,
                    spec.branch.clone(),
                    spec.preserve_merges,
                    spec.auto_squash,
                    spec.keep_empty,
                    spec.update_refs,
                    spec.root,
                    spec.save_policy,
                ),
            }
        };

        match result {
            Ok(outcome) => {
                let final_head = repo
                    .revision_commit_id(spec.branch.clone())
                    .ok()
                    .or_else(|| repo.head_commit_id());
                let final_branch = repo
                    .branch_list()
                    .ok()
                    .and_then(|branches| branches.into_iter().find(|branch| branch.is_current))
                    .map(|branch| branch.name);
                let requires_finish = outcome.paused;
                results.push(MultiRootRebaseResult {
                    root_path: spec.root_path,
                    display_name,
                    success: true,
                    skipped: false,
                    message: if outcome.paused {
                        format!("rebase paused with {} conflict(s)", outcome.conflicts.len())
                    } else {
                        "rebase completed".into()
                    },
                    initial_head,
                    final_head,
                    initial_branch,
                    final_branch,
                    completed: !outcome.paused,
                    requires_finish,
                    conflicts: outcome.conflicts,
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    position + 1,
                    if outcome.paused {
                        "paused".to_string()
                    } else {
                        "completed".to_string()
                    },
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                if outcome.paused {
                    halted = true;
                }
            }
            Err(error) => {
                let final_head = repo
                    .revision_commit_id(spec.branch.clone())
                    .ok()
                    .or_else(|| repo.head_commit_id());
                let final_branch = repo
                    .branch_list()
                    .ok()
                    .and_then(|branches| branches.into_iter().find(|branch| branch.is_current))
                    .map(|branch| branch.name);
                let requires_finish = repo
                    .operation_state()
                    .map(|state| state.is_some())
                    .unwrap_or(false);
                let message = if matches!(error, EngineError::Cancelled) {
                    if requires_finish {
                        "rebase cancelled; Git rebase remains available for recovery".into()
                    } else {
                        "rebase cancelled; the local scene was restored".into()
                    }
                } else {
                    error.to_string()
                };
                results.push(MultiRootRebaseResult {
                    root_path: spec.root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message,
                    initial_head,
                    final_head,
                    initial_branch,
                    final_branch,
                    completed: false,
                    requires_finish,
                    conflicts: Vec::new(),
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    position + 1,
                    if matches!(error, EngineError::Cancelled) {
                        "cancelled".to_string()
                    } else {
                        "failed".to_string()
                    },
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                halted = true;
            }
        }
    }
    Ok(results)
}

/// 在选中的 Git roots 上创建同名本地分支，并可选择同时 checkout。
///
/// 操作按 IntelliJ 的 `GitCreateBranchOperation` 语义顺序执行：一旦某个
/// root 失败，后续 root 标记为 skipped，已经成功的 root 保留为可回滚的
/// partial state，由 UI 询问用户是否回滚，而不是静默吞掉部分成功。
#[uniffi::export]
pub fn run_multi_root_branch_create(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    name: String,
    start_point: Option<String>,
    checkout: bool,
) -> Result<Vec<MultiRootBranchResult>, EngineError> {
    run_multi_root_branch_create_internal(
        scan_root,
        selected_root_paths,
        name,
        start_point,
        checkout,
        false,
    )
}

/// Multi-root New Branch with IntelliJ's explicit overwrite/reset option.
/// Existing branch tips are captured per root so a later rollback restores
/// the old ref instead of deleting it.
#[uniffi::export]
pub fn run_multi_root_branch_create_with_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    name: String,
    start_point: Option<String>,
    checkout: bool,
    reset: bool,
) -> Result<Vec<MultiRootBranchResult>, EngineError> {
    run_multi_root_branch_create_internal(
        scan_root,
        selected_root_paths,
        name,
        start_point,
        checkout,
        reset,
    )
}

fn run_multi_root_branch_create_internal(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    name: String,
    start_point: Option<String>,
    checkout: bool,
    reset: bool,
) -> Result<Vec<MultiRootBranchResult>, EngineError> {
    let name = name.trim().to_string();
    if name.is_empty() || name.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "branch name must not be empty or start with '-'".into(),
        });
    }
    let start_point = start_point
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if start_point
        .as_deref()
        .is_some_and(|value| value.starts_with('-'))
    {
        return Err(EngineError::GitOperation {
            message: "start point must not start with '-'".into(),
        });
    }

    let roots = discover_git_roots(scan_root, None)?;
    let roots = if let Some(selected_root_paths) = selected_root_paths {
        let selected_root_paths = selected_root_paths
            .iter()
            .map(|path| {
                std::fs::canonicalize(path)
                    .unwrap_or_else(|_| PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<Vec<_>>();
        let selected_roots = roots
            .into_iter()
            .filter(|root| selected_root_paths.iter().any(|path| path == &root.path))
            .collect::<Vec<_>>();
        if selected_roots.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected Git root was not found".into(),
            });
        }
        selected_roots
    } else {
        roots
    };

    let mut results = Vec::with_capacity(roots.len());
    for (index, root) in roots.iter().enumerate() {
        let previous_branch = root.head_branch.clone();
        let previous_head = root.head_id.clone();
        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(MultiRootBranchResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    branch_created: false,
                    checked_out: false,
                    previous_branch,
                    previous_head,
                    previous_branch_tip: None,
                    expected_branch_tip: None,
                });
                for skipped_root in roots.iter().skip(index + 1) {
                    results.push(MultiRootBranchResult {
                        root_path: skipped_root.path.clone(),
                        display_name: skipped_root.display_name.clone(),
                        success: true,
                        skipped: true,
                        message: "not attempted after branch creation failure".into(),
                        branch_created: false,
                        checked_out: false,
                        previous_branch: skipped_root.head_branch.clone(),
                        previous_head: skipped_root.head_id.clone(),
                        previous_branch_tip: None,
                        expected_branch_tip: None,
                    });
                }
                break;
            }
        };

        let local_branch_exists = repo
            .branch_list()
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot inspect branch before multi-root creation: {error}"),
            })?
            .into_iter()
            .any(|branch| branch.name == name);
        let previous_branch_tip = if local_branch_exists {
            Some(repo.revision_commit_id(name.clone())?)
        } else {
            None
        };
        let was_current = previous_branch.as_deref() == Some(name.as_str());
        let operation =
            repo.branch_create_or_reset(name.clone(), start_point.clone(), checkout, reset);
        match operation {
            Ok(()) => {
                let expected_branch_tip = repo.revision_commit_id(name.clone()).ok();
                results.push(MultiRootBranchResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: true,
                    skipped: false,
                    message: String::new(),
                    branch_created: !local_branch_exists,
                    checked_out: checkout || (reset && was_current),
                    previous_branch,
                    previous_head,
                    previous_branch_tip: if reset { previous_branch_tip } else { None },
                    expected_branch_tip,
                });
            }
            Err(error) => {
                results.push(MultiRootBranchResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    branch_created: false,
                    checked_out: false,
                    previous_branch,
                    previous_head,
                    previous_branch_tip: None,
                    expected_branch_tip: None,
                });
                for skipped_root in roots.iter().skip(index + 1) {
                    results.push(MultiRootBranchResult {
                        root_path: skipped_root.path.clone(),
                        display_name: skipped_root.display_name.clone(),
                        success: true,
                        skipped: true,
                        message: "not attempted after branch creation failure".into(),
                        branch_created: false,
                        checked_out: false,
                        previous_branch: skipped_root.head_branch.clone(),
                        previous_head: skipped_root.head_id.clone(),
                        previous_branch_tip: None,
                        expected_branch_tip: None,
                    });
                }
                break;
            }
        }
    }
    Ok(results)
}

/// 在选中的 Git roots 上按 IntelliJ `GitMergeOperation` 顺序执行 merge。
///
/// 冲突 root 会作为成功处理结果返回并保留 operation state，继续处理后续
/// roots；非冲突致命错误会停止执行，后续 roots 标记为 skipped。这样 SwiftUI
/// 可以同时呈现冲突工作台和“回滚已成功 roots”的明确选择，而不会把部分
/// 成功伪装成全局成功。
#[uniffi::export]
pub fn run_multi_root_merge(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    branch: String,
    options: MergeOptions,
) -> Result<Vec<MultiRootMergeResult>, EngineError> {
    run_multi_root_merge_internal(scan_root, selected_root_paths, branch, options, None)
}

/// Multi-root Smart Merge with IntelliJ's configured local-change policy.
/// Each root owns its own persisted preservation marker, so a later Continue,
/// Abort, or restore-conflict resolution can recover roots independently.
#[uniffi::export]
pub fn run_multi_root_merge_with_policy(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    branch: String,
    options: MergeOptions,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<MultiRootMergeResult>, EngineError> {
    run_multi_root_merge_internal(
        scan_root,
        selected_root_paths,
        branch,
        options,
        Some(save_policy),
    )
}

fn run_multi_root_merge_internal(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    branch: String,
    options: MergeOptions,
    save_policy: Option<LocalChangesSavePolicy>,
) -> Result<Vec<MultiRootMergeResult>, EngineError> {
    let branch = branch.trim().to_string();
    if branch.is_empty() || branch.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "merge reference must not be empty or start with '-'".into(),
        });
    }

    let roots = discover_git_roots(scan_root, None)?;
    let roots = if let Some(selected_root_paths) = selected_root_paths {
        let selected_root_paths = selected_root_paths
            .iter()
            .map(|path| {
                std::fs::canonicalize(path)
                    .unwrap_or_else(|_| PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<Vec<_>>();
        let selected_roots = roots
            .into_iter()
            .filter(|root| selected_root_paths.iter().any(|path| path == &root.path))
            .collect::<Vec<_>>();
        if selected_roots.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected Git root was not found".into(),
            });
        }
        selected_roots
    } else {
        roots
    };

    let total_roots = roots.len();
    let mut results = Vec::with_capacity(total_roots);
    for (index, root) in roots.iter().enumerate() {
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            index,
            total_roots,
            root.path.clone(),
            root.display_name.clone(),
        );
        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(MultiRootMergeResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    initial_head: root.head_id.clone(),
                    final_head: None,
                    completed: false,
                    requires_finish: false,
                    conflicts: Vec::new(),
                    local_changes_overwrite_paths: Vec::new(),
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    index + 1,
                    "failed".to_string(),
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                for (skipped_index, skipped_root) in roots.iter().enumerate().skip(index + 1) {
                    let skipped_generation = crate::gitprocess::begin_root_operation_progress(
                        skipped_index,
                        total_roots,
                        skipped_root.path.clone(),
                        skipped_root.display_name.clone(),
                    );
                    results.push(MultiRootMergeResult {
                        root_path: skipped_root.path.clone(),
                        display_name: skipped_root.display_name.clone(),
                        success: true,
                        skipped: true,
                        message: "not attempted after merge failure".into(),
                        initial_head: skipped_root.head_id.clone(),
                        final_head: skipped_root.head_id.clone(),
                        completed: false,
                        requires_finish: false,
                        conflicts: Vec::new(),
                        local_changes_overwrite_paths: Vec::new(),
                    });
                    crate::gitprocess::update_root_operation_progress(
                        skipped_generation,
                        skipped_index + 1,
                        "skipped".to_string(),
                    );
                    crate::gitprocess::end_root_operation_progress(skipped_generation);
                }
                break;
            }
        };
        // Read HEAD from the opened repository immediately before merging. The
        // discovery snapshot can be stale if another process committed while
        // the roots were being scanned; rollback must never target that older
        // snapshot.
        let initial_head = repo.head_commit_id();

        let merge_result = match save_policy {
            Some(policy) => {
                repo.merge_with_settings_and_policy(branch.clone(), options.clone(), policy)
            }
            None => repo.merge_with_settings(branch.clone(), options.clone()),
        };
        match merge_result {
            Ok(outcome) => {
                let final_head = repo.head_commit_id();
                let conflicts = outcome.conflicts.clone();
                let message = if !conflicts.is_empty() {
                    format!("merge paused with {} conflict(s)", conflicts.len())
                } else if outcome.requires_finish {
                    "merge applied; explicit finish required".into()
                } else if initial_head == final_head {
                    "already up to date".into()
                } else {
                    "merge completed".into()
                };
                results.push(MultiRootMergeResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: true,
                    skipped: false,
                    message,
                    initial_head,
                    final_head,
                    completed: outcome.completed,
                    requires_finish: outcome.requires_finish,
                    conflicts,
                    local_changes_overwrite_paths: Vec::new(),
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    index + 1,
                    if !outcome.conflicts.is_empty() || outcome.requires_finish {
                        "paused".to_string()
                    } else {
                        "completed".to_string()
                    },
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
            }
            Err(error) => {
                let final_head = repo.head_commit_id();
                let local_changes_overwrite_paths = match &error {
                    EngineError::LocalChangesWouldBeOverwritten { paths } => paths.clone(),
                    _ => Vec::new(),
                };
                results.push(MultiRootMergeResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    initial_head,
                    final_head,
                    completed: false,
                    requires_finish: repo.merge_in_progress(),
                    conflicts: Vec::new(),
                    local_changes_overwrite_paths,
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    index + 1,
                    "failed".to_string(),
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                for (skipped_index, skipped_root) in roots.iter().enumerate().skip(index + 1) {
                    let skipped_generation = crate::gitprocess::begin_root_operation_progress(
                        skipped_index,
                        total_roots,
                        skipped_root.path.clone(),
                        skipped_root.display_name.clone(),
                    );
                    results.push(MultiRootMergeResult {
                        root_path: skipped_root.path.clone(),
                        display_name: skipped_root.display_name.clone(),
                        success: true,
                        skipped: true,
                        message: "not attempted after merge failure".into(),
                        initial_head: skipped_root.head_id.clone(),
                        final_head: skipped_root.head_id.clone(),
                        completed: false,
                        requires_finish: false,
                        conflicts: Vec::new(),
                        local_changes_overwrite_paths: Vec::new(),
                    });
                    crate::gitprocess::update_root_operation_progress(
                        skipped_generation,
                        skipped_index + 1,
                        "skipped".to_string(),
                    );
                    crate::gitprocess::end_root_operation_progress(skipped_generation);
                }
                break;
            }
        }
    }
    Ok(results)
}

/// 在选定 Git roots 上聚合 Reset。每个 root 独立执行并保留结构化的
/// local-overwrite paths，UI 可以一次展示所有受影响文件，再重试 Smart
/// 或 Hard Force，而不会把第一个失败 root 的错误压扁成整体失败。
#[uniffi::export]
pub fn run_multi_root_reset_with_policy(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    commit_id: String,
    mode: ResetMode,
    save_policy: LocalChangesSavePolicy,
    smart: bool,
    force: bool,
) -> Result<Vec<MultiRootResetResult>, EngineError> {
    let commit_id = commit_id.trim().to_string();
    if commit_id.is_empty() {
        return Err(EngineError::GitOperation {
            message: "reset: commit id is required".into(),
        });
    }
    let discovered = discover_git_roots(scan_root, None)?;
    let roots = if let Some(selected_root_paths) = selected_root_paths {
        let selected_root_paths = selected_root_paths
            .iter()
            .map(|path| {
                std::fs::canonicalize(path)
                    .unwrap_or_else(|_| PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<Vec<_>>();
        discovered
            .into_iter()
            .filter(|root| selected_root_paths.iter().any(|path| path == &root.path))
            .collect::<Vec<_>>()
    } else {
        discovered
    };
    if roots.is_empty() {
        return Err(EngineError::GitOperation {
            message: "selected Git root was not found".into(),
        });
    }

    let targets = roots
        .iter()
        .map(|root| MultiRootResetTarget {
            root_path: root.path.clone(),
            commit_id: commit_id.clone(),
        })
        .collect();
    run_multi_root_reset_targets(roots, targets, mode, save_policy, smart, force)
}

/// Reset one selected revision per Git root. This is the aggregate Log form
/// of Reset: a selection containing one commit from root A and one commit from
/// root B must not silently apply A's revision to B.
#[uniffi::export]
pub fn run_multi_root_reset_with_targets(
    scan_root: String,
    targets: Vec<MultiRootResetTarget>,
    mode: ResetMode,
    save_policy: LocalChangesSavePolicy,
    smart: bool,
    force: bool,
) -> Result<Vec<MultiRootResetResult>, EngineError> {
    if targets.is_empty() {
        return Err(EngineError::GitOperation {
            message: "reset: at least one Git root target is required".into(),
        });
    }

    let mut normalized_targets = HashMap::with_capacity(targets.len());
    for target in targets {
        let root_path = std::fs::canonicalize(&target.root_path)
            .unwrap_or_else(|_| PathBuf::from(&target.root_path))
            .display()
            .to_string();
        let commit_id = target.commit_id.trim().to_string();
        if commit_id.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!("reset: commit id is required for root '{root_path}'"),
            });
        }
        if normalized_targets
            .insert(root_path.clone(), commit_id)
            .is_some()
        {
            return Err(EngineError::GitOperation {
                message: format!("reset: duplicate target for root '{root_path}'"),
            });
        }
    }

    let roots = discover_git_roots(scan_root, None)?
        .into_iter()
        .filter(|root| normalized_targets.contains_key(&root.path))
        .collect::<Vec<_>>();
    if roots.is_empty() {
        return Err(EngineError::GitOperation {
            message: "selected Git root was not found".into(),
        });
    }
    if roots.len() != normalized_targets.len() {
        let found_paths = roots
            .iter()
            .map(|root| root.path.as_str())
            .collect::<std::collections::HashSet<_>>();
        let missing = normalized_targets
            .keys()
            .filter(|path| !found_paths.contains(path.as_str()))
            .cloned()
            .collect::<Vec<_>>();
        return Err(EngineError::GitOperation {
            message: format!("selected Git root was not found: {}", missing.join(", ")),
        });
    }

    let targets = roots
        .iter()
        .map(|root| MultiRootResetTarget {
            root_path: root.path.clone(),
            commit_id: normalized_targets
                .get(&root.path)
                .expect("filtered root must have a target")
                .clone(),
        })
        .collect();
    run_multi_root_reset_targets(roots, targets, mode, save_policy, smart, force)
}

fn run_multi_root_reset_targets(
    roots: Vec<GitRootInfo>,
    targets: Vec<MultiRootResetTarget>,
    mode: ResetMode,
    save_policy: LocalChangesSavePolicy,
    smart: bool,
    force: bool,
) -> Result<Vec<MultiRootResetResult>, EngineError> {
    let target_by_root = targets
        .into_iter()
        .map(|target| (target.root_path, target.commit_id))
        .collect::<HashMap<_, _>>();

    let total_roots = roots.len();
    let mut results = Vec::with_capacity(total_roots);
    for (index, root) in roots.into_iter().enumerate() {
        let root_path = root.path.clone();
        let display_name = root.display_name.clone();
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            index,
            total_roots,
            root_path.clone(),
            display_name.clone(),
        );
        let commit_id = target_by_root
            .get(&root.path)
            .expect("every reset root must have a target");
        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(MultiRootResetResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    local_changes_overwrite_paths: Vec::new(),
                    initial_head: None,
                    final_head: None,
                    initial_branch: None,
                    final_branch: None,
                    rollback_id: None,
                });
                crate::gitprocess::update_root_operation_progress(
                    progress_generation,
                    index + 1,
                    "failed".to_string(),
                );
                crate::gitprocess::end_root_operation_progress(progress_generation);
                continue;
            }
        };
        let initial_head = repo.head_commit_id();
        let initial_branch = repo.branch_list().ok().map(|branches| {
            branches
                .into_iter()
                .find(|branch| branch.is_current)
                .map(|branch| branch.name)
                .unwrap_or_default()
        });
        let operation =
            repo.reset_with_recovery(commit_id.clone(), mode, save_policy, smart, force);
        let short_id = commit_id.chars().take(7).collect::<String>();
        match operation {
            Ok(recovery) => {
                results.push(MultiRootResetResult {
                    root_path,
                    display_name,
                    success: true,
                    skipped: false,
                    message: format!("reset to {short_id}"),
                    local_changes_overwrite_paths: Vec::new(),
                    initial_head: Some(recovery.initial_head),
                    final_head: Some(recovery.final_head),
                    initial_branch: recovery.initial_branch,
                    final_branch: recovery.final_branch,
                    rollback_id: recovery.rollback_id,
                });
            }
            Err(error) => {
                let local_changes_overwrite_paths = match &error {
                    EngineError::LocalChangesWouldBeOverwritten { paths } => paths.clone(),
                    _ => Vec::new(),
                };
                results.push(MultiRootResetResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    local_changes_overwrite_paths,
                    initial_head,
                    final_head: repo.head_commit_id(),
                    initial_branch,
                    final_branch: repo.branch_list().ok().map(|branches| {
                        branches
                            .into_iter()
                            .find(|branch| branch.is_current)
                            .map(|branch| branch.name)
                            .unwrap_or_default()
                    }),
                    rollback_id: None,
                });
            }
        }
        let result = results.last().expect("reset result was just appended");
        let state = if result.success {
            if result.skipped {
                "skipped"
            } else {
                "completed"
            }
        } else {
            "failed"
        };
        crate::gitprocess::update_root_operation_progress(
            progress_generation,
            index + 1,
            state.to_string(),
        );
        crate::gitprocess::end_root_operation_progress(progress_generation);
    }
    Ok(results)
}

/// 回滚 soft reset 已成功的 root。每个 root 都使用 expected HEAD/branch
/// 做 compare-and-swap；用户在 reset 后切换分支或提交时，回滚只拒绝该 root。
#[uniffi::export]
pub fn rollback_multi_root_reset(
    targets: Vec<MultiRootResetRollbackTarget>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    if targets.is_empty() {
        return Err(EngineError::GitOperation {
            message: "soft reset rollback requires at least one Git root target".into(),
        });
    }

    let mut results = Vec::with_capacity(targets.len());
    for target in targets {
        if target.mode != ResetMode::Soft {
            results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: false,
                skipped: false,
                message: "soft reset rollback refused: target mode is not Soft".into(),
            });
            continue;
        }
        let repo = match crate::repo::open_repository(target.root_path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(RootOperationResult {
                    root_path: target.root_path,
                    display_name: target.display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                });
                continue;
            }
        };
        match repo.restore_head_ref_if_expected(
            target.initial_head,
            target.expected_head,
            target.expected_head_branch,
        ) {
            Ok(()) => results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: true,
                skipped: false,
                message: "soft reset rollback completed".into(),
            }),
            Err(error) => results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: false,
                skipped: false,
                message: error.to_string(),
            }),
        }
    }
    Ok(results)
}

/// Full-scene reset rollback. Unlike the legacy soft action above, this
/// restores the ref, index, tracked worktree, and untracked/ignored files from
/// the repository-owned recovery marker. Each root is independently guarded;
/// one stale root does not prevent safe rollback of the others.
#[uniffi::export]
pub fn rollback_multi_root_reset_recovery(
    targets: Vec<ResetRecoveryTarget>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    if targets.is_empty() {
        return Err(EngineError::GitOperation {
            message: "reset rollback requires at least one Git root target".into(),
        });
    }

    let mut results = Vec::with_capacity(targets.len());
    for target in targets {
        let repo = match crate::repo::open_repository(target.root_path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(RootOperationResult {
                    root_path: target.root_path,
                    display_name: target.display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                });
                continue;
            }
        };
        match repo.rollback_reset_recovery(target.clone()) {
            Ok(()) => results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: true,
                skipped: false,
                message: "reset rollback completed".into(),
            }),
            Err(error) => results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: false,
                skipped: false,
                message: error.to_string(),
            }),
        }
    }
    Ok(results)
}

/// Keep completed reset results while releasing their repository-owned undo
/// snapshots. Each root is independently guarded so a stale root cannot cause
/// another root's valid recovery action to be discarded.
#[uniffi::export]
pub fn keep_multi_root_reset_recovery(
    targets: Vec<ResetRecoveryTarget>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    if targets.is_empty() {
        return Err(EngineError::GitOperation {
            message: "reset keep requires at least one Git root target".into(),
        });
    }

    let mut results = Vec::with_capacity(targets.len());
    for target in targets {
        let repo = match crate::repo::open_repository(target.root_path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(RootOperationResult {
                    root_path: target.root_path,
                    display_name: target.display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                });
                continue;
            }
        };
        match repo.keep_reset_recovery(target.clone()) {
            Ok(()) => results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: true,
                skipped: false,
                message: "reset result kept".into(),
            }),
            Err(error) => results.push(RootOperationResult {
                root_path: target.root_path,
                display_name: target.display_name,
                success: false,
                skipped: false,
                message: error.to_string(),
            }),
        }
    }
    Ok(results)
}

/// 在项目中当前已签出的 root 上聚合 IntelliJ force-pushed branch update。
/// 每个 root 先保留 dirty path 快照，再独立执行 fetch/rebuild；Smart 路径
/// 使用每个 Repository 自己的 preserving marker，Force 路径显式丢弃 tracked
/// local changes。一个 root 的失败不会污染其它 root 的 branch/upstream 状态。
#[uniffi::export]
pub fn run_multi_root_force_pushed_branch_update_with_auth_and_cancel(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
    force: bool,
) -> Result<Vec<MultiRootForcePushedBranchUpdateResult>, EngineError> {
    let discovered = discover_git_roots(scan_root, None)?;
    let roots = if let Some(selected_root_paths) = selected_root_paths {
        let selected_root_paths = selected_root_paths
            .iter()
            .map(|path| {
                std::fs::canonicalize(path)
                    .unwrap_or_else(|_| PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<Vec<_>>();
        let selected = discovered
            .into_iter()
            .filter(|root| selected_root_paths.iter().any(|path| path == &root.path))
            .collect::<Vec<_>>();
        if selected.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected Git root was not found".into(),
            });
        }
        selected
    } else {
        discovered
    };

    let mut results = Vec::with_capacity(roots.len());
    for (index, root) in roots.iter().enumerate() {
        if cancel.is_cancelled() {
            for skipped_root in roots.iter().skip(index) {
                results.push(MultiRootForcePushedBranchUpdateResult {
                    root_path: skipped_root.path.clone(),
                    display_name: skipped_root.display_name.clone(),
                    success: true,
                    skipped: true,
                    message: "not attempted after cancellation".into(),
                    branch: skipped_root.head_branch.clone().unwrap_or_default(),
                    upstream: String::new(),
                    replayed_commits: 0,
                    used_merge_update: false,
                    received_commits_count: 0,
                    updated_files_count: 0,
                    update_range_start: None,
                    new_upstream_tip: String::new(),
                    local_changes_overwrite_paths: Vec::new(),
                });
            }
            break;
        }

        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(MultiRootForcePushedBranchUpdateResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    branch: root.head_branch.clone().unwrap_or_default(),
                    upstream: String::new(),
                    replayed_commits: 0,
                    used_merge_update: false,
                    received_commits_count: 0,
                    updated_files_count: 0,
                    update_range_start: None,
                    new_upstream_tip: String::new(),
                    local_changes_overwrite_paths: Vec::new(),
                });
                continue;
            }
        };
        let Some(head_branch) = root.head_branch.as_deref() else {
            results.push(MultiRootForcePushedBranchUpdateResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: true,
                message: "detached HEAD; force-pushed update skipped".into(),
                branch: String::new(),
                upstream: String::new(),
                replayed_commits: 0,
                used_merge_update: false,
                received_commits_count: 0,
                updated_files_count: 0,
                update_range_start: None,
                new_upstream_tip: String::new(),
                local_changes_overwrite_paths: Vec::new(),
            });
            continue;
        };
        let tracked_remote = match repo.sync_status() {
            Ok(statuses) => statuses.into_iter().find(|status| {
                status.branch == head_branch
                    && status.tracking_exists
                    && status.upstream.contains('/')
            }),
            Err(error) => {
                results.push(MultiRootForcePushedBranchUpdateResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    branch: head_branch.to_string(),
                    upstream: String::new(),
                    replayed_commits: 0,
                    used_merge_update: false,
                    received_commits_count: 0,
                    updated_files_count: 0,
                    update_range_start: None,
                    new_upstream_tip: String::new(),
                    local_changes_overwrite_paths: Vec::new(),
                });
                continue;
            }
        };
        if tracked_remote.is_none() {
            results.push(MultiRootForcePushedBranchUpdateResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: true,
                message: "no tracked remote branch; force-pushed update skipped".into(),
                branch: head_branch.to_string(),
                upstream: String::new(),
                replayed_commits: 0,
                used_merge_update: false,
                received_commits_count: 0,
                updated_files_count: 0,
                update_range_start: None,
                new_upstream_tip: String::new(),
                local_changes_overwrite_paths: Vec::new(),
            });
            continue;
        }
        let dirty_paths = match repo.status() {
            Ok(entries) => entries
                .into_iter()
                .filter(|entry| {
                    entry.staged != crate::status::ChangeKind::Unchanged
                        || (entry.unstaged != crate::status::ChangeKind::Unchanged
                            && entry.unstaged != crate::status::ChangeKind::Ignored)
                })
                .map(|entry| entry.path)
                .collect::<Vec<_>>(),
            Err(error) => {
                results.push(MultiRootForcePushedBranchUpdateResult {
                    root_path: root.path.clone(),
                    display_name: root.display_name.clone(),
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                    branch: root.head_branch.clone().unwrap_or_default(),
                    upstream: String::new(),
                    replayed_commits: 0,
                    used_merge_update: false,
                    received_commits_count: 0,
                    updated_files_count: 0,
                    update_range_start: None,
                    new_upstream_tip: String::new(),
                    local_changes_overwrite_paths: Vec::new(),
                });
                continue;
            }
        };
        let operation = if force {
            repo.force_pushed_branch_update_with_auth_and_cancel_force(
                Arc::clone(&broker),
                Arc::clone(&cancel),
            )
        } else {
            repo.force_pushed_branch_update_with_auth_and_cancel(
                save_policy,
                Arc::clone(&broker),
                Arc::clone(&cancel),
            )
        };
        match operation {
            Ok(ForcePushedBranchUpdateOutcome {
                branch,
                upstream,
                replayed_commits,
                used_merge_update,
                received_commits_count,
                updated_files_count,
                update_range_start,
                new_upstream_tip,
            }) => results.push(MultiRootForcePushedBranchUpdateResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: false,
                message: if used_merge_update {
                    "updated with merge fallback".into()
                } else {
                    format!("replayed {replayed_commits} local commit(s)")
                },
                branch,
                upstream,
                replayed_commits,
                used_merge_update,
                received_commits_count,
                updated_files_count,
                update_range_start,
                new_upstream_tip,
                local_changes_overwrite_paths: dirty_paths,
            }),
            Err(error) => results.push(MultiRootForcePushedBranchUpdateResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: false,
                skipped: false,
                message: error.to_string(),
                branch: root.head_branch.clone().unwrap_or_default(),
                upstream: String::new(),
                replayed_commits: 0,
                used_merge_update: false,
                received_commits_count: 0,
                updated_files_count: 0,
                update_range_start: None,
                new_upstream_tip: String::new(),
                local_changes_overwrite_paths: dirty_paths,
            }),
        }
    }
    Ok(results)
}

/// 回滚多 root 新建分支已经成功的部分。
///
/// 回滚是显式动作：checkout 模式先恢复原始 branch/detached HEAD，再用安全
/// 的 `git branch -d` 删除新分支；任何一个 root 的回滚失败都独立返回，其他
/// root 仍继续处理，避免把可恢复状态隐藏起来。
#[uniffi::export]
pub fn rollback_multi_root_branch_create(
    name: String,
    targets: Vec<MultiRootBranchTarget>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let targets = targets
        .into_iter()
        .map(|target| MultiRootBranchCreateTarget {
            root_path: target.root_path,
            checked_out: target.checked_out,
            previous_branch: target.previous_branch,
            previous_head: target.previous_head,
            expected_head: target.expected_head,
            expected_branch: target.expected_branch,
            previous_branch_tip: None,
            expected_branch_tip: None,
        })
        .collect();
    rollback_multi_root_branch_create_internal(name, targets, false)
}

/// Rollback stateful multi-root branch creation, restoring overwritten branch
/// tips when the forward operation used the explicit reset option.
#[uniffi::export]
pub fn rollback_multi_root_branch_create_with_state(
    name: String,
    targets: Vec<MultiRootBranchCreateTarget>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    rollback_multi_root_branch_create_internal(name, targets, true)
}

fn rollback_multi_root_branch_create_internal(
    name: String,
    targets: Vec<MultiRootBranchCreateTarget>,
    require_expected_tip: bool,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let name = name.trim().to_string();
    if name.is_empty() || name.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "branch name must not be empty or start with '-'".into(),
        });
    }

    let mut results = Vec::with_capacity(targets.len());
    for target in targets {
        let display_name = Path::new(&target.root_path)
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| target.root_path.clone());
        let repo = match crate::repo::open_repository(target.root_path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(root_failure_result(
                    &GitRootInfo {
                        path: target.root_path,
                        display_name,
                        relative_path: String::new(),
                        is_submodule: false,
                        head_branch: None,
                        head_id: None,
                        dirty: false,
                        operation: None,
                    },
                    error.to_string(),
                ));
                continue;
            }
        };

        let root_path = target.root_path.clone();
        if require_expected_tip && target.expected_branch_tip.is_none() {
            results.push(RootOperationResult {
                root_path,
                display_name,
                success: false,
                skipped: false,
                message: "branch creation rollback refused: expected branch tip was not persisted"
                    .into(),
            });
            continue;
        }
        let current_branch = match repo.branch_list() {
            Ok(branches) => branches
                .into_iter()
                .find(|branch| branch.is_current)
                .map(|branch| branch.name),
            Err(error) => {
                results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!("cannot verify branch rollback state: {error}"),
                });
                continue;
            }
        };

        if let Some(expected_tip) = target.expected_branch_tip.as_deref() {
            let actual_tip = match repo.revision_commit_id(name.clone()) {
                Ok(tip) => tip,
                Err(error) => {
                    results.push(RootOperationResult {
                        root_path,
                        display_name,
                        success: false,
                        skipped: false,
                        message: format!("cannot verify branch tip before rollback: {error}"),
                    });
                    continue;
                }
            };
            if actual_tip != expected_tip {
                results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!(
                        "branch creation rollback refused: expected '{}' tip {}, found {}",
                        name, expected_tip, actual_tip
                    ),
                });
                continue;
            }
        }

        if let Some(expected_head) = target.expected_head.as_deref() {
            let actual_head = match repo.revision_commit_id("HEAD".into()) {
                Ok(head) => head,
                Err(error) => {
                    results.push(RootOperationResult {
                        root_path,
                        display_name,
                        success: false,
                        skipped: false,
                        message: format!("cannot verify HEAD before rollback: {error}"),
                    });
                    continue;
                }
            };
            if actual_head != expected_head {
                results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!(
                        "branch creation rollback refused: expected HEAD {}, found {}",
                        expected_head, actual_head
                    ),
                });
                continue;
            }
        }

        if let Some(expected_branch) = target.expected_branch.as_deref() {
            if current_branch.as_deref() != Some(expected_branch) {
                results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!(
                        "branch creation rollback refused: expected current branch '{}', found {:?}",
                        expected_branch, current_branch
                    ),
                });
                continue;
            }
        } else if target.checked_out || current_branch.as_deref() == Some(name.as_str()) {
            results.push(RootOperationResult {
                root_path,
                display_name,
                success: false,
                skipped: false,
                message: "branch creation rollback refused: checkout state was not persisted"
                    .into(),
            });
            continue;
        }

        if target.checked_out && target.previous_branch_tip.is_none() {
            let restore = match target.previous_branch.clone() {
                Some(branch) => repo.switch_branch(branch),
                None => target
                    .previous_head
                    .clone()
                    .ok_or_else(|| EngineError::GitOperation {
                        message: "cannot restore detached HEAD: original commit is missing".into(),
                    })
                    .and_then(|head| repo.checkout_detached(head)),
            };
            if let Err(error) = restore {
                results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!("restore previous HEAD failed: {error}"),
                });
                continue;
            }
        }

        if let Some(previous_tip) = target.previous_branch_tip.clone() {
            let restore_tip = repo.branch_create_or_reset(
                name.clone(),
                Some(previous_tip),
                target.checked_out,
                true,
            );
            if let Err(error) = restore_tip {
                results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: format!("restore overwritten branch tip failed: {error}"),
                });
                continue;
            }
            if target.checked_out && target.previous_branch.as_deref() != Some(name.as_str()) {
                let restore_head = match target.previous_branch.clone() {
                    Some(branch) => repo.switch_branch(branch),
                    None => target
                        .previous_head
                        .clone()
                        .ok_or_else(|| EngineError::GitOperation {
                            message: "cannot restore detached HEAD: original commit is missing"
                                .into(),
                        })
                        .and_then(|head| repo.checkout_detached(head)),
                };
                if let Err(error) = restore_head {
                    results.push(RootOperationResult {
                        root_path,
                        display_name,
                        success: false,
                        skipped: false,
                        message: format!("restore previous HEAD failed: {error}"),
                    });
                    continue;
                }
            }
            results.push(RootOperationResult {
                root_path,
                display_name,
                success: true,
                skipped: false,
                message: "overwritten branch tip restored".into(),
            });
        } else {
            match repo.branch_delete(name.clone(), false) {
                Ok(()) => results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: true,
                    skipped: false,
                    message: "branch creation rolled back".into(),
                }),
                Err(error) => results.push(RootOperationResult {
                    root_path,
                    display_name,
                    success: false,
                    skipped: false,
                    message: error.to_string(),
                }),
            }
        }
    }
    Ok(results)
}

/// IntelliJ Update Project 的多 root 更新入口：
///
/// - 每个 root 使用自己的 configured upstream；
/// - fetch 经过统一 credential broker 并支持取消；
/// - dirty root 自动保存 tracked/untracked 现场；
/// - update 冲突时保留 system merge/rebase 状态和 stash，交给恢复工作台；
/// - stash 恢复冲突只影响当前 root，其他 root 仍返回自己的结果。
#[uniffi::export]
pub fn run_multi_root_update(
    scan_root: String,
    rebase: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_update_selected_with_policy(
        scan_root,
        None,
        rebase,
        broker,
        cancel,
        LocalChangesSavePolicy::Stash,
    )
}

/// Update all configured roots with IntelliJ's persisted local-change policy.
#[uniffi::export]
pub fn run_multi_root_update_with_policy(
    scan_root: String,
    rebase: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_update_selected_with_policy(scan_root, None, rebase, broker, cancel, save_policy)
}

/// Update all configured roots with an explicit project fetch tag policy.
#[uniffi::export]
pub fn run_multi_root_update_with_policy_and_options(
    scan_root: String,
    rebase: bool,
    tag_mode: crate::remote::FetchTagsMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_update_selected_with_policy_and_options(
        scan_root,
        None,
        rebase,
        broker,
        cancel,
        tag_mode,
        save_policy,
    )
}

/// Update exactly one rejected Push root while preserving nested submodule
/// worktrees.  A Push recovery is narrower than Update Project: it must not
/// update unrelated roots or silently advance a parent chain.  The target
/// root's own changes and every nested submodule's changes are saved deepest
/// first; the target pulls the rejected upstream while ignoring those
/// submodule paths; all saved scenes are then restored independently.
#[uniffi::export]
pub fn run_root_update_for_push_recovery(
    root_path: String,
    remote: String,
    branch: String,
    rebase: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<RootOperationResult, EngineError> {
    run_root_update_for_push_recovery_with_options(
        root_path,
        remote,
        branch,
        rebase,
        crate::remote::FetchTagsMode::Default,
        broker,
        cancel,
        save_policy,
    )
}

/// Root-scoped Push recovery update with an explicit project fetch tag policy.
#[uniffi::export]
pub fn run_root_update_for_push_recovery_with_options(
    root_path: String,
    remote: String,
    branch: String,
    rebase: bool,
    tag_mode: crate::remote::FetchTagsMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<RootOperationResult, EngineError> {
    let roots = discover_git_roots(root_path.clone(), None)?;
    let canonical_target = std::fs::canonicalize(&root_path)
        .unwrap_or_else(|_| PathBuf::from(&root_path))
        .display()
        .to_string();
    let target = roots
        .iter()
        .find(|root| root.path == canonical_target || root.path == root_path)
        .cloned()
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("Push recovery root was not found: {root_path}"),
        })?;
    let target_repo = crate::repo::open_repository(target.path.clone())?;

    if cancel.is_cancelled() {
        return Ok(root_skipped_result(
            &target,
            "cancelled before Push recovery update",
        ));
    }
    if target_repo.operation_state()?.is_some() {
        return Ok(root_failure_result(
            &target,
            "update: another Git operation is already in progress".into(),
        ));
    }
    let current_branch = target_repo
        .branch_list()?
        .into_iter()
        .find(|item| item.is_current)
        .map(|item| item.name);
    if current_branch.as_deref() != Some(branch.as_str()) {
        return Ok(root_failure_result(
            &target,
            format!(
                "Push recovery branch changed; expected '{branch}', found {}",
                current_branch.unwrap_or_else(|| "detached HEAD".into())
            ),
        ));
    }

    let ignored_submodule_paths = submodule_paths_under_root(&roots, &target);
    let mut descendants = roots
        .iter()
        .filter(|root| {
            root.is_submodule
                && root.path != target.path
                && Path::new(&root.path).starts_with(&target.path)
        })
        .cloned()
        .collect::<Vec<_>>();
    descendants.sort_by_key(|root| std::cmp::Reverse(Path::new(&root.path).components().count()));

    let mut saved_descendants: Vec<(Arc<crate::repo::Repository>, SavedLocalChanges)> = Vec::new();
    for descendant in descendants {
        let repo = match crate::repo::open_repository(descendant.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
                return Err(EngineError::GitOperation {
                    message: format!(
                        "cannot open nested submodule '{}': {error}{}",
                        descendant.display_name,
                        restore_error
                            .map(|error| format!("; previous local restore failed: {error}"))
                            .unwrap_or_default()
                    ),
                });
            }
        };
        let operation_state = match repo.operation_state() {
            Ok(state) => state,
            Err(error) => {
                let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
                return Err(EngineError::GitOperation {
                    message: format!(
                        "cannot inspect nested submodule '{}': {error}{}",
                        descendant.display_name,
                        restore_error
                            .map(|error| format!("; previous local restore failed: {error}"))
                            .unwrap_or_default()
                    ),
                });
            }
        };
        if operation_state.is_some() {
            let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
            return Err(EngineError::GitOperation {
                message: format!(
                    "nested submodule '{}' has another Git operation in progress{}",
                    descendant.display_name,
                    restore_error
                        .map(|error| format!("; previous local restore failed: {error}"))
                        .unwrap_or_default()
                ),
            });
        }
        let ignored = submodule_paths_under_root(&roots, &descendant);
        let paths = match dirty_paths_for_preservation(&repo, &ignored) {
            Ok(paths) => paths,
            Err(error) => {
                let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
                return Err(EngineError::GitOperation {
                    message: format!(
                        "cannot inspect nested submodule '{}': {error}{}",
                        descendant.display_name,
                        restore_error
                            .map(|error| format!("; previous local restore failed: {error}"))
                            .unwrap_or_default()
                    ),
                });
            }
        };
        if paths.is_empty() {
            continue;
        }
        let saved = match save_local_changes_for_preservation(
            &repo,
            "Arbor: Push update (submodule)",
            &descendant.display_name,
            save_policy,
            &ignored,
        ) {
            Ok(saved) => saved,
            Err(error) => {
                let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
                return Err(EngineError::GitOperation {
                    message: format!(
                        "cannot preserve nested submodule '{}': {error}{}",
                        descendant.display_name,
                        restore_error
                            .map(|error| format!("; previous local restore failed: {error}"))
                            .unwrap_or_default()
                    ),
                });
            }
        };
        saved_descendants.push((repo, saved));
    }

    let target_paths = match dirty_paths_for_preservation(&target_repo, &ignored_submodule_paths) {
        Ok(paths) => paths,
        Err(error) => {
            let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
            return Err(EngineError::GitOperation {
                message: format!(
                    "cannot inspect Push root '{}': {error}{}",
                    target.display_name,
                    restore_error
                        .map(|error| format!("; nested local restore failed: {error}"))
                        .unwrap_or_default()
                ),
            });
        }
    };
    let saved_target = if target_paths.is_empty() {
        None
    } else {
        match save_local_changes_for_preservation(
            &target_repo,
            "Arbor: Push update",
            &target.display_name,
            save_policy,
            &ignored_submodule_paths,
        ) {
            Ok(saved) => Some(saved),
            Err(error) => {
                let restore_error = restore_saved_push_recovery_scenes(&mut saved_descendants);
                return Err(EngineError::GitOperation {
                    message: format!(
                        "cannot preserve Push root '{}': {error}{}",
                        target.display_name,
                        restore_error
                            .map(|error| format!("; nested local restore failed: {error}"))
                            .unwrap_or_default()
                    ),
                });
            }
        }
    };

    if cancel.is_cancelled() {
        let target_restore = saved_target
            .as_ref()
            .and_then(|saved| restore_saved_local_changes(&target_repo, saved).err());
        let descendant_restore = restore_saved_push_recovery_scenes(&mut saved_descendants);
        let detail = target_restore
            .or(descendant_restore)
            .map(|error| format!("cancelled before update; local restore failed: {error}"))
            .unwrap_or_else(|| "cancelled before Push recovery update".into());
        return Ok(root_skipped_result(&target, &detail));
    }

    let outcome = match target_repo.pull_with_options_and_auth_and_cancel_ignoring_paths(
        Some(remote.clone()),
        rebase,
        tag_mode,
        broker,
        cancel,
        ignored_submodule_paths,
    ) {
        Ok(outcome) => outcome,
        Err(error) => {
            let target_restore = saved_target
                .as_ref()
                .and_then(|saved| restore_saved_local_changes(&target_repo, saved).err());
            let descendant_restore = restore_saved_push_recovery_scenes(&mut saved_descendants);
            let restore_error = target_restore.or(descendant_restore);
            return Ok(root_failure_result(
                &target,
                if let Some(restore_error) = restore_error {
                    format!("{error}; local changes restore failed: {restore_error}")
                } else if let Some(saved) = saved_target.as_ref() {
                    format!(
                        "{error}; local changes remain in {}",
                        saved_local_changes_message(saved)
                    )
                } else {
                    error.to_string()
                },
            ));
        }
    };

    if !outcome.conflicts.is_empty() {
        let descendant_restore = restore_saved_push_recovery_scenes(&mut saved_descendants);
        let mut message = format!(
            "update paused with {} conflict(s); local changes remain in {}",
            outcome.conflicts.len(),
            saved_target
                .as_ref()
                .map(saved_local_changes_message)
                .unwrap_or("the worktree")
        );
        if let Some(error) = descendant_restore {
            message.push_str(&format!("; nested local restore failed: {error}"));
        }
        return Ok(root_failure_result(&target, message));
    }

    let target_restore = saved_target
        .as_ref()
        .and_then(|saved| restore_saved_local_changes(&target_repo, saved).err());
    let descendant_restore = restore_saved_push_recovery_scenes(&mut saved_descendants);
    if let Some(error) = target_restore.or(descendant_restore) {
        return Ok(root_failure_result(
            &target,
            format!("update completed but local restore failed: {error}"),
        ));
    }

    Ok(root_success_result(
        &target,
        format!(
            "updated {} commits from {remote}/{branch} and restored local changes",
            outcome.updated_commits
        ),
    ))
}

/// Update the currently checked-out branch using its configured upstream.
/// Unlike Push recovery, the local and remote branch names may differ; keep
/// both names explicit so the current-branch guard and user-facing result are
/// correct for mappings such as `main -> origin/trunk`.
#[uniffi::export]
pub fn run_root_update_for_current_branch_with_options(
    root_path: String,
    remote: String,
    local_branch: String,
    remote_branch: String,
    rebase: bool,
    tag_mode: crate::remote::FetchTagsMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<RootOperationResult, EngineError> {
    let result = run_root_update_for_push_recovery_with_options(
        root_path,
        remote.clone(),
        local_branch.clone(),
        rebase,
        tag_mode,
        broker,
        cancel,
        save_policy,
    )?;
    if result.success && !result.skipped {
        return Ok(RootOperationResult {
            message: format!(
                "updated current branch '{local_branch}' from {remote}/{remote_branch} and restored local changes"
            ),
            ..result
        });
    }
    Ok(result)
}

fn restore_saved_push_recovery_scenes(
    saved: &mut Vec<(Arc<crate::repo::Repository>, SavedLocalChanges)>,
) -> Option<EngineError> {
    let mut first_error = None;
    for (repo, changes) in saved.drain(..).rev() {
        if let Err(error) = restore_saved_local_changes(&repo, &changes) {
            if first_error.is_none() {
                first_error = Some(error);
            }
        }
    }
    first_error
}

/// Recover and republish selected roots after a non-fast-forward Push.  This
/// is the project-level counterpart of the root-scoped recovery API.  The
/// rejected roots are updated and pushed child-first, while `update_root_paths`
/// can cover every project root to match IntelliJ's GitPushOperation.  Roots
/// that were already pushed are therefore updated when the user chooses Merge
/// or Rebase, but are not pushed a second time.
#[uniffi::export]
pub fn run_multi_root_push_recovery(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    update_root_paths: Option<Vec<String>>,
    rebase: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_push_recovery_with_options(
        scan_root,
        selected_root_paths,
        update_root_paths,
        rebase,
        None,
        false,
        broker,
        cancel,
        save_policy,
    )
}

/// Recovery counterpart of `run_multi_root_push_with_options`. IntelliJ
/// keeps the original Push options when Update with Merge/Rebase republishes
/// the affected roots, so recovery must receive the same values too.
#[uniffi::export]
pub fn run_multi_root_push_recovery_with_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    update_root_paths: Option<Vec<String>>,
    rebase: bool,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_push_recovery_with_options_and_fetch_tags(
        scan_root,
        selected_root_paths,
        update_root_paths,
        rebase,
        crate::remote::FetchTagsMode::Default,
        tag_mode,
        skip_hooks,
        broker,
        cancel,
        save_policy,
    )
}

/// Project-level Push recovery with an explicit fetch tag policy.
#[uniffi::export]
pub fn run_multi_root_push_recovery_with_options_and_fetch_tags(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    update_root_paths: Option<Vec<String>>,
    rebase: bool,
    fetch_tags_mode: crate::remote::FetchTagsMode,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let roots = discover_git_roots(scan_root, None)?;
    let push_indices = push_root_indices(&roots, selected_root_paths.as_deref());
    let mut update_indices = update_root_paths
        .as_deref()
        .map(|paths| push_root_indices(&roots, Some(paths)))
        .unwrap_or_else(|| push_indices.clone());
    for index in &push_indices {
        if !update_indices.contains(index) {
            update_indices.push(*index);
        }
    }
    sort_push_root_indices(&roots, &mut update_indices);
    let mut update_results = Vec::with_capacity(update_indices.len());

    for index in update_indices {
        let root = &roots[index];
        if cancel.is_cancelled() {
            update_results.push(root_skipped_result(
                root,
                "cancelled before Push recovery update",
            ));
            continue;
        }
        if let Some(message) = blocked_by_submodule_update(root, &roots, &update_results) {
            update_results.push(root_skipped_result(root, &message));
            continue;
        }
        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                update_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let branch = match repo.branch_list() {
            Ok(branches) => branches
                .into_iter()
                .find(|branch| branch.is_current)
                .map(|branch| branch.name),
            Err(error) => {
                update_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let Some(branch) = branch else {
            update_results.push(root_skipped_result(
                root,
                "detached HEAD; Push recovery update skipped",
            ));
            continue;
        };
        let tracking = match repo.sync_status() {
            Ok(statuses) => statuses.into_iter().find(|status| status.branch == branch),
            Err(error) => {
                update_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let Some(tracking) = tracking.filter(|status| status.tracking_exists) else {
            update_results.push(root_skipped_result(
                root,
                "no configured upstream; Push recovery update skipped",
            ));
            continue;
        };
        let remote_target = match repo.remote_list() {
            Ok(remotes) => remotes
                .into_iter()
                .filter_map(|remote| {
                    let prefix = format!("{}/", remote.name);
                    tracking
                        .upstream
                        .strip_prefix(&prefix)
                        .filter(|branch| !branch.is_empty())
                        .map(|branch| (remote.name, branch.to_string()))
                })
                .max_by_key(|(remote, _)| remote.len()),
            Err(error) => {
                update_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let Some((remote, remote_branch)) = remote_target else {
            update_results.push(root_failure_result(
                root,
                format!("invalid configured upstream: {}", tracking.upstream),
            ));
            continue;
        };

        match run_root_update_for_push_recovery_with_options(
            root.path.clone(),
            remote.to_string(),
            remote_branch.to_string(),
            rebase,
            fetch_tags_mode,
            Arc::clone(&broker),
            Arc::clone(&cancel),
            save_policy,
        ) {
            Ok(result) => update_results.push(result),
            Err(error) => update_results.push(root_failure_result(root, error.to_string())),
        }
    }

    let update_blocked = update_results
        .iter()
        .any(|result| !result.success || result.message.to_ascii_lowercase().contains("cancelled"));
    let mut push_results = Vec::with_capacity(push_indices.len());
    for index in push_indices {
        let root = &roots[index];
        if let Some(existing) = update_results
            .iter()
            .find(|result| result.root_path == root.path)
        {
            if !existing.success || existing.skipped {
                push_results.push(existing.clone());
                continue;
            }
        }
        if update_blocked {
            push_results.push(root_skipped_result(
                root,
                "Push recovery not attempted because another root update failed",
            ));
            continue;
        }
        if cancel.is_cancelled() {
            push_results.push(root_skipped_result(root, "cancelled before Push recovery"));
            continue;
        }
        if let Some(message) = blocked_by_submodule_update(root, &roots, &update_results) {
            push_results.push(root_skipped_result(root, &message));
            continue;
        }
        if let Some(message) = blocked_by_submodule_push(root, &roots, &push_results) {
            push_results.push(root_skipped_result(root, &message));
            continue;
        }

        // Reopen after Update: the previous gix handle can retain stale refs
        // and otherwise push the pre-update local tip.
        let push_repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                push_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let branch = match push_repo.branch_list() {
            Ok(branches) => branches
                .into_iter()
                .find(|branch| branch.is_current)
                .map(|branch| branch.name),
            Err(error) => {
                push_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let Some(branch) = branch else {
            push_results.push(root_skipped_result(root, "detached HEAD; Push skipped"));
            continue;
        };
        let tracking = match push_repo.sync_status() {
            Ok(statuses) => statuses.into_iter().find(|status| status.branch == branch),
            Err(error) => {
                push_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let Some(tracking) = tracking.filter(|status| status.tracking_exists) else {
            push_results.push(root_skipped_result(
                root,
                "no configured upstream; Push skipped",
            ));
            continue;
        };
        let remote_target = match push_repo.remote_list() {
            Ok(remotes) => remotes
                .into_iter()
                .filter_map(|remote| {
                    let prefix = format!("{}/", remote.name);
                    tracking
                        .upstream
                        .strip_prefix(&prefix)
                        .filter(|branch| !branch.is_empty())
                        .map(|branch| (remote.name, branch.to_string()))
                })
                .max_by_key(|(remote, _)| remote.len()),
            Err(error) => {
                push_results.push(root_failure_result(root, error.to_string()));
                continue;
            }
        };
        let Some((remote, remote_branch)) = remote_target else {
            push_results.push(root_failure_result(
                root,
                format!("invalid configured upstream: {}", tracking.upstream),
            ));
            continue;
        };
        match push_repo.push_with_options_and_auth_and_cancel(
            Some(remote.clone()),
            branch,
            false,
            false,
            false,
            tag_mode,
            skip_hooks,
            Arc::clone(&broker),
            Arc::clone(&cancel),
        ) {
            Ok(()) => push_results.push(root_success_result(
                root,
                format!("updated and pushed {}/{}", remote, remote_branch),
            )),
            Err(EngineError::Cancelled) => {
                push_results.push(root_skipped_result(root, "cancelled during Push recovery"));
            }
            Err(error) => push_results.push(root_failure_result(root, error.to_string())),
        }
    }

    for push_result in push_results {
        if let Some(existing) = update_results
            .iter_mut()
            .find(|result| result.root_path == push_result.root_path)
        {
            *existing = push_result;
        } else {
            update_results.push(push_result);
        }
    }
    Ok(update_results)
}

/// Select Update Project roots, preserving the dependency closure used by
/// retries. When a selected root is a detached submodule, include its
/// discovered parent chain so the gitlink is advanced before the child is
/// updated, matching the normal multi-root dependency order.
fn select_update_roots(
    discovered_roots: Vec<GitRootInfo>,
    selected_root_paths: Option<&[String]>,
) -> Result<Vec<GitRootInfo>, EngineError> {
    let Some(selected_root_paths) = selected_root_paths else {
        return Ok(discovered_roots);
    };
    let selected_root_paths = selected_root_paths
        .iter()
        .map(|path| {
            std::fs::canonicalize(path)
                .unwrap_or_else(|_| PathBuf::from(path))
                .display()
                .to_string()
        })
        .collect::<std::collections::HashSet<_>>();
    if selected_root_paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "selected Git root was not found".into(),
        });
    }
    let roots = discovered_roots
        .into_iter()
        .filter(|root| {
            selected_root_paths.iter().any(|selected| {
                // A retry must include both sides of the submodule
                // dependency edge. The existing ancestor check keeps
                // the parent gitlink update in the transaction; the
                // descendant check keeps a nested submodule that was
                // skipped after its detached parent failed in the same
                // retry group. Independent nested repositories remain
                // scoped to the explicitly selected root.
                selected == &root.path
                    || Path::new(selected).starts_with(&root.path)
                    || (root.is_submodule && Path::new(&root.path).starts_with(selected))
            })
        })
        .collect::<Vec<_>>();
    if roots.is_empty() {
        return Err(EngineError::GitOperation {
            message: "selected Git root was not found".into(),
        });
    }
    Ok(roots)
}

/// Fetch Update Project roots and classify the roots where a rebase would
/// replay a merge commit with a non-empty tree delta. Fetching is intentionally
/// separate from integration so the SwiftUI layer can present IntelliJ's
/// Merge Instead / Rebase Anyway / Cancel decision before touching worktrees.
#[uniffi::export]
pub fn prepare_multi_root_update(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    tag_mode: crate::remote::FetchTagsMode,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
) -> Result<UpdateProjectPreflight, EngineError> {
    let roots = select_update_roots(
        discover_git_roots(scan_root, None)?,
        selected_root_paths.as_deref(),
    )?;
    if !cancel.is_cancelled() {
        if let Some(results) = update_not_ready_results(&roots)? {
            return Ok(UpdateProjectPreflight {
                results,
                fetched_root_paths: Vec::new(),
                problematic_root_paths: Vec::new(),
            });
        }
    }
    let mut results = Vec::with_capacity(roots.len());
    let mut fetched_root_paths = Vec::new();
    let mut problematic_root_paths = Vec::new();

    for root in roots {
        if cancel.is_cancelled() {
            results.push(root_skipped_result(
                &root,
                "cancelled before Update Project fetch",
            ));
            continue;
        }
        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                results.push(root_failure_result(&root, error.to_string()));
                continue;
            }
        };
        if repo.operation_state()?.is_some() {
            results.push(root_failure_result(
                &root,
                "update: another Git operation is already in progress".into(),
            ));
            continue;
        }
        let Some(branch) = root.head_branch.clone() else {
            results.push(root_skipped_result(&root, "detached HEAD"));
            continue;
        };
        let Some(sync) = repo
            .sync_status()?
            .into_iter()
            .find(|status| status.branch == branch)
        else {
            results.push(root_skipped_result(&root, "no configured upstream"));
            continue;
        };
        let Some((remote, _)) = sync.upstream.split_once('/') else {
            results.push(root_failure_result(
                &root,
                "update: local repository upstream is not supported".into(),
            ));
            continue;
        };
        if let Err(error) = repo.fetch_with_options_and_auth_and_cancel(
            Some(remote.to_string()),
            tag_mode,
            Arc::clone(&broker),
            Arc::clone(&cancel),
        ) {
            results.push(root_failure_result(&root, error.to_string()));
            continue;
        }
        let upstream_ref = format!("refs/remotes/{}", sync.upstream);
        let problematic = match repo.has_non_empty_merge_commits_in_range(upstream_ref, branch) {
            Ok(problematic) => problematic,
            Err(error) => {
                results.push(root_failure_result(&root, error.to_string()));
                continue;
            }
        };
        fetched_root_paths.push(root.path.clone());
        if problematic {
            problematic_root_paths.push(root.path.clone());
        }
        results.push(root_success_result(&root, "fetched update refs".into()));
    }

    Ok(UpdateProjectPreflight {
        results,
        fetched_root_paths,
        problematic_root_paths,
    })
}

#[uniffi::export]
pub fn run_multi_root_update_selected_with_policy(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    rebase: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_update_selected_with_policy_and_options(
        scan_root,
        selected_root_paths,
        rebase,
        broker,
        cancel,
        crate::remote::FetchTagsMode::Default,
        save_policy,
    )
}

/// Retry Update Project for selected roots with an explicit project fetch tag policy.
#[uniffi::export]
pub fn run_multi_root_update_selected_with_policy_and_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    rebase: bool,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    tag_mode: crate::remote::FetchTagsMode,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    run_multi_root_update_selected_with_methods_and_options(
        scan_root,
        selected_root_paths,
        rebase,
        None,
        None,
        broker,
        cancel,
        tag_mode,
        save_policy,
    )
}

/// Update selected roots with IntelliJ's per-root rebase-over-merge decision.
/// `rebase_root_paths == nil` keeps the original single-method behavior;
/// otherwise only the listed canonical roots use rebase and every other
/// normal root uses merge. `prefetched_root_paths` identifies roots whose
/// Update Project preflight already fetched the configured remote.
#[uniffi::export]
pub fn run_multi_root_update_selected_with_methods_and_options(
    scan_root: String,
    selected_root_paths: Option<Vec<String>>,
    rebase: bool,
    rebase_root_paths: Option<Vec<String>>,
    prefetched_root_paths: Option<Vec<String>>,
    broker: Arc<crate::auth::CredentialBroker>,
    cancel: Arc<crate::gitprocess::GitCancelHandle>,
    tag_mode: crate::remote::FetchTagsMode,
    save_policy: LocalChangesSavePolicy,
) -> Result<Vec<RootOperationResult>, EngineError> {
    let roots = select_update_roots(
        discover_git_roots(scan_root, None)?,
        selected_root_paths.as_deref(),
    )?;
    let rebase_root_paths = rebase_root_paths.map(|paths| {
        paths
            .into_iter()
            .map(|path| {
                std::fs::canonicalize(&path)
                    .unwrap_or_else(|_| PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<std::collections::HashSet<_>>()
    });
    let prefetched_root_paths = prefetched_root_paths.map(|paths| {
        paths
            .into_iter()
            .map(|path| {
                std::fs::canonicalize(&path)
                    .unwrap_or_else(|_| PathBuf::from(path))
                    .display()
                    .to_string()
            })
            .collect::<std::collections::HashSet<_>>()
    });
    // IntelliJ checks the complete project before fetching, stashing, or
    // updating any root. Otherwise an operation/conflict in a later root can
    // leave earlier roots partially updated, which is not a valid Update
    // Project transaction boundary.
    if !cancel.is_cancelled() {
        if let Some(results) = update_not_ready_results(&roots)? {
            return Ok(results);
        }
    }
    let mut detached_indices = roots
        .iter()
        .enumerate()
        .filter(|(_, root)| root.is_submodule && root.head_branch.is_none())
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    detached_indices.sort_by_key(|index| Path::new(&roots[*index].path).components().count());
    let mut pre_stashed_submodules: Vec<Option<(Arc<crate::repo::Repository>, SavedLocalChanges)>> =
        vec![None; roots.len()];
    let mut pre_stash_errors: Vec<Option<String>> = vec![None; roots.len()];
    // Save the deepest worktree first. Otherwise a parent submodule's stash
    // would capture its child gitlink as dirty and restore that stale gitlink
    // after the parent has advanced.
    for &index in detached_indices.iter().rev() {
        let root = &roots[index];
        if cancel.is_cancelled() {
            break;
        }
        let repo = match crate::repo::open_repository(root.path.clone()) {
            Ok(repo) => repo,
            Err(error) => {
                pre_stash_errors[index] = Some(error.to_string());
                continue;
            }
        };
        match repo.operation_state() {
            Ok(Some(_)) => {
                pre_stash_errors[index] =
                    Some("submodule update: another Git operation is already in progress".into());
            }
            Ok(None) => {
                let dirty = match repo.status() {
                    Ok(entries) => entries.iter().any(|entry| {
                        entry.staged != crate::status::ChangeKind::Unchanged
                            || (entry.unstaged != crate::status::ChangeKind::Unchanged
                                && entry.unstaged != crate::status::ChangeKind::Ignored)
                    }),
                    Err(error) => {
                        pre_stash_errors[index] = Some(error.to_string());
                        continue;
                    }
                };
                if dirty {
                    match save_local_changes_for_preservation(
                        &repo,
                        "Arbor: Update Project (submodule)",
                        &root.display_name,
                        save_policy,
                        &[],
                    ) {
                        Ok(saved) => pre_stashed_submodules[index] = Some((repo, saved)),
                        Err(error) => pre_stash_errors[index] = Some(error.to_string()),
                    }
                }
            }
            Err(error) => pre_stash_errors[index] = Some(error.to_string()),
        }
    }
    let total_roots = roots.len();
    let mut completed_roots = 0usize;
    let mut results = Vec::with_capacity(total_roots);
    for root in &roots {
        if root.is_submodule && root.head_branch.is_none() {
            continue;
        }
        if cancel.is_cancelled() {
            let progress_generation = crate::gitprocess::begin_root_operation_progress(
                completed_roots,
                total_roots,
                root.path.clone(),
                root.display_name.clone(),
            );
            completed_roots += 1;
            crate::gitprocess::update_root_operation_progress(
                progress_generation,
                completed_roots,
                "skipped".to_string(),
            );
            results.push(RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: true,
                message: "cancelled before update".into(),
            });
            crate::gitprocess::end_root_operation_progress(progress_generation);
            continue;
        }
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            completed_roots,
            total_roots,
            root.path.clone(),
            root.display_name.clone(),
        );
        let ignored_submodule_paths = submodule_paths_under_root(&roots, root);
        let root_rebase = rebase_root_paths
            .as_ref()
            .map_or(rebase, |paths| paths.contains(&root.path));
        let fetch = prefetched_root_paths
            .as_ref()
            .is_none_or(|paths| !paths.contains(&root.path));
        let result = run_single_root_update_with_policy(
            &root.path,
            root_rebase,
            fetch,
            &broker,
            &cancel,
            &ignored_submodule_paths,
            tag_mode,
            save_policy,
        );
        let result = match result {
            Ok(message) => RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: false,
                message,
            },
            Err(RootError::Skip(message)) => RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: true,
                message,
            },
            Err(RootError::Fail(error)) => RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: false,
                skipped: false,
                message: error.to_string(),
            },
        };
        let state = if result.success {
            if result.skipped {
                "skipped"
            } else {
                "completed"
            }
        } else {
            "failed"
        };
        completed_roots += 1;
        crate::gitprocess::update_root_operation_progress(
            progress_generation,
            completed_roots,
            state.to_string(),
        );
        results.push(result);
        crate::gitprocess::end_root_operation_progress(progress_generation);
    }

    // Parent roots must update first so their new gitlink is authoritative;
    // detached submodules then follow that gitlink recursively. Sort by path
    // depth so a detached submodule parent is settled before its own child.
    let mut detached_results: Vec<Option<bool>> = vec![None; roots.len()];
    for index in detached_indices.iter().copied() {
        let root = &roots[index];
        let progress_generation = crate::gitprocess::begin_root_operation_progress(
            completed_roots,
            total_roots,
            root.path.clone(),
            root.display_name.clone(),
        );
        let result = if let Some(error) = pre_stash_errors[index].take() {
            Err(RootError::Fail(EngineError::GitOperation {
                message: error,
            }))
        } else if cancel.is_cancelled() {
            Err(detached_submodule_pending_result(
                "cancelled before submodule update",
                &pre_stashed_submodules[index],
            ))
        } else {
            match submodule_parent_for_root(&roots, root) {
                Ok(Some((parent_index, relative_path))) => {
                    let parent = &roots[parent_index];
                    if parent.is_submodule
                        && parent.head_branch.is_none()
                        && detached_results[parent_index] != Some(true)
                    {
                        Err(detached_submodule_pending_result(
                            "detached submodule parent update did not complete",
                            &pre_stashed_submodules[index],
                        ))
                    } else {
                        let recursive = submodule_paths_under_root(&roots, root).is_empty();
                        run_detached_submodule_update(
                            root,
                            parent,
                            &relative_path,
                            recursive,
                            &broker,
                            &cancel,
                            &mut pre_stashed_submodules[index],
                            save_policy,
                        )
                    }
                }
                Ok(None) => Err(detached_submodule_pending_result(
                    "detached submodule parent root was not found",
                    &pre_stashed_submodules[index],
                )),
                Err(error) => Err(detached_submodule_pending_result(
                    error.to_string(),
                    &pre_stashed_submodules[index],
                )),
            }
        };
        detached_results[index] = Some(result.is_ok());
        let result = match result {
            Ok(message) => RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: false,
                message,
            },
            Err(RootError::Skip(message)) => RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: true,
                skipped: true,
                message,
            },
            Err(RootError::Fail(error)) => RootOperationResult {
                root_path: root.path.clone(),
                display_name: root.display_name.clone(),
                success: false,
                skipped: false,
                message: error.to_string(),
            },
        };
        let state = if result.success {
            if result.skipped {
                "skipped"
            } else {
                "completed"
            }
        } else {
            "failed"
        };
        completed_roots += 1;
        crate::gitprocess::update_root_operation_progress(
            progress_generation,
            completed_roots,
            state.to_string(),
        );
        results.push(result);
        crate::gitprocess::end_root_operation_progress(progress_generation);
    }

    // IntelliJ's preserving process restores all saved detached-submodule
    // scenes only after the compound update result is known. If any root
    // failed or the operation was cancelled, keep every saved scene in its
    // stash/Shelf and expose it through the root-scoped recovery workbench.
    let compound_succeeded = !cancel.is_cancelled() && results.iter().all(|result| result.success);
    for index in detached_indices {
        let Some((repo, saved)) = pre_stashed_submodules[index].take() else {
            continue;
        };
        let Some(result) = results
            .iter_mut()
            .find(|result| result.root_path == roots[index].path)
        else {
            continue;
        };
        if !compound_succeeded {
            result.success = false;
            result.skipped = false;
            let suffix = format!(
                "local changes remain in {} for submodule",
                saved_local_changes_message(&saved)
            );
            if !result.message.contains(&suffix) {
                result.message = if result.message.is_empty() {
                    suffix
                } else {
                    format!("{}; {suffix}", result.message)
                };
            }
            // The saved scene is deliberately not popped here. Swift's
            // recovery workbench can restore it immediately or after a
            // relaunch, and a restore conflict remains root-scoped.
            pre_stashed_submodules[index] = Some((repo, saved));
            continue;
        }
        if let Err(error) = restore_saved_local_changes(&repo, &saved) {
            result.success = false;
            result.skipped = false;
            result.message = format!(
                "{}; local restore conflicted while restoring submodule from {}: {error}",
                result.message,
                saved_local_changes_message(&saved)
            );
        } else if !result.message.contains("restored local changes") {
            result.message.push_str("; restored local changes");
        }
    }
    Ok(results)
}

/// Find the nearest discovered parent whose `.gitmodules` registers `root`.
/// Independent nested repositories may also be ancestors, so the gitlink
/// check is required instead of relying on the filesystem relationship alone.
fn submodule_parent_for_root(
    roots: &[GitRootInfo],
    root: &GitRootInfo,
) -> Result<Option<(usize, String)>, EngineError> {
    let root_path = Path::new(&root.path);
    let mut candidates = roots
        .iter()
        .enumerate()
        .filter_map(|(index, candidate)| {
            let candidate_path = Path::new(&candidate.path);
            if candidate_path == root_path || !root_path.starts_with(candidate_path) {
                return None;
            }
            let relative = root_path
                .strip_prefix(candidate_path)
                .ok()?
                .to_string_lossy()
                .into_owned();
            if relative.is_empty() {
                None
            } else {
                Some((index, candidate_path.components().count(), relative))
            }
        })
        .collect::<Vec<_>>();
    candidates.sort_by_key(|(_, depth, _)| *depth);

    for (index, _, relative) in candidates.into_iter().rev() {
        let parent_repo = crate::repo::open_repository(roots[index].path.clone())?;
        if parent_repo
            .submodule_list()?
            .iter()
            .any(|module| module.path == relative)
        {
            return Ok(Some((index, relative)));
        }
    }
    Ok(None)
}

/// 返回 root 下发现的 submodule 相对路径。父 root 的 pull dirty guard
/// 需要忽略这些路径：它们的本地现场已由 detached-root 阶段单独保存，
/// 不应再把“子模块内容变脏”误判为父仓库自己的改动。
fn submodule_paths_under_root(roots: &[GitRootInfo], root: &GitRootInfo) -> Vec<String> {
    let root_path = Path::new(&root.path);
    roots
        .iter()
        .filter(|candidate| candidate.is_submodule && candidate.path != root.path)
        .filter_map(|candidate| {
            Path::new(&candidate.path)
                .strip_prefix(root_path)
                .ok()
                .map(|path| path.to_string_lossy().into_owned())
        })
        .filter(|path| !path.is_empty())
        .collect()
}

fn path_is_covered_by_submodule(path: &str, submodule_paths: &[String]) -> bool {
    submodule_paths.iter().any(|submodule_path| {
        path == submodule_path
            || path.starts_with(&format!("{submodule_path}/"))
            || submodule_path.starts_with(&format!("{path}/"))
    })
}

/// IntelliJ's detached-submodule updater: save local submodule changes,
/// update the gitlink from the parent, and leave restoration to the compound
/// multi-root update finalizer.
fn detached_submodule_pending_result(
    message: impl Into<String>,
    saved: &Option<(Arc<crate::repo::Repository>, SavedLocalChanges)>,
) -> RootError {
    let message = message.into();
    if let Some((_, saved_changes)) = saved {
        return RootError::Fail(EngineError::GitOperation {
            message: format!(
                "{message}; local changes remain in {} for submodule",
                saved_local_changes_message(saved_changes)
            ),
        });
    }
    RootError::Skip(message)
}

fn run_detached_submodule_update(
    root: &GitRootInfo,
    parent: &GitRootInfo,
    relative_path: &str,
    recursive: bool,
    broker: &Arc<crate::auth::CredentialBroker>,
    cancel: &Arc<crate::gitprocess::GitCancelHandle>,
    pre_stashed: &mut Option<(Arc<crate::repo::Repository>, SavedLocalChanges)>,
    save_policy: LocalChangesSavePolicy,
) -> Result<String, RootError> {
    let submodule_repo = match pre_stashed.as_ref() {
        Some((repo, _)) => Arc::clone(repo),
        None => crate::repo::open_repository(root.path.clone()).map_err(RootError::Fail)?,
    };
    let already_saved = pre_stashed.is_some();
    let operation_state = match submodule_repo.operation_state() {
        Ok(state) => state,
        Err(error) => {
            return Err(detached_submodule_pending_result(
                error.to_string(),
                pre_stashed,
            ));
        }
    };
    if operation_state.is_some() {
        return Err(detached_submodule_pending_result(
            "submodule update: another Git operation is already in progress",
            pre_stashed,
        ));
    }

    let dirty = if already_saved {
        true
    } else {
        submodule_repo
            .status()
            .map_err(RootError::Fail)?
            .iter()
            .any(|entry| {
                entry.staged != crate::status::ChangeKind::Unchanged
                    || (entry.unstaged != crate::status::ChangeKind::Unchanged
                        && entry.unstaged != crate::status::ChangeKind::Ignored)
            })
    };
    if cancel.is_cancelled() {
        return Err(detached_submodule_pending_result(
            "cancelled before submodule update",
            pre_stashed,
        ));
    }
    if dirty && !already_saved {
        let saved = save_local_changes_for_preservation(
            &submodule_repo,
            "Arbor: Update Project (submodule)",
            &root.display_name,
            save_policy,
            &[],
        )
        .map_err(RootError::Fail)?;
        *pre_stashed = Some((Arc::clone(&submodule_repo), saved));
    }

    let parent_repo = match crate::repo::open_repository(parent.path.clone()) {
        Ok(repo) => repo,
        Err(error) => {
            return Err(detached_submodule_pending_result(
                error.to_string(),
                pre_stashed,
            ));
        }
    };
    let update = parent_repo.submodule_update_path_with_auth_and_cancel(
        relative_path.to_string(),
        recursive,
        Arc::clone(broker),
        Arc::clone(cancel),
    );
    if let Err(error) = update {
        return Err(detached_submodule_pending_result(
            error.to_string(),
            pre_stashed,
        ));
    }

    Ok(format!(
        "updated detached submodule via parent {}",
        parent.display_name
    ))
}

fn run_single_root_update_with_policy(
    path: &str,
    rebase: bool,
    fetch: bool,
    broker: &Arc<crate::auth::CredentialBroker>,
    cancel: &Arc<crate::gitprocess::GitCancelHandle>,
    ignored_submodule_paths: &[String],
    tag_mode: crate::remote::FetchTagsMode,
    save_policy: LocalChangesSavePolicy,
) -> Result<String, RootError> {
    let repo = crate::repo::open_repository(path.to_string()).map_err(RootError::Fail)?;
    if repo.operation_state().map_err(RootError::Fail)?.is_some() {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: "update: another Git operation is already in progress".into(),
        }));
    }

    let current_branch = repo
        .branch_list()
        .map_err(RootError::Fail)?
        .iter()
        .find(|branch| branch.is_current)
        .map(|branch| branch.name.clone());
    let Some(current_branch) = current_branch else {
        return Err(RootError::Skip("detached HEAD".into()));
    };
    if !repo
        .sync_status()
        .map_err(RootError::Fail)?
        .iter()
        .any(|status| status.branch == current_branch)
    {
        return Err(RootError::Skip("no configured upstream".into()));
    }

    let stashable = repo
        .status()
        .map_err(RootError::Fail)?
        .iter()
        .filter(|entry| !path_is_covered_by_submodule(entry.path.as_str(), ignored_submodule_paths))
        .any(|entry| {
            entry.staged != crate::status::ChangeKind::Unchanged
                || (entry.unstaged != crate::status::ChangeKind::Unchanged
                    && entry.unstaged != crate::status::ChangeKind::Ignored)
        });
    if !stashable {
        let outcome = if fetch {
            repo.pull_with_options_and_auth_and_cancel_ignoring_paths(
                None,
                rebase,
                tag_mode,
                Arc::clone(broker),
                Arc::clone(cancel),
                ignored_submodule_paths.to_vec(),
            )
        } else {
            repo.pull_after_fetch_with_options_ignoring_paths(
                rebase,
                ignored_submodule_paths.to_vec(),
            )
        }
        .map_err(classify_update_error)?;
        return if outcome.conflicts.is_empty() {
            Ok(format!("updated {} commits", outcome.updated_commits))
        } else {
            Err(RootError::Fail(EngineError::GitOperation {
                message: format!(
                    "update paused with {} conflict(s); resolve and continue",
                    outcome.conflicts.len()
                ),
            }))
        };
    }

    let message = if rebase {
        "Arbor: Update Project (rebase)"
    } else {
        "Arbor: Update Project"
    };
    let saved = save_local_changes_for_preservation(
        &repo,
        message,
        Path::new(path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("root"),
        save_policy,
        ignored_submodule_paths,
    )
    .map_err(RootError::Fail)?;
    let outcome = match if fetch {
        repo.pull_with_options_and_auth_and_cancel(
            None,
            rebase,
            tag_mode,
            Arc::clone(broker),
            Arc::clone(cancel),
        )
    } else {
        repo.pull_after_fetch_with_options_ignoring_paths(rebase, ignored_submodule_paths.to_vec())
    } {
        Ok(outcome) => outcome,
        Err(error) => {
            return Err(match classify_update_error(error) {
                RootError::Skip(message) => match restore_saved_local_changes(&repo, &saved) {
                    Ok(()) => RootError::Skip(message),
                    Err(restore_error) => RootError::Fail(EngineError::GitOperation {
                        message: format!(
                            "{message}; local restore after skipped update failed: {restore_error}"
                        ),
                    }),
                },
                RootError::Fail(error) => RootError::Fail(EngineError::GitOperation {
                    message: format!(
                        "{error}; local changes remain in {}",
                        saved_local_changes_message(&saved)
                    ),
                }),
            });
        }
    };
    if !outcome.conflicts.is_empty() {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: format!(
                "update paused with {} conflict(s); local changes remain in {}",
                outcome.conflicts.len(),
                saved_local_changes_message(&saved)
            ),
        }));
    }
    match restore_saved_local_changes(&repo, &saved) {
        Ok(()) => Ok(format!(
            "updated {} commits and restored local changes",
            outcome.updated_commits
        )),
        Err(error) => {
            let message = match saved {
                SavedLocalChanges::Stash(_) => {
                    format!("update completed but local restore conflicted: {error}")
                }
                SavedLocalChanges::Shelf(_) => {
                    format!("update completed but local restore from Shelf conflicted: {error}")
                }
            };
            Err(RootError::Fail(EngineError::GitOperation { message }))
        }
    }
}

fn classify_update_error(error: EngineError) -> RootError {
    match error {
        EngineError::NoUpstream { .. } | EngineError::TrackingMissing { .. } => {
            RootError::Skip(error.to_string())
        }
        other => RootError::Fail(other),
    }
}

enum RootError {
    Skip(String),
    Fail(EngineError),
}

fn run_single_root(
    path: &str,
    operation: MultiRootOperation,
    commit_message: Option<&str>,
) -> Result<(), RootError> {
    let repo = crate::repo::open_repository(path.to_string()).map_err(RootError::Fail)?;
    match operation {
        MultiRootOperation::Fetch => repo.fetch(None).map(|_| ()).map_err(RootError::Fail),
        MultiRootOperation::PullMerge => {
            repo.pull(None, false).map(|_| ()).map_err(RootError::Fail)
        }
        MultiRootOperation::PullRebase => {
            repo.pull(None, true).map(|_| ()).map_err(RootError::Fail)
        }
        MultiRootOperation::Push => {
            let branch = repo
                .branch_list()
                .ok()
                .and_then(|branches| branches.into_iter().find(|b| b.is_current).map(|b| b.name))
                .unwrap_or_else(|| "HEAD".to_string());
            repo.push_with_options(None, branch, false, false)
                .map_err(RootError::Fail)
        }
        MultiRootOperation::Commit => {
            let status = repo.status().map_err(RootError::Fail)?;
            let has_staged = status
                .iter()
                .any(|e| e.staged != crate::status::ChangeKind::Unchanged);
            if !has_staged {
                return Err(RootError::Skip("no staged changes".into()));
            }
            repo.commit(commit_message.unwrap_or("WIP").to_string(), false)
                .map(|_| ())
                .map_err(RootError::Fail)
        }
    }
}

fn run_single_root_commit(
    path: &str,
    message: &str,
    options: &MultiRootCommitOptions,
) -> Result<(), RootError> {
    let repo = crate::repo::open_repository(path.to_string()).map_err(RootError::Fail)?;
    let status = repo.status().map_err(RootError::Fail)?;
    let has_staged = status
        .iter()
        .any(|entry| entry.staged != crate::status::ChangeKind::Unchanged);
    if !options.amend && !has_staged {
        return Err(RootError::Skip("no staged changes".into()));
    }

    // Built-in checks remain mandatory, matching ContentView.doCommit:
    // identity/conflicts block, while detached/large-file/CRLF checks are
    // reported as warnings by the check implementation.
    let blocking = repo
        .commit_checks()
        .map_err(RootError::Fail)?
        .into_iter()
        .filter(|check| check.blocking)
        .map(|check| check.message)
        .collect::<Vec<_>>();
    if !blocking.is_empty() {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: format!("commit blocked by checks: {}", blocking.join("; ")),
        }));
    }

    // This flag mirrors the existing single-root force action: only custom
    // project commands are skipped; built-in identity/conflict checks above
    // are never bypassed by a UI option.
    if options.run_before_commit_checks {
        for check in &options.before_commit_commands {
            let outcome = repo
                .run_check_command(check.command.clone(), check.args.clone())
                .map_err(RootError::Fail)?;
            if !outcome.success {
                let output = outcome.output.trim();
                let suffix = if output.is_empty() {
                    String::new()
                } else {
                    format!(": {output}")
                };
                return Err(RootError::Fail(EngineError::GitOperation {
                    message: format!("before-commit check '{}' failed{suffix}", check.command),
                }));
            }
        }
    }

    let identity = repo.git_identity().ok();
    let author_name = non_empty_option(options.author_name.clone());
    let author_email = non_empty_option(options.author_email.clone());
    let committer_name = non_empty_option(options.committer_name.clone());
    let committer_email = non_empty_option(options.committer_email.clone());
    if author_name.is_some() != author_email.is_some()
        || committer_name.is_some() != committer_email.is_some()
    {
        return Err(RootError::Fail(EngineError::GitOperation {
            message: "author and committer require both name and email".into(),
        }));
    }

    let has_overrides = author_name.is_some()
        || author_email.is_some()
        || committer_name.is_some()
        || committer_email.is_some()
        || options.sign_off
        || !options.co_authors.is_empty();
    if options.amend || has_overrides || identity.as_ref().is_some_and(|value| value.sign_commits) {
        repo.commit_with_options(
            message.to_string(),
            options.skip_hooks,
            author_name,
            author_email,
            committer_name,
            committer_email,
            identity.and_then(|value| value.signing_key),
            options.sign_off,
            options.co_authors.clone(),
            options.amend,
        )
        .map(|_| ())
        .map_err(RootError::Fail)
    } else {
        repo.commit(message.to_string(), options.skip_hooks)
            .map(|_| ())
            .map_err(RootError::Fail)
    }
}

fn non_empty_option(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let value = value.trim().to_string();
        (!value.is_empty()).then_some(value)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(path: &str, display_name: &str, is_submodule: bool) -> GitRootInfo {
        GitRootInfo {
            path: path.into(),
            display_name: display_name.into(),
            relative_path: path.into(),
            is_submodule,
            head_branch: Some("main".into()),
            head_id: None,
            dirty: false,
            operation: None,
        }
    }

    #[test]
    fn push_order_publishes_deep_submodules_before_superprojects() {
        let roots = vec![
            root("/project", "project", false),
            root("/project/vendor/lib", "lib", true),
            root("/project/vendor/lib/tools", "tools", true),
            root("/other", "other", false),
        ];
        let order = push_root_indices(&roots, None);
        assert_eq!(order, vec![2, 1, 0, 3]);
    }

    #[test]
    fn failed_submodule_blocks_only_its_superproject() {
        let roots = vec![
            root("/project", "project", false),
            root("/project/vendor/lib", "lib", true),
            root("/other", "other", false),
        ];
        let results = vec![RootOperationResult {
            root_path: "/project/vendor/lib".into(),
            display_name: "lib".into(),
            success: false,
            skipped: false,
            message: "push rejected".into(),
        }];
        assert!(blocked_by_submodule_push(&roots[0], &roots, &results).is_some());
        assert!(blocked_by_submodule_push(&roots[2], &roots, &results).is_none());
    }
}

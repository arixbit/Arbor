//! 仓库对象：跨 FFI 暴露的 git 仓库句柄。
//!
//! uniffi Object 要求 Send+Sync 且方法不取 &mut self，故内部用 Mutex 做
//! 线程安全内部可变。同步导出在调用方线程内联执行（会阻塞），Swift 侧需把
//! 耗时调用放到后台线程。

use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::ops::{Deref, DerefMut};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

use gix::bstr::{BStr, ByteSlice};

use crate::blame::{BlameLine, BlameOptions};
use crate::branch::{
    compare_branches, compare_branches_all, list_all_merged_branches, list_branches, BranchCompare,
    BranchCompareEntry, BranchDeleteCommit, BranchDeletePreview, BranchInfo, RemoteBranchInfo,
    RemoteTagInfo, SyncStatus,
};
use crate::checks::CheckOutcome;
use crate::diff::{
    blob_bytes, blob_bytes_or_empty, compute_hunks_with, head_bytes, index_bytes, is_binary,
    rev_blob_bytes, rev_content_bytes, worktree_bytes, DiffMode, FileDiff,
};
use crate::error::{EngineError, PushFailureKind};
use crate::gitprocess::{GitCommandCategory, GitCommandSpec};
use crate::highlight::attach_highlights;
use crate::hooks::{run_commit_msg_hook, run_pre_commit_hook};
use crate::index::{index_tree, mode_to_kind};
use crate::log::{
    build_permanent_log_graph, collect_log, commit_info_for_id, parse_commit_signature_record,
    shorten_ref_name, CommitInfo, CommitSignatureInfo, PermanentLogGraph,
};
use crate::merge::{
    apply_merge_with_ancestor, materialize_merge_outcome, materialize_tree, parse_marker_blocks,
    upsert_index_entry, write_resolved, BlockDecision, ConflictEntry, ConflictFile, MergeMode,
    MergeOptions, MergeOutcome, PickKind, PullOptions,
};
use crate::remote::{
    cherry_pick_tree, cherry_pick_tree_with_conflict, clear_rebase_state, list_remotes,
    load_rebase_state, restore_head, restore_head_from_tree, save_rebase_state, CherryPickOutcome,
    CommitPushOutcome, FetchOutcome, FetchTagsMode, RebaseAction, RebaseOutcome, RebasePauseReason,
    RebaseState, RemoteInfo,
};
use crate::shelve::ShelveInfo;
use crate::staging::{apply_partial, LineSelection};
use crate::stash::{
    build_worktree_tree, remove_stash_entry, untracked_paths, walk_stash_chain, StashInfo,
};
use crate::status::{ChangeKind, FileEntry};
use crate::tree::TreeChange;

/// Return the patch-equivalence status for each commit unique to `source_id`.
/// `git cherry` emits `-` for a patch already present in the target and `+`
/// for a non-picked patch. Keep the parser shared by the Log highlighter and
/// IntelliJ-style Find Merged/Branch Cleanup queries.
fn git_cherry_statuses(
    repo: &gix::Repository,
    target_id: gix::hash::ObjectId,
    source_id: gix::hash::ObjectId,
) -> Result<Vec<(char, String)>, EngineError> {
    git_cherry_statuses_with_cancel(repo, target_id, source_id, None)
}

fn git_cherry_statuses_with_cancel(
    repo: &gix::Repository,
    target_id: gix::hash::ObjectId,
    source_id: gix::hash::ObjectId,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<Vec<(char, String)>, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "cherry comparison requires a non-bare worktree".into(),
    })?;
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Branch,
        "cherry",
    )
    .args([
        target_id.to_hex().to_string(),
        source_id.to_hex().to_string(),
    ])
    .working_dir(workdir);
    let outcome = crate::gitprocess::run(&spec, cancel, |_| {})?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }

    let mut statuses = Vec::new();
    for line in outcome.stdout.lines() {
        let mut fields = line.split_whitespace();
        let Some(status) = fields.next().and_then(|value| value.chars().next()) else {
            continue;
        };
        if !matches!(status, '+' | '-') {
            continue;
        }
        let Some(id) = fields.next() else { continue };
        let id = gix::hash::ObjectId::from_hex(id.as_bytes()).map_err(EngineError::from_gix)?;
        statuses.push((status, id.to_hex().to_string()));
    }
    Ok(statuses)
}

/// 一个已打开的 git 仓库。Swift 侧拿到的是引用类型（class）。
struct RepositoryMutex<T> {
    mutex: Mutex<T>,
    git_executable: RwLock<Option<PathBuf>>,
}

struct RepositoryMutexGuard<'a, T> {
    guard: std::sync::MutexGuard<'a, T>,
    _git_scope: crate::gitprocess::GitExecutableScope,
}

impl<T> RepositoryMutex<T> {
    fn new(value: T, git_executable: Option<PathBuf>) -> Self {
        Self {
            mutex: Mutex::new(value),
            git_executable: RwLock::new(git_executable),
        }
    }

    fn lock(&self) -> Result<RepositoryMutexGuard<'_, T>, ()> {
        let guard = self.mutex.lock().map_err(|_| ())?;
        let git_executable = self
            .git_executable
            .read()
            .map_err(|_| ())?
            .clone()
            .unwrap_or_else(|| crate::gitprocess::git_executable_for_working_dir(None));
        let git_scope = crate::gitprocess::begin_git_executable_scope(git_executable);
        Ok(RepositoryMutexGuard {
            guard,
            _git_scope: git_scope,
        })
    }

    fn set_git_executable(&self, executable: Option<PathBuf>) -> Result<(), ()> {
        *self.git_executable.write().map_err(|_| ())? = executable;
        Ok(())
    }
}

impl<T> Deref for RepositoryMutexGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        &self.guard
    }
}

impl<T> DerefMut for RepositoryMutexGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.guard
    }
}

#[derive(uniffi::Object)]
pub struct Repository {
    inner: RepositoryMutex<gix::Repository>,
    permanent_log_graph: Mutex<Option<PermanentLogGraph>>,
}

/// Run an operation against the repository-wide graph, rebuilding it only
/// when refs, HEAD, or the requested graph ordering changed.
fn with_permanent_log_graph<T>(
    repository: &Repository,
    repo: &gix::Repository,
    sort_mode: crate::log::LogGraphSortMode,
    operation: impl FnOnce(&PermanentLogGraph) -> T,
) -> Result<T, EngineError> {
    let refs_token = crate::branch::ref_tip_snapshot(repo)?;
    let head_id = repo.head_id().ok().map(|id| id.detach());
    let mut cache = repository
        .permanent_log_graph
        .lock()
        .expect("permanent log graph mutex poisoned");
    let needs_refresh = cache
        .as_ref()
        .map(|graph| !graph.is_current(&refs_token, head_id, sort_mode))
        .unwrap_or(true);
    if needs_refresh {
        *cache = Some(build_permanent_log_graph(repo, sort_mode)?);
    }
    Ok(operation(
        cache
            .as_ref()
            .expect("permanent log graph must exist after refresh"),
    ))
}

/// Return whether Git can resolve a checkout reference in this repository.
///
/// Multi-root checkout uses this to preserve IntelliJ's `refShouldBeValid=false`
/// behavior: a reference missing from one root is skipped there while other
/// roots continue. The actual checkout still performs its own validation and
/// worktree protection.
pub(crate) fn can_resolve_reference(repository: &Arc<Repository>, reference: &str) -> bool {
    let Ok(repo) = repository.inner.lock() else {
        return false;
    };
    repo.rev_parse_single(BStr::new(reference.as_bytes()))
        .is_ok()
}

fn prepare_log_command_args(command_args: &[String]) -> Vec<String> {
    let separator = command_args
        .iter()
        .position(|argument| argument == "--")
        .unwrap_or(command_args.len());
    let mut args = command_args[..separator].to_vec();
    // Git's output is an implementation detail of the engine API. Place the
    // overrides after user options so --pretty/--format/--patch cannot make
    // commit-id parsing ambiguous. Keep pathspecs after the conventional --.
    args.push("--no-patch".into());
    args.push("--format=%H".into());
    if separator < command_args.len() {
        args.extend_from_slice(&command_args[separator..]);
    }
    args
}

/// `git reset` 的四种安全面板选项，与 Rebased/IntelliJ 的 GitResetMode 一一对应。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResetMode {
    Soft,
    Mixed,
    Hard,
    Keep,
}

/// Result of a reset that recorded a durable, compare-and-swap guarded undo
/// snapshot. `rollback_id` is absent only when the operation did not change
/// either the ref or the local scene.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ResetRecoveryInfo {
    pub initial_head: String,
    pub final_head: String,
    pub initial_branch: Option<String>,
    pub final_branch: Option<String>,
    pub rollback_id: Option<String>,
}

/// A persisted reset recovery target. The rollback id names the repository
/// marker and hidden snapshot refs; the commit and branch fields are the
/// compare-and-swap guard carried by Operation Log/native notifications.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ResetRecoveryTarget {
    pub root_path: String,
    pub display_name: String,
    pub initial_head: String,
    pub expected_head: String,
    pub expected_head_branch: Option<String>,
    pub mode: ResetMode,
    pub rollback_id: String,
}

/// Revert 多提交入口使用的 merge mainline。
///
/// IntelliJ 的日志 Revert action 会在 UI 层禁用 merge commit；引擎仍允许
/// 明确传入 mainline，供未来需要精确处理 merge revert 的调用方使用。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RevertMainline {
    First,
    Second,
}

/// IntelliJ 的 Cherry-pick 空提交处理策略。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum CherryPickEmptyPolicy {
    /// 跳过当前空提交并继续 sequencer。
    Skip,
    /// 使用 Git 生成一个保留原提交消息的空提交。
    CreateEmpty,
}

/// IntelliJ's GitSaveChangesPolicy: preserve dirty local changes with either
/// Git's stash object or Arbor's persistent Shelf model before a history
/// operation.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocalChangesSavePolicy {
    Stash,
    Shelve,
}

/// Persisted identity of local changes waiting for a preserving operation to
/// finish restoring them. The UI uses the exact stash object id or Shelf name
/// to recover the right root after a partial multi-root operation or restart.
#[derive(uniffi::Record, Clone, Debug)]
pub struct LocalChangesRestoreInfo {
    pub operation: String,
    pub kind: String,
    pub identifier: String,
}

/// Result of applying an imported patch one file member at a time. IntelliJ's
/// Apply Patch action keeps successful members when another member cannot be
/// applied, so the UI must not infer success from the absence of an engine
/// error.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PatchApplyStatus {
    Success,
    Partial,
    AlreadyApplied,
    Skip,
    Failure,
    Abort,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PatchApplyMemberResult {
    pub path: String,
    pub status: PatchApplyStatus,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct PatchApplyResult {
    pub applied_paths: Vec<String>,
    pub failed_paths: Vec<String>,
    pub overall_status: PatchApplyStatus,
    pub member_statuses: Vec<PatchApplyMemberResult>,
}

/// Result of rebuilding a checked-out branch after its upstream was force
/// pushed. Linear local commits are replayed on the fetched remote tip; a
/// local merge commit falls back to the normal Update Project merge path.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ForcePushedBranchUpdateOutcome {
    pub branch: String,
    pub upstream: String,
    pub replayed_commits: u32,
    pub used_merge_update: bool,
    /// Number of commits reachable from the fetched upstream tip but not
    /// from the UpdateSession range start.
    pub received_commits_count: u32,
    /// Number of paths changed between the pre-fetch and post-fetch
    /// upstream trees, matching IntelliJ's update notification summary.
    pub updated_files_count: u32,
    /// The UpdateSession range start used by the View Commits action. This is
    /// the pre-fetch merge-base of local HEAD and the old tracking tip, and
    /// can be absent when the tracking ref did not exist before the fetch.
    pub update_range_start: Option<String>,
    pub new_upstream_tip: String,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubmoduleState {
    Clean,
    Modified,
    Uninitialized,
    Conflict,
    Missing,
    Unknown,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SubmoduleInfo {
    pub path: String,
    pub head_id: String,
    pub state: SubmoduleState,
    /// .gitmodules 配置的跟踪分支（未配置 None）。
    pub branch: Option<String>,
    /// 子模块工作区是否有未提交变更（dirty）。
    pub dirty: bool,
}

/// Compare-and-swap boundary for undoing a clean `git submodule remove`.
///
/// Removing a submodule changes `.gitmodules`, the superproject index, and the
/// nested worktree. The UI must therefore persist both sides of the
/// `.gitmodules` snapshot and refuse the undo if any post-remove state changed.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SubmoduleRemoveUndoTarget {
    pub path: String,
    pub expected_parent_head_id: String,
    pub restore_gitlink_id: String,
    pub expected_gitmodules_present: bool,
    pub expected_gitmodules_contents: Option<String>,
    pub restore_gitmodules_present: bool,
    pub restore_gitmodules_contents: Option<String>,
}

/// Compare-and-swap boundary for undoing a clean `git submodule add`.
///
/// Add changes the superproject's `.gitmodules` file, index gitlink, and
/// nested worktree without creating a parent commit. Undo therefore restores
/// the exact pre-add `.gitmodules` bytes and removes the gitlink only while
/// the parent HEAD and post-add child state still match this snapshot.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SubmoduleAddUndoTarget {
    pub path: String,
    pub expected_parent_head_id: String,
    pub expected_submodule_head_id: String,
    pub expected_gitmodules_present: bool,
    pub expected_gitmodules_contents: Option<String>,
    pub restore_gitmodules_present: bool,
    pub restore_gitmodules_contents: Option<String>,
}

/// A gitlink change in a superproject, together with the nested repository
/// state needed by IntelliJ's submodule diff view.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SubmoduleChange {
    pub path: String,
    pub old_commit: Option<String>,
    pub new_commit: Option<String>,
    pub current_commit: Option<String>,
    pub initialized: bool,
    pub dirty: bool,
    /// Commits reachable from `new_commit` but not from `old_commit`, newest first.
    /// This is empty when the nested worktree is not initialized or the objects
    /// are unavailable locally; the two gitlink ids remain available above.
    pub commits: Vec<CommitInfo>,
    /// File-level changes between the two gitlink commits. This is the nested
    /// half of the joint parent-gitlink/submodule diff; it remains empty when
    /// the nested repository is unavailable or either commit object is missing.
    pub nested_changes: Vec<TreeChange>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct WorktreeInfo {
    pub path: String,
    pub head_id: String,
    pub branch: String,
    pub is_bare: bool,
    pub locked: bool,
    pub prunable: bool,
}

/// Result of running Git's configured external merge tool for one conflicted
/// path. The remaining paths are read from the index after the tool exits.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ExternalMergeToolResult {
    pub path: String,
    pub tool: String,
    pub resolved: bool,
    pub remaining_conflicts: Vec<String>,
}

/// Repository-local overrides for the two Git mergetool selectors. Empty
/// values remove the local override and let higher-level Git config apply.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ExternalMergeToolSettings {
    pub merge_tool: String,
    pub merge_gui_tool: String,
}

/// 一次原始 Git 命令的完整结果，供 Git Console 和操作历史使用。
#[derive(uniffi::Record, Clone, Debug)]
pub struct GitCommandResult {
    pub command: String,
    pub stdout: String,
    /// 原始 stdout 字节，供需要保真写盘的 PatchWriter 使用。
    pub stdout_bytes: Vec<u8>,
    pub stderr: String,
    pub exit_code: i32,
    pub duration_ms: u64,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct GitIdentity {
    pub name: Option<String>,
    pub email: Option<String>,
    pub signing_key: Option<String>,
    pub signing_format: Option<String>,
    pub sign_commits: bool,
}

/// OpenSSH host-key verification policy used by the repository's
/// `core.sshCommand`. Strict is the safe default; `noCheck` is intentionally
/// explicit because it disables host-key verification.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SshHostKeyPolicy {
    Strict,
    AcceptNew,
    Ask,
    NoCheck,
}

/// Authentication preference passed to OpenSSH through
/// `PreferredAuthentications`.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SshAuthMethod {
    Auto,
    PublicKey,
    Password,
}

/// Repository-scoped SSH connection settings. Empty paths mean that the
/// corresponding OpenSSH default is used.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SshConnectionSettings {
    /// User-supplied executable/command prefix, for example `ssh` or
    /// `ssh -F ~/.ssh/config`.
    pub command: String,
    pub known_hosts_file: String,
    pub identity_file: String,
    pub host_key_policy: SshHostKeyPolicy,
    pub auth_method: SshAuthMethod,
}

/// 从任意路径向上发现并打开 git 仓库（等价 git 的目录发现）。
/// 非 git 目录返回 `NotARepository`。
#[uniffi::export]
pub fn open_repository(path: String) -> Result<Arc<Repository>, EngineError> {
    ignore_sigpipe();
    let repo = gix::discover(&path)?;
    if let Some(workdir) = repo.workdir() {
        crate::attributes::register_worktree(workdir);
    }
    let git_executable = crate::gitprocess::project_git_executable_for_working_dir(repo.workdir());
    Ok(Arc::new(Repository {
        inner: RepositoryMutex::new(repo, git_executable),
        permanent_log_graph: Mutex::new(None),
    }))
}

/// Enable Git-configured clean/smudge filters and working-tree encodings for
/// conversion-sensitive operations. This is an application-level opt-in;
/// the default remains fail-closed so opening a repository never executes
/// arbitrary filter commands implicitly.
#[uniffi::export]
pub fn set_external_conversion_enabled(enabled: bool) {
    crate::attributes::set_default_external_conversion_enabled(enabled);
}

/// 在指定目录初始化 Git 仓库。目录可以已存在，但不会覆盖已有内容。
/// 使用 argv 调用系统 Git，避免把用户路径拼接进 shell 命令。
#[uniffi::export]
pub fn initialize_repository(path: String) -> Result<String, EngineError> {
    ignore_sigpipe();
    let target = std::fs::canonicalize(&path).map_err(EngineError::from_gix)?;
    if !target.is_dir() {
        return Err(EngineError::GitOperation {
            message: "git init requires a directory".into(),
        });
    }
    let output = crate::gitprocess::git_command()
        .args(["init", "--", target.to_string_lossy().as_ref()])
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git init failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(target.display().to_string())
}

/// 将远程仓库克隆到目标目录，返回目标目录的标准化路径。
#[uniffi::export]
pub fn clone_repository(
    url: String,
    destination: String,
    recursive_submodules: bool,
) -> Result<String, EngineError> {
    clone_inner(url, destination, recursive_submodules, None)
}

/// 带认证代理的克隆：HTTPS/SSH 首次提示走 Swift 的 handler（AUTH-001）。
/// 认证取消时返回 `Cancelled` 分类，而不是 generic error。
#[uniffi::export]
pub fn clone_repository_with_auth(
    url: String,
    destination: String,
    recursive_submodules: bool,
    broker: std::sync::Arc<crate::auth::CredentialBroker>,
) -> Result<String, EngineError> {
    clone_inner(url, destination, recursive_submodules, Some(&broker))
}

fn clone_inner(
    url: String,
    destination: String,
    recursive_submodules: bool,
    broker: Option<&crate::auth::CredentialBroker>,
) -> Result<String, EngineError> {
    ignore_sigpipe();
    let url = url.trim();
    let destination = std::path::PathBuf::from(destination.trim());
    if url.is_empty() {
        return Err(EngineError::GitOperation {
            message: "git clone requires a repository URL".into(),
        });
    }
    if destination.as_os_str().is_empty() || destination.exists() {
        return Err(EngineError::GitOperation {
            message: "clone destination must be a new path".into(),
        });
    }
    let parent = destination
        .parent()
        .ok_or_else(|| EngineError::GitOperation {
            message: "clone destination has no parent directory".into(),
        })?;
    if !parent.is_dir() {
        return Err(EngineError::GitOperation {
            message: "clone destination parent is not a directory".into(),
        });
    }
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Clone,
        "clone",
    )
    .flag_if("--recurse-submodules", recursive_submodules)
    .url_arg(url)
    .arg(destination.to_string_lossy().into_owned());
    let outcome = match broker {
        Some(broker) => crate::auth::run_with_askpass(&spec, broker, None)?,
        None => crate::gitprocess::run_to_completion(&spec)?,
    };
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    Ok(std::fs::canonicalize(&destination)
        .map_err(EngineError::from_gix)?
        .display()
        .to_string())
}

/// 多仓库聚合 status 的一条：仓库显示名 + 该仓库的一条变更。
#[derive(uniffi::Record, Clone, Debug)]
pub struct WorkspaceEntry {
    pub repo: String,
    pub entry: FileEntry,
}

/// 工作区目录中的一项。`path` 始终是相对于仓库根目录的 POSIX 风格路径。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

/// 指定 revision 中的树目录条目。路径相对于仓库根目录。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RevisionEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

/// How historical file content is materialized. This mirrors IntelliJ's
/// `git.read.content.with` setting while keeping the raw blob path available
/// for callers that explicitly choose `None`.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitContentTransformMode {
    None,
    Filters,
    Textconv,
}

/// Git 文件版本内容。二进制文件不返回文本；大文本最多返回 1 MiB。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FileContent {
    pub binary: bool,
    pub truncated: bool,
    pub text: String,
}

/// 三层 staging 对比的一侧内容：HEAD、index（staged）或工作区（local）。
/// `present=false` 用于新增/删除文件，避免把缺失文件和真正的空文件混淆。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct StagingVersionContent {
    pub present: bool,
    pub binary: bool,
    pub truncated: bool,
    pub text: String,
}

/// IntelliJ GitStageCompareThreeVersionsAction 所需的三版本数据。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct StagingFileVersions {
    pub path: String,
    pub head: StagingVersionContent,
    pub staged: StagingVersionContent,
    pub local: StagingVersionContent,
}

const MAX_WORKTREE_TEXT_BYTES: usize = 1024 * 1024;

fn file_content_from_bytes(mut bytes: Vec<u8>, force_binary: bool) -> FileContent {
    let truncated = bytes.len() > MAX_WORKTREE_TEXT_BYTES;
    if truncated {
        bytes.truncate(MAX_WORKTREE_TEXT_BYTES);
    }
    let binary = force_binary || is_binary(&bytes);
    FileContent {
        binary,
        truncated,
        text: if binary {
            String::new()
        } else {
            String::from_utf8_lossy(&bytes).into_owned()
        },
    }
}

fn staging_version_content(bytes: Option<Vec<u8>>, force_binary: bool) -> StagingVersionContent {
    let Some(mut bytes) = bytes else {
        return StagingVersionContent {
            present: false,
            binary: false,
            truncated: false,
            text: String::new(),
        };
    };
    let truncated = bytes.len() > MAX_WORKTREE_TEXT_BYTES;
    if truncated {
        bytes.truncate(MAX_WORKTREE_TEXT_BYTES);
    }
    let binary = force_binary || is_binary(&bytes);
    StagingVersionContent {
        present: true,
        binary,
        truncated,
        text: if binary {
            String::new()
        } else {
            String::from_utf8_lossy(&bytes).into_owned()
        },
    }
}

fn staging_object_content(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
) -> Result<StagingVersionContent, EngineError> {
    let object = repo.find_object(id).map_err(EngineError::from_gix)?;
    if object.kind.is_blob() {
        Ok(staging_version_content(Some(object.data.to_vec()), false))
    } else {
        Ok(staging_version_content(Some(Vec::new()), true))
    }
}

fn revision_tree<'a>(
    repo: &'a gix::Repository,
    revision: &str,
    relative: &str,
) -> Result<gix::Tree<'a>, EngineError> {
    let relative_path = worktree_relative_path(relative)?;
    let spec = if relative_path.as_os_str().is_empty() {
        format!("{revision}^{{tree}}")
    } else {
        format!("{revision}:{}", relative_path.to_string_lossy())
    };
    let id = repo
        .rev_parse_single(BStr::new(spec.as_bytes()))
        .map_err(EngineError::from_gix)?
        .detach();
    repo.find_tree(id).map_err(EngineError::from_gix)
}

fn submodule_gitlink_at_revision(
    repo: &gix::Repository,
    revision: &str,
    path: &str,
) -> Result<Option<gix::hash::ObjectId>, EngineError> {
    if revision.is_empty() {
        return Ok(None);
    }
    let tree_id = repo
        .rev_parse_single(BStr::new(format!("{revision}^{{tree}}").as_bytes()))
        .map_err(EngineError::from_gix)?
        .detach();
    let tree = repo.find_tree(tree_id).map_err(EngineError::from_gix)?;
    Ok(tree
        .lookup_entry_by_path(path)
        .map_err(EngineError::from_gix)?
        .and_then(|entry| entry.mode().is_commit().then_some(entry.object_id())))
}

/// 把 UI 传入的相对路径解析到工作区内，并拒绝越界路径。
pub(crate) fn worktree_relative_path(relative: &str) -> Result<PathBuf, EngineError> {
    let path = Path::new(relative);
    if path.is_absolute() {
        return Err(EngineError::GitOperation {
            message: "worktree path must be relative".into(),
        });
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(EngineError::GitOperation {
            message: "worktree path escapes repository".into(),
        });
    }
    if path
        .components()
        .any(|component| matches!(component, Component::Normal(name) if name == ".git"))
    {
        return Err(EngineError::GitOperation {
            message: "git metadata is not part of the worktree".into(),
        });
    }
    Ok(path.to_path_buf())
}

fn configured_external_merge_tool(workdir: &Path) -> Result<(String, bool), EngineError> {
    for (key, use_gui) in [("merge.tool", false), ("merge.guitool", true)] {
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "config",
        )
        .args(["--get", key])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            continue;
        }
        if let Some(tool) = outcome
            .stdout
            .lines()
            .map(str::trim)
            .find(|tool| !tool.is_empty())
        {
            return Ok((tool.to_string(), use_gui));
        }
    }
    Err(EngineError::GitOperation {
        message: "no Git external merge tool is configured; set merge.tool or merge.guitool".into(),
    })
}

fn worktree_root(repo: &gix::Repository) -> Result<&Path, EngineError> {
    repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "operation requires a non-bare repository".into(),
    })
}

fn percent_encode_path_component(value: &str) -> Option<String> {
    if value.is_empty() || value.contains('\0') {
        return None;
    }
    Some(percent_encode_bytes(value.as_bytes(), false))
}

fn percent_encode_git_path(value: &str) -> Option<String> {
    if value.is_empty() || value.contains('\0') {
        return None;
    }
    Some(percent_encode_bytes(value.as_bytes(), true))
}

fn percent_encode_bytes(bytes: &[u8], preserve_slash: bool) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut encoded = String::with_capacity(bytes.len());
    for &byte in bytes {
        let is_unreserved =
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~');
        if is_unreserved || (preserve_slash && byte == b'/') {
            encoded.push(byte as char);
        } else {
            encoded.push('%');
            encoded.push(HEX[(byte >> 4) as usize] as char);
            encoded.push(HEX[(byte & 0x0f) as usize] as char);
        }
    }
    encoded
}

/// 打开多个仓库并聚合 status（模块 A 多仓库根的数据层）。
/// 每条变更带所属仓库的显示名（workdir basename）。任一路径非仓库即报错。
#[uniffi::export]
pub fn workspace_status(paths: Vec<String>) -> Result<Vec<WorkspaceEntry>, EngineError> {
    ignore_sigpipe();
    let mut out = Vec::new();
    for path in paths {
        let repo = gix::discover(&path)?;
        let name = repo
            .workdir()
            .and_then(|w| w.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.clone());
        let git_executable =
            crate::gitprocess::project_git_executable_for_working_dir(repo.workdir());
        let r = Repository {
            inner: RepositoryMutex::new(repo, git_executable),
            permanent_log_graph: Mutex::new(None),
        };
        for entry in r.status()? {
            out.push(WorkspaceEntry {
                repo: name.clone(),
                entry,
            });
        }
    }
    Ok(out)
}

/// 切换本地分支的核心实现。
///
/// `force` 只跳过“会覆盖未提交变更”的保护；分支解析、工作区物化、
/// index 重建和 HEAD 更新仍走同一条路径，避免 Smart/Force 分支产生
/// 不同的仓库状态。
fn validate_branch_name_inner(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    validate_branch_name_syntax_inner(name)?;
    let full = format!("refs/heads/{name}");
    if repo.find_reference(full.as_str()).is_ok() {
        return Err(EngineError::GitOperation {
            message: format!("branch '{name}' already exists"),
        });
    }
    Ok(())
}

fn validate_branch_name_syntax_inner(name: &str) -> Result<(), EngineError> {
    if name.is_empty() {
        return Err(EngineError::GitOperation {
            message: "branch name must not be empty".into(),
        });
    }
    if name == "HEAD" {
        return Err(EngineError::GitOperation {
            message: "branch name must not be HEAD".into(),
        });
    }
    if name.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "branch name must not start with '-'".into(),
        });
    }
    let full = format!("refs/heads/{name}");
    let _: gix::refs::FullName = full.as_str().try_into().map_err(EngineError::from_gix)?;
    Ok(())
}

fn switch_branch_inner(repo: &gix::Repository, name: &str, force: bool) -> Result<(), EngineError> {
    use gix::refs::transaction::{Change, PreviousValue, RefEdit};
    use gix::refs::Target;

    if crate::opstate::detect(repo)?.is_some() {
        return Err(EngineError::GitOperation {
            message: "checkout: another Git operation is in progress; continue or abort it first"
                .into(),
        });
    }

    let full = format!("refs/heads/{name}");
    let target_id = repo
        .find_reference(full.as_str())
        .map_err(EngineError::from_gix)?
        .try_id()
        .ok_or_else(|| EngineError::GitOperation {
            message: "branch has no object id".into(),
        })?
        .detach();
    let target_commit = repo.find_commit(target_id).map_err(EngineError::from_gix)?;
    let target_tree = target_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let head_commit = repo.head_commit().map_err(EngineError::from_gix)?;
    let head_tree = head_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    if !force {
        crate::merge::guard_uncommitted_overwrite(repo, head_tree, target_tree)?;
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    materialize_tree(repo, head_tree, target_tree, workdir)?;

    let mut index = repo
        .index_from_tree(&target_tree)
        .map_err(EngineError::from_gix)?;
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;

    let full_name: gix::refs::FullName = full.as_str().try_into().map_err(EngineError::from_gix)?;
    let head_name: gix::refs::FullName = "HEAD".try_into().map_err(EngineError::from_gix)?;
    repo.edit_reference(RefEdit {
        change: Change::Update {
            log: Default::default(),
            expected: PreviousValue::Any,
            new: Target::Symbolic(full_name),
        },
        name: head_name,
        deref: false,
    })
    .map_err(EngineError::from_gix)?;
    Ok(())
}

/// 系统 Git 负责 revision/tag 的解析，但 checkout 前后的状态保护仍由
/// Arbor 统一管理，避免 detached checkout 绕过操作状态检查。
fn checkout_detached_inner(
    repo: &gix::Repository,
    commit_id: &str,
    force: bool,
) -> Result<(), EngineError> {
    let commit_id = commit_id.trim();
    if commit_id.is_empty() || commit_id.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "checkout reference must not be empty or start with '-'".into(),
        });
    }
    if crate::opstate::detect(repo)?.is_some() {
        return Err(EngineError::GitOperation {
            message: "checkout: another Git operation is in progress; continue or abort it first"
                .into(),
        });
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "checkout: bare repository has no worktree".into(),
    })?;
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args(["checkout", "--detach"]);
    if force {
        command.arg("--force");
    }
    let output = command
        .args(["--quiet", commit_id])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git checkout failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(())
}

/// 用 system Git 创建 remote-tracking 对应的本地分支；Smart/Force 只包裹
/// 这一原子 checkout，不改变 `--track -c` 的分支创建语义。
fn checkout_remote_branch_inner(
    repo: &gix::Repository,
    remote_branch: &str,
    local_name: Option<&str>,
    force: bool,
) -> Result<(), EngineError> {
    if crate::opstate::detect(repo)?.is_some() {
        return Err(EngineError::GitOperation {
            message: "checkout: another Git operation is in progress; continue or abort it first"
                .into(),
        });
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "checkout remote branch requires a worktree".into(),
    })?;
    let remote_branch = remote_branch.trim();
    let local = local_name
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| {
            remote_branch
                .split_once('/')
                .map(|(_, branch)| branch)
                .unwrap_or(remote_branch)
        });
    if remote_branch.is_empty() || local.trim().is_empty() || !remote_branch.contains('/') {
        return Err(EngineError::GitOperation {
            message: "remote branch must look like remote/branch".into(),
        });
    }
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args(["switch"]);
    if force {
        command.arg("--force");
    }
    let output = command
        .args(["--track", "-c", local, remote_branch])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git switch remote branch failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(())
}

/// Save local changes with the configured IntelliJ policy, execute one
/// checkout operation, then restore the exact saved Shelf or stash. A Shelf
/// restore conflict is intentionally allowed to propagate with its persisted
/// restore snapshot so the normal Merge Revisions workbench can finish it.
fn smart_checkout_with_policy<F>(
    repository: &Repository,
    label: String,
    save_policy: LocalChangesSavePolicy,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    checkout: F,
) -> Result<(), EngineError>
where
    F: FnOnce(&gix::Repository) -> Result<(), EngineError>,
{
    ensure_not_cancelled(cancel)?;
    if repository.operation_state()?.is_some() {
        return Err(EngineError::GitOperation {
            message: "checkout: another Git operation is in progress; continue or abort it first"
                .into(),
        });
    }
    let dirty = repository.status()?.iter().any(|entry| {
        entry.staged != ChangeKind::Unchanged
            || !matches!(entry.unstaged, ChangeKind::Unchanged | ChangeKind::Ignored)
    });
    if !dirty {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        return checkout(&repo);
    }

    let (shelf_name, stash_id) = if save_policy == LocalChangesSavePolicy::Shelve {
        let (name, paths) = {
            let repo = repository.inner.lock().expect("repo mutex poisoned");
            let paths = crate::status::compute_status(&repo)?
                .into_iter()
                .filter(|entry| {
                    entry.staged != ChangeKind::Unchanged || entry.unstaged != ChangeKind::Unchanged
                })
                .map(|entry| entry.path)
                .collect::<Vec<_>>();
            (unique_temporary_shelf_name(&repo, &label)?, paths)
        };
        repository.shelve_for_preservation(name.clone(), paths)?;
        (Some(name), None)
    } else {
        // Preserve the exact stash object. A user or another background
        // operation may add a newer stash before checkout finishes, so
        // restoring by index 0 can apply or remove the wrong local scene.
        let stash_id = repository.stash_save_with_options(Some(label.clone()), true, false)?;
        let stash_id =
            gix::hash::ObjectId::from_hex(stash_id.as_bytes()).map_err(EngineError::from_gix)?;
        (None, Some(stash_id))
    };
    if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
        let restore_result = match (&shelf_name, stash_id) {
            (Some(name), _) => {
                let repo = repository.inner.lock().expect("repo mutex poisoned");
                shelve_pop_preservation_locked(&repo, name)
            }
            (_, Some(stash_id)) => stash_pop_with_id(repository, stash_id, true),
            (None, None) => Ok(()),
        };
        return match restore_result {
            Ok(()) => Err(EngineError::Cancelled),
            Err(restore_error) => Err(EngineError::GitOperation {
                message: format!(
                    "{label} was cancelled, but saved local changes could not be restored: {restore_error}"
                ),
            }),
        };
    }
    let checkout_result = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        let result = checkout(&repo);
        if result.is_ok() && cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
            Err(EngineError::Cancelled)
        } else {
            result
        }
    };
    let restore = || match (&shelf_name, stash_id) {
        (Some(name), _) => {
            let repo = repository.inner.lock().expect("repo mutex poisoned");
            shelve_pop_preservation_locked_with_cancel(&repo, name, cancel)
        }
        (_, Some(stash_id)) => stash_pop_with_id(repository, stash_id, true),
        (None, None) => Ok(()),
    };
    match checkout_result {
        Ok(()) => restore(),
        Err(checkout_error) => match restore() {
            Ok(()) => Err(checkout_error),
            Err(restore_error) => match restore_error {
                EngineError::Cancelled => Err(EngineError::Cancelled),
                EngineError::StashApplyConflict { paths, stash_id } => {
                    Err(EngineError::StashApplyConflict { paths, stash_id })
                }
                EngineError::ShelveApplyConflict { name, paths } => {
                    Err(EngineError::ShelveApplyConflict { name, paths })
                }
                other => Err(EngineError::GitOperation {
                    message: format!(
                        "smart checkout failed: {checkout_error}; restoring local changes also failed: {other}"
                    ),
                }),
            },
        },
    }
}

/// 忽略 SIGPIPE（进程级一次）：gix 的文件传输内部用管道，宿主程序若不是 Rust
/// （如 Swift），管道破裂会触发默认 SIGPIPE 处理器直接终止进程；忽略后变为
/// EPIPE 错误正常传播。
static SIGPIPE_INIT: std::sync::Once = std::sync::Once::new();
fn ignore_sigpipe() {
    SIGPIPE_INIT.call_once(|| unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    });
}

/// 统一提交原语；调用方负责决定父提交和 hooks。
fn commit_inner(
    repo: &gix::Repository,
    message: &str,
    parents: &[gix::hash::ObjectId],
    skip_hooks: bool,
) -> Result<gix::hash::ObjectId, EngineError> {
    if let Some(output) = run_pre_commit_hook(repo, skip_hooks)? {
        return Err(EngineError::GitOperation {
            message: format!("pre-commit hook failed: {output}"),
        });
    }
    let message = crate::commit_message::format(repo, message.to_string())?;
    let message = run_commit_msg_hook(repo, &message, skip_hooks)?;
    let tree_id = index_tree(repo)?;
    let msg = if message.ends_with('\n') {
        message
    } else {
        format!("{message}\n")
    };
    repo.commit("HEAD", &msg, tree_id, parents.iter().copied())
        .map(|id| id.detach())
        .map_err(EngineError::from_gix)
}

/// A merge which has materialized its result but has not been committed yet.
///
/// Keeping this tiny bit of state in `.git` is what makes the conflict flow
/// restartable: resolving a file is not the same operation as creating the
/// eventual two-parent or squash single-parent commit.
#[derive(Clone, Debug)]
struct MergeState {
    ours: gix::hash::ObjectId,
    theirs: gix::hash::ObjectId,
    /// The ref/revision selected by the user. Older state files do not carry
    /// this field, so an empty value remains a valid backward-compatible
    /// state and simply disables post-merge branch actions.
    reference: String,
    message: String,
    mode: MergeMode,
    no_verify: bool,
}

fn merge_state_path(repo: &gix::Repository) -> PathBuf {
    repo.git_dir().join("arbor-merge-state")
}

fn encode_merge_state_field(value: &str) -> String {
    value.replace('\\', "\\\\").replace('\n', "\\n")
}

fn decode_merge_state_field(value: &str) -> String {
    let mut output = String::new();
    let mut chars = value.chars();
    while let Some(ch) = chars.next() {
        if ch == '\\' {
            match chars.next() {
                Some('n') => output.push('\n'),
                Some('\\') => output.push('\\'),
                Some(other) => {
                    output.push('\\');
                    output.push(other);
                }
                None => output.push('\\'),
            }
        } else {
            output.push(ch);
        }
    }
    output
}

fn save_merge_state(
    repo: &gix::Repository,
    ours: gix::hash::ObjectId,
    theirs: gix::hash::ObjectId,
    reference: &str,
    message: &str,
    mode: MergeMode,
    no_verify: bool,
) -> Result<(), EngineError> {
    let text = format!(
        "ours={ours}\ntheirs={theirs}\nreference={}\nmode={}\nno-verify={}\nmessage={}\n",
        encode_merge_state_field(reference),
        merge_mode_name(mode),
        no_verify,
        encode_merge_state_field(message),
    );
    std::fs::write(merge_state_path(repo), text).map_err(EngineError::from_gix)
}

fn merge_mode_name(mode: MergeMode) -> &'static str {
    match mode {
        MergeMode::FastForward => "fast-forward",
        MergeMode::FastForwardOnly => "fast-forward-only",
        MergeMode::NoFastForward => "no-fast-forward",
        MergeMode::Squash => "squash",
    }
}

fn parse_merge_mode(value: &str) -> Option<MergeMode> {
    match value {
        "fast-forward" => Some(MergeMode::FastForward),
        "fast-forward-only" => Some(MergeMode::FastForwardOnly),
        "no-fast-forward" => Some(MergeMode::NoFastForward),
        "squash" => Some(MergeMode::Squash),
        _ => None,
    }
}

fn load_merge_state(repo: &gix::Repository) -> Result<Option<MergeState>, EngineError> {
    let path = merge_state_path(repo);
    let Ok(text) = std::fs::read_to_string(path) else {
        return Ok(None);
    };
    let mut ours = None;
    let mut theirs = None;
    let mut reference = String::new();
    let mut message = String::new();
    let mut no_verify = false;
    // Old state files predate merge modes and represented the existing
    // explicit two-parent finish flow.
    let mut mode = MergeMode::NoFastForward;
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "ours" => ours = gix::hash::ObjectId::from_hex(value.as_bytes()).ok(),
            "theirs" => theirs = gix::hash::ObjectId::from_hex(value.as_bytes()).ok(),
            "reference" => reference = decode_merge_state_field(value),
            "mode" => mode = parse_merge_mode(value).unwrap_or(MergeMode::NoFastForward),
            "no-verify" => no_verify = value == "true",
            "message" => message = decode_merge_state_field(value),
            _ => {}
        }
    }
    match (ours, theirs) {
        (Some(ours), Some(theirs)) => Ok(Some(MergeState {
            ours,
            theirs,
            reference,
            message,
            mode,
            no_verify,
        })),
        _ => Err(EngineError::GitOperation {
            message: "merge: invalid merge state".into(),
        }),
    }
}

fn clear_merge_state(repo: &gix::Repository) {
    let _ = std::fs::remove_file(merge_state_path(repo));
    crate::conflict::clear_resolved_ledger(repo);
}

fn push_failure_kind(output: &str) -> PushFailureKind {
    let lower = output.to_ascii_lowercase();
    if lower.contains("stale info") || lower.contains("stale lease") {
        PushFailureKind::StaleInfo
    } else if lower.contains("authentication failed")
        || lower.contains("could not read username")
        || lower.contains("invalid username")
        || lower.contains("invalid credentials")
        || lower.contains("permission denied (publickey)")
        || lower.contains("publickey")
    {
        PushFailureKind::Authentication
    } else if lower.contains("permission denied")
        || lower.contains("write access to repository not granted")
        || lower.contains("not permitted")
    {
        PushFailureKind::Permission
    } else if lower.contains("non-fast-forward")
        || lower.contains("fetch first")
        || lower.contains("tip of your current branch is behind")
    {
        PushFailureKind::NonFastForward
    } else {
        PushFailureKind::Other
    }
}

/// 统一 push 原语；gix 0.86 没有 send-pack，仍由系统 git 执行。
/// IDX-001：单文件单方向 diff（uniffi 导出块外，可接收内部类型）。
fn diff_file_inner(
    repo: &gix::Repository,
    path: &str,
    mode: DiffMode,
    ignore_whitespace: bool,
) -> Result<FileDiff, EngineError> {
    diff_file_inner_settings(
        repo,
        path,
        mode,
        &crate::diff::DiffSettings {
            ignore_all_space: ignore_whitespace,
            ..crate::diff::DiffSettings::default()
        },
    )
}

/// Render a configured Git textconv driver through system Git when the caller
/// has explicitly opted in. `--no-ext-diff` keeps arbitrary diff helpers out
/// of this path; `--textconv` is the narrower, read-only conversion mode.
fn textconv_diff_if_enabled(
    repo: &gix::Repository,
    path: &str,
    mode: DiffMode,
    settings: &crate::diff::DiffSettings,
) -> Result<Option<FileDiff>, EngineError> {
    if !settings.use_external_textconv {
        return Ok(None);
    }
    let reverse = matches!(mode, DiffMode::IndexToWorktree);
    let command_mode = if reverse {
        DiffMode::WorktreeToIndex
    } else {
        mode
    };
    let mut args = Vec::new();
    match command_mode {
        DiffMode::WorktreeToIndex => {}
        DiffMode::IndexToHead => {
            args.push("--cached".to_string());
        }
        DiffMode::WorktreeToHead => {
            args.push("HEAD".to_string());
        }
        DiffMode::IndexToWorktree => unreachable!("reverse mode is normalized above"),
    }
    textconv_git_diff_if_enabled(repo, path, settings, args, reverse, true)
}

/// Run textconv for two revision endpoints. The pathspec form preserves Git's
/// attributes resolution and supports ordinary and binary diff drivers.
fn textconv_revision_diff_if_enabled(
    repo: &gix::Repository,
    old_revision: &str,
    new_revision: &str,
    path: &str,
    settings: &crate::diff::DiffSettings,
) -> Result<Option<FileDiff>, EngineError> {
    if !settings.use_external_textconv {
        return Ok(None);
    }
    textconv_git_diff_if_enabled(
        repo,
        path,
        settings,
        vec![old_revision.to_string(), new_revision.to_string()],
        false,
        true,
    )
}

/// Run textconv for two arbitrary Git object endpoints. This is used for a
/// rename where the old and new revision paths differ.
fn textconv_object_diff_if_enabled(
    repo: &gix::Repository,
    old_endpoint: &str,
    new_endpoint: &str,
    output_path: &str,
    settings: &crate::diff::DiffSettings,
) -> Result<Option<FileDiff>, EngineError> {
    if !settings.use_external_textconv {
        return Ok(None);
    }
    textconv_git_diff_if_enabled(
        repo,
        output_path,
        settings,
        vec![old_endpoint.to_string(), new_endpoint.to_string()],
        false,
        false,
    )
}

/// Run textconv for a historical path against a differently named worktree
/// path. Git's normal revision↔worktree form only accepts one pathspec, so a
/// rename would otherwise lose the historical blob. A temporary index maps
/// the old blob onto the current path without touching the real index or
/// worktree; Git then owns attributes/textconv resolution as usual.
fn textconv_renamed_revision_worktree_diff_if_enabled(
    repo: &gix::Repository,
    revision: &str,
    revision_path: &str,
    worktree_path: &str,
    settings: &crate::diff::DiffSettings,
) -> Result<Option<FileDiff>, EngineError> {
    if !settings.use_external_textconv {
        return Ok(None);
    }
    let old_endpoint = format!("{}:{}", revision.trim(), revision_path);
    let old_id = match repo.rev_parse_single(BStr::new(old_endpoint.as_bytes())) {
        Ok(id) => id.detach(),
        Err(_) => return Ok(None),
    };
    let Some(workdir) = repo.workdir() else {
        return Ok(None);
    };
    let temporary = tempfile::tempdir().map_err(EngineError::from_gix)?;
    let index_path = temporary.path().join("index");
    let index_value = index_path.to_string_lossy().into_owned();

    let read_tree = GitCommandSpec::new(GitCommandCategory::Other, "read-tree")
        .args(["--empty"])
        .working_dir(workdir)
        .env("GIT_INDEX_FILE", index_value.clone())
        .timeout(std::time::Duration::from_secs(10));
    let outcome = crate::gitprocess::run_to_completion(&read_tree)?;
    if !outcome.success() {
        return Err(outcome.into_error(&read_tree));
    }

    let cache_info = format!("100644,{},{}", old_id, worktree_path);
    let update_index = GitCommandSpec::new(GitCommandCategory::Other, "update-index")
        .args(["--add".to_string(), "--cacheinfo".to_string(), cache_info])
        .working_dir(workdir)
        .env("GIT_INDEX_FILE", index_value.clone())
        .timeout(std::time::Duration::from_secs(10));
    let outcome = crate::gitprocess::run_to_completion(&update_index)?;
    if !outcome.success() {
        return Err(outcome.into_error(&update_index));
    }

    textconv_git_diff_if_enabled_with_env(
        repo,
        worktree_path,
        settings,
        Vec::new(),
        false,
        true,
        &[("GIT_INDEX_FILE".to_string(), index_value)],
    )
}

fn textconv_git_diff_if_enabled(
    repo: &gix::Repository,
    path: &str,
    settings: &crate::diff::DiffSettings,
    revision_args: Vec<String>,
    reverse: bool,
    append_pathspec: bool,
) -> Result<Option<FileDiff>, EngineError> {
    textconv_git_diff_if_enabled_with_env(
        repo,
        path,
        settings,
        revision_args,
        reverse,
        append_pathspec,
        &[],
    )
}

fn textconv_git_diff_if_enabled_with_env(
    repo: &gix::Repository,
    path: &str,
    settings: &crate::diff::DiffSettings,
    mut revision_args: Vec<String>,
    reverse: bool,
    append_pathspec: bool,
    extra_env: &[(String, String)],
) -> Result<Option<FileDiff>, EngineError> {
    let Some(workdir) = repo.workdir() else {
        return Ok(None);
    };
    let Some(attrs) = crate::attributes::check_attributes(workdir, &[path.to_string()])
        .ok()
        .and_then(|mut attrs| attrs.pop())
    else {
        return Ok(None);
    };
    if !matches!(attrs.diff, crate::attributes::AttributeValue::Value { .. }) {
        return Ok(None);
    }

    let mut args = vec![
        "--no-color".to_string(),
        "--no-ext-diff".to_string(),
        "--textconv".to_string(),
        "--unified=3".to_string(),
    ];
    if settings.ignore_all_space {
        args.push("--ignore-all-space".to_string());
    } else if settings.ignore_whitespace_at_eol {
        args.push("--ignore-space-at-eol".to_string());
    }
    args.append(&mut revision_args);
    if append_pathspec {
        args.push("--".to_string());
        args.push(path.to_string());
    }
    let mut spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Other,
        "diff",
    )
    .args(args)
    .working_dir(workdir)
    .timeout(std::time::Duration::from_secs(10));
    for (key, value) in extra_env {
        spec = spec.env(key, value.clone());
    }
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    let diff = crate::diff::parse_external_unified_diff(&outcome.stdout, path)?;
    Ok(Some(if reverse {
        crate::diff::reverse_file_diff(diff)
    } else {
        diff
    }))
}

/// DIFF-001：带设置的 diff；attributes 的 binary 属性优先于 NUL 嗅探。
fn diff_file_inner_settings(
    repo: &gix::Repository,
    path: &str,
    mode: DiffMode,
    settings: &crate::diff::DiffSettings,
) -> Result<FileDiff, EngineError> {
    if let Some(diff) = textconv_diff_if_enabled(repo, path, mode, settings)? {
        return Ok(diff);
    }
    let (old, new) = match mode {
        DiffMode::WorktreeToIndex => (
            index_bytes(repo, path)?,
            normalized_worktree_bytes(repo, path)?,
        ),
        DiffMode::IndexToWorktree => (
            normalized_worktree_bytes(repo, path)?,
            index_bytes(repo, path)?,
        ),
        DiffMode::IndexToHead => (
            head_bytes_for_worktree_path(repo, path)?,
            index_bytes(repo, path)?,
        ),
        DiffMode::WorktreeToHead => (
            head_bytes_for_worktree_path(repo, path)?,
            normalized_worktree_bytes(repo, path)?,
        ),
    };
    // attributes 优先:binary 属性 set 即二进制(即使内容无 NUL)
    let attr_binary = repo
        .workdir()
        .and_then(|wd| {
            crate::attributes::check_attributes(wd, &[path.to_string()])
                .ok()
                .and_then(|attrs| attrs.first().cloned())
        })
        .map(|attrs| attrs.binary == crate::attributes::AttributeValue::Set)
        .unwrap_or(false);
    if attr_binary || is_binary(&old) || is_binary(&new) {
        return Ok(FileDiff {
            path: path.to_string(),
            binary: true,
            hunks: Vec::new(),
        });
    }
    let hunks = crate::diff::compute_hunks_with_settings(&old, &new, settings);
    let mut diff = FileDiff {
        path: path.to_string(),
        binary: false,
        hunks,
    };
    let path = diff.path.clone();
    attach_highlights(&path, &old, &new, &mut diff);
    Ok(diff)
}

struct PatchPreviewWorkspace(PathBuf);

impl Drop for PatchPreviewWorkspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn mapped_patch_preview_path(
    raw_path: &str,
    base_directory: &str,
    path_strip: u32,
) -> Result<PathBuf, EngineError> {
    let components = raw_path
        .replace('\\', "/")
        .split('/')
        .filter(|component| !component.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let strip = usize::try_from(path_strip).map_err(|_| EngineError::GitOperation {
        message: "patch preview path strip is too large".into(),
    })?;
    if strip >= components.len() {
        return Err(EngineError::GitOperation {
            message: format!("patch preview path strip -p{path_strip} exceeds '{raw_path}'"),
        });
    }
    let stripped = components[strip..].join("/");
    let base = worktree_relative_path(base_directory)?;
    worktree_relative_path(&base.join(stripped).to_string_lossy())
}

fn create_patch_preview_workspace() -> Result<PatchPreviewWorkspace, EngineError> {
    use std::time::{SystemTime, UNIX_EPOCH};

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| EngineError::GitOperation {
            message: format!("patch preview clock failed: {error}"),
        })?
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "arbor-patch-preview-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir(&path).map_err(EngineError::from_gix)?;
    Ok(PatchPreviewWorkspace(path))
}

/// Build the same local-to-patched content diff that IntelliJ's
/// `AbstractFilePatchInProgress.getDiffRequestProducers` exposes for an
/// imported patch. The real worktree is never touched: only the selected
/// patch member is copied into a private directory, where Git applies that
/// member with the requested base and path strip before the two resulting
/// byte streams are diffed.
fn imported_patch_file_diff_inner(
    repo: &gix::Repository,
    patch: &str,
    path: &str,
    base_directory: &str,
    path_strip: u32,
    ignore_whitespace: bool,
) -> Result<FileDiff, EngineError> {
    use std::io::Write;
    use std::process::Stdio;

    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "imported patch preview requires a non-bare worktree".into(),
    })?;
    let change = crate::shelve::parse_patch_changes(patch)?
        .into_iter()
        .find(|change| change.path == path || change.endpoints.iter().any(|item| item == path))
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("imported patch preview has no member for '{path}'"),
        })?;
    let first_raw_path = change
        .raw_endpoints
        .first()
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("imported patch preview has no source path for '{path}'"),
        })?;
    let last_raw_path = change.raw_endpoints.last().unwrap_or(first_raw_path);
    let old_relative = mapped_patch_preview_path(first_raw_path, base_directory, path_strip)?;
    let new_relative = mapped_patch_preview_path(last_raw_path, base_directory, path_strip)?;
    let old_source = workdir.join(&old_relative);
    let old_exists = old_source.is_file();
    let old_bytes = if old_exists {
        std::fs::read(&old_source).map_err(EngineError::from_gix)?
    } else {
        Vec::new()
    };

    let workspace = create_patch_preview_workspace()?;
    let preview_old = workspace.0.join(&old_relative);
    if old_exists {
        if let Some(parent) = preview_old.parent() {
            std::fs::create_dir_all(parent).map_err(EngineError::from_gix)?;
        }
        std::fs::write(&preview_old, &old_bytes).map_err(EngineError::from_gix)?;
    }

    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args(["apply", "--binary", "--whitespace=nowarn"]);
    command.arg(format!("-p{path_strip}"));
    if !base_directory.is_empty() {
        command.arg(format!("--directory={base_directory}"));
    }
    let mut child = command
        .current_dir(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(EngineError::from_gix)?;
    child
        .stdin
        .take()
        .ok_or_else(|| EngineError::GitOperation {
            message: "imported patch preview could not open patch input".into(),
        })?
        .write_all(change.chunk.as_bytes())
        .map_err(EngineError::from_gix)?;
    let output = child.wait_with_output().map_err(EngineError::from_gix)?;
    if !output.status.success() {
        // `git apply` intentionally requires the hunk's advertised line
        // position for a plain patch. IntelliJ's GenericPatchApplier also
        // accepts a clean context match after local line movement, so use
        // the system patch utility in the isolated directory for that
        // preview-only fallback. Binary and mode patches remain on Git's
        // path and still fail cleanly when they cannot be previewed.
        let patch_root = if base_directory.is_empty() {
            workspace.0.clone()
        } else {
            let root = workspace.0.join(base_directory);
            std::fs::create_dir_all(&root).map_err(EngineError::from_gix)?;
            root
        };
        let mut fallback = std::process::Command::new("patch");
        fallback.args(["-t", "-N"]);
        fallback.arg(format!("-p{path_strip}"));
        let mut fallback_child = fallback
            .current_dir(&patch_root)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(EngineError::from_gix)?;
        fallback_child
            .stdin
            .take()
            .ok_or_else(|| EngineError::GitOperation {
                message: "imported patch preview could not open fallback patch input".into(),
            })?
            .write_all(change.chunk.as_bytes())
            .map_err(EngineError::from_gix)?;
        let fallback_output = fallback_child
            .wait_with_output()
            .map_err(EngineError::from_gix)?;
        if !fallback_output.status.success() {
            let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let fallback_detail = String::from_utf8_lossy(&fallback_output.stderr)
                .trim()
                .to_string();
            let detail = if fallback_detail.is_empty() {
                detail
            } else if detail.is_empty() {
                fallback_detail
            } else {
                format!("{detail}; fallback: {fallback_detail}")
            };
            return Err(EngineError::GitOperation {
                message: if detail.is_empty() {
                    format!("imported patch preview could not apply '{path}'")
                } else {
                    format!("imported patch preview could not apply '{path}': {detail}")
                },
            });
        }
    }

    let preview_new = workspace.0.join(&new_relative);
    let new_bytes = if preview_new.is_file() {
        std::fs::read(&preview_new).map_err(EngineError::from_gix)?
    } else {
        Vec::new()
    };
    let attr_binary = repo
        .workdir()
        .and_then(|wd| {
            crate::attributes::check_attributes(wd, &[path.to_string()])
                .ok()
                .and_then(|attrs| attrs.first().cloned())
        })
        .map(|attrs| attrs.binary == crate::attributes::AttributeValue::Set)
        .unwrap_or(false);
    if attr_binary || is_binary(&old_bytes) || is_binary(&new_bytes) {
        return Ok(FileDiff {
            path: path.to_string(),
            binary: true,
            hunks: Vec::new(),
        });
    }

    let mut diff = FileDiff {
        path: path.to_string(),
        binary: false,
        hunks: compute_hunks_with(&old_bytes, &new_bytes, ignore_whitespace),
    };
    let diff_path = diff.path.clone();
    attach_highlights(&diff_path, &old_bytes, &new_bytes, &mut diff);
    Ok(diff)
}

/// IDX-001：某个方向两侧内容是否不同（staging_diff 的快速跳过判断）。
fn path_bytes_differ(
    repo: &gix::Repository,
    path: &str,
    mode: DiffMode,
) -> Result<bool, EngineError> {
    let (a, b) = match mode {
        DiffMode::WorktreeToIndex => (
            index_bytes(repo, path)?,
            normalized_worktree_bytes(repo, path)?,
        ),
        DiffMode::IndexToWorktree => (
            normalized_worktree_bytes(repo, path)?,
            index_bytes(repo, path)?,
        ),
        DiffMode::IndexToHead => (
            head_bytes_for_worktree_path(repo, path)?,
            index_bytes(repo, path)?,
        ),
        DiffMode::WorktreeToHead => (
            head_bytes_for_worktree_path(repo, path)?,
            normalized_worktree_bytes(repo, path)?,
        ),
    };
    Ok(a != b)
}

fn normalized_worktree_bytes(repo: &gix::Repository, path: &str) -> Result<Vec<u8>, EngineError> {
    let bytes = worktree_bytes(repo, path);
    let Some(workdir) = repo.workdir() else {
        return Ok(bytes);
    };
    crate::attributes::normalize_worktree_for_diff(workdir, path, &bytes)
}

/// Resolve the HEAD-side path for a current worktree path. Git status exposes
/// rename/copy origins separately from the new path; without this lookup a
/// three-layer view of `old.txt -> new.txt` incorrectly renders HEAD as an
/// empty added-file side.
fn head_path_for_worktree_path(repo: &gix::Repository, path: &str) -> Result<String, EngineError> {
    let spec = format!("HEAD:{path}");
    if repo.rev_parse_single(BStr::new(spec.as_bytes())).is_ok() {
        return Ok(path.to_string());
    }
    let old_path = crate::status::compute_status(repo)?
        .into_iter()
        .find(|entry| entry.path == path)
        .and_then(|entry| entry.old_path);
    Ok(old_path.unwrap_or_else(|| path.to_string()))
}

fn head_bytes_for_worktree_path(
    repo: &gix::Repository,
    path: &str,
) -> Result<Vec<u8>, EngineError> {
    let spec = format!("HEAD:{path}");
    if let Ok(id) = repo.rev_parse_single(BStr::new(spec.as_bytes())) {
        return blob_bytes_or_empty(repo, id.detach());
    }
    let head_path = head_path_for_worktree_path(repo, path)?;
    head_bytes(repo, &head_path)
}

/// 提交标题（第一行）。
fn commit_title(repo: &gix::Repository, id: gix::hash::ObjectId) -> Result<String, EngineError> {
    Ok(repo
        .find_commit(id)
        .map_err(EngineError::from_gix)?
        .message()
        .map(|m| m.title.trim_end().to_str_lossy().into_owned())
        .unwrap_or_default())
}

/// 日志历史改写在对象级执行时要求目标位于当前分支 first-parent 线，且
/// 实际 rewrite 闭包看到的是干净工作区；外层 preserving process 会在此
/// 之前保存本地现场，并在成功或失败后恢复，而不是静默丢失本地修改。
fn ensure_history_change_operation_is_idle(repo: &gix::Repository) -> Result<(), EngineError> {
    if system_rebase_active(repo)
        || load_rebase_state(repo)?.is_some()
        || load_merge_state(repo)?.is_some()
        || ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
            .iter()
            .any(|name| repo.git_dir().join(name).exists())
    {
        return Err(EngineError::GitOperation {
            message:
                "history change operation is unavailable while another Git operation is in progress"
                    .into(),
        });
    }
    Ok(())
}

fn ensure_history_change_operation_is_safe(repo: &gix::Repository) -> Result<(), EngineError> {
    ensure_history_change_operation_is_idle(repo)?;
    let status = crate::status::compute_status(repo)?;
    if !status.is_empty() {
        return Err(EngineError::GitOperation {
            message: "history change operation requires a clean worktree".into(),
        });
    }
    Ok(())
}

/// IntelliJ's history-editing operations preserve the complete local scene
/// (index, tracked worktree, untracked files, and ignored files) around the
/// object-level rewrite. Keep the same transaction boundary here: save only
/// when needed, execute against a clean worktree, then restore with the saved
/// index. If restoration conflicts, stash_pop keeps the temporary stash and a
/// root-scoped apply marker so the SwiftUI conflict workbench can resume the
/// exact restore instead of leaving only an untracked stash.
fn with_preserved_local_changes<T, F>(
    repository: &Repository,
    operation_name: &str,
    operation: F,
) -> Result<T, EngineError>
where
    F: FnOnce(&gix::Repository) -> Result<T, EngineError>,
{
    let has_local_changes = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        ensure_history_change_operation_is_idle(&repo)?;
        if load_apply_local_changes(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "{operation_name}: saved local changes are waiting to be restored; resolve the previous restore first"
                ),
            });
        }
        ensure_nested_submodule_worktrees_clean(&repo)?;
        !crate::status::compute_status(&repo)?.is_empty()
    };

    if !has_local_changes {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        return operation(&repo);
    }

    let stash_id =
        repository.stash_save_with_options(Some(format!("Arbor: {operation_name}")), true, true)?;
    let stash_object_id =
        gix::hash::ObjectId::from_hex(stash_id.as_bytes()).map_err(EngineError::from_gix)?;
    if let Err(marker_error) =
        repository.persist_apply_local_changes_restore("history-rewrite", "stash", &stash_id)
    {
        let restore_error = stash_pop_with_id(repository, stash_object_id, true).err();
        return Err(match restore_error {
            Some(restore_error) => EngineError::GitOperation {
                message: format!(
                    "{operation_name}: could not record the local-change restore marker; restoring local changes also failed: {marker_error}; {restore_error}"
                ),
            },
            None => marker_error,
        });
    }
    let operation_result = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        operation(&repo)
    };
    let restore_result = stash_pop_with_id(repository, stash_object_id, true);

    match (operation_result, restore_result) {
        (Ok(value), Ok(())) => {
            repository.clear_apply_local_changes_restore();
            Ok(value)
        }
        (Err(operation_error), Ok(())) => {
            repository.clear_apply_local_changes_restore();
            Err(operation_error)
        }
        (Ok(_), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "{operation_name} completed, but local changes could not be restored; stash {stash_id} was kept: {restore_error}"
            ),
        }),
        (Err(operation_error), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "{operation_name} failed: {operation_error}; local changes could not be restored; stash {stash_id} was kept: {restore_error}"
            ),
        }),
    }
}

/// Selected history rewrites preserve the superproject scene, but they do not
/// have a nested-repository stash format. Refuse a dirty submodule before the
/// parent stash can reset or materialize its gitlink, preserving the user's
/// nested worktree instead of silently discarding it.
fn ensure_nested_submodule_worktrees_clean(repo: &gix::Repository) -> Result<(), EngineError> {
    let Some(workdir) = repo.workdir() else {
        return Ok(());
    };
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "submodule",
    )
    .args([
        "foreach",
        "--recursive",
        "--quiet",
        "git status --porcelain --untracked-files=all",
    ])
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "could not inspect nested submodule worktrees before history rewrite: {}",
                outcome.into_error(&spec)
            ),
        });
    }
    if !outcome.stdout.trim().is_empty() {
        let detail = outcome
            .stdout
            .lines()
            .take(8)
            .collect::<Vec<_>>()
            .join("; ");
        return Err(EngineError::GitOperation {
            message: format!("history rewrite requires clean nested submodule worktrees: {detail}"),
        });
    }
    Ok(())
}

fn rebase_local_stash_path(repo: &gix::Repository) -> PathBuf {
    repo.git_dir().join("arbor-rebase-local-stash")
}

#[derive(Clone, Debug)]
enum RebaseLocalChanges {
    Stash(gix::hash::ObjectId),
    Shelf(String),
}

fn load_rebase_local_changes(
    repo: &gix::Repository,
) -> Result<Option<RebaseLocalChanges>, EngineError> {
    let path = rebase_local_stash_path(repo);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(None);
    };
    let value = text.trim();
    if value.is_empty() {
        return Ok(None);
    }
    if let Some(name) = value.strip_prefix("shelf:") {
        let name = name.trim();
        if name.is_empty() {
            return Err(EngineError::GitOperation {
                message: "rebase: invalid saved local-changes shelf".into(),
            });
        }
        return Ok(Some(RebaseLocalChanges::Shelf(name.to_string())));
    }
    gix::hash::ObjectId::from_hex(value.as_bytes())
        .map(RebaseLocalChanges::Stash)
        .map(Some)
        .map_err(|_| EngineError::GitOperation {
            message: "rebase: invalid saved local-changes stash".into(),
        })
}

fn save_rebase_local_stash(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    std::fs::write(rebase_local_stash_path(repo), stash_id.to_hex().to_string())
        .map_err(EngineError::from_gix)
}

fn save_rebase_local_shelf(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    std::fs::write(rebase_local_stash_path(repo), format!("shelf:{name}"))
        .map_err(EngineError::from_gix)
}

fn clear_rebase_local_stash(repo: &gix::Repository) {
    let _ = std::fs::remove_file(rebase_local_stash_path(repo));
}

fn clear_rebase_local_stash_if_shelf(repo: &gix::Repository, name: &str) {
    if matches!(
        load_rebase_local_changes(repo),
        Ok(Some(RebaseLocalChanges::Shelf(saved))) if saved == name
    ) {
        clear_rebase_local_stash(repo);
    }
}

#[derive(Clone, Debug)]
struct ApplyLocalChanges {
    kind: String,
    saved: RebaseLocalChanges,
}

fn apply_local_changes_path(repo: &gix::Repository) -> PathBuf {
    repo.git_dir().join("arbor-apply-local-changes")
}

fn load_apply_local_changes(
    repo: &gix::Repository,
) -> Result<Option<ApplyLocalChanges>, EngineError> {
    let path = apply_local_changes_path(repo);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(None);
    };
    let mut lines = text.lines();
    let kind = lines.next().unwrap_or_default().trim();
    let artifact = lines.next().unwrap_or_default().trim();
    if !matches!(
        kind,
        "pull"
            | "merge"
            | "reset"
            | "cherry-pick"
            | "revert"
            | "history-rewrite"
            | "submodule-update"
    ) || artifact.is_empty()
    {
        return Err(EngineError::GitOperation {
            message: "apply: invalid saved local-changes marker".into(),
        });
    }
    let saved = if let Some(name) = artifact.strip_prefix("shelf:") {
        let name = name.trim();
        if name.is_empty() {
            return Err(EngineError::GitOperation {
                message: "apply: invalid saved local-changes Shelf".into(),
            });
        }
        RebaseLocalChanges::Shelf(name.to_string())
    } else {
        let stash_id = artifact.strip_prefix("stash:").unwrap_or(artifact);
        RebaseLocalChanges::Stash(
            gix::hash::ObjectId::from_hex(stash_id.trim().as_bytes()).map_err(|_| {
                EngineError::GitOperation {
                    message: "apply: invalid saved local-changes stash".into(),
                }
            })?,
        )
    };
    Ok(Some(ApplyLocalChanges {
        kind: kind.to_string(),
        saved,
    }))
}

fn save_apply_local_changes(
    repo: &gix::Repository,
    kind: &str,
    saved: &RebaseLocalChanges,
) -> Result<(), EngineError> {
    let artifact = match saved {
        RebaseLocalChanges::Stash(stash_id) => format!("stash:{}", stash_id.to_hex()),
        RebaseLocalChanges::Shelf(name) => format!("shelf:{name}"),
    };
    std::fs::write(
        apply_local_changes_path(repo),
        format!("{kind}\n{artifact}\n"),
    )
    .map_err(EngineError::from_gix)
}

fn clear_apply_local_changes(repo: &gix::Repository) {
    let _ = std::fs::remove_file(apply_local_changes_path(repo));
}

fn clear_apply_local_changes_if_shelf(repo: &gix::Repository, name: &str) {
    if matches!(
        load_apply_local_changes(repo),
        Ok(Some(ApplyLocalChanges {
            kind: _,
            saved: RebaseLocalChanges::Shelf(saved),
        })) if saved == name
    ) {
        clear_apply_local_changes(repo);
    }
}

fn prepare_apply_local_changes(
    repository: &Repository,
    kind: &str,
    save_policy: LocalChangesSavePolicy,
) -> Result<bool, EngineError> {
    let has_local_changes = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        ensure_history_change_operation_is_idle(&repo)?;
        if load_apply_local_changes(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "{kind}: saved local changes are waiting for a previous operation; continue or abort it first"
                ),
            });
        }
        !crate::status::compute_status(&repo)?.is_empty()
    };
    if !has_local_changes {
        return Ok(false);
    }

    let saved = match save_policy {
        LocalChangesSavePolicy::Stash => {
            let stash_id = repository.stash_save_with_options(
                Some(format!("Arbor: {kind} local changes")),
                true,
                true,
            )?;
            RebaseLocalChanges::Stash(
                gix::hash::ObjectId::from_hex(stash_id.as_bytes())
                    .map_err(EngineError::from_gix)?,
            )
        }
        LocalChangesSavePolicy::Shelve => {
            let (name, paths) = {
                let repo = repository.inner.lock().expect("repo mutex poisoned");
                let name =
                    unique_temporary_shelf_name(&repo, &format!("Arbor: {kind} local changes"))?;
                let paths = crate::status::compute_status(&repo)?
                    .into_iter()
                    .filter(|entry| {
                        entry.staged != crate::status::ChangeKind::Unchanged
                            || entry.unstaged != crate::status::ChangeKind::Unchanged
                    })
                    .map(|entry| entry.path)
                    .collect::<Vec<_>>();
                (name, paths)
            };
            repository.shelve_for_preservation(name.clone(), paths)?;
            RebaseLocalChanges::Shelf(name)
        }
    };

    let save_result = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        save_apply_local_changes(&repo, kind, &saved)
    };
    if let Err(save_error) = save_result {
        let restore_error = {
            let repo = repository.inner.lock().expect("repo mutex poisoned");
            match &saved {
                RebaseLocalChanges::Stash(stash_id) => {
                    stash_pop_with_id_locked(&repo, *stash_id, true).err()
                }
                RebaseLocalChanges::Shelf(name) => {
                    shelve_pop_preservation_locked(&repo, name).err()
                }
            }
        };
        return Err(match restore_error {
            Some(restore_error) => EngineError::GitOperation {
                message: format!(
                    "{kind}: could not record local changes; restoring them also failed: {save_error}; {restore_error}"
                ),
            },
            None => save_error,
        });
    }
    Ok(true)
}

fn restore_apply_local_changes_locked(
    repo: &gix::Repository,
    kind: &str,
) -> Result<(), EngineError> {
    let Some(saved) = load_apply_local_changes(repo)? else {
        return Ok(());
    };
    let compatible = saved.kind == kind
        // Pull shares the merge/rebase state machines. Keep the marker's
        // origin visible to recovery UI while allowing the operation's
        // native Continue/Abort entry points to finish its restoration.
        || (saved.kind == "pull" && matches!(kind, "merge" | "rebase"));
    if !compatible {
        return Err(EngineError::GitOperation {
            message: format!(
                "{kind}: saved local changes belong to {} operation",
                saved.kind
            ),
        });
    }
    match saved.saved {
        RebaseLocalChanges::Stash(stash_id) => stash_pop_with_id_locked(repo, stash_id, true)?,
        RebaseLocalChanges::Shelf(name) => shelve_pop_preservation_locked(repo, &name)?,
    }
    clear_apply_local_changes(repo);
    Ok(())
}

/// Restore the saved worktree after a preserving operation has left Git's
/// operation state. If restoration conflicts, keep the marker and let the
/// normal stash/shelf conflict workbench finish the lifecycle.
fn finish_apply_local_changes<T>(
    repository: &Repository,
    kind: &str,
    saved: bool,
    result: Result<T, EngineError>,
) -> Result<T, EngineError> {
    if !saved || repository.operation_state()?.is_some() {
        return result;
    }
    let restore_result = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        restore_apply_local_changes_locked(&repo, kind)
    };
    match (result, restore_result) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(operation_error), Ok(())) => Err(operation_error),
        (Ok(_), Err(restore_error)) => Err(restore_error),
        (Err(operation_error), Err(restore_error)) => match restore_error {
            EngineError::StashApplyConflict { paths, stash_id } => {
                Err(EngineError::StashApplyConflict { paths, stash_id })
            }
            EngineError::ShelveApplyConflict { name, paths } => {
                Err(EngineError::ShelveApplyConflict { name, paths })
            }
            other => Err(EngineError::GitOperation {
                message: format!(
                    "{kind} failed: {operation_error}; local changes could not be restored and the temporary preservation was kept: {other}"
                ),
            }),
        },
    }
}

fn restore_rebase_local_stash_locked(
    repo: &gix::Repository,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    let Some(saved) = load_rebase_local_changes(repo)? else {
        return Ok(());
    };
    match saved {
        RebaseLocalChanges::Stash(stash_id) => {
            stash_pop_with_id_locked(repo, stash_id, true)?;
        }
        RebaseLocalChanges::Shelf(name) => {
            shelve_pop_preservation_locked_with_cancel(repo, &name, cancel)?;
        }
    }
    clear_rebase_local_stash(repo);
    Ok(())
}

fn unique_temporary_shelf_name(repo: &gix::Repository, base: &str) -> Result<String, EngineError> {
    let shelves = crate::shelve::load_shelves(repo)?;
    let deleted = crate::shelve::load_deleted_shelves(repo)?;
    for suffix in 0..1000 {
        let candidate = if suffix == 0 {
            base.to_string()
        } else {
            format!("{base} ({suffix})")
        };
        let ref_name = crate::shelve::sanitize_ref_name(&candidate);
        if !shelves.iter().chain(deleted.iter()).any(|(name, _)| {
            *name == candidate || crate::shelve::sanitize_ref_name(name) == ref_name
        }) {
            return Ok(candidate);
        }
    }
    Err(EngineError::GitOperation {
        message: "rebase: could not allocate a temporary Shelf name".into(),
    })
}

fn unique_rebase_shelf_name(repo: &gix::Repository) -> Result<String, EngineError> {
    unique_temporary_shelf_name(repo, "Arbor: Rebase local changes")
}

fn prepare_rebase_local_changes(
    repository: &Repository,
    save_policy: LocalChangesSavePolicy,
) -> Result<bool, EngineError> {
    let has_local_changes = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        ensure_history_change_operation_is_idle(&repo)?;
        if load_rebase_local_changes(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "rebase: saved local changes are waiting for a previous rebase; continue or abort it first".into(),
            });
        }
        !crate::status::compute_status(&repo)?.is_empty()
    };
    if !has_local_changes {
        return Ok(false);
    }

    match save_policy {
        LocalChangesSavePolicy::Stash => {
            let stash_id = repository.stash_save_with_options(
                Some("Arbor: Rebase local changes".into()),
                true,
                true,
            )?;
            let stash_id = gix::hash::ObjectId::from_hex(stash_id.as_bytes())
                .map_err(EngineError::from_gix)?;
            let save_result = {
                let repo = repository.inner.lock().expect("repo mutex poisoned");
                save_rebase_local_stash(&repo, stash_id)
            };
            if let Err(save_error) = save_result {
                let restore_error = stash_pop_with_id(repository, stash_id, true).err();
                return Err(match restore_error {
                    Some(restore_error) => EngineError::GitOperation {
                        message: format!(
                            "rebase: could not record local changes stash: {save_error}; restoring it also failed: {restore_error}"
                        ),
                    },
                    None => save_error,
                });
            }
        }
        LocalChangesSavePolicy::Shelve => {
            let (name, paths) = {
                let repo = repository.inner.lock().expect("repo mutex poisoned");
                let name = unique_rebase_shelf_name(&repo)?;
                let paths = crate::status::compute_status(&repo)?
                    .into_iter()
                    .filter(|entry| {
                        entry.staged != crate::status::ChangeKind::Unchanged
                            || entry.unstaged != crate::status::ChangeKind::Unchanged
                    })
                    .map(|entry| entry.path)
                    .collect::<Vec<_>>();
                (name, paths)
            };
            repository.shelve_for_preservation(name.clone(), paths)?;
            let save_result = {
                let repo = repository.inner.lock().expect("repo mutex poisoned");
                save_rebase_local_shelf(&repo, &name)
            };
            if let Err(save_error) = save_result {
                let restore_error = {
                    let repo = repository.inner.lock().expect("repo mutex poisoned");
                    shelve_pop_preservation_locked(&repo, &name).err()
                };
                return Err(match restore_error {
                    Some(restore_error) => EngineError::GitOperation {
                        message: format!(
                            "rebase: could not record local changes Shelf: {save_error}; restoring it also failed: {restore_error}"
                        ),
                    },
                    None => save_error,
                });
            }
        }
    }
    Ok(true)
}

fn finish_rebase_local_changes_locked(
    repo: &gix::Repository,
    result: Result<RebaseOutcome, EngineError>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<RebaseOutcome, EngineError> {
    let active = system_rebase_active(repo) || load_rebase_state(repo)?.is_some();
    let should_restore =
        result.as_ref().is_ok_and(|outcome| !outcome.paused) || (result.is_err() && !active);
    if !should_restore {
        return result;
    }
    let restore_result = restore_rebase_local_stash_locked(repo, cancel)
        .and_then(|()| restore_apply_local_changes_locked(repo, "rebase"));
    match (result, restore_result) {
        (Ok(outcome), Ok(())) => Ok(outcome),
        (Err(operation_error), Ok(())) => Err(operation_error),
        (Ok(_), Err(EngineError::Cancelled)) => Err(EngineError::Cancelled),
        (Err(_), Err(EngineError::Cancelled)) => Err(EngineError::Cancelled),
        (Ok(_), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "rebase completed, but local changes could not be restored; the temporary preservation was kept: {restore_error}"
            ),
        }),
        (Err(operation_error), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "rebase failed: {operation_error}; local changes could not be restored and the temporary preservation was kept: {restore_error}"
            ),
        }),
    }
}

fn finish_rebase_abort_locked(
    repo: &gix::Repository,
    result: Result<(), EngineError>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    let active = system_rebase_active(repo) || load_rebase_state(repo)?.is_some();
    let should_restore = result.is_ok() || (result.is_err() && !active);
    if !should_restore {
        return result;
    }
    let restore_result = restore_rebase_local_stash_locked(repo, cancel)
        .and_then(|()| restore_apply_local_changes_locked(repo, "rebase"));
    match (result, restore_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(operation_error), Ok(())) => Err(operation_error),
        (Ok(()), Err(EngineError::Cancelled)) => Err(EngineError::Cancelled),
        (Err(_), Err(EngineError::Cancelled)) => Err(EngineError::Cancelled),
        (Ok(()), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "rebase aborted, but local changes could not be restored; the temporary preservation was kept: {restore_error}"
            ),
        }),
        (Err(operation_error), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "rebase abort failed: {operation_error}; local changes could not be restored and the temporary preservation was kept: {restore_error}"
            ),
        }),
    }
}

fn with_rebase_local_changes<F>(
    repository: &Repository,
    save_policy: LocalChangesSavePolicy,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    operation: F,
) -> Result<RebaseOutcome, EngineError>
where
    F: FnOnce() -> Result<RebaseOutcome, EngineError>,
{
    ensure_not_cancelled(cancel)?;
    let stashed = prepare_rebase_local_changes(repository, save_policy)?;
    if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
        if stashed {
            let repo = repository.inner.lock().expect("repo mutex poisoned");
            return match restore_rebase_local_stash_locked(&repo, None) {
                Ok(()) => Err(EngineError::Cancelled),
                Err(restore_error) => Err(EngineError::GitOperation {
                    message: format!(
                        "rebase was cancelled, but saved local changes could not be restored: {restore_error}"
                    ),
                }),
            };
        }
        return Err(EngineError::Cancelled);
    }
    let result = operation();
    if !stashed {
        return result;
    }
    let repo = repository.inner.lock().expect("repo mutex poisoned");
    let restore_cancel = if result.is_err() && !system_rebase_active(&repo) {
        None
    } else {
        cancel
    };
    finish_rebase_local_changes_locked(&repo, result, restore_cancel)
}

/// Generic counterpart used by the raw-todo preparation phase.  Capturing the
/// native todo returns text rather than a `RebaseOutcome`, but it still needs
/// the same stash/Shelf lifecycle and the same rule that a paused native
/// operation must retain its saved local changes.
fn with_rebase_local_changes_value<F, T>(
    repository: &Repository,
    save_policy: LocalChangesSavePolicy,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    operation: F,
) -> Result<T, EngineError>
where
    F: FnOnce() -> Result<T, EngineError>,
{
    ensure_not_cancelled(cancel)?;
    let stashed = prepare_rebase_local_changes(repository, save_policy)?;
    if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
        if stashed {
            let repo = repository.inner.lock().expect("repo mutex poisoned");
            return match restore_rebase_local_stash_locked(&repo, None) {
                Ok(()) => Err(EngineError::Cancelled),
                Err(restore_error) => Err(EngineError::GitOperation {
                    message: format!(
                        "rebase todo preparation was cancelled, but saved local changes could not be restored: {restore_error}"
                    ),
                }),
            };
        }
        return Err(EngineError::Cancelled);
    }
    let result = operation();
    if !stashed {
        return result;
    }
    let repo = repository.inner.lock().expect("repo mutex poisoned");
    if result.is_err() && system_rebase_active(&repo) {
        return result;
    }
    let restore_result = restore_rebase_local_stash_locked(&repo, None);
    match (result, restore_result) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(operation_error), Ok(())) => Err(operation_error),
        (Ok(_), Err(EngineError::Cancelled)) => Err(EngineError::Cancelled),
        (Err(_), Err(EngineError::Cancelled)) => Err(EngineError::Cancelled),
        (Ok(_), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "rebase todo preparation completed, but local changes could not be restored; the temporary preservation was kept: {restore_error}"
            ),
        }),
        (Err(operation_error), Err(restore_error)) => Err(EngineError::GitOperation {
            message: format!(
                "rebase todo preparation failed: {operation_error}; local changes could not be restored and the temporary preservation was kept: {restore_error}"
            ),
        }),
    }
}

/// 校验 UI 传入的选中路径，同时确认它们确实是目标提交的文件级变更。
/// Rename 由 UI 以新路径（或旧路径）表示，但树替换必须同时处理两端；
/// 因此返回展开后的路径集合。gitlink 也作为一个可选的 Git 路径保留，
/// 工作区物化由 merge 层按子模块边界单独处理。
fn validate_selected_history_paths(
    repo: &gix::Repository,
    parent_tree: gix::hash::ObjectId,
    target_tree: gix::hash::ObjectId,
    paths: &[String],
) -> Result<Vec<String>, EngineError> {
    use gix::object::tree::diff::ChangeDetached;

    if paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "select at least one changed file".into(),
        });
    }
    let mut normalized = HashSet::new();
    for path in paths {
        let relative = worktree_relative_path(path)?;
        if relative.as_os_str().is_empty()
            || path.starts_with('-')
            || path.starts_with('/')
            || path.ends_with('/')
            || path.split('/').any(|component| component.is_empty())
        {
            return Err(EngineError::GitOperation {
                message: format!("invalid selected change path: {path}"),
            });
        }
        if !normalized.insert(path.clone()) {
            return Err(EngineError::GitOperation {
                message: format!("selected change path appears more than once: {path}"),
            });
        }
    }

    let old_tree = repo.find_tree(parent_tree).map_err(EngineError::from_gix)?;
    let new_tree = repo.find_tree(target_tree).map_err(EngineError::from_gix)?;
    let changes = repo
        .diff_tree_to_tree(
            Some(&old_tree),
            Some(&new_tree),
            Some(gix::diff::Options::default().with_rewrites(Some(Default::default()))),
        )
        .map_err(EngineError::from_gix)?;
    let mut selected_changes = HashSet::new();
    let mut expanded_paths = HashSet::new();
    for path in paths {
        let Some((index, selected_paths)) =
            changes.iter().enumerate().find_map(|(index, change)| {
                let selected_paths = match change {
                    ChangeDetached::Addition { location, .. }
                    | ChangeDetached::Modification { location, .. }
                    | ChangeDetached::Deletion { location, .. }
                        if location.to_string() == path.as_str() =>
                    {
                        vec![path.clone()]
                    }
                    ChangeDetached::Rewrite {
                        source_location,
                        location,
                        ..
                    } if source_location.to_string() == path.as_str()
                        || location.to_string() == path.as_str() =>
                    {
                        vec![source_location.to_string(), location.to_string()]
                    }
                    _ => return None,
                };
                Some((index, selected_paths))
            })
        else {
            return Err(EngineError::GitOperation {
                message: format!("selected path is not changed by the target commit: {path}"),
            });
        };
        selected_changes.insert(index);
        expanded_paths.extend(selected_paths);
    }
    if selected_changes.len() >= changes.len() {
        return Err(EngineError::GitOperation {
            message: "select fewer than all changed files".into(),
        });
    }

    for path in &expanded_paths {
        let parent_entry = old_tree
            .lookup_entry(path.split('/'))
            .map_err(EngineError::from_gix)?;
        let target_entry = new_tree
            .lookup_entry(path.split('/'))
            .map_err(EngineError::from_gix)?;
        if parent_entry
            .as_ref()
            .is_some_and(|entry| entry.mode().is_tree())
            || target_entry
                .as_ref()
                .is_some_and(|entry| entry.mode().is_tree())
        {
            return Err(EngineError::GitOperation {
                message: format!("directory changes are not supported: {path}"),
            });
        }
    }
    let mut expanded_paths: Vec<_> = expanded_paths.into_iter().collect();
    expanded_paths.sort();
    Ok(expanded_paths)
}

/// 用 source tree 中的相同路径替换 base tree；source 缺失表示删除。
pub(crate) fn replace_tree_paths(
    repo: &gix::Repository,
    base_tree: gix::hash::ObjectId,
    source_tree: gix::hash::ObjectId,
    paths: &[String],
) -> Result<gix::hash::ObjectId, EngineError> {
    let source = repo.find_tree(source_tree).map_err(EngineError::from_gix)?;
    let mut editor = repo.edit_tree(base_tree).map_err(EngineError::from_gix)?;
    for path in paths {
        let source_entry = source
            .lookup_entry(path.split('/'))
            .map_err(EngineError::from_gix)?;
        match source_entry {
            Some(entry) => {
                editor
                    .upsert(path, entry.mode().kind(), entry.object_id())
                    .map_err(EngineError::from_gix)?;
            }
            None => {
                editor.remove(path).map_err(EngineError::from_gix)?;
            }
        }
    }
    editor
        .write()
        .map(|tree| tree.detach())
        .map_err(EngineError::from_gix)
}

fn shelve_info_for(
    repo: &gix::Repository,
    name: &str,
    id: gix::hash::ObjectId,
    is_deleted: bool,
) -> Result<ShelveInfo, EngineError> {
    let hex = id.to_hex().to_string();
    let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
    let fallback_timestamp = commit.time().map(|time| time.seconds).unwrap_or(0);
    let metadata = crate::shelve::load_shelf_metadata(repo)?
        .into_iter()
        .find(|item| item.name == name);
    let is_recycled = metadata.as_ref().map(|item| item.recycled).unwrap_or(false);
    let is_pending_delete = metadata
        .as_ref()
        .map(|item| item.to_delete)
        .unwrap_or(false);
    let imported_paths = crate::shelve::read_shelf_patch(repo, name, is_deleted)?
        .map(|bytes| crate::shelve::patch_paths_bytes(&bytes))
        .transpose()?;
    let parent_id = commit
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} has no parent"),
        })?
        .detach();
    let parent_tree = repo
        .find_commit(parent_id)
        .map_err(EngineError::from_gix)?
        .tree()
        .map_err(EngineError::from_gix)?;
    let patch_tree = commit.tree().map_err(EngineError::from_gix)?;
    // A rewrite/rename is one ShelvedChange in IntelliJ's tree, so expose its
    // destination once instead of rendering the old and new paths as two
    // unrelated children.
    let paths = match imported_paths {
        Some(paths) => paths,
        None => crate::tree::diff_trees(repo, parent_tree.id, patch_tree.id)?
            .into_iter()
            .map(|change| change.path)
            .collect(),
    };
    Ok(ShelveInfo {
        name: name.to_string(),
        short_id: hex.chars().take(7).collect(),
        id: hex,
        paths,
        description: metadata
            .as_ref()
            .map(|item| item.description.clone())
            .unwrap_or_else(|| name.to_string()),
        timestamp: metadata
            .map(|item| item.timestamp)
            .unwrap_or(fallback_timestamp),
        is_deleted,
        is_recycled,
        is_pending_delete,
    })
}

fn current_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// IntelliJ removes deleted shelf lists older than one week. Run the same
/// cleanup when the collection is read so a short-lived app has deterministic
/// behavior without needing a background scheduler.
fn purge_expired_deleted_shelves_locked(repo: &gix::Repository) -> Result<(), EngineError> {
    use crate::shelve::{
        load_deleted_shelves, load_shelf_metadata, save_deleted_shelves, save_shelf_metadata,
    };
    use gix::refs::transaction::{Change, PreviousValue, RefEdit, RefLog};

    const WEEK_SECONDS: i64 = 7 * 24 * 60 * 60;
    let mut deleted = load_deleted_shelves(repo)?;
    let mut metadata = load_shelf_metadata(repo)?;
    let cutoff = current_unix_seconds().saturating_sub(WEEK_SECONDS);
    let mut expired = Vec::new();
    for (name, id) in &deleted {
        let timestamp = metadata
            .iter()
            .find(|item| item.name == *name)
            .map(|item| item.timestamp)
            .or_else(|| {
                repo.find_commit(*id)
                    .ok()
                    .and_then(|commit| commit.time().ok().map(|time| time.seconds))
            })
            .unwrap_or(0);
        if timestamp < cutoff {
            expired.push((name.clone(), *id));
        }
    }
    if expired.is_empty() {
        return Ok(());
    }

    for (name, _) in &expired {
        repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::Any,
                log: RefLog::AndReference,
            },
            name: shelf_ref_name("shelved-deleted", name)?,
            deref: false,
        })
        .map_err(EngineError::from_gix)?;
        crate::shelve::remove_shelf_patch(repo, name, true)?;
    }
    deleted.retain(|(name, _)| !expired.iter().any(|(candidate, _)| candidate == name));
    metadata.retain(|item| !expired.iter().any(|(name, _)| name == &item.name));
    save_deleted_shelves(repo, &deleted)?;
    save_shelf_metadata(repo, &metadata)?;
    Ok(())
}

/// Remove recycled Shelf lists whose lifecycle timestamp is before the
/// supplied cutoff. IntelliJ exposes this as the explicit "clean already
/// unshelved" action; recycled entries are intentionally removed permanently
/// instead of being moved to Recently Deleted a second time.
fn clean_recycled_shelves_locked(
    repo: &gix::Repository,
    before_timestamp: i64,
) -> Result<Vec<String>, EngineError> {
    use crate::shelve::{load_shelf_metadata, load_shelves};

    let metadata = load_shelf_metadata(repo)?;
    let pending_restore_name = crate::shelve::restore_info(repo)?.map(|info| info.name);
    let names = load_shelves(repo)?
        .into_iter()
        .filter_map(|(name, _)| {
            let item = metadata.iter().find(|item| item.name == name)?;
            (item.recycled && item.timestamp < before_timestamp).then_some(name)
        })
        .filter(|name| pending_restore_name.as_deref() != Some(name.as_str()))
        .collect::<Vec<_>>();

    for name in &names {
        drop_shelve_locked(repo, name)?;
    }
    Ok(names)
}

fn shelf_ref_name(namespace: &str, name: &str) -> Result<gix::refs::FullName, EngineError> {
    format!(
        "refs/{namespace}/{}",
        crate::shelve::sanitize_ref_name(name)
    )
    .as_str()
    .try_into()
    .map_err(EngineError::from_gix)
}

fn drop_shelve_locked(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    use crate::shelve::{load_shelves, remove_shelf_metadata, sanitize_ref_name, save_shelves};
    use gix::refs::transaction::{Change, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;

    let shelves_file = crate::shelve::shelves_file(repo);
    let original_shelves_file = std::fs::read(&shelves_file).ok();
    let mut list = load_shelves(repo)?;
    let index = list
        .iter()
        .position(|(candidate, _)| candidate == name)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    let patch_id = list[index].1;
    list.remove(index);
    save_shelves(repo, &list)?;
    let full_name: gix::refs::FullName = format!("refs/shelved/{}", sanitize_ref_name(name))
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    if let Err(error) = repo.edit_reference(RefEdit {
        change: Change::Delete {
            expected: PreviousValue::Any,
            log: RefLog::AndReference,
        },
        name: full_name,
        deref: false,
    }) {
        match original_shelves_file {
            Some(bytes) => {
                let _ = std::fs::write(&shelves_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&shelves_file);
            }
        }
        return Err(EngineError::from_gix(error));
    }
    if let Err(error) = crate::shelve::remove_shelf_patch(repo, name, false) {
        match original_shelves_file {
            Some(bytes) => {
                let _ = std::fs::write(&shelves_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&shelves_file);
            }
        }
        let _ = repo.edit_reference(RefEdit {
            change: Change::Update {
                log: gix::refs::transaction::LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: true,
                    message: name.to_string().into(),
                },
                expected: PreviousValue::MustNotExist,
                new: Target::Object(patch_id),
            },
            name: shelf_ref_name("shelved", name)?,
            deref: false,
        });
        return Err(error);
    }
    remove_shelf_metadata(repo, name)?;
    Ok(())
}

/// Move a shelf to the persistent Recently Deleted collection.
fn archive_shelve_locked(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    use crate::shelve::{
        deleted_shelves_file, load_deleted_shelves, load_shelf_metadata, load_shelves,
        save_deleted_shelves, save_shelves, set_shelf_metadata_state, shelf_metadata_file,
        upsert_shelf_metadata,
    };
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;

    let shelves_file = crate::shelve::shelves_file(repo);
    let deleted_file = deleted_shelves_file(repo);
    let metadata_file = shelf_metadata_file(repo);
    let original_shelves_file = std::fs::read(&shelves_file).map_err(EngineError::from_gix)?;
    let original_deleted_file = std::fs::read(&deleted_file).ok();
    let original_metadata_file = std::fs::read(&metadata_file).ok();
    let mut shelves = load_shelves(repo)?;
    let mut deleted = load_deleted_shelves(repo)?;
    let original_metadata = load_shelf_metadata(repo)?
        .into_iter()
        .find(|item| item.name == name);
    let original_description = original_metadata
        .as_ref()
        .map(|item| item.description.clone())
        .unwrap_or_else(|| name.to_string());
    let was_recycled = original_metadata
        .as_ref()
        .map(|item| item.recycled)
        .unwrap_or(false);
    let index = shelves
        .iter()
        .position(|(candidate, _)| candidate == name)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    let patch_id = shelves[index].1;
    let ref_name = crate::shelve::sanitize_ref_name(name);
    if deleted
        .iter()
        .any(|(candidate, _)| crate::shelve::sanitize_ref_name(candidate) == ref_name)
    {
        return Err(EngineError::GitOperation {
            message: format!("shelve: deleted shelf ref already exists for {name}"),
        });
    }

    shelves.remove(index);
    deleted.insert(0, (name.to_string(), patch_id));
    let active_ref = shelf_ref_name("shelved", name)?;
    let deleted_ref = shelf_ref_name("shelved-deleted", name)?;
    repo.edit_reference(RefEdit {
        change: Change::Update {
            log: LogChange {
                mode: RefLog::AndReference,
                force_create_reflog: true,
                message: format!("{name}: moved to Recently Deleted").into(),
            },
            expected: PreviousValue::MustNotExist,
            new: Target::Object(patch_id),
        },
        name: deleted_ref.clone(),
        deref: false,
    })
    .map_err(EngineError::from_gix)?;
    if let Err(error) = repo.edit_reference(RefEdit {
        change: Change::Delete {
            expected: PreviousValue::MustExistAndMatch(Target::Object(patch_id)),
            log: RefLog::AndReference,
        },
        name: active_ref.clone(),
        deref: false,
    }) {
        let _ = repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::Any,
                log: RefLog::AndReference,
            },
            name: deleted_ref.clone(),
            deref: false,
        });
        return Err(EngineError::GitOperation {
            message: format!("shelve: could not archive active ref: {error}"),
        });
    }
    let raw_patch_moved = match crate::shelve::move_shelf_patch(repo, name, false, true) {
        Ok(moved) => moved,
        Err(error) => {
            let _ = repo.edit_reference(RefEdit {
                change: Change::Update {
                    log: LogChange {
                        mode: RefLog::AndReference,
                        force_create_reflog: true,
                        message: name.to_string().into(),
                    },
                    expected: PreviousValue::MustNotExist,
                    new: Target::Object(patch_id),
                },
                name: active_ref.clone(),
                deref: false,
            });
            let _ = repo.edit_reference(RefEdit {
                change: Change::Delete {
                    expected: PreviousValue::Any,
                    log: RefLog::AndReference,
                },
                name: deleted_ref.clone(),
                deref: false,
            });
            return Err(error);
        }
    };
    if let Err(error) = save_shelves(repo, &shelves)
        .and_then(|_| save_deleted_shelves(repo, &deleted))
        .and_then(|_| {
            upsert_shelf_metadata(
                repo,
                name,
                patch_id,
                current_unix_seconds(),
                &original_description,
            )
        })
        .and_then(|_| set_shelf_metadata_state(repo, name, was_recycled, false, true))
    {
        let _ = std::fs::write(&shelves_file, original_shelves_file);
        match original_deleted_file {
            Some(bytes) => {
                let _ = std::fs::write(&deleted_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&deleted_file);
            }
        }
        match original_metadata_file {
            Some(bytes) => {
                let _ = std::fs::write(&metadata_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&metadata_file);
            }
        }
        if raw_patch_moved {
            let _ = crate::shelve::move_shelf_patch(repo, name, true, false);
        }
        let _ = repo.edit_reference(RefEdit {
            change: Change::Update {
                log: LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: true,
                    message: name.to_string().into(),
                },
                expected: PreviousValue::MustNotExist,
                new: Target::Object(patch_id),
            },
            name: active_ref,
            deref: false,
        });
        let _ = repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::Any,
                log: RefLog::AndReference,
            },
            name: deleted_ref,
            deref: false,
        });
        return Err(error);
    }
    Ok(())
}

fn create_shelve_copy_from_patch_locked(
    repo: &gix::Repository,
    source_name: &str,
    patch_id: gix::hash::ObjectId,
    patch: &str,
    description: &str,
    is_deleted: bool,
    is_recycled: bool,
) -> Result<String, EngineError> {
    use crate::shelve::{
        deleted_shelves_file, load_deleted_shelves, load_shelves, save_deleted_shelves,
        save_shelves, set_shelf_metadata_state, shelf_metadata_file, shelves_file,
        upsert_shelf_metadata,
    };
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;

    let active = load_shelves(repo)?;
    let mut deleted = load_deleted_shelves(repo)?;
    let base_name = format!(
        "{source_name} ({})",
        if is_deleted { "deleted" } else { "recycled" }
    );
    let mut deleted_name = base_name.clone();
    let mut suffix = 2;
    while active.iter().chain(deleted.iter()).any(|(candidate, _)| {
        *candidate == deleted_name
            || crate::shelve::sanitize_ref_name(candidate)
                == crate::shelve::sanitize_ref_name(&deleted_name)
    }) {
        deleted_name = format!("{base_name} {suffix}");
        suffix += 1;
    }

    let target_file = if is_deleted {
        deleted_shelves_file(repo)
    } else {
        shelves_file(repo)
    };
    let original_target_file = std::fs::read(&target_file).ok();
    let metadata_file = shelf_metadata_file(repo);
    let original_metadata_file = std::fs::read(&metadata_file).ok();
    let target_ref = shelf_ref_name(
        if is_deleted {
            "shelved-deleted"
        } else {
            "shelved"
        },
        &deleted_name,
    )?;

    crate::shelve::write_shelf_patch(repo, &deleted_name, is_deleted, patch.as_bytes(), false)?;
    if let Err(error) = repo.edit_reference(RefEdit {
        change: Change::Update {
            log: LogChange {
                mode: RefLog::AndReference,
                force_create_reflog: true,
                message: format!("{source_name}: selected members deleted").into(),
            },
            expected: PreviousValue::MustNotExist,
            new: Target::Object(patch_id),
        },
        name: target_ref.clone(),
        deref: false,
    }) {
        let _ = crate::shelve::remove_shelf_patch(repo, &deleted_name, is_deleted);
        return Err(EngineError::from_gix(error));
    }

    if is_deleted {
        deleted.insert(0, (deleted_name.clone(), patch_id));
    }
    let mut active = active;
    if !is_deleted {
        active.insert(0, (deleted_name.clone(), patch_id));
    }
    let timestamp = current_unix_seconds();
    let save_target = if is_deleted {
        save_deleted_shelves(repo, &deleted)
    } else {
        save_shelves(repo, &active)
    };
    if let Err(error) = save_target
        .and_then(|_| upsert_shelf_metadata(repo, &deleted_name, patch_id, timestamp, description))
        .and_then(|_| set_shelf_metadata_state(repo, &deleted_name, is_recycled, false, is_deleted))
    {
        match original_target_file {
            Some(bytes) => {
                let _ = std::fs::write(&target_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&target_file);
            }
        }
        match original_metadata_file {
            Some(bytes) => {
                let _ = std::fs::write(&metadata_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&metadata_file);
            }
        }
        let _ = repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::Any,
                log: RefLog::AndReference,
            },
            name: target_ref,
            deref: false,
        });
        let _ = crate::shelve::remove_shelf_patch(repo, &deleted_name, is_deleted);
        return Err(error);
    }
    Ok(deleted_name)
}

fn create_deleted_shelve_from_patch_locked(
    repo: &gix::Repository,
    source_name: &str,
    patch_id: gix::hash::ObjectId,
    patch: &str,
    description: &str,
) -> Result<String, EngineError> {
    create_shelve_copy_from_patch_locked(
        repo,
        source_name,
        patch_id,
        patch,
        description,
        true,
        false,
    )
}

fn create_recycled_shelve_from_patch_locked(
    repo: &gix::Repository,
    source_name: &str,
    patch_id: gix::hash::ObjectId,
    patch: &str,
    description: &str,
) -> Result<String, EngineError> {
    create_shelve_copy_from_patch_locked(
        repo,
        source_name,
        patch_id,
        patch,
        description,
        false,
        true,
    )
}

fn ensure_shelve_not_pending_restore(
    repo: &gix::Repository,
    name: &str,
) -> Result<(), EngineError> {
    if crate::shelve::restore_info(repo)?.is_some_and(|pending| pending.name == name) {
        return Err(EngineError::GitOperation {
            message:
                "shelve: restore is paused; complete or roll it back before changing the shelf"
                    .into(),
        });
    }
    Ok(())
}

fn delete_deleted_shelve_locked(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    use crate::shelve::{load_deleted_shelves, remove_shelf_metadata, save_deleted_shelves};
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;

    let deleted_file = crate::shelve::deleted_shelves_file(repo);
    let original_deleted_file = std::fs::read(&deleted_file).map_err(EngineError::from_gix)?;
    let mut deleted = load_deleted_shelves(repo)?;
    let index = deleted
        .iter()
        .position(|(candidate, _)| *candidate == name)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: deleted shelf {name} not found"),
        })?;
    let patch_id = deleted[index].1;
    let deleted_ref = shelf_ref_name("shelved-deleted", name)?;
    repo.edit_reference(RefEdit {
        change: Change::Delete {
            expected: PreviousValue::Any,
            log: RefLog::AndReference,
        },
        name: deleted_ref.clone(),
        deref: false,
    })
    .map_err(EngineError::from_gix)?;
    deleted.remove(index);
    if let Err(error) = save_deleted_shelves(repo, &deleted) {
        let _ = std::fs::write(&deleted_file, original_deleted_file);
        let _ = repo.edit_reference(RefEdit {
            change: Change::Update {
                log: LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: true,
                    message: name.to_string().into(),
                },
                expected: PreviousValue::MustNotExist,
                new: Target::Object(patch_id),
            },
            name: deleted_ref,
            deref: false,
        });
        return Err(error);
    }
    if let Err(error) = crate::shelve::remove_shelf_patch(repo, name, true) {
        let _ = std::fs::write(&deleted_file, original_deleted_file);
        let _ = repo.edit_reference(RefEdit {
            change: Change::Update {
                log: LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: true,
                    message: name.to_string().into(),
                },
                expected: PreviousValue::MustNotExist,
                new: Target::Object(patch_id),
            },
            name: deleted_ref,
            deref: false,
        });
        return Err(error);
    }
    remove_shelf_metadata(repo, name)?;
    Ok(())
}

/// Permanently remove selected members from a Recently Deleted shelf while
/// keeping all unselected patch chunks recoverable. This mirrors IntelliJ's
/// shelf delete provider when the selected tree node is a deleted file rather
/// than the whole ShelvedChangeList.
fn delete_deleted_shelve_paths_locked(
    repo: &gix::Repository,
    name: &str,
    paths: &[String],
) -> Result<(), EngineError> {
    use crate::shelve::{load_deleted_shelves, read_shelf_patch, write_shelf_patch};

    if paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: select at least one deleted shelf member".into(),
        });
    }
    ensure_shelve_not_pending_restore(repo, name)?;
    let deleted = load_deleted_shelves(repo)?;
    if !deleted.iter().any(|(candidate, _)| candidate == name) {
        return Err(EngineError::GitOperation {
            message: format!("shelve: deleted shelf {name} not found"),
        });
    }

    let raw_patch = read_shelf_patch(repo, name, true)?;
    let generated_patch;
    let patch = match raw_patch.as_deref() {
        Some(bytes) => bytes,
        None => {
            generated_patch = shelve_diff_locked_from_collection(repo, name, true)?.into_bytes();
            &generated_patch
        }
    };
    let Some(remaining_patch) = crate::shelve::remove_patch_chunks_bytes(patch, paths)? else {
        return delete_deleted_shelve_locked(repo, name);
    };

    // Legacy revision-backed shelves have no raw patch file. Materializing
    // the filtered patch is intentional: after a member-level permanent
    // delete, the remaining deleted list must retain its exact path set.
    write_shelf_patch(repo, name, true, &remaining_patch, raw_patch.is_some())
}

fn mark_shelve_recycled_locked(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    use crate::shelve::{
        load_shelf_metadata, load_shelves, set_shelf_metadata_state, upsert_shelf_metadata,
    };

    let patch_id = load_shelves(repo)?
        .iter()
        .find(|(candidate, _)| candidate == name)
        .map(|(_, id)| *id)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    let description = load_shelf_metadata(repo)?
        .into_iter()
        .find(|item| item.name == name)
        .map(|item| item.description)
        .unwrap_or_else(|| name.to_string());
    upsert_shelf_metadata(repo, name, patch_id, current_unix_seconds(), &description)?;
    set_shelf_metadata_state(repo, name, true, false, false)
}

fn mark_shelve_pending_delete_locked(
    repo: &gix::Repository,
    name: &str,
) -> Result<(), EngineError> {
    use crate::shelve::{load_shelf_metadata, load_shelves, set_shelf_metadata_state};

    load_shelves(repo)?
        .iter()
        .find(|(candidate, _)| candidate == name)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    let recycled = load_shelf_metadata(repo)?
        .into_iter()
        .find(|item| item.name == name)
        .map(|item| item.recycled)
        .unwrap_or(false);
    set_shelf_metadata_state(repo, name, recycled, true, false)
}

fn finalize_pending_shelve_deletes_locked(repo: &gix::Repository) -> Result<(), EngineError> {
    let pending = crate::shelve::load_shelf_metadata(repo)?
        .into_iter()
        .filter(|item| item.to_delete && !item.deleted)
        .map(|item| item.name)
        .collect::<Vec<_>>();
    for name in pending {
        if crate::shelve::load_shelves(repo)?
            .iter()
            .any(|(candidate, _)| candidate == &name)
        {
            archive_shelve_locked(repo, &name)?;
        }
    }
    Ok(())
}

/// Finalize a successful Unshelve after the worktree has been updated. IntelliJ
/// keeps the un-applied remainder in the original list and stores the applied
/// selection as a separate recycled list; applying the whole list only marks
/// that list recycled.
fn finalize_unshelve_selection_locked(
    repo: &gix::Repository,
    name: &str,
    paths: &[String],
    remove_applied: bool,
) -> Result<(), EngineError> {
    let active = crate::shelve::load_shelves(repo)?;
    let deleted = crate::shelve::load_deleted_shelves(repo)?;
    let (patch_id, is_deleted) =
        if let Some((_, id)) = active.iter().find(|(candidate, _)| candidate == name) {
            (*id, false)
        } else if let Some((_, id)) = deleted.iter().find(|(candidate, _)| candidate == name) {
            (*id, true)
        } else {
            return Err(EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            });
        };
    let source_patch = shelve_diff_locked_from_collection(repo, name, is_deleted)?;
    let selected_patch = crate::shelve::select_patch_chunks(&source_patch, paths)?;
    let remaining_patch = crate::shelve::remove_patch_chunks(&source_patch, paths)?;
    finalize_unshelve_patch_locked(
        repo,
        name,
        patch_id,
        is_deleted,
        selected_patch,
        remaining_patch,
        remove_applied,
    )
}

/// Consume successfully applied members from an imported Shelf Pop while
/// leaving ordinary failed members in the active Shelf remainder. Pop is a
/// permanent consume operation, so it must not create a recycled or deleted
/// copy for the successful subset.
fn consume_shelve_selection_locked(
    repo: &gix::Repository,
    name: &str,
    paths: &[String],
) -> Result<(), EngineError> {
    let source_patch = shelve_diff_locked(repo, name)?;
    let Some(remaining_patch) = crate::shelve::remove_patch_chunks(&source_patch, paths)? else {
        return drop_shelve_locked(repo, name);
    };
    let source_original = crate::shelve::read_shelf_patch(repo, name, false)?;
    crate::shelve::write_shelf_patch(
        repo,
        name,
        false,
        remaining_patch.as_bytes(),
        source_original.is_some(),
    )
}

fn finalize_unshelve_patch_locked(
    repo: &gix::Repository,
    name: &str,
    patch_id: gix::hash::ObjectId,
    is_deleted: bool,
    selected_patch: String,
    remaining_patch: Option<String>,
    remove_applied: bool,
) -> Result<(), EngineError> {
    use crate::shelve::{load_shelf_metadata, remove_shelf_patch, write_shelf_patch};

    let Some(remaining_patch) = remaining_patch else {
        if is_deleted {
            return if remove_applied {
                delete_deleted_shelve_locked(repo, name)
            } else {
                Ok(())
            };
        }
        if remove_applied {
            return archive_shelve_locked(repo, name);
        }
        return mark_shelve_recycled_locked(repo, name);
    };

    let description = load_shelf_metadata(repo)?
        .into_iter()
        .find(|item| item.name == name)
        .map(|item| item.description)
        .unwrap_or_else(|| name.to_string());

    // IntelliJ leaves a deleted changelist in Recently Deleted when the
    // action is configured to keep applied files. When applied files are
    // removed, only the unapplied remainder stays in that same deleted list;
    // no recycled copy is created.
    if is_deleted {
        if !remove_applied {
            return Ok(());
        }
        let source_original = crate::shelve::read_shelf_patch(repo, name, true)?;
        write_shelf_patch(
            repo,
            name,
            true,
            remaining_patch.as_bytes(),
            source_original.is_some(),
        )?;
        crate::shelve::upsert_shelf_metadata(
            repo,
            name,
            patch_id,
            current_unix_seconds(),
            &description,
        )?;
        return Ok(());
    }

    let source_original = crate::shelve::read_shelf_patch(repo, name, false)?;
    write_shelf_patch(
        repo,
        name,
        false,
        remaining_patch.as_bytes(),
        source_original.is_some(),
    )?;
    let create_copy = if remove_applied {
        create_deleted_shelve_from_patch_locked(repo, name, patch_id, &selected_patch, &description)
    } else {
        create_recycled_shelve_from_patch_locked(
            repo,
            name,
            patch_id,
            &selected_patch,
            &description,
        )
    };
    if let Err(error) = create_copy {
        match source_original {
            Some(bytes) => {
                let _ = write_shelf_patch(repo, name, false, &bytes, true);
            }
            None => {
                let _ = remove_shelf_patch(repo, name, false);
            }
        }
        return Err(error);
    }
    Ok(())
}

/// Convert the engine's mapped target paths back to source-patch members
/// before Shelf remainder/recycled bookkeeping. Revision-backed Shelves have
/// no path mapping and can return their applied paths unchanged.
fn source_shelve_paths_for_apply_locked(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
    requested_paths: Option<&[String]>,
    applied_paths: &[String],
    base_path: Option<&str>,
    path_strip: u32,
) -> Result<Vec<String>, EngineError> {
    if crate::shelve::read_shelf_patch(repo, name, is_deleted)?.is_none() {
        return Ok(applied_paths.to_vec());
    }
    let source_patch = shelve_diff_locked_from_collection(repo, name, is_deleted)?;
    crate::shelve::source_paths_for_applied_target_paths(
        &source_patch,
        requested_paths,
        applied_paths,
        base_path,
        path_strip,
    )
}

fn source_shelve_member_statuses_for_apply_locked(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
    requested_paths: Option<&[String]>,
    member_statuses: &[PatchApplyMemberResult],
    base_path: Option<&str>,
    path_strip: u32,
) -> Result<Vec<PatchApplyMemberResult>, EngineError> {
    let mut mapped = std::collections::BTreeMap::new();
    for member in member_statuses {
        let target_paths = [member.path.clone()];
        let source_paths = source_shelve_paths_for_apply_locked(
            repo,
            name,
            is_deleted,
            requested_paths,
            &target_paths,
            base_path,
            path_strip,
        )?;
        for path in source_paths {
            let status = match mapped.get(&path).copied() {
                Some(existing) => merge_patch_apply_status(existing, member.status),
                None => member.status,
            };
            mapped.insert(path, status);
        }
    }
    Ok(mapped
        .into_iter()
        .map(|(path, status)| PatchApplyMemberResult { path, status })
        .collect())
}

fn merge_patch_apply_status(lhs: PatchApplyStatus, rhs: PatchApplyStatus) -> PatchApplyStatus {
    use PatchApplyStatus::{AlreadyApplied, Partial, Success};

    if matches!(
        (lhs, rhs),
        (Success, AlreadyApplied) | (AlreadyApplied, Success)
    ) {
        return Partial;
    }
    let rank = |status: PatchApplyStatus| match status {
        PatchApplyStatus::Skip => 0,
        PatchApplyStatus::Success => 1,
        PatchApplyStatus::AlreadyApplied => 2,
        PatchApplyStatus::Partial => 3,
        PatchApplyStatus::Failure => 4,
        PatchApplyStatus::Abort => 5,
    };
    if rank(rhs) > rank(lhs) {
        rhs
    } else {
        lhs
    }
}

fn source_shelve_patch_apply_result_locked(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
    requested_paths: Option<&[String]>,
    result: PatchApplyResult,
    base_path: Option<&str>,
    path_strip: u32,
) -> Result<PatchApplyResult, EngineError> {
    let applied_paths = source_shelve_paths_for_apply_locked(
        repo,
        name,
        is_deleted,
        requested_paths,
        &result.applied_paths,
        base_path,
        path_strip,
    )?;
    let failed_paths = source_shelve_paths_for_apply_locked(
        repo,
        name,
        is_deleted,
        requested_paths,
        &result.failed_paths,
        base_path,
        path_strip,
    )?;
    let member_statuses = source_shelve_member_statuses_for_apply_locked(
        repo,
        name,
        is_deleted,
        requested_paths,
        &result.member_statuses,
        base_path,
        path_strip,
    )?;
    Ok(PatchApplyResult {
        applied_paths,
        failed_paths,
        overall_status: result.overall_status,
        member_statuses,
    })
}

/// Apply a revision-backed Shelf through the same per-file patch executor used
/// by IntelliJ's PatchApplier. The existing tree merge remains available for
/// legacy/internal flows; user-facing Unshelve uses this path so a clean file
/// is retained when a different file fails.
fn apply_differentiated_shelf_selection_locked(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
    paths: &[String],
    is_pop: bool,
    remove_applied: bool,
) -> Result<PatchApplyResult, EngineError> {
    let source_patch = shelve_diff_locked_from_collection(repo, name, is_deleted)?;
    let result = crate::shelve::apply_raw_shelve_differentiated(
        repo,
        &source_patch,
        name,
        paths,
        None,
        Some(1),
        is_pop,
        remove_applied,
        false,
        None,
    )?;
    let result = source_shelve_patch_apply_result_locked(
        repo,
        name,
        is_deleted,
        Some(paths),
        result,
        None,
        1,
    )?;
    let applied_paths = result.applied_paths.clone();
    if is_pop {
        if !applied_paths.is_empty() {
            consume_shelve_selection_locked(repo, name, &applied_paths)?;
        }
    } else if !applied_paths.is_empty() {
        finalize_unshelve_selection_locked(repo, name, &applied_paths, remove_applied)?;
    }
    Ok(result)
}

fn full_commit_message(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
) -> Result<String, EngineError> {
    let message = repo
        .find_commit(id)
        .map_err(EngineError::from_gix)?
        .message_raw()
        .map_err(EngineError::from_gix)?
        .to_str_lossy()
        .into_owned();
    Ok(if message.ends_with('\n') {
        message
    } else {
        format!("{message}\n")
    })
}

/// 创建历史重写提交时保留原提交的 author；committer 使用当前仓库身份，
/// 与 IntelliJ 的 commitTreeWithOverrides 语义一致。
fn new_commit_preserving_author(
    repo: &gix::Repository,
    source_id: gix::hash::ObjectId,
    message: &str,
    tree: gix::hash::ObjectId,
    parents: impl IntoIterator<Item = gix::hash::ObjectId>,
) -> Result<gix::hash::ObjectId, EngineError> {
    let source = repo.find_commit(source_id).map_err(EngineError::from_gix)?;
    let author = source.author().map_err(EngineError::from_gix)?;
    let committer = repo
        .committer()
        .ok_or_else(|| EngineError::GitOperation {
            message: "history rewrite requires a configured committer identity".into(),
        })?
        .map_err(EngineError::from_gix)?;
    repo.new_commit_as(committer, author, message, tree, parents)
        .map(|commit| commit.id)
        .map_err(EngineError::from_gix)
}

/// 判断提交是否能沿任意 parent 路径追溯到 selected target。
fn selected_history_reaches_target(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
    target: gix::hash::ObjectId,
    memo: &mut HashMap<gix::hash::ObjectId, bool>,
) -> Result<bool, EngineError> {
    if id == target {
        return Ok(true);
    }
    if let Some(reaches) = memo.get(&id) {
        return Ok(*reaches);
    }
    let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
    let parents: Vec<_> = commit.parent_ids().map(|parent| parent.detach()).collect();
    let reaches = parents.into_iter().try_fold(false, |reaches, parent| {
        if reaches {
            return Ok(true);
        }
        selected_history_reaches_target(repo, parent, target, memo)
    })?;
    memo.insert(id, reaches);
    Ok(reaches)
}

/// 返回 selected target 到当前 HEAD 的后继 DAG（旧 -> 新）。selected
/// target 仍必须位于当前分支的 first-parent 线上；target 之后的 merge
/// descendant 会保留原始 parent 拓扑，具体 tree 由其 first-parent patch
/// 应用到重写后的 first parent 上得到。
fn selected_history_graph_order(
    repo: &gix::Repository,
    target: gix::hash::ObjectId,
    head: gix::hash::ObjectId,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    let mut cursor = head;
    loop {
        if cursor == target {
            break;
        }
        let commit = repo.find_commit(cursor).map_err(EngineError::from_gix)?;
        let Some(parent) = commit.parent_ids().next().map(|id| id.detach()) else {
            return Err(EngineError::GitOperation {
                message: "selected commit is not on the current branch first-parent history".into(),
            });
        };
        cursor = parent;
    }

    let mut memo = HashMap::new();
    let mut range = HashSet::new();
    if !selected_history_reaches_target(repo, head, target, &mut memo)? {
        return Err(EngineError::GitOperation {
            message: "selected commit is not on the current branch first-parent history".into(),
        });
    }
    let mut visited = HashSet::new();
    let mut order = Vec::new();
    fn collect_range(
        repo: &gix::Repository,
        id: gix::hash::ObjectId,
        target: gix::hash::ObjectId,
        memo: &mut HashMap<gix::hash::ObjectId, bool>,
        range: &mut HashSet<gix::hash::ObjectId>,
    ) -> Result<(), EngineError> {
        if id == target {
            range.insert(id);
            return Ok(());
        }
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|parent| parent.detach()).collect();
        for parent in parents {
            if selected_history_reaches_target(repo, parent, target, memo)? {
                collect_range(repo, parent, target, memo, range)?;
            }
        }
        range.insert(id);
        Ok(())
    }
    collect_range(repo, head, target, &mut memo, &mut range)?;
    visit_rebase_graph(repo, head, &range, &mut visited, &mut order)?;
    Ok(order)
}

/// 创建重写后的目标提交/后续提交，并在全部对象计算成功后一次更新 HEAD。
/// `second_tree/message` 只用于 Extract；Drop 只传入替换后的第一提交树。
fn rewrite_selected_commit_history(
    repo: &gix::Repository,
    target: gix::hash::ObjectId,
    first_tree: gix::hash::ObjectId,
    second_tree: Option<gix::hash::ObjectId>,
    second_message: Option<&str>,
) -> Result<RebaseOutcome, EngineError> {
    let original_head = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let original_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let history = selected_history_graph_order(repo, target, original_head)?;
    let mut replayed_commits = HashMap::new();
    let mut replayed_trees = HashMap::new();

    for id in history {
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let original_message = full_commit_message(repo, id)?;
        let original_parents: Vec<_> = commit.parent_ids().map(|parent| parent.detach()).collect();
        let mapped_parents: Vec<_> = original_parents
            .iter()
            .map(|parent| replayed_commits.get(parent).copied().unwrap_or(*parent))
            .collect();

        let mapped_first_parent_tree = original_parents
            .first()
            .map(|parent| {
                replayed_trees
                    .get(parent)
                    .copied()
                    .map(Ok)
                    .unwrap_or_else(|| {
                        repo.find_commit(*parent)
                            .map_err(EngineError::from_gix)?
                            .tree_id()
                            .map_err(EngineError::from_gix)
                            .map(|tree| tree.detach())
                    })
            })
            .transpose()?
            .unwrap_or_else(|| repo.empty_tree().id);

        let (rewritten_id, rewritten_tree) = if id == target {
            let first = new_commit_preserving_author(
                repo,
                id,
                &original_message,
                first_tree,
                mapped_parents,
            )?;
            if let (Some(second_tree), Some(second_message)) = (second_tree, second_message) {
                let second_message = if second_message.ends_with('\n') {
                    second_message.to_owned()
                } else {
                    format!("{second_message}\n")
                };
                let second =
                    new_commit_preserving_author(repo, id, &second_message, second_tree, [first])?;
                (second, second_tree)
            } else {
                (first, first_tree)
            }
        } else {
            let replayed_tree =
                cherry_pick_tree(repo, &commit, mapped_first_parent_tree).map_err(|error| {
                    EngineError::GitOperation {
                        message: format!("unable to replay descendant {id}: {error}"),
                    }
                })?;
            let rewritten = new_commit_preserving_author(
                repo,
                id,
                &original_message,
                replayed_tree,
                mapped_parents,
            )?;
            (rewritten, replayed_tree)
        };

        replayed_commits.insert(id, rewritten_id);
        replayed_trees.insert(id, rewritten_tree);
    }

    let final_head = replayed_commits
        .get(&original_head)
        .copied()
        .ok_or_else(|| EngineError::GitOperation {
            message: "history rewrite produced no commit".into(),
        })?;
    let final_tree =
        replayed_trees
            .get(&original_head)
            .copied()
            .ok_or_else(|| EngineError::GitOperation {
                message: "history rewrite produced no tree".into(),
            })?;
    if let Some(workdir) = repo.workdir() {
        let gitlink_changes =
            crate::merge::gitlink_changes_for_tree_rewrite(repo, original_tree, final_tree)?;
        crate::merge::preflight_gitlink_worktrees(workdir, &gitlink_changes)?;
    }
    move_head_to(repo, final_head)?;
    finalize_rebase(repo, original_tree, final_head, final_tree)?;
    Ok(RebaseOutcome {
        head_id: final_head.to_hex().to_string(),
        paused: false,
        pause_reason: None,
        conflicts: Vec::new(),
    })
}

/// Rebuild a linear history from the repository root so a non-HEAD root
/// commit can be reworded without importing staged or working-tree changes.
///
/// Git's `rebase --root` can also flatten merge descendants when merge
/// preservation is disabled. The object-level path deliberately rejects that
/// case instead of silently changing the branch topology; callers can use the
/// regular interactive rebase flow when merge preservation is required.
fn rewrite_root_commit_history(
    repo: &gix::Repository,
    root: gix::hash::ObjectId,
    message: &str,
) -> Result<RebaseOutcome, EngineError> {
    let message = message.trim();
    if message.is_empty() {
        return Err(EngineError::GitOperation {
            message: "reword root commit requires a non-empty message".into(),
        });
    }

    let original_head = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let original_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let root_commit = repo.find_commit(root).map_err(EngineError::from_gix)?;
    if root_commit.parent_ids().next().is_some() {
        return Err(EngineError::GitOperation {
            message: "reword root commit requires a commit with no parent".into(),
        });
    }

    let mut history = Vec::new();
    let mut cursor = original_head;
    loop {
        let commit = repo.find_commit(cursor).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|id| id.detach()).collect();
        if parents.len() > 1 {
            return Err(EngineError::GitOperation {
                message: "reword root commit does not support merge descendants; use Interactive Rebase with merge preservation".into(),
            });
        }
        history.push(cursor);
        let Some(parent) = parents.first().copied() else {
            break;
        };
        cursor = parent;
    }
    history.reverse();
    if history.first().copied() != Some(root) {
        return Err(EngineError::GitOperation {
            message: "the selected root commit is not an ancestor of HEAD".into(),
        });
    }

    let root_message = format!("{message}\n");
    let mut new_head = None;
    let mut current_tree = repo.empty_tree().id;
    for id in history {
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let tree = commit.tree_id().map_err(EngineError::from_gix)?.detach();
        let commit_message = if id == root {
            root_message.clone()
        } else {
            // Keep the original full message and its trailing newline for all
            // descendants; only the selected root message is changed.
            full_commit_message(repo, id)?
        };
        let parent = new_head.into_iter().collect::<Vec<_>>();
        let rewritten = new_commit_preserving_author(repo, id, &commit_message, tree, parent)?;
        new_head = Some(rewritten);
        current_tree = tree;
    }

    let final_head = new_head.ok_or_else(|| EngineError::GitOperation {
        message: "reword root commit produced no commit".into(),
    })?;
    move_head_to(repo, final_head)?;
    finalize_rebase(repo, original_tree, final_head, current_tree)?;
    Ok(RebaseOutcome {
        head_id: final_head.to_hex().to_string(),
        paused: false,
        pause_reason: None,
        conflicts: Vec::new(),
    })
}

/// 执行线性 rebase 的动作序列（pairs 顺序 = 最终拓扑顺序；
/// rebase_with_todo 的拖拽排序依赖此顺序）。
fn execute_linear_rebase(
    repo: &gix::Repository,
    onto_id: gix::hash::ObjectId,
    original_head: gix::hash::ObjectId,
    original_tree: gix::hash::ObjectId,
    start_tree: gix::hash::ObjectId,
    pairs: &[(RebaseAction, gix::hash::ObjectId)],
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<RebaseOutcome, EngineError> {
    ensure_not_cancelled(cancel)?;
    // 先把 HEAD 移到 onto：后续重放提交的 CAS 以 onto 为基准。
    move_head_to(repo, onto_id)?;

    match apply_rebase_actions(repo, onto_id, start_tree, pairs, true, cancel) {
        Ok(ApplyOutcome::Done { head, tree }) => {
            finalize_rebase(repo, original_tree, head, tree)?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: false,
                pause_reason: None,
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::Paused {
            head,
            tree,
            message,
            remaining,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head,
                    onto: onto_id,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Edit,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Edit),
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::PausedConflict {
            head,
            tree,
            message,
            remaining,
            conflicts,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head,
                    onto: onto_id,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Conflict,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Conflict),
                conflicts,
            })
        }
        Err(e) => {
            restore_head(&repo, original_head)?;
            Err(e)
        }
    }
}

/// 校验远程名合法（防 config 注入：非空、不以 - 开头、无空白/斜杠）。
fn remote_name_ok(name: &str) -> Result<(), EngineError> {
    let name = name.trim();
    if name.is_empty()
        || name.starts_with('-')
        || name.contains(' ')
        || name.contains('/')
        || name.contains('\n')
    {
        return Err(EngineError::GitOperation {
            message: format!("invalid remote name: {name:?}"),
        });
    }
    Ok(())
}

fn tag_refspec(tag: &str) -> Result<String, EngineError> {
    let tag = tag.trim();
    if tag.is_empty() || tag.starts_with('-') || tag.contains('\n') || tag.contains('\r') {
        return Err(EngineError::GitOperation {
            message: "invalid tag name".into(),
        });
    }
    let full_ref = format!("refs/tags/{tag}");
    let _: gix::refs::FullName = full_ref
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    Ok(format!("{full_ref}:{full_ref}"))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RemoteAuthMode {
    /// Use configured system credential helpers/SSH configuration without
    /// installing the Arbor askpass broker.
    System,
    /// Allow the interactive SwiftUI credential handler.
    Interactive,
    /// Use broker-backed stored credentials only; never open SwiftUI.
    Silent,
    /// Disable credential helpers and terminal prompts for background checks.
    NoAuthentication,
}

fn run_remote_query_command(
    spec: &crate::gitprocess::GitCommandSpec,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<crate::gitprocess::GitProcessOutcome, EngineError> {
    let mode = if broker.is_some() {
        RemoteAuthMode::Interactive
    } else {
        RemoteAuthMode::System
    };
    run_remote_query_command_with_mode(spec, broker, cancel, mode)
}

fn disable_interactive_auth(
    spec: &crate::gitprocess::GitCommandSpec,
) -> crate::gitprocess::GitCommandSpec {
    // Do not rely on the caller's environment: an inherited askpass or
    // pinentry helper could otherwise turn a background check into a dialog.
    spec.clone()
        .global_arg("-c")
        .global_arg("credential.helper=")
        .env("GIT_ASKPASS", "")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("SSH_ASKPASS", "")
        .env("SSH_ASKPASS_REQUIRE", "never")
}

fn run_remote_query_command_with_mode(
    spec: &crate::gitprocess::GitCommandSpec,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    mode: RemoteAuthMode,
) -> Result<crate::gitprocess::GitProcessOutcome, EngineError> {
    let spec = if mode == RemoteAuthMode::NoAuthentication {
        disable_interactive_auth(spec)
    } else {
        spec.clone()
    };
    match mode {
        RemoteAuthMode::Interactive => match broker {
            Some(broker) => crate::auth::run_with_askpass(&spec, broker, cancel),
            None => crate::gitprocess::run(&spec, cancel, |_| {}),
        },
        RemoteAuthMode::Silent => match broker {
            Some(broker) => crate::auth::run_with_silent_askpass(&spec, broker, cancel),
            None => crate::gitprocess::run(&spec, cancel, |_| {}),
        },
        RemoteAuthMode::System | RemoteAuthMode::NoAuthentication => match cancel {
            Some(cancel) => crate::gitprocess::run(&spec, Some(cancel), |_| {}),
            None => crate::gitprocess::run_to_completion(&spec),
        },
    }
}

fn run_submodule_command_spec(
    spec: &crate::gitprocess::GitCommandSpec,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    let outcome = match broker {
        Some(broker) => crate::auth::run_with_askpass(spec, broker, cancel)?,
        None => match cancel {
            Some(cancel) => crate::gitprocess::run(spec, Some(cancel), |_| {})?,
            None => crate::gitprocess::run_to_completion(spec)?,
        },
    };
    if !outcome.success() {
        return Err(outcome.into_error(spec));
    }
    Ok(())
}

fn optional_text_file(path: &Path) -> Result<(bool, Option<String>), EngineError> {
    match std::fs::read_to_string(path) {
        Ok(contents) => Ok((true, Some(contents))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok((false, None)),
        Err(error) => Err(EngineError::from_gix(error)),
    }
}

fn write_optional_text_file(
    path: &Path,
    present: bool,
    contents: Option<&str>,
) -> Result<(), EngineError> {
    if !present {
        match std::fs::remove_file(path) {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(EngineError::from_gix(error)),
        }
    }
    let contents = contents.ok_or_else(|| EngineError::GitOperation {
        message: "submodule undo is missing .gitmodules contents".into(),
    })?;
    let temporary = path.with_extension("arbor-undo.tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(EngineError::from_gix)?;
    use std::io::Write;
    if let Err(error) = file.write_all(contents.as_bytes()) {
        let _ = std::fs::remove_file(&temporary);
        return Err(EngineError::from_gix(error));
    }
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(EngineError::from_gix(error));
    }
    Ok(())
}

fn stage_gitmodules(workdir: &Path, present: bool) -> Result<(), EngineError> {
    let args: Vec<String> = if present {
        vec!["--".into(), ".gitmodules".into()]
    } else {
        vec!["-u".into(), "--".into(), ".gitmodules".into()]
    };
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "add",
    )
    .args(args)
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if outcome.success() {
        Ok(())
    } else {
        Err(outcome.into_error(&spec))
    }
}

fn index_entry_exists(workdir: &Path, path: &Path) -> Result<bool, EngineError> {
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "ls-files",
    )
    .args([
        "--error-unmatch".to_string(),
        "--".to_string(),
        path.to_string_lossy().into_owned(),
    ])
    .working_dir(workdir);
    Ok(crate::gitprocess::run_to_completion(&spec)?.success())
}

fn index_gitlink_id(workdir: &Path, path: &Path) -> Result<Option<String>, EngineError> {
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "ls-files",
    )
    .args([
        "--stage".to_string(),
        "--".to_string(),
        path.to_string_lossy().into_owned(),
    ])
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Ok(None);
    }
    let Some(line) = outcome.stdout.lines().find(|line| !line.trim().is_empty()) else {
        return Ok(None);
    };
    let fields: Vec<&str> = line.split_whitespace().collect();
    if fields.len() < 3 || fields[0] != "160000" {
        return Ok(None);
    }
    Ok(Some(fields[1].to_string()))
}

fn ensure_empty_or_missing_path(path: &Path) -> Result<(), EngineError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(EngineError::from_gix(error)),
    };
    if metadata.file_type().is_symlink() {
        return Err(EngineError::GitOperation {
            message: "submodule remove undo refused: the path is a symlink".into(),
        });
    }
    if !metadata.is_dir() {
        return Err(EngineError::GitOperation {
            message: "submodule remove undo refused: the path is occupied by a file".into(),
        });
    }
    let mut entries = std::fs::read_dir(path).map_err(EngineError::from_gix)?;
    if entries
        .next()
        .transpose()
        .map_err(EngineError::from_gix)?
        .is_some()
    {
        return Err(EngineError::GitOperation {
            message: "submodule remove undo refused: the path contains new files".into(),
        });
    }
    Ok(())
}

fn restore_added_submodule_post_state(
    workdir: &Path,
    path: &Path,
    expected_submodule_head_id: &str,
    expected_gitmodules_present: bool,
    expected_gitmodules_contents: Option<&str>,
    broker: &crate::auth::CredentialBroker,
    cancel: &crate::gitprocess::GitCancelHandle,
) -> Result<(), EngineError> {
    let mut failures = Vec::new();
    if let Err(error) = write_optional_text_file(
        &workdir.join(".gitmodules"),
        expected_gitmodules_present,
        expected_gitmodules_contents,
    ) {
        failures.push(error.to_string());
    } else if let Err(error) = stage_gitmodules(workdir, expected_gitmodules_present) {
        failures.push(error.to_string());
    }

    let restore_index = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "update-index",
    )
    .args([
        "--add".to_string(),
        "--cacheinfo".to_string(),
        format!(
            "160000,{},{}",
            expected_submodule_head_id,
            path.to_string_lossy()
        ),
    ])
    .working_dir(workdir);
    match crate::gitprocess::run_to_completion(&restore_index) {
        Ok(outcome) if outcome.success() => {}
        Ok(outcome) => failures.push(outcome.into_error(&restore_index).to_string()),
        Err(error) => failures.push(error.to_string()),
    }

    let submodule_worktree = workdir.join(path);
    if submodule_worktree.exists() {
        match ensure_empty_or_missing_path(&submodule_worktree) {
            Ok(()) => {
                if let Err(error) = std::fs::remove_dir(&submodule_worktree) {
                    failures.push(error.to_string());
                }
            }
            Err(error) => failures.push(error.to_string()),
        }
    }
    if !submodule_worktree.exists() {
        let update = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args([
            "update".to_string(),
            "--init".to_string(),
            "--".to_string(),
            path.to_string_lossy().into_owned(),
        ])
        .working_dir(workdir);
        if let Err(error) = run_submodule_command_spec(&update, Some(broker), Some(cancel.token()))
        {
            failures.push(error.to_string());
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(EngineError::GitOperation {
            message: format!("unable to restore post-add state: {}", failures.join("; ")),
        })
    }
}

fn submodule_status_line(workdir: &Path, path: &Path) -> Result<Option<String>, EngineError> {
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "submodule",
    )
    .args([
        "status".to_string(),
        "--".to_string(),
        path.to_string_lossy().into_owned(),
    ])
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    Ok(outcome
        .stdout
        .lines()
        .map(str::trim_end)
        .find(|line| !line.is_empty())
        .map(str::to_string))
}

fn restore_removed_submodule_post_state(
    workdir: &Path,
    path: &Path,
    expected_gitmodules_present: bool,
    expected_gitmodules_contents: Option<&str>,
) -> Result<(), EngineError> {
    let mut failures = Vec::new();
    let submodule_worktree = workdir.join(path);
    if submodule_worktree.exists() {
        match nested_worktree_has_changes(&submodule_worktree) {
            Ok(true) => failures.push(
                "partial submodule worktree has changes; preserved it instead of deinit --force"
                    .into(),
            ),
            Ok(false) => {
                let deinit = crate::gitprocess::GitCommandSpec::new(
                    crate::gitprocess::GitCommandCategory::Submodule,
                    "submodule",
                )
                .args([
                    "deinit".to_string(),
                    "--force".to_string(),
                    "--".to_string(),
                    path.to_string_lossy().into_owned(),
                ])
                .working_dir(workdir);
                if let Err(error) = run_submodule_command_spec(&deinit, None, None) {
                    failures.push(error.to_string());
                }
            }
            Err(error) => failures.push(error.to_string()),
        }
    }
    if let Err(error) = write_optional_text_file(
        &workdir.join(".gitmodules"),
        expected_gitmodules_present,
        expected_gitmodules_contents,
    ) {
        failures.push(error.to_string());
    } else if let Err(error) = stage_gitmodules(workdir, expected_gitmodules_present) {
        failures.push(error.to_string());
    }
    let remove_index = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Submodule,
        "update-index",
    )
    .args([
        "--remove".to_string(),
        "--".to_string(),
        path.to_string_lossy().into_owned(),
    ])
    .working_dir(workdir);
    match crate::gitprocess::run_to_completion(&remove_index) {
        Ok(outcome) if outcome.success() => {}
        Ok(outcome) => failures.push(outcome.into_error(&remove_index).to_string()),
        Err(error) => failures.push(error.to_string()),
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(EngineError::GitOperation {
            message: format!(
                "unable to restore post-remove state: {}",
                failures.join("; ")
            ),
        })
    }
}

fn nested_worktree_has_changes(path: &Path) -> Result<bool, EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(path)
        .args([
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--ignored",
        ])
        .current_dir(path)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git submodule cleanup status failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(!output.stdout.is_empty())
}

fn append_recovery_cleanup_error(
    error: EngineError,
    cleanup: Result<(), EngineError>,
) -> EngineError {
    match cleanup {
        Ok(()) => error,
        Err(cleanup) => EngineError::GitOperation {
            message: format!("{error}; cleanup failed: {cleanup}"),
        },
    }
}

fn list_remote_tags_locked(
    repo: &gix::Repository,
    remote: &str,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<Vec<RemoteTagInfo>, EngineError> {
    let remote = remote.trim();
    remote_name_ok(remote)?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "list remote tags requires a worktree".into(),
    })?;
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Tag,
        "ls-remote",
    )
    .args(["--tags", remote])
    .working_dir(workdir);
    let outcome = run_remote_query_command(&spec, broker, cancel)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }

    // The first line for an annotated tag names the tag object, followed by a
    // `^{}` line naming its peeled target. Lightweight tags have only the
    // first form. Keep both values because the tag object id is the deletion
    // lease value while the peeled target is the useful display value.
    let mut parsed: HashMap<String, (String, String, bool)> = HashMap::new();
    for line in outcome.stdout.lines() {
        let Some((object_id, reference)) = line.split_once('\t') else {
            continue;
        };
        let Some(reference) = reference.strip_prefix("refs/tags/") else {
            continue;
        };
        let is_peeled = reference.ends_with("^{}");
        let name = reference.strip_suffix("^{}").unwrap_or(reference);
        if name.is_empty() || object_id.is_empty() {
            continue;
        }
        let full_ref = format!("refs/tags/{name}");
        let valid_ref: Result<gix::refs::FullName, _> = full_ref.as_str().try_into();
        if valid_ref.is_err() {
            continue;
        }
        let entry = parsed
            .entry(name.to_string())
            .or_insert_with(|| (String::new(), String::new(), false));
        if is_peeled {
            entry.1 = object_id.to_string();
            entry.2 = true;
        } else {
            entry.0 = object_id.to_string();
            if !entry.2 {
                entry.1 = object_id.to_string();
            }
        }
    }

    let mut tags = parsed
        .into_iter()
        .filter_map(|(name, (object_id, id, annotated))| {
            if object_id.is_empty() || id.is_empty() {
                return None;
            }
            Some(RemoteTagInfo {
                remote: remote.to_string(),
                name,
                object_id,
                short_id: id.chars().take(7).collect(),
                id,
                kind: if annotated {
                    crate::branch::TagKind::Annotated
                } else {
                    crate::branch::TagKind::Lightweight
                },
            })
        })
        .collect::<Vec<_>>();
    tags.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(tags)
}

fn remote_incoming_branches_locked(
    repo: &gix::Repository,
    remote: &str,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<Vec<String>, EngineError> {
    let auth_mode = if broker.is_some() {
        RemoteAuthMode::Interactive
    } else {
        RemoteAuthMode::System
    };
    remote_incoming_branches_locked_with_auth_mode(repo, remote, broker, cancel, auth_mode)
}

fn remote_incoming_branches_locked_with_auth_mode(
    repo: &gix::Repository,
    remote: &str,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    auth_mode: RemoteAuthMode,
) -> Result<Vec<String>, EngineError> {
    let remote = remote.trim();
    remote_name_ok(remote)?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "check remote incoming changes requires a worktree".into(),
    })?;

    let mut tracked = Vec::new();
    for item in repo
        .references()
        .map_err(EngineError::from_gix)?
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = item.map_err(crate::log::boxed_err)?;
        let local_branch = shorten_ref_name(reference.name().as_bstr());
        let upstream = match configured_upstream(repo, &local_branch) {
            Ok(upstream) => upstream,
            Err(EngineError::NoUpstream { .. }) => continue,
            Err(error) => return Err(error),
        };
        if upstream.remote == remote {
            let full_ref = format!("refs/heads/{}", upstream.branch);
            let _: gix::refs::FullName = full_ref
                .as_str()
                .try_into()
                .map_err(EngineError::from_gix)?;
            tracked.push((local_branch, upstream.branch));
        }
    }
    tracked.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    if tracked.is_empty() {
        return Ok(Vec::new());
    }

    let mut spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Fetch,
        "ls-remote",
    )
    .arg("--heads")
    .arg(remote)
    .working_dir(workdir);
    for (_, upstream_branch) in &tracked {
        spec = spec.arg(format!("refs/heads/{upstream_branch}"));
    }
    let outcome = run_remote_query_command_with_mode(&spec, broker, cancel, auth_mode)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }

    let mut remote_ids = HashMap::new();
    for line in outcome.stdout.lines() {
        let mut fields = line.split_whitespace();
        let Some(object_id) = fields.next() else {
            continue;
        };
        let Some(reference) = fields.next() else {
            continue;
        };
        let Some(branch) = reference.strip_prefix("refs/heads/") else {
            continue;
        };
        remote_ids.insert(branch.to_string(), object_id.to_string());
    }

    let mut incoming = Vec::new();
    for (local_branch, upstream_branch) in tracked {
        let Some(remote_id) = remote_ids.get(&upstream_branch) else {
            continue;
        };
        let tracking_ref = format!("refs/remotes/{remote}/{upstream_branch}");
        let local_tracking_id =
            repo.find_reference(tracking_ref.as_str())
                .ok()
                .and_then(|reference| {
                    reference
                        .try_id()
                        .map(|id| id.detach().to_hex().to_string())
                });
        if local_tracking_id.as_deref() != Some(remote_id.as_str()) {
            incoming.push(local_branch);
        }
    }
    incoming.sort();
    Ok(incoming)
}

fn delete_remote_branch_locked(
    repo: &mut gix::Repository,
    remote_branch: &str,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    let remote_branch = remote_branch.trim();
    let (remote, branch) =
        remote_branch
            .split_once('/')
            .ok_or_else(|| EngineError::GitOperation {
                message: "remote branch must look like remote/branch".into(),
            })?;
    remote_name_ok(remote)?;
    if branch.is_empty() || branch == "HEAD" || branch.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "invalid remote branch".into(),
        });
    }
    let full_ref = format!("refs/heads/{branch}");
    let _: gix::refs::FullName = full_ref
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "delete remote branch requires a worktree".into(),
    })?;

    let delete =
        crate::gitprocess::GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Push, "push")
            .args(["--delete", remote, branch])
            .working_dir(workdir);
    let outcome = run_remote_query_command(&delete, broker, cancel)?;
    if !outcome.success() {
        // IntelliJ treats a branch that disappeared between listing and
        // confirmation as an already-completed deletion, then prunes the
        // stale tracking ref instead of reporting a hard failure.
        let remote_delete_output = format!("{}\n{}", outcome.stderr, outcome.stdout);
        if remote_delete_output.contains("remote ref does not exist") {
            let prune = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Fetch,
                "remote",
            )
            .args(["prune", remote])
            .working_dir(workdir);
            let prune_outcome = run_remote_query_command(&prune, broker, cancel)?;
            if prune_outcome.success() {
                repo.reload().map_err(EngineError::from_gix)?;
                return Ok(());
            }
            return Err(prune_outcome.into_error(&prune));
        }
        return Err(outcome.into_error(&delete));
    }

    // `git push --delete` removes the server ref, but a long-lived gix
    // handle can still expose the cached remote-tracking ref. Remove the
    // local tracking ref explicitly so the branch popover refresh is
    // immediately truthful, matching IntelliJ's repository update.
    let tracking = format!("refs/remotes/{remote}/{branch}");
    let cleanup = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Branch,
        "update-ref",
    )
    .args(["-d".to_string(), tracking])
    .working_dir(workdir);
    // The remote deletion is already committed at this point. Finish the
    // local tracking-ref cleanup even if cancellation arrives immediately
    // afterwards, otherwise the next Branches Popup refresh can resurrect a
    // stale remote branch.
    let cleanup_outcome = crate::gitprocess::run_to_completion(&cleanup)?;
    if !cleanup_outcome.success() && cleanup_outcome.exit_code != 1 {
        return Err(cleanup_outcome.into_error(&cleanup));
    }
    repo.reload().map_err(EngineError::from_gix)?;
    Ok(())
}

fn delete_remote_tag_locked(
    repo: &gix::Repository,
    remote: &str,
    tag: &str,
    expected_object_id: Option<&str>,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<bool, EngineError> {
    let remote = remote.trim();
    remote_name_ok(remote)?;
    let tag = tag.trim();
    if tag.is_empty() || tag.starts_with('-') || tag.contains('\n') || tag.contains('\r') {
        return Err(EngineError::GitOperation {
            message: "invalid tag name".into(),
        });
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "delete remote tag requires a worktree".into(),
    })?;
    let full_ref = format!("refs/tags/{tag}");
    let _: gix::refs::FullName = full_ref
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    let lookup = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Tag,
        "ls-remote",
    )
    .args(["--refs", remote, &full_ref])
    .working_dir(workdir);
    let outcome = run_remote_query_command(&lookup, broker, cancel)?;
    if !outcome.success() {
        return Err(outcome.into_error(&lookup));
    }
    let remote_id = outcome
        .stdout
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let id = fields.next()?;
            let ref_name = fields.next()?;
            (ref_name == full_ref).then_some(id.to_string())
        })
        .next();
    let Some(remote_id) = remote_id else {
        return Ok(false);
    };
    if let Some(expected_object_id) = expected_object_id {
        if remote_id != expected_object_id {
            return Err(EngineError::GitOperation {
                message: format!(
                    "remote tag changed before deletion; expected {}, found {}",
                    expected_object_id, remote_id
                ),
            });
        }
    }
    let lease = format!("--force-with-lease={full_ref}:{remote_id}");
    let delete_ref = format!(":{full_ref}");
    let push =
        crate::gitprocess::GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Push, "push")
            .args([&lease, remote, &delete_ref])
            .working_dir(workdir);
    let outcome = run_remote_query_command(&push, broker, cancel)?;
    if !outcome.success() {
        return Err(outcome.into_error(&push));
    }
    Ok(true)
}

/// push 失败的结构化错误（含认证/非 fast-forward 分类）。
fn push_rejected_error(
    outcome: crate::gitprocess::GitProcessOutcome,
    spec: &crate::gitprocess::GitCommandSpec,
    remote: &str,
    branch: &str,
) -> EngineError {
    EngineError::PushRejected {
        kind: push_failure_kind_from_outcome(&outcome),
        remote: remote.to_string(),
        branch: branch.to_string(),
        message: outcome.into_error(spec).to_string(),
    }
}

fn push_failure_kind_from_outcome(
    outcome: &crate::gitprocess::GitProcessOutcome,
) -> PushFailureKind {
    let output = format!("{}\n{}", outcome.stdout, outcome.stderr);
    if matches!(push_failure_kind(&output), PushFailureKind::StaleInfo) {
        return PushFailureKind::StaleInfo;
    }
    match outcome.failure {
        Some(crate::gitprocess::GitFailureKind::Authentication) => PushFailureKind::Authentication,
        Some(crate::gitprocess::GitFailureKind::NonFastForward) => PushFailureKind::NonFastForward,
        _ => push_failure_kind(&output),
    }
}

fn push_inner(
    repo: &gix::Repository,
    remote: &str,
    branch: &str,
    force: bool,
    force_with_lease: bool,
    set_upstream: bool,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    let spec =
        crate::gitprocess::GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Push, "push")
            .flag_if("--force-with-lease", force_with_lease)
            .flag_if("--force", force && !force_with_lease)
            .flag_if("--set-upstream", set_upstream)
            .flag_if("--no-verify", skip_hooks)
            .flag_if("--tags", tag_mode == Some(crate::remote::PushTagMode::All))
            .flag_if(
                "--follow-tags",
                tag_mode == Some(crate::remote::PushTagMode::Follow),
            )
            .url_arg(remote)
            .arg(branch)
            .working_dir(workdir);
    let outcome = match broker {
        Some(broker) => crate::auth::run_with_askpass(&spec, broker, cancel)?,
        None => crate::gitprocess::run(&spec, cancel, |_| {})?,
    };
    if !outcome.success() {
        if matches!(
            outcome.failure,
            Some(crate::gitprocess::GitFailureKind::Cancelled)
        ) || outcome.cancelled
        {
            return Err(EngineError::Cancelled);
        }
        return Err(EngineError::PushRejected {
            kind: push_failure_kind_from_outcome(&outcome),
            remote: remote.to_string(),
            branch: branch.to_string(),
            message: outcome.into_error(&spec).to_string(),
        });
    }
    Ok(())
}

fn push_refspec_inner(
    repo: &gix::Repository,
    remote: &str,
    refspec: &str,
    force: bool,
    force_with_lease: bool,
    tag_mode: Option<crate::remote::PushTagMode>,
    skip_hooks: bool,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "push requires a non-bare worktree".into(),
    })?;
    let spec =
        crate::gitprocess::GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Push, "push")
            .flag_if("--force-with-lease", force_with_lease)
            .flag_if("--force", force && !force_with_lease)
            .flag_if("--no-verify", skip_hooks)
            .flag_if("--tags", tag_mode == Some(crate::remote::PushTagMode::All))
            .flag_if(
                "--follow-tags",
                tag_mode == Some(crate::remote::PushTagMode::Follow),
            )
            .url_arg(remote)
            .arg(refspec)
            .working_dir(workdir);
    let outcome = match broker {
        Some(broker) => crate::auth::run_with_askpass(&spec, broker, cancel)?,
        None => crate::gitprocess::run(&spec, cancel, |_| {})?,
    };
    if !outcome.success() {
        if matches!(
            outcome.failure,
            Some(crate::gitprocess::GitFailureKind::Cancelled)
        ) || outcome.cancelled
        {
            return Err(EngineError::Cancelled);
        }
        let branch = refspec
            .rsplit_once(':')
            .map(|(_, target)| target.trim_start_matches("refs/heads/").to_string())
            .unwrap_or_else(|| refspec.to_string());
        return Err(EngineError::PushRejected {
            kind: push_failure_kind_from_outcome(&outcome),
            remote: remote.to_string(),
            branch,
            message: outcome.into_error(&spec).to_string(),
        });
    }
    Ok(())
}

fn rebase_range_with_options_for_head(
    repo: &gix::Repository,
    onto_id: Option<gix::hash::ObjectId>,
    preserve_merges: bool,
    root: bool,
    head_id: gix::hash::ObjectId,
) -> Result<Vec<CommitInfo>, EngineError> {
    let ids =
        rebase_ids_with_optional_onto_for_head(repo, onto_id, preserve_merges, root, head_id)?;
    let refs = crate::log::collect_refs(repo)?;
    let mut commits = ids
        .into_iter()
        .map(|id| commit_info_for_id(repo, id, &refs, head_id))
        .collect::<Result<Vec<_>, _>>()?;
    crate::log::assign_graph_lanes(&mut commits, false, !preserve_merges);
    Ok(commits)
}

fn rebase_todo_ids_with_options_for_head(
    repo: &gix::Repository,
    onto_id: Option<gix::hash::ObjectId>,
    preserve_merges: bool,
    root: bool,
    head_id: gix::hash::ObjectId,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    if preserve_merges {
        return rebase_merge_order(repo, onto_id, head_id, root);
    }
    rebase_ids_with_optional_onto_for_head(repo, onto_id, false, root, head_id)
}

fn rebase_ids_with_optional_onto_for_head(
    repo: &gix::Repository,
    onto_id: Option<gix::hash::ObjectId>,
    preserve_merges: bool,
    root: bool,
    head_id: gix::hash::ObjectId,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    let ids = if preserve_merges {
        rebase_merge_order(repo, onto_id, head_id, root)?
            .into_iter()
            .filter(|id| {
                repo.find_commit(*id)
                    .map(|commit| commit.parent_ids().nth(1).is_none())
                    .unwrap_or(false)
            })
            .collect::<Vec<_>>()
    } else if root {
        rebase_root_graph_order(repo, onto_id, head_id)?
            .into_iter()
            .filter(|id| {
                repo.find_commit(*id)
                    .map(|commit| commit.parent_ids().nth(1).is_none())
                    .unwrap_or(false)
            })
            .collect::<Vec<_>>()
    } else {
        let onto_id = onto_id.ok_or_else(|| EngineError::GitOperation {
            message: "rebase: a non-root rebase requires an onto revision".into(),
        })?;
        crate::rebasetodo::rebase_range(repo, onto_id, head_id)?
    };
    Ok(ids)
}

fn shelve_diff_locked(repo: &gix::Repository, name: &str) -> Result<String, EngineError> {
    shelve_diff_locked_from_collection(repo, name, false)
}

fn shelve_diff_locked_from_collection(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
) -> Result<String, EngineError> {
    if let Some(bytes) = crate::shelve::read_shelf_patch(repo, name, is_deleted)? {
        return String::from_utf8(bytes).map_err(|_| EngineError::GitOperation {
            message: format!("shelve: imported patch for {name} is not UTF-8"),
        });
    }
    let list = if is_deleted {
        crate::shelve::load_deleted_shelves(repo)?
    } else {
        crate::shelve::load_shelves(repo)?
    };
    let patch_id = list
        .iter()
        .find(|(candidate, _)| candidate == name)
        .map(|(_, id)| *id)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    let patch = repo.find_commit(patch_id).map_err(EngineError::from_gix)?;
    let parent_id = patch
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: patch has no parent".into(),
        })?
        .detach();
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve diff requires a non-bare worktree".into(),
    })?;
    let parent = parent_id.to_hex().to_string();
    let patch = patch_id.to_hex().to_string();
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args([
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--format=",
            "--binary",
            &parent,
            &patch,
            "--",
        ])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!("git shelf diff failed: {}", command_output_message(&output)),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn shelve_file_diff_locked(
    repo: &gix::Repository,
    name: &str,
    path: &str,
    with_local: bool,
    settings: &crate::diff::DiffSettings,
    is_deleted: bool,
) -> Result<FileDiff, EngineError> {
    if crate::shelve::read_shelf_patch(repo, name, is_deleted)?.is_some() {
        return Err(EngineError::GitOperation {
            message: "imported shelf has no structured revision tree".into(),
        });
    }
    let list = if is_deleted {
        crate::shelve::load_deleted_shelves(repo)?
    } else {
        crate::shelve::load_shelves(repo)?
    };
    let patch_id = list
        .iter()
        .find(|(candidate, _)| candidate == name)
        .map(|(_, id)| *id)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    let patch = repo.find_commit(patch_id).map_err(EngineError::from_gix)?;
    let parent_id = patch
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: patch has no parent".into(),
        })?
        .detach();
    let patch_revision = patch_id.to_hex().to_string();
    let parent_revision = parent_id.to_hex().to_string();
    let textconv = if with_local {
        textconv_git_diff_if_enabled(
            repo,
            path,
            settings,
            vec![patch_revision.clone()],
            true,
            true,
        )?
    } else {
        textconv_revision_diff_if_enabled(repo, &parent_revision, &patch_revision, path, settings)?
    };
    if let Some(diff) = textconv {
        return Ok(diff);
    }
    let old = if with_local {
        normalized_worktree_bytes(repo, path)?
    } else {
        rev_content_bytes(repo, &parent_revision, path)?
    };
    let new = rev_content_bytes(repo, &patch_revision, path)?;
    if is_binary(&old) || is_binary(&new) {
        return Ok(FileDiff {
            path: path.to_string(),
            binary: true,
            hunks: Vec::new(),
        });
    }
    let hunks = compute_hunks_with(&old, &new, settings.ignore_all_space);
    let mut diff = FileDiff {
        path: path.to_string(),
        binary: false,
        hunks,
    };
    let path = diff.path.clone();
    attach_highlights(&path, &old, &new, &mut diff);
    Ok(diff)
}

/// Apply and remove a Shelf while the caller already owns no `Repository`
/// mutex guard. Ordinary user Pop keeps its legacy compatibility path when no
/// preservation snapshot exists; preserving-process restores always use the
/// differentiated executor so a missing snapshot cannot silently downgrade
/// recovery to an atomic tree merge.
fn ensure_not_cancelled(
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
        Err(EngineError::Cancelled)
    } else {
        Ok(())
    }
}

fn shelve_pop_locked(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    shelve_pop_locked_with_mode(repo, name, None, false)
}

fn shelve_pop_preservation_locked(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    shelve_pop_locked_with_mode(repo, name, None, true)
}

fn shelve_pop_preservation_locked_with_cancel(
    repo: &gix::Repository,
    name: &str,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    shelve_pop_locked_with_mode(repo, name, cancel, true)
}

fn shelve_pop_locked_with_mode(
    repo: &gix::Repository,
    name: &str,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    preservation: bool,
) -> Result<(), EngineError> {
    ensure_not_cancelled(cancel)?;
    use crate::shelve::load_shelves;
    let patch_id = load_shelves(repo)?
        .iter()
        .find(|(candidate, _)| candidate == name)
        .map(|(_, id)| *id)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("shelve: {name} not found"),
        })?;
    if crate::shelve::read_shelf_patch(repo, name, false)?.is_some() {
        // Imported user Shelves retain their legacy atomic executor. The
        // cancellable differentiated path is used by preservation Shelves;
        // still honor cancellation at the operation boundary here.
        ensure_not_cancelled(cancel)?;
        let applied_paths =
            crate::shelve::apply_shelve_with_options(repo, patch_id, name, true, false)?;
        let source_paths =
            source_shelve_paths_for_apply_locked(repo, name, false, None, &applied_paths, None, 1)?;
        if !source_paths.is_empty() {
            consume_shelve_selection_locked(repo, name, &source_paths)?;
        }
        return Ok(());
    }
    if !preservation && !crate::shelve::has_temporary_index_snapshot(repo)? {
        crate::shelve::apply_shelve_with_options(repo, patch_id, name, true, false)?;
        return drop_shelve_locked(repo, name);
    }
    let patch = shelve_diff_locked(repo, name)?;
    if patch.trim().is_empty() {
        if crate::shelve::has_temporary_index_snapshot(repo)? {
            crate::shelve::restore_temporary_index_snapshot(repo, name)?;
        }
        return drop_shelve_locked(repo, name);
    }
    let paths = crate::shelve::patch_member_paths(&patch)?;
    let result = match crate::shelve::apply_raw_shelve_differentiated(
        repo,
        &patch,
        name,
        &paths,
        None,
        Some(1),
        true,
        true,
        false,
        cancel,
    ) {
        Ok(result) if result.overall_status == PatchApplyStatus::Abort => {
            return Err(EngineError::Cancelled);
        }
        Ok(result) => result,
        Err(error) => return Err(error),
    };
    if crate::shelve::has_temporary_index_snapshot(repo)? {
        crate::shelve::restore_temporary_index_snapshot(repo, name)?;
    }
    if !result.failed_paths.is_empty() {
        if !result.applied_paths.is_empty() {
            consume_shelve_selection_locked(repo, name, &result.applied_paths)?;
        }
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: temporary restore could not apply: {}",
                result.failed_paths.join(", ")
            ),
        });
    }
    consume_shelve_selection_locked(repo, name, &paths)
}

fn shelve_locked(
    repo: &gix::Repository,
    name: String,
    paths: Vec<String>,
    preserve_index: bool,
) -> Result<(), EngineError> {
    use crate::shelve::{
        build_patch_tree, capture_index_entries_for_paths, load_shelves, reset_path_to_head,
        sanitize_ref_name, save_shelves, upsert_shelf_metadata,
    };
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;

    let name = name.trim().to_string();
    if name.is_empty() || paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: name and paths required".into(),
        });
    }
    if name
        .chars()
        .any(|character| matches!(character, '\t' | '\r' | '\n'))
    {
        return Err(EngineError::GitOperation {
            message: "shelve: name must not contain tabs or line breaks".into(),
        });
    }
    if preserve_index && crate::shelve::has_temporary_index_snapshot(repo)? {
        return Err(EngineError::GitOperation {
            message: "shelve: another temporary local-change preservation is pending".into(),
        });
    }
    let original_index_entries = if preserve_index {
        capture_index_entries_for_paths(repo, &paths)?
    } else {
        Vec::new()
    };
    let shelves = load_shelves(repo)?;
    let deleted_shelves = crate::shelve::load_deleted_shelves(repo)?;
    let ref_name = sanitize_ref_name(&name);
    if shelves
        .iter()
        .chain(deleted_shelves.iter())
        .any(|(candidate, _)| *candidate == name || sanitize_ref_name(candidate) == ref_name)
    {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: {name} already exists or conflicts with an existing shelf ref"
            ),
        });
    }
    let patch_tree = build_patch_tree(repo, &paths)?;
    let head_id = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let patch_id = repo
        .new_commit(&name, patch_tree, [head_id])
        .map_err(EngineError::from_gix)?
        .id;
    let full_name: gix::refs::FullName = format!("refs/shelved/{ref_name}")
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    repo.edit_reference(RefEdit {
        change: Change::Update {
            log: LogChange {
                mode: RefLog::AndReference,
                force_create_reflog: true,
                message: name.clone().into(),
            },
            expected: PreviousValue::MustNotExist,
            new: Target::Object(patch_id),
        },
        name: full_name.clone(),
        deref: false,
    })
    .map_err(EngineError::from_gix)?;

    let shelves_file = crate::shelve::shelves_file(repo);
    let original_shelves_file = std::fs::read(&shelves_file).ok();
    let metadata_file = crate::shelve::shelf_metadata_file(repo);
    let original_metadata_file = std::fs::read(&metadata_file).ok();
    let mut list = load_shelves(repo)?;
    list.insert(0, (name.clone(), patch_id));
    if let Err(error) = save_shelves(repo, &list)
        .and_then(|_| upsert_shelf_metadata(repo, &name, patch_id, current_unix_seconds(), &name))
    {
        match original_shelves_file {
            Some(bytes) => {
                let _ = std::fs::write(&shelves_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&shelves_file);
            }
        }
        match original_metadata_file {
            Some(bytes) => {
                let _ = std::fs::write(&metadata_file, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&metadata_file);
            }
        }
        let _ = repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::Any,
                log: RefLog::AndReference,
            },
            name: full_name,
            deref: false,
        });
        return Err(error);
    }
    if preserve_index {
        // Keep the Shelf and the user's worktree intact if metadata cannot be
        // written; only reset after the durable staged-state record exists.
        crate::shelve::write_temporary_index_snapshot(
            repo,
            &name,
            &paths,
            &original_index_entries,
        )?;
    }
    for path in &paths {
        reset_path_to_head(repo, path)?;
    }
    Ok(())
}

fn apply_imported_patch_differentiated_locked(
    repo: &gix::Repository,
    name: &str,
    patch: &str,
    paths: &[String],
    selections: &[crate::shelve::ShelvePatchSelection],
    base_path: &str,
    path_strip: u32,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<PatchApplyResult, EngineError> {
    if selections.is_empty() {
        crate::shelve::apply_raw_shelve_differentiated(
            repo,
            patch,
            name,
            paths,
            Some(base_path),
            Some(path_strip),
            false,
            false,
            true,
            cancel,
        )
    } else {
        crate::shelve::apply_raw_shelve_selections_differentiated(
            repo,
            patch,
            name,
            selections,
            Some(base_path),
            Some(path_strip),
            false,
            false,
            true,
            cancel,
        )
    }
}

#[uniffi::export]
impl Repository {
    /// Set the explicit external conversion policy for this Git root. The
    /// setting is kept per worktree so multiple open roots cannot change one
    /// another while auxiliary multi-root operations are running.
    pub fn set_external_conversion_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if let Some(workdir) = repo.workdir() {
            crate::attributes::set_worktree_external_conversion_enabled(workdir, enabled);
        }
        Ok(())
    }

    /// 当前仓库是否仍是 shallow clone。
    ///
    /// IntelliJ 只在 shallow repository 上显示 GitUnshallowRepositoryAction；
    /// 直接读取 gix 解析出的 shallow 文件，避免用提交数量或错误字符串猜测。
    pub fn is_shallow(&self) -> bool {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        repo.is_shallow()
    }

    /// Update the executable captured by this repository after project settings
    /// change. `None` restores the live application-level fallback.
    pub fn set_git_executable_override(&self, path: Option<String>) -> Result<(), EngineError> {
        let executable = path
            .map(|path| crate::gitprocess::validate_git_executable(&path))
            .transpose()?
            .map(PathBuf::from);
        self.inner
            .set_git_executable(executable)
            .map_err(|_| EngineError::GitOperation {
                message: "repository mutex poisoned".into(),
            })
    }

    /// 仓库的工作区根目录（裸仓库为 None）。
    pub fn workdir(&self) -> Option<String> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        repo.workdir().map(|p| p.display().to_string())
    }

    /// 仓库实际使用的 Git 管理目录。
    ///
    /// 对普通仓库是 `<workdir>/.git`，对 linked worktree 是其
    /// `.git/worktrees/<name>` 管理目录。UI 文件监视器必须监听这个真实
    /// 路径，不能把 `.git` 文件误当成目录。
    pub fn git_dir(&self) -> String {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        repo.git_dir().display().to_string()
    }

    /// 仓库显示名（工作区根目录的 basename，如 "arbor-engine"）；多仓库 UI 标签用。
    pub fn display_name(&self) -> String {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        repo.workdir()
            .and_then(|w| w.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }

    /// 按需列出工作区中的一个目录。根目录使用空字符串；.git 永远不返回。
    /// 隐藏文件仍会返回，UI 可自行以较弱的视觉层级呈现。
    pub fn list_dir(&self, relative: String) -> Result<Vec<DirEntry>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative_path = worktree_relative_path(&relative)?;
        let directory = worktree_root(&repo)?.join(&relative_path);
        let metadata = std::fs::metadata(&directory).map_err(EngineError::from_gix)?;
        if !metadata.is_dir() {
            return Err(EngineError::GitOperation {
                message: format!("not a directory: {relative}"),
            });
        }

        let prefix = relative.trim_matches('/');
        let mut entries = Vec::new();
        for item in std::fs::read_dir(&directory).map_err(EngineError::from_gix)? {
            let item = item.map_err(EngineError::from_gix)?;
            let name = item.file_name().to_string_lossy().into_owned();
            if name == ".git" {
                continue;
            }
            let item_path = if prefix.is_empty() {
                name.clone()
            } else {
                format!("{prefix}/{name}")
            };
            let is_dir = item.file_type().map_err(EngineError::from_gix)?.is_dir();
            entries.push(DirEntry {
                name,
                path: item_path,
                is_dir,
            });
        }
        entries.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(entries)
    }

    /// 列出指定 revision 中的目录。根目录使用空字符串。
    pub fn list_revision_dir(
        &self,
        revision: String,
        relative: String,
    ) -> Result<Vec<RevisionEntry>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let tree = revision_tree(&repo, &revision, &relative)?;
        let prefix = relative.trim_matches('/');
        let mut entries = Vec::new();
        for item in tree.iter() {
            let item = item.map_err(EngineError::from_gix)?;
            let name = item.inner.filename.to_string();
            let path = if prefix.is_empty() {
                name.clone()
            } else {
                format!("{prefix}/{name}")
            };
            entries.push(RevisionEntry {
                name,
                path,
                is_dir: item.inner.mode.is_tree(),
            });
        }
        entries.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(entries)
    }

    /// 读取工作区中的一个文件。二进制文件不转成文本，文本文件超过 1 MiB 时截断。
    pub fn read_worktree_file(&self, path: String) -> Result<FileContent, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative_path = worktree_relative_path(&path)?;
        let file_path = worktree_root(&repo)?.join(relative_path);
        let metadata = std::fs::metadata(&file_path).map_err(EngineError::from_gix)?;
        if !metadata.is_file() {
            return Err(EngineError::GitOperation {
                message: format!("not a file: {path}"),
            });
        }

        // 只读到上限+1，避免打开大日志/生成物时一次性分配整个文件。
        let mut file = std::fs::File::open(&file_path).map_err(EngineError::from_gix)?;
        let mut bytes = Vec::new();
        file.by_ref()
            .take((MAX_WORKTREE_TEXT_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(EngineError::from_gix)?;
        Ok(file_content_from_bytes(bytes, false))
    }

    /// 读取 Git index 中的 staged 文件版本，不触碰工作区或 index。
    /// 目录、冲突 index entry 和不在 index 中的路径都会返回错误。
    pub fn read_index_file(&self, path: String) -> Result<FileContent, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative_path = worktree_relative_path(&path)?;
        if relative_path.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "index path must be a file".into(),
            });
        }
        let index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let path_bytes = relative_path.to_string_lossy();
        let id = index
            .entry_by_path_and_stage(
                path_bytes.as_bytes().as_bstr(),
                gix::index::entry::Stage::Unconflicted,
            )
            .map(|entry| entry.id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("staged file not found in index: {path}"),
            })?;
        let object = repo.find_object(id).map_err(EngineError::from_gix)?;
        Ok(file_content_from_bytes(
            object.data.to_vec(),
            !object.kind.is_blob(),
        ))
    }

    /// 读取指定 revision 中的一个 blob。目录、子模块和缺失路径都会返回错误。
    pub fn read_revision_file(
        &self,
        revision: String,
        path: String,
    ) -> Result<FileContent, EngineError> {
        self.read_revision_file_with_mode(revision, path, GitContentTransformMode::None)
    }

    /// Read a file from a historical revision, optionally applying Git's
    /// checkout filters or textconv driver for the path. The transformed
    /// modes use system Git because gix does not execute Git filter/textconv
    /// drivers; stdout is redirected to a temporary file to preserve arbitrary
    /// bytes and avoid an unbounded in-memory process pipe.
    pub fn read_revision_file_with_mode(
        &self,
        revision: String,
        path: String,
        mode: GitContentTransformMode,
    ) -> Result<FileContent, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative_path = worktree_relative_path(&path)?;
        if relative_path.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "revision path must be a file".into(),
            });
        }
        let relative = relative_path.to_string_lossy().into_owned();

        match mode {
            GitContentTransformMode::None => {
                let spec = format!("{revision}:{relative}");
                let id = repo
                    .rev_parse_single(BStr::new(spec.as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach();
                let blob = repo.find_blob(id).map_err(EngineError::from_gix)?;
                Ok(file_content_from_bytes(blob.data.to_vec(), false))
            }
            GitContentTransformMode::Filters | GitContentTransformMode::Textconv => {
                let revision_id = repo
                    .rev_parse_single(BStr::new(revision.as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach();
                let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                    message: "transformed revision content requires a non-bare worktree".into(),
                })?;
                let transform_flag = match mode {
                    GitContentTransformMode::Filters => "--filters",
                    GitContentTransformMode::Textconv => "--textconv",
                    GitContentTransformMode::None => unreachable!(),
                };
                let output = tempfile::NamedTempFile::new().map_err(EngineError::from_gix)?;
                let object_spec = format!("{}:{relative}", revision_id.to_hex());
                let spec = GitCommandSpec::new(GitCommandCategory::Other, "cat-file")
                    .args([transform_flag, &format!("--path={relative}"), &object_spec])
                    .working_dir(workdir)
                    .timeout(std::time::Duration::from_secs(10))
                    .stdout_file(output.path());
                let outcome = crate::gitprocess::run_to_completion(&spec)?;
                if !outcome.success() {
                    return Err(outcome.into_error(&spec));
                }

                let mut bytes = Vec::new();
                std::fs::File::open(output.path())
                    .map_err(EngineError::from_gix)?
                    .take((MAX_WORKTREE_TEXT_BYTES + 1) as u64)
                    .read_to_end(&mut bytes)
                    .map_err(EngineError::from_gix)?;
                Ok(file_content_from_bytes(bytes, false))
            }
        }
    }

    /// 计算工作区状态：staged（index vs HEAD）+ unstaged（worktree vs index）+ untracked。
    /// 结果按 path 排序（gix 默认并行，顺序非确定，这里统一排序）。
    pub fn status(&self) -> Result<Vec<FileEntry>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::status::compute_status(&repo)
    }

    /// 返回指定路径范围的状态，用于文件树的增量刷新；目录参数会包含其子路径。
    pub fn status_paths(&self, paths: Vec<String>) -> Result<Vec<FileEntry>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::status::compute_status_paths(&repo, &paths)
    }

    /// Return the blob id Git would create for a worktree file after applying
    /// the path's clean filter. This is read-only and does not write an object
    /// or change the index. External VFS rename recovery uses it as a strong
    /// identity signal when FSEvents omitted the old endpoint.
    pub fn worktree_blob_id(&self, path: String) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative_path = worktree_relative_path(&path)?;
        if relative_path.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "worktree blob identity requires a file path".into(),
            });
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "worktree blob identity requires a non-bare worktree".into(),
        })?;
        let file_path = workdir.join(&relative_path);
        let metadata = std::fs::metadata(&file_path).map_err(EngineError::from_gix)?;
        if !metadata.is_file() {
            return Err(EngineError::GitOperation {
                message: format!("not a file: {path}"),
            });
        }

        let relative = relative_path.to_string_lossy().into_owned();
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            "hash-object",
        )
        .args(vec![format!("--path={relative}"), "--".into(), relative])
        .working_dir(workdir)
        .timeout(std::time::Duration::from_secs(10));
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        let object_id = outcome.stdout.trim();
        if object_id.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!("git hash-object returned no object id for {path}"),
            });
        }
        Ok(object_id.to_string())
    }

    /// Return the blob id stored for an unconflicted index entry. Missing
    /// paths, submodules, and conflict stages return `None`; this keeps the
    /// caller's rename matcher fail-closed instead of treating a tree or a
    /// partial conflict entry as file identity evidence.
    pub fn index_blob_id(&self, path: String) -> Result<Option<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative_path = worktree_relative_path(&path)?;
        if relative_path.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "index blob identity requires a file path".into(),
            });
        }
        let index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let path_bytes = relative_path.to_string_lossy();
        let Some(entry) = index.entry_by_path_and_stage(
            path_bytes.as_bytes().as_bstr(),
            gix::index::entry::Stage::Unconflicted,
        ) else {
            return Ok(None);
        };
        let object = repo.find_object(entry.id).map_err(EngineError::from_gix)?;
        if !object.kind.is_blob() {
            return Ok(None);
        }
        Ok(Some(entry.id.to_hex().to_string()))
    }

    /// Return the tracked paths known by the current Git index. Patch base
    /// matching uses this as the lightweight desktop equivalent of IntelliJ's
    /// VFS filename index; the UI still verifies each candidate on disk before
    /// offering it as an apply target.
    pub fn patch_index_paths(&self) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?;
        let mut paths = std::collections::BTreeSet::new();
        for entry in index.entries() {
            paths.insert(entry.path(&index).to_string());
        }
        Ok(paths.into_iter().collect())
    }

    // MARK: IntelliJ local Changelists

    /// 返回持久化的本地 Changelist 及其当前变更成员。它只描述 Changes
    /// Browser 的归属，不改变 Git index 或 worktree。
    pub fn changelist_list(&self) -> Result<Vec<crate::changelist::ChangeListInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let state = crate::changelist::load_change_lists(&repo)?;
        let status = crate::status::compute_status(&repo)?;
        let current_paths: Vec<String> = status.into_iter().map(|entry| entry.path).collect();
        Ok(crate::changelist::to_info(&state, &current_paths))
    }

    /// Build the local Changelist projection from a status snapshot that the
    /// caller already computed. Incremental worktree refreshes use this
    /// boundary so Changes Browser metadata does not trigger a second full
    /// repository status walk.
    pub fn changelist_list_for_paths(
        &self,
        current_paths: Vec<String>,
    ) -> Result<Vec<crate::changelist::ChangeListInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let state = crate::changelist::load_change_lists(&repo)?;
        Ok(crate::changelist::to_info(&state, &current_paths))
    }

    /// 创建一个空的 Changelist。新列表不会隐式修改当前活动列表或 Git 状态。
    pub fn changelist_create(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = name.trim().to_string();
        crate::changelist::validate_change_list_name(&name)?;
        let mut state = crate::changelist::load_change_lists(&repo)?;
        if state.lists.iter().any(|list| list.name == name) {
            return Err(EngineError::GitOperation {
                message: format!("changelist: list '{name}' already exists"),
            });
        }
        state.lists.push(crate::changelist::StoredChangeList {
            name,
            is_default: false,
        });
        crate::changelist::save_change_lists(&repo, &state)
    }

    /// Ensure a Changelist exists without changing the active list or Git
    /// state. IntelliJ uses this idempotent boundary when an unshelve has no
    /// explicit target and automatic Changelists are enabled.
    pub fn changelist_ensure(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = name.trim().to_string();
        crate::changelist::validate_change_list_name(&name)?;
        let mut state = crate::changelist::load_change_lists(&repo)?;
        if state.lists.iter().any(|list| list.name == name) {
            return Ok(());
        }
        state.lists.push(crate::changelist::StoredChangeList {
            name,
            is_default: false,
        });
        crate::changelist::save_change_lists(&repo, &state)
    }

    /// 重命名 Changelist；成员归属和列表顺序保持不变。
    pub fn changelist_rename(&self, old_name: String, new_name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let mut state = crate::changelist::load_change_lists(&repo)?;
        crate::changelist::rename(&mut state, old_name.trim(), new_name.trim())?;
        crate::changelist::save_change_lists(&repo, &state)
    }

    /// 删除非默认 Changelist。其成员回到默认列表，文件本身不受影响。
    pub fn changelist_delete(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let mut state = crate::changelist::load_change_lists(&repo)?;
        crate::changelist::delete(&mut state, name.trim())?;
        crate::changelist::save_change_lists(&repo, &state)
    }

    /// 切换 Changes Browser 的活动 Changelist。活动状态仅用于后续拖入/创建
    /// 行为，不改变 Git staging。
    pub fn changelist_activate(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let mut state = crate::changelist::load_change_lists(&repo)?;
        crate::changelist::activate(&mut state, name.trim())?;
        crate::changelist::save_change_lists(&repo, &state)
    }

    /// 把当前变更路径移动到目标 Changelist，并保持传入顺序作为目标列表
    /// 的成员追加顺序。
    pub fn changelist_move_paths(
        &self,
        paths: Vec<String>,
        target_name: String,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let status = crate::status::compute_status(&repo)?;
        let current: HashSet<String> = status.into_iter().map(|entry| entry.path).collect();
        let target_name = target_name.trim().to_string();
        let mut state = crate::changelist::load_change_lists(&repo)?;
        for path in &paths {
            if !current.contains(path) {
                return Err(EngineError::GitOperation {
                    message: format!("changelist: path is not a current change '{path}'"),
                });
            }
        }
        crate::changelist::move_paths(&mut state, &paths, &target_name)?;
        crate::changelist::save_change_lists(&repo, &state)
    }

    // MARK: IDX-001 三层 staging 模型

    /// 全量三层模型：每个变更文件的 HEAD/index/worktree 层级状态、
    /// 二进制/子模块降级标记、index 特殊标志与 index 修订。
    pub fn staging_model(&self) -> Result<crate::stagingmodel::StagingModel, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let status = crate::status::compute_status(&repo)?;
        crate::stagingmodel::build_model(&repo, &status)
    }

    /// index 文件修订（外部 Git 写入后变化，UI 增量刷新基准）。
    pub fn index_revision(&self) -> Result<crate::stagingmodel::IndexRevision, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::index_revision_of(&repo)
    }

    /// index 是否自上次修订后变化（外部 Git 修改 index 的检测）。
    pub fn index_changed_since(
        &self,
        previous: crate::stagingmodel::IndexRevision,
    ) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::index_changed_since(&repo, &previous)
    }

    /// 单文件三层 diff：未暂存（worktree↔index）+ 已暂存（index↔HEAD）。
    /// 任一侧为二进制时对应 FileDiff.binary=true（降级策略）。
    pub fn staging_diff(
        &self,
        path: String,
        ignore_whitespace: bool,
    ) -> Result<crate::stagingmodel::StagingFileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let unstaged = if path_bytes_differ(&repo, &path, DiffMode::WorktreeToIndex)? {
            Some(diff_file_inner(
                &repo,
                &path,
                DiffMode::WorktreeToIndex,
                ignore_whitespace,
            )?)
        } else {
            None
        };
        let staged = if path_bytes_differ(&repo, &path, DiffMode::IndexToHead)? {
            Some(diff_file_inner(
                &repo,
                &path,
                DiffMode::IndexToHead,
                ignore_whitespace,
            )?)
        } else {
            None
        };
        Ok(crate::stagingmodel::StagingFileDiff {
            path,
            unstaged,
            staged,
        })
    }

    /// 返回 HEAD/index/worktree 三层原始内容，供三栏 staging 对比使用。
    /// 该接口只读，不修改 index 或工作区；缺失的一侧用 `present=false` 表示。
    pub fn staging_file_versions(&self, path: String) -> Result<StagingFileVersions, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative = worktree_relative_path(&path)?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "staging versions require a file path".into(),
            });
        }

        let head = {
            let head_path = head_path_for_worktree_path(&repo, &path)?;
            let spec = format!("HEAD:{head_path}");
            match repo.rev_parse_single(BStr::new(spec.as_bytes())) {
                Ok(id) => staging_object_content(&repo, id.detach())?,
                Err(_) => staging_version_content(None, false),
            }
        };
        let staged = {
            let index = repo
                .index_or_load_from_head_or_empty()
                .map_err(EngineError::from_gix)?
                .into_owned();
            match index.entry_by_path(relative.to_string_lossy().as_bytes().as_bstr()) {
                Some(entry) => staging_object_content(&repo, entry.id)?,
                None => staging_version_content(None, false),
            }
        };
        let local = {
            let file_path = worktree_root(&repo)?.join(relative);
            match std::fs::symlink_metadata(&file_path) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    let target = std::fs::read_link(file_path).map_err(EngineError::from_gix)?;
                    staging_version_content(
                        Some(target.to_string_lossy().into_owned().into_bytes()),
                        false,
                    )
                }
                Ok(metadata) if metadata.is_file() => staging_version_content(
                    Some(std::fs::read(file_path).map_err(EngineError::from_gix)?),
                    false,
                ),
                Ok(_) => staging_version_content(Some(Vec::new()), true),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    staging_version_content(None, false)
                }
                Err(error) => return Err(EngineError::from_gix(error)),
            }
        };
        Ok(StagingFileVersions {
            path,
            head,
            staged,
            local,
        })
    }

    /// 仅暂存已跟踪的工作区变更（等价 `git add -u` 的路径语义）。
    ///
    /// 未跟踪文件不会被加入 index；删除的已跟踪文件仍会被记录为删除。
    /// 这是 IntelliJ `Git.Stage.Add.Tracked` 的引擎级语义，供 staging
    /// 工具栏直接调用，而不是由 Swift 层自行拼接路径。
    pub fn stage_tracked(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let paths: Vec<String> = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                entry.unstaged != crate::status::ChangeKind::Unchanged
                    && entry.unstaged != crate::status::ChangeKind::Untracked
                    && entry.unstaged != crate::status::ChangeKind::Ignored
            })
            .map(|entry| entry.path)
            .collect();
        drop(repo);
        for path in paths {
            self.stage(path)?;
        }
        Ok(())
    }

    /// 暂存所有变更（等价 `git add -A`）。
    pub fn stage_all(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let status = crate::status::compute_status(&repo)?;
        let paths: Vec<String> = status
            .into_iter()
            .filter(|e| {
                e.unstaged != crate::status::ChangeKind::Unchanged
                    && e.unstaged != crate::status::ChangeKind::Ignored
            })
            .map(|e| e.path)
            .collect();
        drop(repo);
        for path in paths {
            self.stage(path)?;
        }
        Ok(())
    }

    /// 取消暂存所有变更（等价 `git restore --staged .`）。
    pub fn unstage_all(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let status = crate::status::compute_status(&repo)?;
        let paths: Vec<String> = status
            .into_iter()
            .filter(|e| e.staged != crate::status::ChangeKind::Unchanged)
            .map(|e| e.path)
            .collect();
        drop(repo);
        for path in paths {
            self.unstage(path)?;
        }
        Ok(())
    }

    /// 「Add to Git / Ignore」入口：把规则追加到工作区 `.gitignore`。
    /// 返回实际写入的规则；已有同名规则由 git 的叠加语义处理。
    pub fn add_to_gitignore(&self, rule: String) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::append_gitignore(&repo, &rule)
    }

    /// Append multiple rules to the worktree `.gitignore` in one write.
    pub fn add_to_gitignore_rules(&self, rules: Vec<String>) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::append_gitignore_rules(&repo, &rules)
    }

    /// Append a rule to a selected or newly-created suitable `.gitignore` for a target path.
    pub fn add_to_gitignore_at(
        &self,
        rule: String,
        ignore_file: String,
        target_path: String,
    ) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::append_gitignore_at(&repo, &rule, &ignore_file, &target_path)
    }

    /// Append multiple rules to one suitable `.gitignore` after validating
    /// every selected target path.
    pub fn add_to_gitignore_at_paths(
        &self,
        rules: Vec<String>,
        ignore_file: String,
        target_paths: Vec<String>,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::append_gitignore_rules_at(&repo, &rules, &ignore_file, &target_paths)
    }

    /// 「Exclude」入口：把路径追加到 `.git/info/exclude`（不入库）。
    pub fn exclude_path(&self, path: String) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::stagingmodel::append_info_exclude(&repo, &path)
    }

    /// 返回 ignored 路径及其命中的规则来源，供 Changes/文件树解释为什么隐藏。
    pub fn ignored_rules(&self) -> Result<Vec<crate::status::IgnoreRuleInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::status::ignored_rule_info(&repo)
    }

    /// 暂存单个路径（等价 `git add <path>`，含删除场景）。
    pub fn stage(&self, path: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative = worktree_relative_path(&path)?;
        let path = relative.to_string_lossy().into_owned();
        let mut index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let workdir = repo
            .workdir()
            .ok_or_else(|| EngineError::GitOperation {
                message: "bare repository has no worktree".into(),
            })?
            .to_path_buf();
        let file_path = workdir.join(&path);
        let path_bstr = path.as_bytes().as_bstr();
        let existing_index_entry =
            index.entry_index_by_path_and_stage(path_bstr, gix::index::entry::Stage::Unconflicted);
        let existing_mode =
            existing_index_entry.map(|index_entry| index.entries()[index_entry].mode);

        match gix::index::fs::Metadata::from_path_no_follow(&file_path) {
            Ok(meta)
                if meta.is_dir()
                    && existing_mode
                        .is_some_and(|mode| mode.contains(gix::index::entry::Mode::COMMIT)) =>
            {
                // IntelliJ stages a changed submodule through its parent
                // repository as a gitlink. The worktree path is a directory,
                // so treating it like an ordinary file would try to read the
                // directory bytes and fail. Read only the nested repository's
                // HEAD and replace the existing 160000 index entry.
                let nested_repo = gix::open(&file_path).map_err(EngineError::from_gix)?;
                let nested_workdir = nested_repo
                    .workdir()
                    .ok_or_else(|| EngineError::GitOperation {
                        message: format!("submodule path is not an initialized worktree: {path}"),
                    })?
                    .canonicalize()
                    .map_err(EngineError::from_gix)?;
                let expected_workdir = file_path.canonicalize().map_err(EngineError::from_gix)?;
                if nested_workdir != expected_workdir {
                    return Err(EngineError::GitOperation {
                        message: format!("submodule path is not an initialized repository: {path}"),
                    });
                }
                let nested_head = nested_repo
                    .head_id()
                    .map_err(EngineError::from_gix)?
                    .detach();
                let index_entry =
                    existing_index_entry.ok_or_else(|| EngineError::GitOperation {
                        message: format!("submodule index entry disappeared: {path}"),
                    })?;
                let stat =
                    gix::index::entry::Stat::from_fs(&meta).map_err(EngineError::from_gix)?;
                let entry = &mut index.entries_mut()[index_entry];
                entry.stat = stat;
                entry.id = nested_head;
                entry.mode = gix::index::entry::Mode::COMMIT;
            }
            Ok(meta) if meta.is_dir() => {
                return Err(EngineError::GitOperation {
                    message: format!("cannot stage a directory as a regular file: {path}"),
                });
            }
            Ok(meta) => {
                // 文件存在：写 blob + upsert 索引条目
                let (blob_id, mode) = if meta.is_symlink() {
                    let target = std::fs::read_link(&file_path).map_err(EngineError::from_gix)?;
                    let id = repo
                        .write_blob(target.to_string_lossy().as_bytes())
                        .map_err(EngineError::from_gix)?
                        .detach();
                    (id, gix::index::entry::Mode::SYMLINK)
                } else {
                    let bytes = std::fs::read(&file_path).map_err(EngineError::from_gix)?;
                    let bytes = crate::attributes::clean_worktree_bytes(&workdir, &path, &bytes)?;
                    let id = repo
                        .write_blob(&bytes)
                        .map_err(EngineError::from_gix)?
                        .detach();
                    let mode = if meta.is_executable() {
                        gix::index::entry::Mode::FILE_EXECUTABLE
                    } else {
                        gix::index::entry::Mode::FILE
                    };
                    (id, mode)
                };
                let stat =
                    gix::index::entry::Stat::from_fs(&meta).map_err(EngineError::from_gix)?;
                match existing_index_entry {
                    Some(i) => {
                        let e = &mut index.entries_mut()[i];
                        e.stat = stat;
                        e.id = blob_id;
                        e.mode = mode;
                    }
                    None => {
                        index.dangerously_push_entry(
                            stat,
                            blob_id,
                            gix::index::entry::Flags::empty(),
                            mode,
                            path_bstr,
                        );
                        index.sort_entries();
                    }
                }
            }
            Err(_) => {
                // 文件不存在：暂存删除（移除索引条目）
                if let Some(i) = index.entry_index_by_path_and_stage(
                    path_bstr,
                    gix::index::entry::Stage::Unconflicted,
                ) {
                    index.remove_entry_at_index(i);
                }
            }
        }
        index.remove_tree();
        index
            .write(gix::index::write::Options::default())
            .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 将外部 VFS 创建的文件以 IntelliJ staging-area 的方式加入 index：
    /// 写入一个空 blob，而不是把当前工作区内容完整暂存。这样 Git 会把
    /// 文件报告为 `AM`，staged 侧显示新增、unstaged 侧保留真实内容。
    /// 这对应 IntelliJ `GitFileUtils.addPathsToIndex`，不要与用户主动执行
    /// 的 `git add -N`（`stage_without_content`）混用。
    pub fn stage_empty_blob_paths(&self, paths: Vec<String>) -> Result<(), EngineError> {
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "staging-area add requires one or more file paths".into(),
            });
        }
        let relatives = paths
            .iter()
            .map(|path| worktree_relative_path(path))
            .collect::<Result<Vec<_>, _>>()?;
        if relatives.iter().any(|path| path.as_os_str().is_empty()) {
            return Err(EngineError::GitOperation {
                message: "staging-area add requires file paths".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?;
        let mut metadata = Vec::with_capacity(relatives.len());
        for relative in &relatives {
            let file_path = workdir.join(relative);
            let meta = gix::index::fs::Metadata::from_path_no_follow(&file_path)
                .map_err(EngineError::from_gix)?;
            if !meta.is_file() && !meta.is_symlink() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "staging-area add requires a file: {}",
                        relative.to_string_lossy()
                    ),
                });
            }
            metadata.push(meta);
        }

        let mut index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let empty_blob = repo
            .write_blob(&[])
            .map_err(EngineError::from_gix)?
            .detach();

        for (relative, meta) in relatives.iter().zip(metadata.iter()) {
            let path_bstr = relative.to_string_lossy();
            let path_bstr = path_bstr.as_bytes().as_bstr();
            let stat = gix::index::entry::Stat::from_fs(meta).map_err(EngineError::from_gix)?;
            match index
                .entry_index_by_path_and_stage(path_bstr, gix::index::entry::Stage::Unconflicted)
            {
                Some(index_entry) => {
                    let entry = &mut index.entries_mut()[index_entry];
                    entry.stat = stat;
                    entry.id = empty_blob;
                    entry.mode = gix::index::entry::Mode::FILE;
                }
                None => {
                    index.dangerously_push_entry(
                        stat,
                        empty_blob,
                        gix::index::entry::Flags::empty(),
                        gix::index::entry::Mode::FILE,
                        path_bstr,
                    );
                }
            }
        }
        index.remove_tree();
        index.sort_entries();
        index
            .write(gix::index::write::Options::default())
            .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 将未跟踪路径以 intent-to-add 形式加入索引（等价 `git add -N -- <path>`）。
    /// 这只记录路径，不把当前工作区内容写入索引，适合先让 diff/staging 视图显示新文件。
    pub fn stage_without_content(&self, path: String) -> Result<(), EngineError> {
        let relative = worktree_relative_path(&path)?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "intent-to-add requires a file path".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?;
        let file_path = workdir.join(&relative);
        let metadata = std::fs::metadata(&file_path).map_err(EngineError::from_gix)?;
        if !metadata.is_file() {
            return Err(EngineError::GitOperation {
                message: format!("intent-to-add requires a file: {path}"),
            });
        }
        let relative = relative.to_string_lossy().into_owned();
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            "add",
        )
        .args(["-N".to_string(), "--".to_string(), relative])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 将多个未跟踪文件以 intent-to-add 形式一次加入索引（等价
    /// `git add -N -- <paths>`）。索引只记录路径，不写入当前工作区内容。
    pub fn stage_without_content_paths(&self, paths: Vec<String>) -> Result<(), EngineError> {
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "intent-to-add requires one or more file paths".into(),
            });
        }
        let relatives = paths
            .iter()
            .map(|path| worktree_relative_path(path))
            .collect::<Result<Vec<_>, _>>()?;
        if relatives.iter().any(|path| path.as_os_str().is_empty()) {
            return Err(EngineError::GitOperation {
                message: "intent-to-add requires file paths".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?;
        for relative in &relatives {
            let file_path = workdir.join(relative);
            let metadata = std::fs::metadata(&file_path).map_err(EngineError::from_gix)?;
            if !metadata.is_file() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "intent-to-add requires a file: {}",
                        relative.to_string_lossy()
                    ),
                });
            }
        }
        let mut args = vec!["-N".to_string(), "--".to_string()];
        args.extend(
            relatives
                .into_iter()
                .map(|path| path.to_string_lossy().into_owned()),
        );
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            "add",
        )
        .args(args)
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 取消暂存单个路径（等价 `git restore --staged <path>`，不动工作区文件）。
    pub fn unstage(&self, path: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let mut index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let path_bstr = path.as_bytes().as_bstr();
        let head_tree_id = repo
            .head_tree_id_or_empty()
            .map_err(EngineError::from_gix)?;
        let head_index = repo
            .index_from_tree(&head_tree_id)
            .map_err(EngineError::from_gix)?;

        match head_index.entry_by_path(path_bstr) {
            Some(head_entry) => {
                // HEAD 中有：把索引条目重置为 HEAD 版本（stat 置默认，racy clean 让 status 重算）
                match index.entry_index_by_path_and_stage(
                    path_bstr,
                    gix::index::entry::Stage::Unconflicted,
                ) {
                    Some(i) => {
                        let e = &mut index.entries_mut()[i];
                        e.id = head_entry.id;
                        e.mode = head_entry.mode;
                        e.stat = gix::index::entry::Stat::default();
                    }
                    None => {
                        index.dangerously_push_entry(
                            gix::index::entry::Stat::default(),
                            head_entry.id,
                            gix::index::entry::Flags::empty(),
                            head_entry.mode,
                            path_bstr,
                        );
                        index.sort_entries();
                    }
                }
            }
            None => {
                // HEAD 中没有（曾是未跟踪被暂存）：移除条目
                if let Some(i) = index.entry_index_by_path_and_stage(
                    path_bstr,
                    gix::index::entry::Stage::Unconflicted,
                ) {
                    index.remove_entry_at_index(i);
                }
            }
        }
        index.remove_tree();
        index
            .write(gix::index::write::Options::default())
            .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 用当前暂存区写一个提交，返回新 commit id（hex）。提交信息自动补尾换行。
    /// author/committer 取 git config；无身份时 gix 返回 AuthorMissing/CommitterMissing。
    pub fn commit(&self, message: String, skip_hooks: bool) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let parents: Vec<gix::hash::ObjectId> =
            if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
                Vec::new()
            } else {
                vec![repo
                    .head_commit()
                    .map_err(EngineError::from_gix)?
                    .id()
                    .detach()]
            };
        let commit_id = commit_inner(&repo, &message, &parents, skip_hooks)?;
        Ok(commit_id.to_hex().to_string())
    }

    /// 读取当前仓库的提交身份与签名配置。
    pub fn git_identity(&self) -> Result<GitIdentity, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "git identity requires a non-bare worktree".into(),
        })?;
        Ok(GitIdentity {
            name: git_config_effective_value(workdir, "user.name")?,
            email: git_config_effective_value(workdir, "user.email")?,
            signing_key: git_config_effective_value(workdir, "user.signingkey")?,
            signing_format: git_config_effective_value(workdir, "gpg.format")?,
            sign_commits: git_config_effective_value(workdir, "commit.gpgsign")?.is_some_and(
                |value| {
                    matches!(
                        value.to_ascii_lowercase().as_str(),
                        "true" | "yes" | "on" | "1"
                    )
                },
            ),
        })
    }

    /// 写入仓库级提交身份与签名配置；空字符串会清除对应配置。
    pub fn set_git_identity(
        &self,
        name: String,
        email: String,
        signing_key: Option<String>,
        signing_format: Option<String>,
        sign_commits: bool,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "git identity requires a non-bare worktree".into(),
        })?;
        set_git_config_value(workdir, "user.name", &name)?;
        set_git_config_value(workdir, "user.email", &email)?;
        set_git_config_value(
            workdir,
            "commit.gpgsign",
            if sign_commits { "true" } else { "false" },
        )?;
        match signing_key.filter(|value| !value.trim().is_empty()) {
            Some(value) => set_git_config_value(workdir, "user.signingkey", value.trim())?,
            None => unset_git_config_value(workdir, "user.signingkey")?,
        }
        match signing_format.filter(|value| !value.trim().is_empty()) {
            Some(value) => set_git_config_value(workdir, "gpg.format", value.trim())?,
            None => unset_git_config_value(workdir, "gpg.format")?,
        }
        Ok(())
    }

    /// 写入全局 user.name/user.email，并将本仓库的同名 local 覆盖移除；
    /// signing 配置仍保持 repository-local，避免无意扩大签名策略的作用域。
    pub fn set_git_identity_with_global_name_email(
        &self,
        name: String,
        email: String,
        signing_key: Option<String>,
        signing_format: Option<String>,
        sign_commits: bool,
    ) -> Result<(), EngineError> {
        if name.trim().is_empty() || email.trim().is_empty() {
            return Err(EngineError::GitOperation {
                message: "global Git identity requires both name and email".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "git identity requires a non-bare worktree".into(),
        })?;
        set_git_config_value_scope(workdir, "user.name", name.trim(), "--global")?;
        set_git_config_value_scope(workdir, "user.email", email.trim(), "--global")?;
        unset_git_config_value(workdir, "user.name")?;
        unset_git_config_value(workdir, "user.email")?;
        set_git_config_value(
            workdir,
            "commit.gpgsign",
            if sign_commits { "true" } else { "false" },
        )?;
        match signing_key.filter(|value| !value.trim().is_empty()) {
            Some(value) => set_git_config_value(workdir, "user.signingkey", value.trim())?,
            None => unset_git_config_value(workdir, "user.signingkey")?,
        }
        match signing_format.filter(|value| !value.trim().is_empty()) {
            Some(value) => set_git_config_value(workdir, "gpg.format", value.trim())?,
            None => unset_git_config_value(workdir, "gpg.format")?,
        }
        Ok(())
    }

    /// 使用系统 Git 执行带 author/committer、签名和 sign-off 选项的提交。
    /// 不带扩展选项的旧入口仍使用 gix，保持现有 hooks 与测试语义。
    pub fn commit_with_options(
        &self,
        message: String,
        skip_hooks: bool,
        author_name: Option<String>,
        author_email: Option<String>,
        committer_name: Option<String>,
        committer_email: Option<String>,
        sign_key: Option<String>,
        sign_off: bool,
        co_authors: Vec<String>,
        amend: bool,
    ) -> Result<String, EngineError> {
        if author_name.is_some() != author_email.is_some()
            || committer_name.is_some() != committer_email.is_some()
        {
            return Err(EngineError::GitOperation {
                message: "author and committer require both name and email".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "commit requires a non-bare worktree".into(),
        })?;
        let message = append_coauthor_trailers(message, &co_authors);
        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        command.args(["commit", "--message", &message]);
        if amend {
            command.arg("--amend");
        }
        if skip_hooks {
            command.arg("--no-verify");
        }
        if sign_off {
            command.arg("--signoff");
        }
        if let (Some(name), Some(email)) = (author_name, author_email) {
            command.args(["--author", &format!("{} <{}>", name.trim(), email.trim())]);
        }
        if let Some(key) = sign_key.filter(|value| !value.trim().is_empty()) {
            command.arg(format!("--gpg-sign={}", key.trim()));
        }
        if let (Some(name), Some(email)) = (committer_name, committer_email) {
            command.env("GIT_COMMITTER_NAME", name.trim());
            command.env("GIT_COMMITTER_EMAIL", email.trim());
        }
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!("git commit failed: {}", command_output_message(&output)),
            });
        }
        let id = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["rev-parse", "HEAD"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        Ok(String::from_utf8_lossy(&id.stdout).trim().to_string())
    }

    /// Commit only the selected staged paths while preserving the real index.
    ///
    /// A temporary index is materialized from HEAD and receives the selected
    /// entries from the real index. This is intentionally not implemented as
    /// \`git commit --only\`: that form reads the worktree and would commit
    /// unstaged edits when a file is partially staged.
    pub fn commit_with_options_paths(
        &self,
        message: String,
        paths: Vec<String>,
        skip_hooks: bool,
        author_name: Option<String>,
        author_email: Option<String>,
        committer_name: Option<String>,
        committer_email: Option<String>,
        sign_key: Option<String>,
        sign_off: bool,
        co_authors: Vec<String>,
        amend: bool,
    ) -> Result<String, EngineError> {
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected commit requires one or more paths".into(),
            });
        }
        if author_name.is_some() != author_email.is_some()
            || committer_name.is_some() != committer_email.is_some()
        {
            return Err(EngineError::GitOperation {
                message: "author and committer require both name and email".into(),
            });
        }

        let normalized_paths = paths
            .iter()
            .map(|path| {
                let relative = worktree_relative_path(path)?;
                if relative.as_os_str().is_empty() {
                    return Err(EngineError::GitOperation {
                        message: "selected commit requires file paths".into(),
                    });
                }
                Ok(relative.to_string_lossy().into_owned())
            })
            .collect::<Result<Vec<_>, EngineError>>()?;
        let normalized_paths = normalized_paths
            .into_iter()
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let mut normalized_paths = normalized_paths;
        normalized_paths.sort();

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "selected commit requires a non-bare worktree".into(),
        })?;
        let temporary = tempfile::tempdir().map_err(EngineError::from_gix)?;
        let temporary_index = temporary.path().join("index");

        let head_is_unborn = repo.head().map_err(EngineError::from_gix)?.is_unborn();
        let read_tree_args = if head_is_unborn {
            vec!["read-tree".to_string(), "--empty".to_string()]
        } else {
            vec!["read-tree".to_string(), "HEAD".to_string()]
        };
        let output = run_git_with_index(workdir, &read_tree_args, Some(&temporary_index))?;
        ensure_git_command_success(&output, "git read-tree")?;

        let current_index = run_git_with_index(
            workdir,
            &[
                "ls-files".to_string(),
                "--stage".to_string(),
                "-z".to_string(),
            ],
            None,
        )?;
        ensure_git_command_success(&current_index, "git ls-files")?;
        let current_entries = parse_index_stage_records(&current_index.stdout)?;

        let temporary_index_paths = run_git_with_index(
            workdir,
            &["ls-files".to_string(), "-z".to_string()],
            Some(&temporary_index),
        )?;
        ensure_git_command_success(&temporary_index_paths, "git ls-files temporary index")?;
        let head_paths = parse_nul_paths(&temporary_index_paths.stdout)?;

        for path in &normalized_paths {
            match current_entries.get(path) {
                Some(entries) if entries.len() != 1 || entries[0].stage != 0 => {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "selected commit cannot include unresolved index stages: {path}"
                        ),
                    });
                }
                Some(entries) => {
                    let entry = &entries[0];
                    let cache_info = format!("{},{},{}", entry.mode, entry.object, path);
                    let update_index_args = vec![
                        "update-index".to_string(),
                        "--add".to_string(),
                        "--cacheinfo".to_string(),
                        cache_info,
                    ];
                    let output =
                        run_git_with_index(workdir, &update_index_args, Some(&temporary_index))?;
                    ensure_git_command_success(&output, "git update-index")?;
                }
                None if head_paths.contains(path) => {
                    let remove_index_args = vec![
                        "update-index".to_string(),
                        "--force-remove".to_string(),
                        "--".to_string(),
                        path.clone(),
                    ];
                    let output =
                        run_git_with_index(workdir, &remove_index_args, Some(&temporary_index))?;
                    ensure_git_command_success(&output, "git update-index --force-remove")?;
                }
                None => {}
            }
        }

        let message = append_coauthor_trailers(message, &co_authors);
        let mut commit_args = vec!["commit".to_string(), "--message".to_string(), message];
        if amend {
            commit_args.push("--amend".to_string());
        }
        if skip_hooks {
            commit_args.push("--no-verify".to_string());
        }
        if sign_off {
            commit_args.push("--signoff".to_string());
        }
        if let (Some(name), Some(email)) = (author_name, author_email) {
            commit_args.push("--author".to_string());
            commit_args.push(format!("{} <{}>", name.trim(), email.trim()));
        }
        if let Some(key) = sign_key.filter(|value| !value.trim().is_empty()) {
            commit_args.push(format!("--gpg-sign={}", key.trim()));
        }
        let mut commit_environment = Vec::new();
        if let (Some(name), Some(email)) = (committer_name, committer_email) {
            commit_environment.push(("GIT_COMMITTER_NAME".to_string(), name.trim().to_string()));
            commit_environment.push(("GIT_COMMITTER_EMAIL".to_string(), email.trim().to_string()));
        }

        let output = run_git_with_index_and_environment(
            workdir,
            &commit_args,
            Some(&temporary_index),
            &commit_environment,
        )?;
        ensure_git_command_success(&output, "git commit")?;

        let id = run_git_with_index(
            workdir,
            &["rev-parse".to_string(), "HEAD".to_string()],
            None,
        )?;
        ensure_git_command_success(&id, "git rev-parse HEAD")?;
        let commit_id = String::from_utf8_lossy(&id.stdout).trim().to_string();
        if commit_id.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected commit completed without a HEAD revision".into(),
            });
        }
        Ok(commit_id)
    }

    /// 在当前仓库根目录执行一个提交前检查命令。命令与参数按 argv 传递，绝不经过 shell。
    /// 默认超时 60 秒；需要短超时测试或调用方策略时使用 `run_check_command_with_timeout`。
    // MARK: COMMIT-001 内置检查与签名配置

    /// 内置提交检查：身份缺失（阻塞）、未解决冲突（阻塞）、detached HEAD、
    /// 大文件、CRLF 混合（警告）。与 before-commit 命令检查互补。
    pub fn commit_checks(&self) -> Result<Vec<crate::checks::CommitCheckResult>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::checks::run_commit_checks(
            &repo,
            crate::checks::DEFAULT_COMMIT_CHECK_LARGE_FILE_LIMIT_BYTES,
            None,
        )
    }

    /// Run built-in commit checks with the caller's project large-file limit.
    pub fn commit_checks_with_large_file_limit(
        &self,
        max_file_size_bytes: u64,
    ) -> Result<Vec<crate::checks::CommitCheckResult>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::checks::run_commit_checks(&repo, max_file_size_bytes, None)
    }

    /// Run built-in commit checks only for the paths selected for a commit.
    pub fn commit_checks_with_large_file_limit_for_paths(
        &self,
        max_file_size_bytes: u64,
        paths: Vec<String>,
    ) -> Result<Vec<crate::checks::CommitCheckResult>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::checks::run_commit_checks(&repo, max_file_size_bytes, Some(&paths))
    }

    /// Apply IntelliJ's recommended macOS CRLF fix before committing.
    pub fn set_global_core_autocrlf(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "core.autocrlf requires a non-bare worktree".into(),
        })?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["config", "--global", "core.autocrlf", "input"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git config --global core.autocrlf failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        Ok(())
    }

    /// 已配置的 credential helper 检测（AUTH-001 收口）。
    pub fn credential_helpers(
        &self,
    ) -> Result<Vec<crate::checks::CredentialHelperInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::checks::credential_helpers(&repo)
    }

    /// Read-only diagnostics for the user's OpenSSH authentication agent.
    /// The probe reports only reachability and identity count; it never
    /// exposes key fingerprints or agent command output.
    pub fn ssh_agent_diagnostics(&self) -> Result<crate::checks::SshAgentDiagnostics, EngineError> {
        let _repo = self.inner.lock().expect("repo mutex poisoned");
        crate::checks::ssh_agent_diagnostics()
    }

    /// 读取仓库级 `credential.helper` 多值配置。
    ///
    /// 这里只返回 local scope；用户级 helper 仍由
    /// [`credential_helpers`](Self::credential_helpers) 作为诊断展示，避免
    /// 设置页误把全局配置当成当前仓库的可编辑值。
    pub fn credential_helper_config(&self) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "credential helper settings require a non-bare worktree".into(),
        })?;
        git_config_values(workdir, "credential.helper")
    }

    /// 替换仓库级 `credential.helper` 多值配置。
    ///
    /// 每个非空字符串作为一个 Git config value 通过 argv 写入，不经过
    /// shell；空列表清除当前仓库的 local override，但不会修改用户级配置。
    pub fn set_credential_helper_config(&self, helpers: Vec<String>) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "credential helper settings require a non-bare worktree".into(),
        })?;
        let values = helpers
            .into_iter()
            .map(|helper| {
                let value = helper.trim().to_string();
                if value.contains('\0') || value.contains('\n') || value.contains('\r') {
                    return Err(EngineError::GitOperation {
                        message:
                            "credential helper values cannot contain NUL or newline characters"
                                .into(),
                    });
                }
                Ok(value)
            })
            .filter_map(|value| match value {
                Ok(value) if !value.is_empty() => Some(Ok(value)),
                Ok(_) => None,
                Err(error) => Some(Err(error)),
            })
            .collect::<Result<Vec<_>, _>>()?;

        unset_git_config_values(workdir, "credential.helper")?;
        for value in values {
            add_git_config_value(workdir, "credential.helper", &value)?;
        }
        Ok(())
    }

    /// 签名配置（commit.gpgsign / gpg.format / user.signingkey）。
    pub fn signing_config(&self) -> Result<crate::checks::SigningConfig, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::checks::signing_config(&repo)
    }

    pub fn run_check_command(
        &self,
        command: String,
        args: Vec<String>,
    ) -> Result<CheckOutcome, EngineError> {
        self.run_check_command_with_timeout(command, args, 60)
    }

    /// 执行提交前检查命令，timeout_seconds 为最小 1 秒。
    pub fn run_check_command_with_timeout(
        &self,
        command: String,
        args: Vec<String>,
        timeout_seconds: u32,
    ) -> Result<CheckOutcome, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "check command requires a non-bare repository".into(),
        })?;
        crate::checks::run(
            workdir,
            &command,
            &args,
            std::time::Duration::from_secs(timeout_seconds.max(1) as u64),
        )
    }

    /// 提交后立即推送。没有远程或当前处于 detached HEAD 时只提交并返回 pushed=false。
    pub fn commit_and_push(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        skip_hooks: bool,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_options(message, remote, branch, force, skip_hooks, false)
    }

    /// 提交并推送的完整入口；`set_upstream` 对应首次发布当前分支。
    pub fn commit_and_push_with_options(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        skip_hooks: bool,
        set_upstream: bool,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_options_inner(
            message,
            remote,
            branch,
            force,
            false,
            skip_hooks,
            set_upstream,
            None,
            None,
        )
    }

    /// 带认证代理的完整提交并推送入口。提交完成后，推送阶段复用同一
    /// askpass broker，避免 Commit and Push 与普通 Push 的认证行为分叉。
    pub fn commit_and_push_with_options_with_auth(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        force_with_lease: bool,
        skip_hooks: bool,
        set_upstream: bool,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_options_inner(
            message,
            remote,
            branch,
            force,
            force_with_lease,
            skip_hooks,
            set_upstream,
            Some(broker),
            None,
        )
    }

    /// 可取消的认证提交并推送入口。
    pub fn commit_and_push_with_options_with_auth_and_cancel(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        force_with_lease: bool,
        skip_hooks: bool,
        set_upstream: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_options_inner(
            message,
            remote,
            branch,
            force,
            force_with_lease,
            skip_hooks,
            set_upstream,
            Some(broker),
            Some(cancel),
        )
    }

    fn commit_and_push_with_options_inner(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        force_with_lease: bool,
        skip_hooks: bool,
        set_upstream: bool,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<CommitPushOutcome, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let parents: Vec<gix::hash::ObjectId> =
            if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
                Vec::new()
            } else {
                vec![repo
                    .head_commit()
                    .map_err(EngineError::from_gix)?
                    .id()
                    .detach()]
            };
        let commit_id = commit_inner(&repo, &message, &parents, skip_hooks)?;
        let remotes = list_remotes(&repo)?;
        let Some(remote_name) = remote.or_else(|| remotes.first().map(|r| r.name.clone())) else {
            return Ok(CommitPushOutcome {
                commit_id: commit_id.to_hex().to_string(),
                pushed: false,
            });
        };
        let current_branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        let Some(branch_name) = branch.or(current_branch) else {
            return Ok(CommitPushOutcome {
                commit_id: commit_id.to_hex().to_string(),
                pushed: false,
            });
        };
        if let Err(error) = push_inner(
            &repo,
            &remote_name,
            &branch_name,
            force,
            force_with_lease,
            set_upstream,
            None,
            false,
            broker.as_deref(),
            cancel
                .as_deref()
                .map(crate::gitprocess::GitCancelHandle::token),
        ) {
            return Err(match error {
                EngineError::PushRejected {
                    kind,
                    remote,
                    branch,
                    message: push_message,
                } => EngineError::PushRejected {
                    kind,
                    remote,
                    branch,
                    message: format!("commit {} created; {push_message}", commit_id.to_hex()),
                },
                other => EngineError::GitOperation {
                    message: format!(
                        "commit {} created; push failed: {}",
                        commit_id.to_hex(),
                        other
                    ),
                },
            });
        }
        Ok(CommitPushOutcome {
            commit_id: commit_id.to_hex().to_string(),
            pushed: true,
        })
    }

    /// 使用完整提交身份选项提交后推送；提交阶段沿用系统 Git，因此支持
    /// author/committer 分离、sign-off 和 GPG/SSH signing config。
    pub fn commit_and_push_with_identity(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        skip_hooks: bool,
        set_upstream: bool,
        author_name: Option<String>,
        author_email: Option<String>,
        committer_name: Option<String>,
        committer_email: Option<String>,
        sign_key: Option<String>,
        sign_off: bool,
        co_authors: Vec<String>,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_identity_inner(
            message,
            remote,
            branch,
            force,
            false,
            skip_hooks,
            set_upstream,
            author_name,
            author_email,
            committer_name,
            committer_email,
            sign_key,
            sign_off,
            co_authors,
            None,
            None,
        )
    }

    /// 带认证代理的身份选项提交并推送入口。
    pub fn commit_and_push_with_identity_with_auth(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        force_with_lease: bool,
        skip_hooks: bool,
        set_upstream: bool,
        author_name: Option<String>,
        author_email: Option<String>,
        committer_name: Option<String>,
        committer_email: Option<String>,
        sign_key: Option<String>,
        sign_off: bool,
        co_authors: Vec<String>,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_identity_inner(
            message,
            remote,
            branch,
            force,
            force_with_lease,
            skip_hooks,
            set_upstream,
            author_name,
            author_email,
            committer_name,
            committer_email,
            sign_key,
            sign_off,
            co_authors,
            Some(broker),
            None,
        )
    }

    /// 可取消的认证身份选项提交并推送入口。
    pub fn commit_and_push_with_identity_with_auth_and_cancel(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        force_with_lease: bool,
        skip_hooks: bool,
        set_upstream: bool,
        author_name: Option<String>,
        author_email: Option<String>,
        committer_name: Option<String>,
        committer_email: Option<String>,
        sign_key: Option<String>,
        sign_off: bool,
        co_authors: Vec<String>,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<CommitPushOutcome, EngineError> {
        self.commit_and_push_with_identity_inner(
            message,
            remote,
            branch,
            force,
            force_with_lease,
            skip_hooks,
            set_upstream,
            author_name,
            author_email,
            committer_name,
            committer_email,
            sign_key,
            sign_off,
            co_authors,
            Some(broker),
            Some(cancel),
        )
    }

    fn commit_and_push_with_identity_inner(
        &self,
        message: String,
        remote: Option<String>,
        branch: Option<String>,
        force: bool,
        force_with_lease: bool,
        skip_hooks: bool,
        set_upstream: bool,
        author_name: Option<String>,
        author_email: Option<String>,
        committer_name: Option<String>,
        committer_email: Option<String>,
        sign_key: Option<String>,
        sign_off: bool,
        co_authors: Vec<String>,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<CommitPushOutcome, EngineError> {
        let commit_id = self.commit_with_options(
            message,
            skip_hooks,
            author_name,
            author_email,
            committer_name,
            committer_email,
            sign_key,
            sign_off,
            co_authors,
            false,
        )?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let remotes = list_remotes(&repo)?;
        let Some(remote_name) = remote.or_else(|| remotes.first().map(|r| r.name.clone())) else {
            return Ok(CommitPushOutcome {
                commit_id,
                pushed: false,
            });
        };
        let current_branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        let Some(branch_name) = branch.or(current_branch) else {
            return Ok(CommitPushOutcome {
                commit_id,
                pushed: false,
            });
        };
        if let Err(error) = push_inner(
            &repo,
            &remote_name,
            &branch_name,
            force,
            force_with_lease,
            set_upstream,
            None,
            false,
            broker.as_deref(),
            cancel
                .as_deref()
                .map(crate::gitprocess::GitCancelHandle::token),
        ) {
            return Err(match error {
                EngineError::PushRejected {
                    kind,
                    remote,
                    branch,
                    message,
                } => EngineError::PushRejected {
                    kind,
                    remote,
                    branch,
                    message: format!("commit {commit_id} created; {message}"),
                },
                other => EngineError::GitOperation {
                    message: format!("commit {commit_id} created; push failed: {other}"),
                },
            });
        }
        Ok(CommitPushOutcome {
            commit_id,
            pushed: true,
        })
    }

    /// Amend 最近一次提交：树=当前索引，信息=给定 message，父=HEAD 第一父，CAS 更新 HEAD。
    /// 等价 `git commit --amend -m <message>`（不运行 hooks）。返回新 commit id（hex）。
    pub fn amend(&self, message: String, skip_hooks: bool) -> Result<String, EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        use gix::refs::Target;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
            return Err(EngineError::GitOperation {
                message: "amend: HEAD is unborn (no commit to amend)".into(),
            });
        }
        let head_commit = repo.head_commit().map_err(EngineError::from_gix)?;
        let head_id = head_commit.id().detach();
        let parent = head_commit
            .parent_ids()
            .next()
            .ok_or_else(|| EngineError::GitOperation {
                message: "amend: HEAD commit has no parent (cannot amend root commit)".into(),
            })?
            .detach();
        if let Some(output) = run_pre_commit_hook(&repo, skip_hooks)? {
            return Err(EngineError::GitOperation {
                message: format!("pre-commit hook failed: {output}"),
            });
        }
        let message = crate::commit_message::format(&repo, message)?;
        let message = run_commit_msg_hook(&repo, &message, skip_hooks)?;
        // 树 = 当前索引（同 commit() 的建树逻辑）
        let index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let mut editor = repo
            .edit_tree(repo.empty_tree().id)
            .map_err(EngineError::from_gix)?;
        for entry in index.entries() {
            let path = entry.path(&index);
            editor
                .upsert(path, mode_to_kind(entry.mode), entry.id)
                .map_err(EngineError::from_gix)?;
        }
        let tree_id = editor.write().map_err(EngineError::from_gix)?;
        let msg = if message.ends_with('\n') {
            message
        } else {
            format!("{message}\n")
        };
        let amended = repo
            .new_commit(&msg, tree_id, [parent])
            .map_err(EngineError::from_gix)?
            .id;
        // CAS 更新 HEAD：head_id -> amended（symbolic 或 detached）
        match repo.head_name().map_err(EngineError::from_gix)? {
            Some(name) => {
                repo.reference(
                    name,
                    amended,
                    PreviousValue::MustExistAndMatch(Target::Object(head_id)),
                    "amend",
                )
                .map_err(EngineError::from_gix)?;
            }
            None => {
                let head_name: gix::refs::FullName =
                    "HEAD".try_into().map_err(EngineError::from_gix)?;
                repo.edit_reference(RefEdit {
                    change: Change::Update {
                        log: Default::default(),
                        expected: PreviousValue::MustExistAndMatch(Target::Object(head_id)),
                        new: Target::Object(amended),
                    },
                    name: head_name,
                    deref: true,
                })
                .map_err(EngineError::from_gix)?;
            }
        }
        Ok(amended.to_hex().to_string())
    }

    /// 只改写 HEAD 的提交信息，不把当前 index 的 staged 变更带入新提交。
    /// 等价于 `git commit --amend --only`，用于 Log 的 Reword action。
    pub fn reword_head(&self, message: String, skip_hooks: bool) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "reword HEAD requires a non-bare worktree".into(),
        })?;
        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        command.args(["commit", "--amend", "--only", "--message", &message]);
        if skip_hooks {
            command.arg("--no-verify");
        }
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git reword HEAD failed: {}",
                    command_output_message(&output)
                ),
            });
        }
        let id = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["rev-parse", "HEAD"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        Ok(String::from_utf8_lossy(&id.stdout).trim().to_string())
    }

    /// Reword a non-HEAD root commit by rebuilding the current linear branch.
    /// This is the object-level equivalent of `git rebase --root` for the
    /// history-editing action; it requires a clean worktree and preserves
    /// staged/worktree state by refusing to start when either is dirty.
    pub fn reword_root_commit(
        &self,
        commit_id: String,
        message: String,
    ) -> Result<RebaseOutcome, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        ensure_history_change_operation_is_safe(&repo)?;
        let root = repo
            .rev_parse_single(BStr::new(commit_id.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        rewrite_root_commit_history(&repo, root, &message)
    }

    /// 最近的提交信息（标题，新->旧，去重，limit 上限）。供提交面板「最近信息」下拉。
    pub fn recent_commit_messages(&self, limit: u32) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if limit == 0 || repo.head().map_err(EngineError::from_gix)?.is_unborn() {
            return Ok(Vec::new());
        }
        let head_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        let walk = repo
            .rev_walk([head_id])
            .all()
            .map_err(EngineError::from_gix)?;
        let mut out: Vec<String> = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for item in walk {
            let info = item.map_err(EngineError::from_gix)?;
            let commit = repo.find_commit(info.id).map_err(EngineError::from_gix)?;
            let title = commit
                .message()
                .map(|m| m.title.trim_end().to_str_lossy().into_owned())
                .unwrap_or_default();
            if !title.is_empty() && seen.insert(title.clone()) {
                out.push(title);
                if out.len() >= limit as usize {
                    break;
                }
            }
        }
        Ok(out)
    }

    /// 提交信息模板：读 `commit.template` 配置指向的文件内容；未配置/文件缺失返回 None。
    pub fn commit_template(&self) -> Result<Option<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let config = repo.config_snapshot();
        let path = match config.string("commit.template") {
            Some(p) => p.to_str_lossy().into_owned(),
            None => return Ok(None),
        };
        // commit.template 相对仓库工作区根（git 惯例）；`~` 展开为主目录
        let expanded = if path.starts_with("~/") {
            format!(
                "{}/{}",
                std::env::var("HOME").unwrap_or_default(),
                &path[2..]
            )
        } else {
            path.clone()
        };
        let p = std::path::Path::new(&expanded);
        let resolved = if p.is_absolute() {
            p.to_path_buf()
        } else if let Some(wd) = repo.workdir() {
            wd.join(p)
        } else {
            p.to_path_buf()
        };
        match std::fs::read_to_string(&resolved) {
            Ok(t) => Ok(Some(t)),
            Err(_) => Ok(None), // 文件缺失 -> None（不报错）
        }
    }

    /// 列出已合并入 HEAD 的本地分支（tip 可达于 HEAD，不含当前分支）。
    /// 供「删除已合并分支」用。
    pub fn branch_list_merged(&self) -> Result<Vec<BranchInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let head_name = repo.head_name().map_err(EngineError::from_gix)?;
        if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
            return Ok(Vec::new());
        }
        let head_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        // HEAD 可达集合
        let walk = repo
            .rev_walk([head_id])
            .all()
            .map_err(EngineError::from_gix)?;
        let mut reachable: std::collections::HashSet<gix::hash::ObjectId> =
            std::collections::HashSet::new();
        for item in walk {
            let info = item.map_err(EngineError::from_gix)?;
            reachable.insert(info.id);
        }
        // 本地分支过滤：tip 在 reachable 内且非当前
        let platform = repo.references().map_err(EngineError::from_gix)?;
        let mut out = Vec::new();
        for r in platform
            .local_branches()
            .map_err(EngineError::from_gix)?
            .peeled()
            .map_err(EngineError::from_gix)?
        {
            let r = r.map_err(crate::log::boxed_err)?;
            if let Some(id) = r.try_id() {
                let id = id.detach();
                let name_full = r.name().as_bstr();
                let is_current = head_name
                    .as_ref()
                    .map(|h| h.as_bstr() == name_full)
                    .unwrap_or(false);
                if !is_current && reachable.contains(&id) {
                    let last_commit_time = repo
                        .find_commit(id)
                        .ok()
                        .and_then(|commit| commit.time().ok().map(|time| time.seconds))
                        .unwrap_or(0);
                    out.push(BranchInfo {
                        name: shorten_ref_name(name_full),
                        is_current: false,
                        short_id: id.to_hex().to_string().chars().take(7).collect(),
                        last_commit_time,
                    });
                }
            }
        }
        Ok(out)
    }

    /// 列出已经合并入指定目标 revision 的本地分支。
    ///
    /// IntelliJ 的 FindMergedLocalBranches/Branch Cleanup 使用
    /// `DeepComparator`：除了祖先可达性，还要把目标分支中已被
    /// cherry-pick 的等价补丁视为已合并。`git cherry <target> <branch>`
    /// 正好提供这个语义；只要候选分支没有 `+`（non-picked）提交，就算
    /// 已合并。允许调用方按名称前缀过滤。
    pub fn branch_list_merged_into(
        &self,
        target: String,
        prefix: String,
    ) -> Result<Vec<BranchInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let target = target.trim();
        if target.is_empty() {
            return Err(EngineError::GitOperation {
                message: "cleanup target branch is required".into(),
            });
        }
        let target_id = repo
            .rev_parse_single(BStr::new(target.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();

        let prefix = prefix.trim();
        let head_name = repo.head_name().map_err(EngineError::from_gix)?;
        let platform = repo.references().map_err(EngineError::from_gix)?;
        let mut out = Vec::new();
        for r in platform
            .local_branches()
            .map_err(EngineError::from_gix)?
            .peeled()
            .map_err(EngineError::from_gix)?
        {
            let r = r.map_err(crate::log::boxed_err)?;
            let Some(id) = r.try_id().map(|id| id.detach()) else {
                continue;
            };
            let name = crate::log::shorten_ref_name(r.name().as_bstr());
            if name == target {
                continue;
            }
            if !prefix.is_empty() && !name.starts_with(prefix) {
                continue;
            }
            let is_current = head_name
                .as_ref()
                .map(|head| head.as_bstr() == r.name().as_bstr())
                .unwrap_or(false);
            let has_non_picked = git_cherry_statuses(&repo, target_id, id)?
                .into_iter()
                .any(|(status, _)| status == '+');
            if !has_non_picked {
                out.push(BranchInfo {
                    name,
                    is_current,
                    short_id: id.to_hex().to_string().chars().take(7).collect(),
                    last_commit_time: repo
                        .find_commit(id)
                        .ok()
                        .and_then(|commit| commit.time().ok().map(|time| time.seconds))
                        .unwrap_or(0),
                });
            }
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    /// 逐行/逐 hunk 部分暂存：选择命中的变更组应用到索引（工作区不动）。
    /// `selections` 的 old_lines 为该文件 diff（WorktreeToIndex）的 old 侧行号（1-based）。
    /// old_lines 空 = 选中该 hunk 全部变更组。
    pub fn stage_lines(
        &self,
        path: String,
        selections: Vec<LineSelection>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let old = index_bytes(&repo, &path)?;
        let raw_new = worktree_bytes(&repo, &path);
        if is_binary(&old) || is_binary(&raw_new) {
            return Err(EngineError::GitOperation {
                message: "stage_lines: binary file not supported".into(),
            });
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "stage_lines requires a non-bare worktree".into(),
        })?;
        // Partial staging operates on the index's canonical content. Convert
        // the worktree side before selecting hunks so CRLF does not turn an
        // otherwise single-line edit into an all-lines selection.
        let new = crate::attributes::clean_worktree_bytes(workdir, &path, &raw_new)?;
        let content = apply_partial(&old, &new, &selections, false)?;
        let content = crate::attributes::clean_worktree_bytes(workdir, &path, content.as_bytes())?;
        let path_bstr = path.as_bytes().as_bstr();
        let mut index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        // 模式：优先沿用现有索引条目；否则按工作区文件推断
        let mode = index
            .entry_by_path_and_stage(path_bstr, gix::index::entry::Stage::Unconflicted)
            .map(|e| e.mode)
            .unwrap_or(gix::index::entry::Mode::FILE);
        // stat 用默认（racy）：部分暂存后索引 blob != 工作区，必须强制 status 重算内容
        upsert_index_entry(
            &repo,
            &mut index,
            path_bstr,
            &content,
            mode,
            gix::index::entry::Stat::default(),
        )?;
        index.remove_tree();
        index
            .write(gix::index::write::Options::default())
            .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 逐行/逐 hunk 部分取消暂存：选择命中的变更组回退到 HEAD（索引侧）。
    /// `selections` 的 old_lines 为该文件 diff（IndexToHead）的 old 侧行号（1-based，HEAD 侧）。
    pub fn unstage_lines(
        &self,
        path: String,
        selections: Vec<LineSelection>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let old = head_bytes_for_worktree_path(&repo, &path)?;
        let new = index_bytes(&repo, &path)?;
        if is_binary(&old) || is_binary(&new) {
            return Err(EngineError::GitOperation {
                message: "unstage_lines: binary file not supported".into(),
            });
        }
        let content = apply_partial(&old, &new, &selections, true)?;
        let path_bstr = path.as_bytes().as_bstr();
        let mut index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let mode = index
            .entry_by_path_and_stage(path_bstr, gix::index::entry::Stage::Unconflicted)
            .map(|e| e.mode)
            .unwrap_or(gix::index::entry::Mode::FILE);
        upsert_index_entry(
            &repo,
            &mut index,
            path_bstr,
            content.as_bytes(),
            mode,
            gix::index::entry::Stat::default(),
        )?;
        index.remove_tree();
        index
            .write(gix::index::write::Options::default())
            .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 逐行/逐 hunk 撤销工作区相对 index 的变更，保持 index 不变。
    /// `selections` 使用 WorktreeToIndex diff 的 old 侧行号；空的
    /// `old_lines` 选择整个 hunk。它是文件级 `restore_unstaged_path` 的
    /// 精确范围版本，对部分暂存文件不会回退已暂存内容。
    pub fn restore_unstaged_lines(
        &self,
        path: String,
        selections: Vec<LineSelection>,
    ) -> Result<(), EngineError> {
        if selections.is_empty() {
            return Err(EngineError::GitOperation {
                message: "restore_unstaged_lines requires a hunk or line selection".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative = worktree_relative_path(&path)?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "restore unstaged lines requires a file path".into(),
            });
        }
        let relative = relative.to_string_lossy().into_owned();
        let old = index_bytes(&repo, &relative)?;
        let raw_new = worktree_bytes(&repo, &relative);
        let workdir = worktree_root(&repo)?;
        let new = crate::attributes::clean_worktree_bytes(&workdir, &relative, &raw_new)?;
        if is_binary(&old) || is_binary(&new) {
            return Err(EngineError::GitOperation {
                message: "restore_unstaged_lines: binary file not supported".into(),
            });
        }
        if compute_hunks_with(&old, &new, false).is_empty() {
            return Err(EngineError::GitOperation {
                message: "restore_unstaged_lines: file has no unstaged hunk".into(),
            });
        }
        let content = apply_partial(&old, &new, &selections, true)?;
        let path_bstr = relative.as_bytes().as_bstr();
        let index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        let index_mode = index
            .entry_by_path_and_stage(path_bstr, gix::index::entry::Stage::Unconflicted)
            .map(|entry| entry.mode);
        let target = workdir.join(&relative);

        // With no index entry, selecting the complete addition means the
        // correct result is absence, not an empty file. Otherwise preserve
        // the existing worktree mode while writing the remaining content.
        if index_mode.is_none() && content.is_empty() {
            match std::fs::symlink_metadata(&target) {
                Ok(metadata) if metadata.file_type().is_dir() => {
                    std::fs::remove_dir_all(&target).map_err(EngineError::from_gix)?;
                }
                Ok(_) => std::fs::remove_file(&target).map_err(EngineError::from_gix)?,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(EngineError::from_gix(error)),
            }
            return Ok(());
        }

        let mode = index_mode.unwrap_or_else(|| {
            gix::index::fs::Metadata::from_path_no_follow(&target)
                .ok()
                .map(|metadata| {
                    if metadata.is_symlink() {
                        gix::index::entry::Mode::SYMLINK
                    } else if metadata.is_executable() {
                        gix::index::entry::Mode::FILE_EXECUTABLE
                    } else {
                        gix::index::entry::Mode::FILE
                    }
                })
                .unwrap_or(gix::index::entry::Mode::FILE)
        });
        crate::merge::write_worktree_entry(workdir, path_bstr, content.as_bytes(), mode)
    }

    /// 当前 HEAD commit id（hex），unborn 或出错返回 None。用于提交后反馈/显示。
    pub fn head_commit_id(&self) -> Option<String> {
        let repo = self.inner.lock().ok()?;
        let commit = repo.head_commit().ok()?;
        Some(commit.id().to_hex().to_string())
    }

    /// Resolve an arbitrary commit-ish to its commit id without changing
    /// HEAD.  Multi-root history operations use this for selected branches:
    /// the selected branch tip is not necessarily the repository's current
    /// HEAD while the dialog is open.
    pub fn revision_commit_id(&self, revision: String) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let id = repo
            .rev_parse_single(BStr::new(revision.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        Ok(id.to_hex().to_string())
    }

    /// Resolve the common ancestor of two revisions without changing HEAD.
    /// Push/update notifications use this as the stable start of a received
    /// commit range, matching IntelliJ's merge-base based range calculation.
    pub fn merge_base_revision_id(
        &self,
        first: String,
        second: String,
    ) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let first = repo
            .rev_parse_single(BStr::new(first.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let second = repo
            .rev_parse_single(BStr::new(second.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let base = repo
            .merge_base(first, second)
            .map_err(EngineError::from_gix)?
            .detach();
        Ok(base.to_hex().to_string())
    }

    /// Detect IntelliJ's "rebase over merge" warning condition.
    ///
    /// The range is the same half-open `base..current` revision range used by
    /// `GitRebaseOverMergeProblem`: only merge commits reachable from
    /// `current` and not from `base` are inspected. A merge is relevant only
    /// when its resulting tree differs from its first parent; an empty
    /// `--no-ff` merge therefore does not trigger the warning.
    pub fn has_non_empty_merge_commits_in_range(
        &self,
        base: String,
        current: String,
    ) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let base_id = repo
            .rev_parse_single(BStr::new(base.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let current_id = repo
            .rev_parse_single(BStr::new(current.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let walk = gix::traverse::commit::topo::Builder::from_iters(
            &repo.objects,
            [current_id],
            Some(vec![base_id]),
        )
        .sorting(gix::traverse::commit::topo::Sorting::TopoOrder)
        .build()
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot build merge warning walk: {error}"),
        })?;

        for item in walk {
            let id = item
                .map(|info| info.id)
                .map_err(|error| EngineError::GitOperation {
                    message: format!("cannot traverse merge warning range: {error}"),
                })?;
            // gix's end iterator is a traversal boundary, but explicitly
            // exclude it as well so `base == current` is the empty range and
            // the behavior remains visibly identical to Git's `base..current`.
            if id == base_id {
                continue;
            }
            let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
            let parents = commit
                .parent_ids()
                .map(|parent| parent.detach())
                .collect::<Vec<_>>();
            if parents.len() < 2 {
                continue;
            }
            let parent_tree = repo
                .find_commit(parents[0])
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let merge_tree = commit.tree_id().map_err(EngineError::from_gix)?.detach();
            if !crate::tree::diff_trees(&repo, parent_tree, merge_tree)?.is_empty() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// 单文件 line-level diff。
    /// WorktreeToIndex: old=索引 blob, new=工作区；IndexToWorktree 为反向的
    /// staged/local 只读展示；IndexToHead: old=HEAD blob, new=索引 blob。
    /// 二进制文件返回 `binary=true` 且无 hunks。`ignore_whitespace` 为 git `-w` 语义。
    pub fn diff_file(
        &self,
        path: String,
        mode: DiffMode,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        diff_file_inner(&repo, &path, mode, ignore_whitespace)
    }

    /// DIFF-001：带完整设置的 diff（whitespace/word/CRLF）。
    /// binary 判定优先用 attributes（`binary` 属性 set 即二进制，即使无 NUL）。
    pub fn diff_file_with_settings(
        &self,
        path: String,
        mode: DiffMode,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        diff_file_inner_settings(&repo, &path, mode, &settings)
    }

    /// 任意两个 rev（分支名/提交 id/tag）的指定文件比较。
    pub fn diff_commits(
        &self,
        rev1: String,
        rev2: String,
        path: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.diff_commits_with_settings(
            rev1,
            rev2,
            path,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// DIFF-002：任意两个 rev 的指定文件比较，支持显式 opt-in textconv。
    pub fn diff_commits_with_settings(
        &self,
        rev1: String,
        rev2: String,
        path: String,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if let Some(diff) =
            textconv_revision_diff_if_enabled(&repo, &rev1, &rev2, &path, &settings)?
        {
            return Ok(diff);
        }
        let old = crate::diff::rev_content_bytes(&repo, &rev1, &path)?;
        let new = crate::diff::rev_content_bytes(&repo, &rev2, &path)?;
        if is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let hunks = compute_hunks_with(&old, &new, settings.ignore_all_space);
        let mut diff = FileDiff {
            path,
            binary: false,
            hunks,
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    /// Compare two revisions when the file path changed between them.
    ///
    /// This is the file-level half of a rename-aware submodule diff: the
    /// parent repository supplies the old/new gitlink commits and the nested
    /// repository supplies the old and new file endpoints.  Keep the result
    /// path on the new side so the UI can route the preview to the target
    /// file, while the old path is still read from the correct tree.
    pub fn diff_commits_with_paths(
        &self,
        rev1: String,
        path1: String,
        rev2: String,
        path2: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.diff_commits_with_paths_with_settings(
            rev1,
            path1,
            rev2,
            path2,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// DIFF-002：rename-aware revision comparison with opt-in textconv.
    pub fn diff_commits_with_paths_with_settings(
        &self,
        rev1: String,
        path1: String,
        rev2: String,
        path2: String,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let old_path = worktree_relative_path(&path1)?;
        let new_path = worktree_relative_path(&path2)?;
        let old_path = old_path.to_string_lossy().into_owned();
        let new_path = new_path.to_string_lossy().into_owned();
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if !rev1.trim().is_empty() && !rev2.trim().is_empty() {
            let textconv = if old_path == new_path {
                textconv_revision_diff_if_enabled(&repo, &rev1, &rev2, &new_path, &settings)?
            } else {
                textconv_object_diff_if_enabled(
                    &repo,
                    &format!("{}:{}", rev1.trim(), old_path),
                    &format!("{}:{}", rev2.trim(), new_path),
                    &new_path,
                    &settings,
                )?
            };
            if let Some(diff) = textconv {
                return Ok(diff);
            }
        }
        let old = if rev1.trim().is_empty() {
            Vec::new()
        } else {
            crate::diff::rev_content_bytes(&repo, &rev1, &old_path)?
        };
        let new = if rev2.trim().is_empty() {
            Vec::new()
        } else {
            crate::diff::rev_content_bytes(&repo, &rev2, &new_path)?
        };
        if is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path: new_path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let hunks = compute_hunks_with(&old, &new, settings.ignore_all_space);
        let mut diff = FileDiff {
            path: new_path,
            binary: false,
            hunks,
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    /// Compare one historical file revision with its current worktree copy.
    /// Missing paths are represented as an empty side, matching Git's added
    /// and deleted-file diff semantics. This is the engine backing for the
    /// Changes Browser's `Compare with Local` action.
    pub fn diff_revision_with_worktree(
        &self,
        revision: String,
        path: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.diff_revision_path_with_worktree(revision, path.clone(), path, ignore_whitespace)
    }

    /// Compare different paths on the revision and worktree sides. This is
    /// required for a rename: the old revision path and the current target
    /// path are intentionally not the same string.
    pub fn diff_revision_path_with_worktree(
        &self,
        revision: String,
        revision_path: String,
        worktree_path: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.diff_revision_path_with_worktree_with_settings(
            revision,
            revision_path,
            worktree_path,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// DIFF-002：revision/worktree comparison with opt-in textconv.
    pub fn diff_revision_path_with_worktree_with_settings(
        &self,
        revision: String,
        revision_path: String,
        worktree_path: String,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let textconv = if revision_path == worktree_path {
            textconv_git_diff_if_enabled(
                &repo,
                &worktree_path,
                &settings,
                vec![revision.clone()],
                false,
                true,
            )?
        } else {
            textconv_renamed_revision_worktree_diff_if_enabled(
                &repo,
                &revision,
                &revision_path,
                &worktree_path,
                &settings,
            )?
        };
        if let Some(diff) = textconv {
            return Ok(diff);
        }
        let old = crate::diff::rev_content_bytes(&repo, &revision, &revision_path)?;
        let new = normalized_worktree_bytes(&repo, &worktree_path)?;
        let attr_binary = repo
            .workdir()
            .and_then(|wd| {
                crate::attributes::check_attributes(wd, &[worktree_path.clone()])
                    .ok()
                    .and_then(|attrs| attrs.first().cloned())
            })
            .map(|attrs| attrs.binary == crate::attributes::AttributeValue::Set)
            .unwrap_or(false);
        if attr_binary || is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path: worktree_path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let hunks = compute_hunks_with(&old, &new, settings.ignore_all_space);
        let mut diff = FileDiff {
            path: worktree_path,
            binary: false,
            hunks,
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    /// Apply or reverse selected file changes from one commit to the current
    /// worktree. This is the patch-based semantic behind IntelliJ's
    /// `Apply Selected Changes` and `Revert Selected Changes`; unlike
    /// `restore_file`, it does not replace the index and does not overwrite
    /// unrelated local files.
    pub fn apply_selected_commit_changes(
        &self,
        commit_id: String,
        parent_index: Option<u32>,
        paths: Vec<String>,
        reverse: bool,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        ensure_history_change_operation_is_idle(&repo)?;
        let workdir = worktree_root(&repo)?;
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "select at least one changed file".into(),
            });
        }

        let mut selected_paths = Vec::with_capacity(paths.len());
        let mut seen = HashSet::new();
        for path in paths {
            let relative = worktree_relative_path(&path)?;
            if relative.as_os_str().is_empty()
                || path.starts_with('-')
                || path.starts_with('/')
                || path.ends_with('/')
                || path.split('/').any(|component| component.is_empty())
            {
                return Err(EngineError::GitOperation {
                    message: format!("invalid selected change path: {path}"),
                });
            }
            if !seen.insert(path.clone()) {
                return Err(EngineError::GitOperation {
                    message: format!("selected change path appears more than once: {path}"),
                });
            }
            selected_paths.push(path);
        }

        let id = repo
            .rev_parse_single(BStr::new(commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|parent| parent.detach()).collect();
        let parent = match parent_index.map(|index| index as usize) {
            Some(index) if index >= parents.len() => {
                return Err(EngineError::GitOperation {
                    message: format!("commit has no parent at index {index}"),
                });
            }
            Some(index) => parents[index].to_hex().to_string(),
            None if parents.is_empty() => repo.empty_tree().id.to_hex().to_string(),
            None => parents[0].to_hex().to_string(),
        };
        let target = id.to_hex().to_string();
        let (from, to) = if reverse {
            (target.as_str(), parent.as_str())
        } else {
            (parent.as_str(), target.as_str())
        };

        // Keep patch generation on the configured Git executable so
        // attributes, binary patches, renames and user Git settings follow
        // the same semantics as the rest of the app. Applying through the
        // direct-patch engine below is important: a rejected patch must leave
        // a restart-safe snapshot and normal conflict stages for the SwiftUI
        // Apply Patch workbench instead of becoming a terminal error.
        let mut diff_command = crate::gitprocess::git_command_for_working_dir(workdir);
        diff_command
            .args([
                "diff",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
                from,
                to,
                "--",
            ])
            .args(&selected_paths)
            .current_dir(workdir);
        let patch = diff_command.output().map_err(EngineError::from_gix)?;
        if !patch.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git diff failed: {}",
                    String::from_utf8_lossy(&patch.stderr).trim()
                ),
            });
        }
        if patch.stdout.is_empty() {
            return Err(EngineError::GitOperation {
                message: "selected files have no applicable changes in the commit".into(),
            });
        }

        let patch = String::from_utf8(patch.stdout).map_err(|_| EngineError::GitOperation {
            message: "selected commit change patch is not valid UTF-8".into(),
        })?;
        let operation_name = format!(
            "Log {} {}",
            if reverse { "Revert" } else { "Apply" },
            target
        );
        crate::shelve::apply_raw_shelve(
            &repo,
            &patch,
            &operation_name,
            false,
            false,
            Some(&selected_paths),
            None,
            Some(1),
            true,
        )?;
        Ok(())
    }

    /// Diff a file as it changed in one commit.  Unlike `diff_commits`, this
    /// also supports root commits by comparing against the empty tree.
    pub fn commit_file_diff(
        &self,
        commit_id: String,
        parent_index: Option<u32>,
        path: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.commit_file_diff_with_settings(
            commit_id,
            parent_index,
            path,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// DIFF-002：single-commit file diff with opt-in textconv.
    pub fn commit_file_diff_with_settings(
        &self,
        commit_id: String,
        parent_index: Option<u32>,
        path: String,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let id = repo
            .rev_parse_single(BStr::new(commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|parent| parent.detach()).collect();
        let parent = parent_index
            .map(|index| index as usize)
            .filter(|index| *index < parents.len())
            .unwrap_or(0);
        let parent_revision = parents
            .get(parent)
            .map(|parent| parent.to_hex().to_string())
            .unwrap_or_else(|| repo.empty_tree().id.to_hex().to_string());
        if let Some(diff) = textconv_revision_diff_if_enabled(
            &repo,
            &parent_revision,
            &id.to_hex().to_string(),
            &path,
            &settings,
        )? {
            return Ok(diff);
        }
        let old = parents
            .get(parent)
            .map(|parent| {
                crate::diff::rev_content_bytes(&repo, &parent.to_hex().to_string(), &path)
            })
            .transpose()?
            .unwrap_or_default();
        let new = crate::diff::rev_content_bytes(&repo, &id.to_hex().to_string(), &path)?;
        if is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let hunks = compute_hunks_with(&old, &new, settings.ignore_all_space);
        let mut diff = FileDiff {
            path,
            binary: false,
            hunks,
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    /// 文件工作区内容 vs 给定文本（剪贴板比较）。
    pub fn diff_with_text(
        &self,
        path: String,
        text: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let old = worktree_bytes(&repo, &path);
        let new = text.as_bytes().to_vec();
        if is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let hunks = compute_hunks_with(&old, &new, ignore_whitespace);
        let mut diff = FileDiff {
            path,
            binary: false,
            hunks,
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    /// Compare two caller-provided text snapshots without reading the
    /// worktree. Apply Patch's "Show Diff with Local" needs this while the
    /// current worktree still contains conflict markers, so the local stage
    /// and the editable result must remain independent of the worktree.
    pub fn diff_texts(
        &self,
        path: String,
        old_text: String,
        new_text: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        let old = old_text.into_bytes();
        let new = new_text.into_bytes();
        if is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let mut diff = FileDiff {
            path,
            binary: false,
            hunks: compute_hunks_with(&old, &new, ignore_whitespace),
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    /// 提交日志（新→旧）。`path=Some` -> 只含触碰该路径的提交（逐文件历史）；`limit` 上限。
    /// `follow=true` 时跨重命名追踪（--follow 语义，仅对 path=Some 有效）。
    /// unborn HEAD 返回空。
    pub fn log(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        after_id: Option<String>,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_with_sort(
            path,
            limit,
            follow,
            after_id,
            crate::log::LogGraphSortMode::ByCommitDate,
        )
    }

    /// 提交日志，并允许选择 IntelliJ VCS Log 的图形排序模式。
    pub fn log_with_sort(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        after_id: Option<String>,
        sort_mode: crate::log::LogGraphSortMode,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let after_id = after_id
            .filter(|s| !s.trim().is_empty())
            .map(|s| gix::hash::ObjectId::from_hex(s.as_bytes()).map_err(EngineError::from_gix))
            .transpose()?;
        if limit == 0 {
            return Ok(Vec::new());
        }
        if path.is_none() && !follow {
            return with_permanent_log_graph(self, &repo, sort_mode, |graph| {
                graph.page(after_id, limit)
            });
        }
        collect_log(
            &repo, path, limit, follow, None, None, None, None, None, None, false, false, false,
            after_id, sort_mode,
        )
    }

    /// Load one commit directly for detail panes and revision actions.
    /// Unlike a bounded log page, this remains correct when the selected
    /// rebase entry is older than the current VCS Log viewport.
    pub fn commit_info(&self, commit_id: String) -> Result<CommitInfo, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let id = repo
            .rev_parse_single(BStr::new(commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let refs = crate::log::collect_refs(&repo)?;
        let head_id = repo
            .head_commit()
            .ok()
            .map(|head| head.id().detach())
            .unwrap_or(id);
        commit_info_for_id(&repo, id, &refs, head_id)
    }

    /// Resolve all direct child commits for VCS Log navigation, including
    /// children that are outside the currently loaded UI page.
    pub fn commit_children(&self, commit_id: String) -> Result<Vec<CommitInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let id = repo
            .rev_parse_single(BStr::new(commit_id.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        if let Some(children) = with_permanent_log_graph(
            self,
            &repo,
            crate::log::LogGraphSortMode::ByCommitDate,
            |graph| graph.children(id),
        )? {
            return Ok(children);
        }
        crate::log::direct_children(&repo, id)
    }

    /// Run an arbitrary `git log` revision/filter expression and return the
    /// matching commits in the same record shape as the normal VCS Log.
    ///
    /// The command filter is deliberately executed by Git itself: options
    /// such as `--author`, `--grep`, ranges, pathspecs, and revision walks all
    /// retain Git's exact semantics. Output formatting is replaced with an
    /// object-id-only format internally, after which commit metadata is
    /// materialized through the engine and graph lanes are rebuilt for the
    /// visible result.
    pub fn log_with_command(
        &self,
        command_args: Vec<String>,
        limit: u32,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        match repo.head() {
            Ok(head) if head.is_unborn() => return Ok(Vec::new()),
            Ok(_) => {}
            // gix reports an unborn branch whose symbolic HEAD target has
            // not been created as a missing reference rather than `is_unborn`.
            Err(_) => return Ok(Vec::new()),
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "git log command requires a non-bare worktree".into(),
        })?;
        let args = prepare_log_command_args(&command_args);
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .arg("log")
            .args(&args)
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git log command failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }

        let ids = String::from_utf8_lossy(&output.stdout)
            .lines()
            .take(limit as usize)
            .map(|line| {
                gix::hash::ObjectId::from_hex(line.trim().as_bytes()).map_err(|error| {
                    EngineError::GitOperation {
                        message: format!("git log returned an invalid revision: {error}"),
                    }
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let refs = crate::log::collect_refs(&repo)?;
        let head_commit_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        let mut commits = Vec::with_capacity(ids.len());
        for id in ids {
            commits.push(commit_info_for_id(&repo, id, &refs, head_commit_id)?);
        }
        crate::log::assign_graph_lanes(&mut commits, false, false);
        Ok(commits)
    }

    /// 带起点、作者、时间过滤的日志。`start_rev` 为空时从 HEAD 开始。
    pub fn log_filtered(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_rev: Option<String>,
        author: Option<String>,
        since: Option<i64>,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_filtered_with_message(path, limit, follow, start_rev, author, since, None)
    }

    /// 带起点、作者、时间和提交信息全文过滤的日志。
    pub fn log_filtered_with_message(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_rev: Option<String>,
        author: Option<String>,
        since: Option<i64>,
        message: Option<String>,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_filtered_with_message_and_sort(
            path,
            limit,
            follow,
            start_rev,
            author,
            since,
            message,
            crate::log::LogGraphSortMode::ByCommitDate,
        )
    }

    /// 带过滤条件和图形排序模式的日志。
    pub fn log_filtered_with_message_and_sort(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_rev: Option<String>,
        author: Option<String>,
        since: Option<i64>,
        message: Option<String>,
        sort_mode: crate::log::LogGraphSortMode,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_filtered_with_message_and_options(
            path, limit, follow, start_rev, author, since, message, false, false, sort_mode,
        )
    }

    /// 带过滤条件、文本过滤选项和图形排序模式的日志。
    pub fn log_filtered_with_message_and_options(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_rev: Option<String>,
        author: Option<String>,
        since: Option<i64>,
        message: Option<String>,
        message_regex: bool,
        message_match_case: bool,
        sort_mode: crate::log::LogGraphSortMode,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let start_id = start_rev
            .filter(|s| !s.trim().is_empty())
            .map(|s| {
                repo.rev_parse_single(BStr::new(s.as_bytes()))
                    .map(|id| id.detach())
                    .map_err(EngineError::from_gix)
            })
            .transpose()?;
        collect_log(
            &repo,
            path,
            limit,
            follow,
            start_id.map(|id| vec![id]),
            None,
            author.as_deref(),
            since,
            None,
            message.as_deref(),
            message_regex,
            message_match_case,
            false,
            None,
            sort_mode,
        )
    }

    /// 带完整日期范围、文本选项和 No Merges 图形过滤的日志。
    /// `until` 对应 IntelliJ VCS Log 的严格 before 上限；`no_merges` 过滤掉两个及以上父提交的提交。
    pub fn log_filtered_with_message_and_date_options(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_rev: Option<String>,
        author: Option<String>,
        since: Option<i64>,
        until: Option<i64>,
        message: Option<String>,
        message_regex: bool,
        message_match_case: bool,
        no_merges: bool,
        sort_mode: crate::log::LogGraphSortMode,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_filtered_with_message_and_date_options_for_revisions(
            path,
            limit,
            follow,
            start_rev.into_iter().collect(),
            author,
            since,
            until,
            message,
            message_regex,
            message_match_case,
            no_merges,
            sort_mode,
        )
    }

    /// 带多个 branch/revision heads 的完整 VCS Log 过滤。
    /// 多个起点取其可达历史的并集；空数组保持默认的全仓库 refs 语义。
    pub fn log_filtered_with_message_and_date_options_for_revisions(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_revs: Vec<String>,
        author: Option<String>,
        since: Option<i64>,
        until: Option<i64>,
        message: Option<String>,
        message_regex: bool,
        message_match_case: bool,
        no_merges: bool,
        sort_mode: crate::log::LogGraphSortMode,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_filtered_with_message_and_date_options_for_revisions_with_after_id(
            path,
            limit,
            follow,
            start_revs,
            author,
            since,
            until,
            message,
            message_regex,
            message_match_case,
            no_merges,
            sort_mode,
            None,
        )
    }

    /// 带多个 branch/revision heads 的完整 VCS Log 过滤，并从给定提交之后继续分页。
    ///
    /// `after_id` 是上一页最后一条可见提交。它只改变遍历游标，不改变 revision
    /// range 或其它过滤条件；找不到游标时返回空页，让调用方安全地丢弃过期分页结果。
    pub fn log_filtered_with_message_and_date_options_for_revisions_with_after_id(
        &self,
        path: Option<String>,
        limit: u32,
        follow: bool,
        start_revs: Vec<String>,
        author: Option<String>,
        since: Option<i64>,
        until: Option<i64>,
        message: Option<String>,
        message_regex: bool,
        message_match_case: bool,
        no_merges: bool,
        sort_mode: crate::log::LogGraphSortMode,
        after_id: Option<String>,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        let after_id = after_id
            .filter(|id| !id.trim().is_empty())
            .map(|id| {
                gix::hash::ObjectId::from_hex(id.trim().as_bytes()).map_err(|error| {
                    EngineError::GitOperation {
                        message: format!("invalid log pagination cursor: {error}"),
                    }
                })
            })
            .transpose()?;
        log_filtered_with_paths_with_message_and_date_options_for_revisions_internal(
            self,
            path.map(|path| vec![path]),
            limit,
            follow,
            start_revs,
            author,
            since,
            until,
            message,
            message_regex,
            message_match_case,
            no_merges,
            after_id,
            sort_mode,
        )
    }

    /// 带多个 Paths structure-filter 路径的完整 VCS Log 过滤。
    /// 每个路径属于同一个 Git root；引擎在一次遍历中取路径集合的并集，
    /// 因而保留统一的拓扑/日期排序，而不是在 UI 层拼接多个独立 log walk。
    pub fn log_filtered_with_paths_with_message_and_date_options_for_revisions(
        &self,
        paths: Vec<String>,
        limit: u32,
        follow: bool,
        start_revs: Vec<String>,
        author: Option<String>,
        since: Option<i64>,
        until: Option<i64>,
        message: Option<String>,
        message_regex: bool,
        message_match_case: bool,
        no_merges: bool,
        sort_mode: crate::log::LogGraphSortMode,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.log_filtered_with_paths_with_message_and_date_options_for_revisions_with_after_id(
            paths,
            limit,
            follow,
            start_revs,
            author,
            since,
            until,
            message,
            message_regex,
            message_match_case,
            no_merges,
            sort_mode,
            None,
        )
    }

    /// 带多个 Paths structure-filter 路径的完整 VCS Log 过滤，并从给定提交之后继续分页。
    /// `after_id` 是该 root 上一页最后一条可见提交；找不到游标时返回空页。
    pub fn log_filtered_with_paths_with_message_and_date_options_for_revisions_with_after_id(
        &self,
        paths: Vec<String>,
        limit: u32,
        follow: bool,
        start_revs: Vec<String>,
        author: Option<String>,
        since: Option<i64>,
        until: Option<i64>,
        message: Option<String>,
        message_regex: bool,
        message_match_case: bool,
        no_merges: bool,
        sort_mode: crate::log::LogGraphSortMode,
        after_id: Option<String>,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        let after_id = after_id
            .filter(|id| !id.trim().is_empty())
            .map(|id| {
                gix::hash::ObjectId::from_hex(id.trim().as_bytes()).map_err(|error| {
                    EngineError::GitOperation {
                        message: format!("invalid log pagination cursor: {error}"),
                    }
                })
            })
            .transpose()?;
        log_filtered_with_paths_with_message_and_date_options_for_revisions_internal(
            self,
            (!paths.is_empty()).then_some(paths),
            limit,
            follow,
            start_revs,
            author,
            since,
            until,
            message,
            message_regex,
            message_match_case,
            no_merges,
            after_id,
            sort_mode,
        )
    }
}

fn log_filtered_with_paths_with_message_and_date_options_for_revisions_internal(
    repository: &Repository,
    paths: Option<Vec<String>>,
    limit: u32,
    follow: bool,
    start_revs: Vec<String>,
    author: Option<String>,
    since: Option<i64>,
    until: Option<i64>,
    message: Option<String>,
    message_regex: bool,
    message_match_case: bool,
    no_merges: bool,
    after_id: Option<gix::hash::ObjectId>,
    sort_mode: crate::log::LogGraphSortMode,
) -> Result<Vec<CommitInfo>, EngineError> {
    let repo = repository.inner.lock().expect("repo mutex poisoned");
    let mut start_ids = Vec::new();
    let mut end_ids = Vec::new();
    for raw in start_revs {
        let revision = raw.trim();
        if revision.is_empty() {
            continue;
        }
        if !revision.contains("...") {
            if let Some((end, start)) = revision.split_once("..") {
                if !end.is_empty() && !start.is_empty() {
                    let end_id = repo
                        .rev_parse_single(BStr::new(end.as_bytes()))
                        .map(|id| id.detach())
                        .map_err(EngineError::from_gix)?;
                    let start_id = repo
                        .rev_parse_single(BStr::new(start.as_bytes()))
                        .map(|id| id.detach())
                        .map_err(EngineError::from_gix)?;
                    end_ids.push(end_id);
                    start_ids.push(start_id);
                    continue;
                }
            }
        }
        let start_id = repo
            .rev_parse_single(BStr::new(revision.as_bytes()))
            .map(|id| id.detach())
            .map_err(EngineError::from_gix)?;
        start_ids.push(start_id);
    }
    // Fast-path the query shapes that IntelliJ answers from its permanent
    // graph: no path/follow state, no left-side range exclusion, and only
    // visible-head plus commit-detail filters. Keep arbitrary dangling
    // revisions on the Git-walk path when they are absent from the graph.
    if paths.is_none() && !follow && end_ids.is_empty() {
        let visible_heads = (!start_ids.is_empty()).then_some(start_ids.as_slice());
        let visible = with_permanent_log_graph(repository, &repo, sort_mode, |graph| {
            if start_ids.iter().all(|id| graph.contains_commit(*id)) {
                Some(graph.filtered_page(
                    visible_heads,
                    after_id,
                    limit,
                    author.as_deref(),
                    since,
                    until,
                    message.as_deref(),
                    message_regex,
                    message_match_case,
                    no_merges,
                ))
            } else {
                None
            }
        })?;
        if let Some(result) = visible {
            return result;
        }
    }
    crate::log::collect_log_paths(
        &repo,
        paths,
        limit,
        follow,
        if start_ids.is_empty() {
            None
        } else {
            Some(start_ids)
        },
        if end_ids.is_empty() {
            None
        } else {
            Some(end_ids)
        },
        author.as_deref(),
        since,
        until,
        message.as_deref(),
        message_regex,
        message_match_case,
        no_merges,
        after_id,
        sort_mode,
    )
}

#[uniffi::export]
impl Repository {
    /// 读取 HEAD reflog，按最新到最旧返回，limit=0 返回空。
    pub fn reflog(&self, limit: u32) -> Result<Vec<crate::log::ReflogEntry>, EngineError> {
        self.reflog_page(limit, 0)
    }

    /// 读取 HEAD reflog 的一页，按最新到最旧返回。
    ///
    /// `offset` 按有效的 reflog 记录计数，而不是按原始文件行计数；这样
    /// 损坏/旧格式行不会让 UI 的“加载更早记录”跳过可读记录。保持单独的
    /// page API 也避免 SwiftUI 为了翻页读取整个历史文件。
    pub fn reflog_page(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<crate::log::ReflogEntry>, EngineError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let path = repo.git_dir().join("logs").join("HEAD");
        let Ok(text) = std::fs::read_to_string(path) else {
            return Ok(Vec::new());
        };
        let offset = offset as usize;
        let mut skipped = 0usize;
        let mut entries = Vec::new();
        for line in text.lines().rev() {
            let Some((header, message)) = line.split_once('\t') else {
                continue;
            };
            let fields: Vec<&str> = header.split_whitespace().collect();
            if fields.len() < 5 {
                continue;
            }
            let Ok(time) = fields[fields.len() - 2].parse::<i64>() else {
                continue;
            };
            if skipped < offset {
                skipped += 1;
                continue;
            }
            entries.push(crate::log::ReflogEntry {
                old_id: fields[0].to_owned(),
                new_id: fields[1].to_owned(),
                message: message.to_owned(),
                time,
                ref_name: "HEAD".into(),
            });
            if entries.len() >= limit as usize {
                break;
            }
        }
        Ok(entries)
    }

    /// 两个 revision 的完整树差异。
    pub fn tree_changes(&self, rev1: String, rev2: String) -> Result<Vec<TreeChange>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let old_id = repo
            .rev_parse_single(BStr::new(rev1.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let new_id = repo
            .rev_parse_single(BStr::new(rev2.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let old_tree = repo
            .find_commit(old_id)
            .map_err(EngineError::from_gix)?
            .tree()
            .map_err(EngineError::from_gix)?;
        let new_tree = repo
            .find_commit(new_id)
            .map_err(EngineError::from_gix)?
            .tree()
            .map_err(EngineError::from_gix)?;
        crate::tree::diff_trees(&repo, old_tree.id, new_tree.id)
    }

    /// 返回给定 revision 与当前工作区之间的 tracked 文件变化。
    ///
    /// IntelliJ 的 `Show Diff with Working Tree` 使用 `git diff <revision>`：
    /// 它包含 staged/unstaged 的 tracked 变化，但不把未跟踪文件伪装成
    /// revision diff。这里保留 Git 的 rename score，并复用 TreeChange
    /// 模型供 Swift Changes Browser 展示。
    pub fn tree_changes_with_worktree(
        &self,
        revision: String,
    ) -> Result<Vec<TreeChange>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let revision = revision.trim();
        if revision.is_empty() {
            return Err(EngineError::GitOperation {
                message: "working-tree diff requires a revision".into(),
            });
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "working-tree diff requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            "diff",
        )
        .args(vec![
            "--no-ext-diff".to_string(),
            "--no-textconv".to_string(),
            "--name-status".to_string(),
            "-z".to_string(),
            "-M".to_string(),
            "--diff-filter=ACDMRUXT".to_string(),
            revision.to_string(),
            "--".to_string(),
        ])
        .working_dir(workdir);
        let output = crate::gitprocess::run_to_completion(&spec)?;
        if !output.success() {
            return Err(output.into_error(&spec));
        }

        let mut fields = output.stdout.as_bytes().split(|byte| *byte == 0);
        let mut changes = Vec::new();
        while let Some(status_field) = fields.next() {
            if status_field.is_empty() {
                continue;
            }
            let status = status_field[0];
            let is_rename = status == b'R' || status == b'C';
            let (path, old_path) = if is_rename {
                let source_field = fields.next().ok_or_else(|| EngineError::GitOperation {
                    message: "git diff returned a malformed rename record".into(),
                })?;
                let target_field = fields.next().ok_or_else(|| EngineError::GitOperation {
                    message: "git diff returned a malformed rename record".into(),
                })?;
                (
                    String::from_utf8_lossy(target_field).into_owned(),
                    Some(String::from_utf8_lossy(source_field).into_owned()),
                )
            } else {
                let path_field = fields.next().ok_or_else(|| EngineError::GitOperation {
                    message: "git diff returned a malformed name-status record".into(),
                })?;
                (String::from_utf8_lossy(path_field).into_owned(), None)
            };
            let (kind, old_mode, new_mode) = match status {
                b'A' => (crate::tree::TreeChangeKind::Added, 0, 1),
                b'D' => (crate::tree::TreeChangeKind::Deleted, 1, 0),
                b'R' => (crate::tree::TreeChangeKind::Renamed, 1, 1),
                _ => (crate::tree::TreeChangeKind::Modified, 1, 1),
            };
            let is_pure_move =
                status == b'R' && status_field.get(1..).is_some_and(|score| score == b"100");
            changes.push(TreeChange {
                path,
                old_path,
                is_pure_move,
                kind,
                old_mode,
                new_mode,
            });
        }
        Ok(changes)
    }

    // MARK: HISTORY-001 提交 diff 与签名

    /// 单个提交的文件级 diff：`parent_index` 选择父（merge commit 双父/多父），
    /// None = 第一父；**root commit 与空 tree 比较**，返回完整文件列表。
    pub fn commit_diff(
        &self,
        commit_id: String,
        parent_index: Option<u32>,
    ) -> Result<crate::log::CommitDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let id = repo
            .rev_parse_single(BStr::new(commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|p| p.detach()).collect();
        let empty = repo.empty_tree().id;
        let (old_tree_id, parent_id) = if parents.is_empty() {
            (empty, None)
        } else {
            let pick = parent_index
                .map(|i| i as usize)
                .filter(|i| *i < parents.len())
                .unwrap_or(0);
            let parent = parents[pick];
            let parent_tree = repo
                .find_commit(parent)
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            (parent_tree, Some(parent.to_hex().to_string()))
        };
        let new_tree = commit.tree_id().map_err(EngineError::from_gix)?.detach();
        let changes = crate::tree::diff_trees(&repo, old_tree_id, new_tree)?;
        Ok(crate::log::CommitDiff {
            commit_id: id.to_hex().to_string(),
            parent_id,
            is_root: parents.is_empty(),
            parent_count: parents.len() as u32,
            changes,
        })
    }

    /// PGP/SSH 签名验证状态（`git verify-commit`）。
    pub fn commit_signature_status(
        &self,
        commit_id: String,
    ) -> Result<crate::log::SignatureStatus, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let id = repo
            .rev_parse_single(BStr::new(commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        if commit.signature().ok().flatten().is_none() {
            return Ok(crate::log::SignatureStatus::None);
        }
        let workdir = repo
            .workdir()
            .ok_or_else(|| EngineError::GitOperation {
                message: "verify-commit requires a non-bare worktree".into(),
            })?
            .to_path_buf();
        drop(commit);
        drop(repo);
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            "verify-commit",
        )
        .arg(commit_id)
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        let hay = format!("{}\n{}", outcome.stdout, outcome.stderr);
        let lower = hay.to_ascii_lowercase();
        if lower.contains("bad signature") {
            return Ok(crate::log::SignatureStatus::Invalid);
        }
        if lower.contains("good signature") {
            return Ok(crate::log::SignatureStatus::Valid);
        }
        Ok(crate::log::SignatureStatus::Unknown)
    }

    /// Load signature status for several commits in one background-friendly
    /// Git process.  This mirrors IntelliJ's windowed signature loader: Git
    /// supplies the compact status code, signer and fingerprint together, and
    /// the caller receives results in its requested commit order.
    pub fn commit_signature_statuses(
        &self,
        commit_ids: Vec<String>,
    ) -> Result<Vec<CommitSignatureInfo>, EngineError> {
        if commit_ids.is_empty() {
            return Ok(Vec::new());
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let mut resolved_ids = Vec::with_capacity(commit_ids.len());
        for commit_id in &commit_ids {
            let id = repo
                .rev_parse_single(BStr::new(commit_id.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            resolved_ids.push(id.to_hex().to_string());
        }
        let workdir = repo
            .workdir()
            .ok_or_else(|| EngineError::GitOperation {
                message: "commit signature status requires a non-bare worktree".into(),
            })?
            .to_path_buf();
        drop(repo);

        let format = "%H%x00%G?%x00%GS%x00%GF%x00";
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            "log",
        )
        .args([
            "--no-walk=unsorted".to_string(),
            format!("--format={format}"),
        ])
        .args(resolved_ids.clone())
        .working_dir(workdir)
        .timeout(std::time::Duration::from_secs(15));
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if outcome.exit_code != 0 {
            return Err(outcome.into_error(&spec));
        }

        let parsed: HashMap<String, CommitSignatureInfo> = outcome
            .stdout
            .split('\n')
            .filter_map(parse_commit_signature_record)
            .map(|info| (info.commit_id.clone(), info))
            .collect();
        resolved_ids
            .into_iter()
            .map(|id| {
                parsed
                    .get(&id)
                    .cloned()
                    .ok_or_else(|| EngineError::GitOperation {
                        message: format!("Git did not return signature status for commit {id}"),
                    })
            })
            .collect()
    }
    pub fn uncommit(&self) -> Result<(), EngineError> {
        self.uncommit_expected_head(String::new())
    }

    /// Move HEAD to its first parent while preserving the selected commit's
    /// root scope. An optional expected HEAD protects the UI chooser from
    /// undoing a newer commit if the repository changed while the dialog was
    /// open. The detached-HEAD path updates HEAD directly, matching `git
    /// reset --soft HEAD^` and IntelliJ's reset operation.
    pub fn uncommit_expected_head(&self, expected_head: String) -> Result<(), EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        use gix::refs::Target;

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let current = repo.head_id().map_err(EngineError::from_gix)?.detach();
        let expected_head = expected_head.trim();
        if !expected_head.is_empty() && current.to_hex().to_string() != expected_head {
            return Err(EngineError::GitOperation {
                message: format!(
                    "HEAD changed before uncommit (expected {expected_head}, found {})",
                    current.to_hex()
                ),
            });
        }
        let parent = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .parent_ids()
            .next()
            .ok_or_else(|| EngineError::GitOperation {
                message: "HEAD has no parent to uncommit to".into(),
            })?
            .detach();
        match repo.head_name().map_err(EngineError::from_gix)? {
            Some(head_name) => {
                repo.reference(
                    head_name,
                    parent,
                    PreviousValue::MustExistAndMatch(Target::Object(current)),
                    "reset: uncommit",
                )
                .map_err(EngineError::from_gix)?;
            }
            None => {
                let head_name: gix::refs::FullName =
                    "HEAD".try_into().map_err(EngineError::from_gix)?;
                repo.edit_reference(RefEdit {
                    change: Change::Update {
                        log: Default::default(),
                        expected: PreviousValue::MustExistAndMatch(Target::Object(current)),
                        new: Target::Object(parent),
                    },
                    name: head_name,
                    deref: true,
                })
                .map_err(EngineError::from_gix)?;
            }
        }
        Ok(())
    }

    /// Restore the commit that was just undone by `uncommit_expected_head`.
    ///
    /// This is intentionally a soft ref move: the index and worktree are not
    /// rewritten, so edits made after the Uncommit remain untouched. Both the
    /// current HEAD and symbolic branch are compared before the ref update so
    /// a stale notification cannot move a different branch or a newer commit.
    pub fn undo_uncommit_expected_head(
        &self,
        original_commit_id: String,
        expected_head: String,
        expected_branch: String,
    ) -> Result<(), EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        use gix::refs::Target;

        let original_commit_id = original_commit_id.trim();
        let expected_head = expected_head.trim();
        let expected_branch = expected_branch.trim();
        if original_commit_id.is_empty() || expected_head.is_empty() {
            return Err(EngineError::GitOperation {
                message: "undo uncommit requires an original and expected HEAD".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let current = repo.head_id().map_err(EngineError::from_gix)?.detach();
        if current.to_hex().to_string() != expected_head {
            return Err(EngineError::GitOperation {
                message: format!(
                    "HEAD changed before undo uncommit (expected {expected_head}, found {})",
                    current.to_hex()
                ),
            });
        }

        let current_branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        let actual_branch = current_branch.as_deref().unwrap_or("");
        if actual_branch != expected_branch {
            return Err(EngineError::GitOperation {
                message: format!(
                    "branch changed before undo uncommit (expected '{}', found '{}')",
                    if expected_branch.is_empty() {
                        "detached HEAD"
                    } else {
                        expected_branch
                    },
                    if actual_branch.is_empty() {
                        "detached HEAD"
                    } else {
                        actual_branch
                    }
                ),
            });
        }

        let original = repo
            .rev_parse_single(BStr::new(original_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let parent = repo
            .find_commit(original)
            .map_err(EngineError::from_gix)?
            .parent_ids()
            .next()
            .ok_or_else(|| EngineError::GitOperation {
                message: "the original uncommitted commit has no parent".into(),
            })?
            .detach();
        if parent != current {
            return Err(EngineError::GitOperation {
                message: "HEAD is no longer the parent produced by Uncommit".into(),
            });
        }

        match repo.head_name().map_err(EngineError::from_gix)? {
            Some(head_name) => {
                repo.reference(
                    head_name,
                    original,
                    PreviousValue::MustExistAndMatch(Target::Object(current)),
                    "reset: undo uncommit",
                )
                .map_err(EngineError::from_gix)?;
            }
            None => {
                let head_name: gix::refs::FullName =
                    "HEAD".try_into().map_err(EngineError::from_gix)?;
                repo.edit_reference(RefEdit {
                    change: Change::Update {
                        log: Default::default(),
                        expected: PreviousValue::MustExistAndMatch(Target::Object(current)),
                        new: Target::Object(original),
                    },
                    name: head_name,
                    deref: true,
                })
                .map_err(EngineError::from_gix)?;
            }
        }
        Ok(())
    }

    /// 按 Rebased/IntelliJ 的 reset 面板语义重置到目标提交。
    /// Soft 只移动 HEAD；Mixed 同时重置 index；Hard 再重置工作区；
    /// Keep 只覆盖目标 revision 相对当前 HEAD 发生变化的路径，并保留其它本地修改。
    pub fn reset(&self, commit_id: String, mode: ResetMode) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        reset_locked(&repo, &commit_id, mode, false)
    }

    /// Smart Reset preserving lifecycle. The direct reset path reports local
    /// overwrite paths; this retry saves the exact Stash/Shelf reference and
    /// restores it after the reset, leaving a marker when restoration conflicts.
    pub fn reset_with_policy(
        &self,
        commit_id: String,
        mode: ResetMode,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<(), EngineError> {
        let saved = prepare_apply_local_changes(self, "reset", save_policy)?;
        finish_apply_local_changes(self, "reset", saved, self.reset(commit_id, mode))
    }

    /// hard reset：HEAD/索引/工作区全部重置到目标提交（破坏性，未提交变更被覆盖）。
    pub fn reset_hard(&self, commit_id: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        reset_locked(&repo, &commit_id, ResetMode::Hard, true)
    }

    /// Reset while retaining a durable undo snapshot. The snapshot is created
    /// before the operation and verified again after it, so Undo can restore
    /// the complete pre-reset scene rather than merely moving HEAD back.
    ///
    /// `smart` is a fallback only for the same local-overwrite decision used
    /// by IntelliJ's Smart Reset dialog. `force` is intentionally restricted
    /// to Hard Reset and is the only path that permits overwriting the current
    /// tracked worktree.
    pub fn reset_with_recovery(
        &self,
        commit_id: String,
        mode: ResetMode,
        save_policy: LocalChangesSavePolicy,
        smart: bool,
        force: bool,
    ) -> Result<ResetRecoveryInfo, EngineError> {
        if smart && force {
            return Err(EngineError::GitOperation {
                message: "reset recovery cannot combine Smart and Force".into(),
            });
        }
        if force && mode != ResetMode::Hard {
            return Err(EngineError::GitOperation {
                message: "reset force is available only for Hard mode".into(),
            });
        }

        let (initial_head, initial_branch) = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            if reset_recovery_marker_path(&repo).exists() {
                return Err(EngineError::GitOperation {
                    message: "reset undo is still available; undo or keep the previous reset first"
                        .into(),
                });
            }
            let head = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach()
                .to_hex()
                .to_string();
            let branch = head_branch_identity(&repo)?;
            (head, branch)
        };

        let rollback_id = allocate_reset_recovery_id(self)?;
        let pre_ref = capture_reset_snapshot(self, &rollback_id, "pre")?;
        let operation = if force {
            self.reset_hard(commit_id.clone())
        } else {
            match self.reset(commit_id.clone(), mode) {
                Ok(()) => Ok(()),
                Err(error)
                    if smart
                        && matches!(&error, EngineError::LocalChangesWouldBeOverwritten { .. }) =>
                {
                    self.reset_with_policy(commit_id.clone(), mode, save_policy)
                }
                Err(error) => Err(error),
            }
        };

        if let Err(error) = operation {
            cleanup_reset_recovery(self, &rollback_id, pre_ref.as_deref(), None);
            return Err(error);
        }

        let (final_head, final_branch) = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            let head = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach()
                .to_hex()
                .to_string();
            let branch = head_branch_identity(&repo)?;
            (head, branch)
        };
        let post_ref = match capture_reset_snapshot(self, &rollback_id, "post") {
            Ok(reference) => reference,
            Err(error) => {
                cleanup_reset_recovery(self, &rollback_id, pre_ref.as_deref(), None);
                return Err(EngineError::GitOperation {
                    message: format!(
                        "reset completed, but its undo snapshot could not be recorded: {error}"
                    ),
                });
            }
        };

        let has_undo = initial_head != final_head
            || initial_branch != final_branch
            || pre_ref.is_some()
            || post_ref.is_some();
        if !has_undo {
            cleanup_reset_recovery(self, &rollback_id, pre_ref.as_deref(), post_ref.as_deref());
            return Ok(ResetRecoveryInfo {
                initial_head,
                final_head,
                initial_branch: Some(initial_branch),
                final_branch: Some(final_branch),
                rollback_id: None,
            });
        }

        let marker = ResetRecoveryMarker {
            id: rollback_id.clone(),
            mode,
            initial_head: initial_head.clone(),
            expected_head: final_head.clone(),
            initial_branch: initial_branch.clone(),
            expected_branch: final_branch.clone(),
            pre_ref: pre_ref.clone(),
            post_ref: post_ref.clone(),
        };
        if let Err(error) = write_reset_recovery_marker(self, &marker) {
            cleanup_reset_recovery(self, &rollback_id, pre_ref.as_deref(), post_ref.as_deref());
            return Err(EngineError::GitOperation {
                message: format!(
                    "reset completed, but its undo marker could not be persisted: {error}"
                ),
            });
        }

        Ok(ResetRecoveryInfo {
            initial_head,
            final_head,
            initial_branch: Some(initial_branch),
            final_branch: Some(final_branch),
            rollback_id: Some(rollback_id),
        })
    }

    /// Undo a reset only when the repository still matches the post-reset
    /// snapshot. The current worktree is first compared byte-for-byte against
    /// that snapshot; a later user edit therefore fails closed before any ref
    /// or file is changed.
    pub fn rollback_reset_recovery(&self, target: ResetRecoveryTarget) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let marker = load_reset_recovery_marker(&repo)?;
        if marker.id != target.rollback_id
            || marker.mode != target.mode
            || marker.initial_head != target.initial_head
            || marker.expected_head != target.expected_head
            || marker.expected_branch != target.expected_head_branch.clone().unwrap_or_default()
        {
            return Err(EngineError::GitOperation {
                message: "reset rollback refused: persisted snapshot does not match the action"
                    .into(),
            });
        }

        let expected = parse_commit_id(&repo, &marker.expected_head)?;
        let initial = parse_commit_id(&repo, &marker.initial_head)?;
        let current = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        if current != expected {
            return Err(EngineError::GitOperation {
                message: "reset rollback refused: HEAD changed after the reset".into(),
            });
        }
        let actual_branch = head_branch_identity(&repo)?;
        if actual_branch != marker.expected_branch {
            return Err(EngineError::GitOperation {
                message: "reset rollback refused: HEAD reference changed after the reset".into(),
            });
        }
        verify_reset_post_snapshot(&repo, marker.post_ref.as_deref(), expected)?;

        let expected_tree = repo
            .find_commit(expected)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        let initial_tree = repo
            .find_commit(initial)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();

        restore_head_ref_locked(&mut repo, initial, expected)?;
        if let Some(workdir) = repo.workdir() {
            materialize_tree(&repo, expected_tree, initial_tree, workdir)?;
        }
        reset_index_to_tree(&repo, initial_tree)?;
        remove_reset_post_untracked(&repo, marker.post_ref.as_deref(), initial_tree)?;
        if let Some(pre_ref) = marker.pre_ref.as_deref() {
            let pre_id = reset_snapshot_ref_id(&repo, pre_ref)?;
            stash_apply_with_id_locked(&repo, pre_id, true)?;
        }
        cleanup_reset_recovery_locked(&mut repo, &marker);
        Ok(())
    }

    /// Keep the reset result and release its durable undo snapshot. This is
    /// compare-and-swap guarded by the same post-reset scene check as Undo;
    /// silently discarding an undo snapshot after a later edit would make the
    /// persisted action lie about the state it protects.
    pub fn keep_reset_recovery(&self, target: ResetRecoveryTarget) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let marker = load_reset_recovery_marker(&repo)?;
        if marker.id != target.rollback_id
            || marker.mode != target.mode
            || marker.initial_head != target.initial_head
            || marker.expected_head != target.expected_head
            || marker.expected_branch != target.expected_head_branch.clone().unwrap_or_default()
        {
            return Err(EngineError::GitOperation {
                message: "reset keep refused: persisted snapshot does not match the action".into(),
            });
        }

        let expected = parse_commit_id(&repo, &marker.expected_head)?;
        let current = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        if current != expected {
            return Err(EngineError::GitOperation {
                message: "reset keep refused: HEAD changed after the reset".into(),
            });
        }
        let actual_branch = head_branch_identity(&repo)?;
        if actual_branch != marker.expected_branch {
            return Err(EngineError::GitOperation {
                message: "reset keep refused: HEAD reference changed after the reset".into(),
            });
        }
        verify_reset_post_snapshot(&repo, marker.post_ref.as_deref(), expected)?;
        cleanup_reset_recovery_locked(&mut repo, &marker);
        Ok(())
    }

    /// Restore a rebased local branch only when it still points at the exact
    /// tip produced by that rebase.  Current branches also restore the
    /// worktree and index with `--keep` semantics; non-current branches only
    /// move their ref and never disturb the checked-out worktree.
    pub fn restore_branch_if_expected(
        &self,
        branch: String,
        initial_commit_id: String,
        expected_commit_id: String,
    ) -> Result<(), EngineError> {
        use gix::refs::transaction::PreviousValue;
        use gix::refs::Target;

        let branch = branch.trim();
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if branch.is_empty() || branch == "HEAD" || branch.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "rollback branch name is invalid".into(),
            });
        }
        let branch_ref = format!("refs/heads/{branch}");
        let branch_name: gix::refs::FullName = branch_ref
            .as_str()
            .try_into()
            .map_err(EngineError::from_gix)?;
        let expected = repo
            .rev_parse_single(BStr::new(expected_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let initial = repo
            .rev_parse_single(BStr::new(initial_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let current = repo
            .find_reference(branch_ref.as_str())
            .map_err(EngineError::from_gix)?
            .try_id()
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("branch '{branch}' has no object id"),
            })?
            .detach();
        if current != expected {
            return Err(EngineError::GitOperation {
                message: format!(
                    "branch '{branch}' changed after the rebase; rollback is no longer safe"
                ),
            });
        }

        let current_branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        if current_branch.as_deref() == Some(branch) {
            let current_tree = repo
                .find_commit(expected)
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let target_tree = repo
                .find_commit(initial)
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            crate::merge::guard_uncommitted_overwrite(&repo, current_tree, target_tree)?;
            repo.reference(
                branch_name,
                initial,
                PreviousValue::MustExistAndMatch(Target::Object(expected)),
                "rebase: rollback",
            )
            .map_err(EngineError::from_gix)?;
            if let Some(workdir) = repo.workdir() {
                crate::merge::materialize_tree(&repo, current_tree, target_tree, workdir)?;
            }
            reset_index_to_tree(&repo, target_tree)?;
        } else {
            repo.reference(
                branch_name,
                initial,
                PreviousValue::MustExistAndMatch(Target::Object(expected)),
                "rebase: rollback",
            )
            .map_err(EngineError::from_gix)?;
        }
        Ok(())
    }

    /// Restore the checked-out HEAD only when Update Project still owns the
    /// exact tip it produced. This covers both a normal branch and a detached
    /// submodule HEAD, and refuses to overwrite local edits or a later user
    /// change made after the update.
    pub fn restore_head_if_expected(
        &self,
        initial_commit_id: String,
        expected_commit_id: String,
    ) -> Result<(), EngineError> {
        self.restore_head_if_expected_with_ignored_paths(
            initial_commit_id,
            expected_commit_id,
            Vec::new(),
        )
    }

    /// Restore only the HEAD ref after a soft reset when it still points at
    /// the exact result recorded by the operation. Soft reset does not touch
    /// the index or worktree, so this deliberately performs no materialize or
    /// index write; it is a narrower rollback than Update's full-tree restore.
    pub fn restore_head_ref_if_expected(
        &self,
        initial_commit_id: String,
        expected_commit_id: String,
        expected_head_branch: Option<String>,
    ) -> Result<(), EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        use gix::refs::Target;

        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let expected = repo
            .rev_parse_single(BStr::new(expected_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let initial = repo
            .rev_parse_single(BStr::new(initial_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let current = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        if current != expected {
            return Err(EngineError::GitOperation {
                message: "soft reset rollback refused: HEAD changed after the reset".into(),
            });
        }
        if let Some(expected_branch) = expected_head_branch {
            let actual_branch = repo
                .head_name()
                .map_err(EngineError::from_gix)?
                .map(|name| shorten_ref_name(name.as_bstr()))
                .unwrap_or_default();
            if actual_branch != expected_branch {
                return Err(EngineError::GitOperation {
                    message: "soft reset rollback refused: HEAD reference changed after the reset"
                        .into(),
                });
            }
        }

        let previous_reflog = repo.refs.write_reflog;
        repo.refs.write_reflog = gix::refs::store::WriteReflog::Disable;
        let edit_result = (|| -> Result<(), EngineError> {
            match repo.head_name().map_err(EngineError::from_gix)? {
                Some(name) => {
                    repo.edit_reference(RefEdit {
                        change: Change::Update {
                            log: Default::default(),
                            expected: PreviousValue::MustExistAndMatch(Target::Object(expected)),
                            new: Target::Object(initial),
                        },
                        name,
                        deref: false,
                    })
                    .map_err(EngineError::from_gix)?;
                }
                None => {
                    let head_name: gix::refs::FullName =
                        "HEAD".try_into().map_err(EngineError::from_gix)?;
                    repo.edit_reference(RefEdit {
                        change: Change::Update {
                            log: Default::default(),
                            expected: PreviousValue::MustExistAndMatch(Target::Object(expected)),
                            new: Target::Object(initial),
                        },
                        name: head_name,
                        deref: true,
                    })
                    .map_err(EngineError::from_gix)?;
                }
            }
            Ok(())
        })();
        repo.refs.write_reflog = previous_reflog;
        edit_result
    }

    /// Undo a completed Log Drop/Extract rewrite while preserving the current
    /// local scene whenever `reset --keep` can do so safely. The expected HEAD
    /// and symbolic branch are checked before the reset so a stale feedback
    /// action cannot rewrite a later commit or a different branch.
    pub fn undo_log_selected_changes_expected_head(
        &self,
        initial_commit_id: String,
        expected_head: String,
        expected_branch: String,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<(), EngineError> {
        let initial_commit_id = initial_commit_id.trim();
        let expected_head = expected_head.trim();
        let expected_branch = expected_branch.trim();
        if initial_commit_id.is_empty() || expected_head.is_empty() {
            return Err(EngineError::GitOperation {
                message: "undo selected changes requires an initial and expected HEAD".into(),
            });
        }

        let saved = prepare_apply_local_changes(self, "history-rewrite", save_policy)?;
        let result = (|| -> Result<(), EngineError> {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let current = repo.head_id().map_err(EngineError::from_gix)?.detach();
            if current.to_hex().to_string() != expected_head {
                Err(EngineError::GitOperation {
                    message: format!(
                        "HEAD changed before undo selected changes (expected {expected_head}, found {})",
                        current.to_hex()
                    ),
                })
            } else {
                let current_branch = repo
                    .head_name()
                    .map_err(EngineError::from_gix)?
                    .map(|name| shorten_ref_name(name.as_bstr()));
                let actual_branch = current_branch.as_deref().unwrap_or("");
                if actual_branch != expected_branch {
                    Err(EngineError::GitOperation {
                        message: format!(
                            "branch changed before undo selected changes (expected '{}', found '{}')",
                            if expected_branch.is_empty() {
                                "detached HEAD"
                            } else {
                                expected_branch
                            },
                            if actual_branch.is_empty() {
                                "detached HEAD"
                            } else {
                                actual_branch
                            }
                        ),
                    })
                } else {
                    let initial = repo
                        .rev_parse_single(BStr::new(initial_commit_id.as_bytes()))
                        .map_err(EngineError::from_gix)?
                        .detach();
                    if initial == current {
                        Err(EngineError::GitOperation {
                            message: "undo selected changes has no rewritten history to restore"
                                .into(),
                        })
                    } else {
                        reset_locked(&repo, initial_commit_id, ResetMode::Keep, false)
                    }
                }
            }
        })();
        finish_apply_local_changes(self, "history-rewrite", saved, result)
    }

    /// Expected-HEAD Update rollback with explicit nested-submodule paths.
    /// Gitlink changes are restored by the parent while the nested worktree is
    /// rolled back as its own target, so a child worktree must not be treated
    /// as an unrelated local overwrite of the parent rollback.
    pub fn restore_head_if_expected_with_ignored_paths(
        &self,
        initial_commit_id: String,
        expected_commit_id: String,
        ignored_paths: Vec<String>,
    ) -> Result<(), EngineError> {
        self.restore_head_if_expected_with_ignored_paths_and_branch(
            initial_commit_id,
            expected_commit_id,
            None,
            ignored_paths,
        )
    }

    /// Expected-HEAD rollback with an optional symbolic HEAD identity check.
    /// An empty expected branch means detached HEAD; `None` keeps compatibility
    /// with older persisted actions that only stored commit IDs.
    pub fn restore_head_if_expected_with_ignored_paths_and_branch(
        &self,
        initial_commit_id: String,
        expected_commit_id: String,
        expected_head_branch: Option<String>,
        ignored_paths: Vec<String>,
    ) -> Result<(), EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        use gix::refs::Target;

        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let expected = repo
            .rev_parse_single(BStr::new(expected_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let initial = repo
            .rev_parse_single(BStr::new(initial_commit_id.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let current = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        if current != expected {
            return Err(EngineError::GitOperation {
                message: "Update rollback refused: HEAD changed after the update".into(),
            });
        }
        if let Some(expected_branch) = expected_head_branch {
            let actual_branch = repo
                .head_name()
                .map_err(EngineError::from_gix)?
                .map(|name| shorten_ref_name(name.as_bstr()))
                .unwrap_or_default();
            if actual_branch != expected_branch {
                return Err(EngineError::GitOperation {
                    message: "Update rollback refused: HEAD reference changed after the update"
                        .into(),
                });
            }
        }

        let current_tree = repo
            .find_commit(expected)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        let target_tree = repo
            .find_commit(initial)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        crate::merge::guard_uncommitted_overwrite_ignoring_paths(
            &repo,
            current_tree,
            target_tree,
            &ignored_paths,
        )?;

        let previous_reflog = repo.refs.write_reflog;
        repo.refs.write_reflog = gix::refs::store::WriteReflog::Disable;
        let edit_result = (|| -> Result<(), EngineError> {
            match repo.head_name().map_err(EngineError::from_gix)? {
                Some(name) => {
                    repo.edit_reference(RefEdit {
                        change: Change::Update {
                            log: Default::default(),
                            expected: PreviousValue::MustExistAndMatch(Target::Object(expected)),
                            new: Target::Object(initial),
                        },
                        name,
                        deref: false,
                    })
                    .map_err(EngineError::from_gix)?;
                }
                None => {
                    let head_name: gix::refs::FullName =
                        "HEAD".try_into().map_err(EngineError::from_gix)?;
                    repo.edit_reference(RefEdit {
                        change: Change::Update {
                            log: Default::default(),
                            expected: PreviousValue::MustExistAndMatch(Target::Object(expected)),
                            new: Target::Object(initial),
                        },
                        name: head_name,
                        deref: true,
                    })
                    .map_err(EngineError::from_gix)?;
                }
            }
            Ok(())
        })();
        repo.refs.write_reflog = previous_reflog;
        edit_result?;
        if let Some(workdir) = repo.workdir() {
            if ignored_paths.is_empty() {
                crate::merge::materialize_tree(&repo, current_tree, target_tree, workdir)?;
            } else {
                crate::merge::materialize_tree_ignoring_paths(
                    &repo,
                    current_tree,
                    target_tree,
                    workdir,
                    &ignored_paths,
                )?;
            }
        }
        reset_index_to_tree(&repo, target_tree)
    }

    /// 从 HEAD 或指定 revision 恢复单个文件，包含已删除文件；同时恢复 index
    /// 和工作区，等价 `git restore --source <revision> --staged --worktree -- path`。
    pub fn restore_file(&self, path: String, revision: Option<String>) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative = worktree_relative_path(&path)?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "restore file requires a path".into(),
            });
        }
        let source = revision
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "HEAD".into());
        if source.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "restore revision must not start with '-'".into(),
            });
        }
        let workdir = worktree_root(&repo)?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args([
                "restore",
                "--source",
                source.as_str(),
                "--staged",
                "--worktree",
                "--",
                path.as_str(),
            ])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(EngineError::GitOperation {
                message: format!("git restore failed: {detail}"),
            });
        }
        Ok(())
    }

    /// 仅撤销工作区相对 index 的未暂存变更，等价于
    /// `git restore --worktree -- <path>`。index 保持不变，供 Staging
    /// diff preview 的 Git.Stage.Revert 使用；它不能退化为从 HEAD 恢复，
    /// 否则部分暂存文件会被错误地整体清空。
    pub fn restore_unstaged_path(&self, path: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let relative = worktree_relative_path(&path)?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "restore unstaged path requires a file path".into(),
            });
        }
        let relative = relative.to_string_lossy().into_owned();
        let workdir = worktree_root(&repo)?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["restore", "--worktree", "--", relative.as_str()])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(EngineError::GitOperation {
                message: format!("git restore unstaged path failed: {detail}"),
            });
        }
        Ok(())
    }

    /// checkout 到指定提交并进入 detached HEAD；工作区有未提交变更时由 git 拒绝。
    /// 这里沿用引擎中 push/tag/submodule 的系统 git 边界，保留 git 原生的
    /// 路径保护和错误信息，不把 checkout 误实现成只移动当前分支。
    pub fn checkout_detached(&self, commit_id: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        checkout_detached_inner(&repo, &commit_id, false)
    }

    /// Smart Checkout：保存本地 tracked/untracked 变更，进入 detached HEAD，
    /// 再把现场恢复到目标 revision；冲突时保留 stash 供 UI 继续处理。
    pub fn smart_checkout_detached(&self, commit_id: String) -> Result<(), EngineError> {
        self.smart_checkout_detached_with_policy(commit_id, LocalChangesSavePolicy::Stash)
    }

    /// Smart Checkout with IntelliJ's local-changes save policy.
    pub fn smart_checkout_detached_with_policy(
        &self,
        commit_id: String,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<(), EngineError> {
        self.smart_checkout_detached_with_policy_and_cancel(
            commit_id,
            save_policy,
            crate::gitprocess::GitCancelHandle::new(),
        )
    }

    /// Cancellable Smart Checkout with IntelliJ's local-changes save policy.
    pub fn smart_checkout_detached_with_policy_and_cancel(
        &self,
        commit_id: String,
        save_policy: LocalChangesSavePolicy,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let label = format!("Arbor: Smart Checkout to {commit_id}");
        smart_checkout_with_policy(
            self,
            label,
            save_policy,
            Some(cancel.token()),
            move |repo| checkout_detached_inner(repo, &commit_id, false),
        )
    }

    /// Force Checkout：明确放弃会被目标 revision 覆盖的工作区内容。
    pub fn force_checkout_detached(&self, commit_id: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        checkout_detached_inner(&repo, &commit_id, true)
    }

    /// 逆提交：使用标准 Git 的 revert 状态机生成逆提交。
    ///
    /// 不能用一次性的 tree 编辑替代这里的操作：发生冲突时 Git 必须
    /// 留下 REVERT_HEAD、冲突索引和工作树，让 UI 可以进入同一个
    /// Continue/Abort 工作台。commit_id 支持短 id（Git 自己解析）。
    pub fn revert(&self, commit_id: String) -> Result<String, EngineError> {
        self.revert_many(vec![commit_id], None)
    }

    /// 按 UI 给出的顺序执行多个 Revert。
    ///
    /// Git 会维护完整的 revert sequencer，因此冲突后 Continue/Abort 仍
    /// 能恢复整条序列。merge commit 默认拒绝，匹配 IntelliJ 日志 action；
    /// 只有显式传入 mainline 的内部调用方才允许处理 merge commit。
    pub fn revert_many(
        &self,
        commit_ids: Vec<String>,
        mainline: Option<RevertMainline>,
    ) -> Result<String, EngineError> {
        let commit_ids = normalize_commit_sequence(commit_ids, "revert")?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        for commit_id in &commit_ids {
            let target_id = repo
                .rev_parse_single(BStr::new(commit_id.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let target = repo.find_commit(target_id).map_err(EngineError::from_gix)?;
            let parent_count = target.parent_ids().count();
            if parent_count == 0 {
                return Err(EngineError::GitOperation {
                    message: "cannot revert a root commit".into(),
                });
            }
            if parent_count > 1 && mainline.is_none() {
                return Err(EngineError::GitOperation {
                    message: "cannot revert a merge commit without an explicit mainline".into(),
                });
            }
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "revert: bare repository has no worktree".into(),
        })?;
        let mut spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Revert,
            "revert",
        )
        .args(["--no-edit"])
        .working_dir(workdir);
        if let Some(mainline) = mainline {
            spec = spec.arg("-m").arg(match mainline {
                RevertMainline::First => "1",
                RevertMainline::Second => "2",
            });
        }
        for commit_id in commit_ids {
            spec = spec.arg(commit_id);
        }
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            let output = format!("{}\n{}", outcome.stdout, outcome.stderr).to_lowercase();
            let empty = output.contains("nothing to commit")
                || output.contains("previous revert is now empty")
                || output.contains("nothing added to commit");
            let has_revert_state = repo.git_dir().join("REVERT_HEAD").exists()
                || repo.git_dir().join("sequencer").exists();
            if empty && !has_revert_state {
                return current_head_after_git_command(workdir);
            }
            if empty && has_revert_state {
                let (ok, recovery_output) = crate::opstate::run_recovery(
                    workdir,
                    crate::opstate::OperationKind::Revert,
                    crate::opstate::RecoveryAction::Skip,
                )?;
                if ok {
                    return current_head_after_git_command(workdir);
                }
                return Err(EngineError::GitOperation {
                    message: format!("git revert --skip failed: {recovery_output}"),
                });
            }
            return Err(outcome.into_error(&spec));
        }
        current_head_after_git_command(workdir)
    }

    /// Revert with IntelliJ's Save local changes and retry lifecycle. The
    /// ordinary API remains unchanged for callers that already guarantee a
    /// clean worktree.
    pub fn revert_many_with_policy(
        &self,
        commit_ids: Vec<String>,
        mainline: Option<RevertMainline>,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<String, EngineError> {
        let saved = prepare_apply_local_changes(self, "revert", save_policy)?;
        finish_apply_local_changes(
            self,
            "revert",
            saved,
            self.revert_many(commit_ids, mainline),
        )
    }

    /// 将指定提交交给标准 Git cherry-pick 状态机。
    ///
    /// 成功时返回新提交 id；冲突时保留 CHERRY_PICK_HEAD、冲突索引和
    /// 工作树，供 operation_state/cherry_pick_continue/cherry_pick_abort
    /// 恢复。这与 IntelliJ 的 Git 操作模型一致。
    pub fn cherry_pick(&self, commit_id: String) -> Result<String, EngineError> {
        self.cherry_pick_many(vec![commit_id])
    }

    /// 按给定顺序把多个提交交给 Git sequencer。
    ///
    /// 使用一次 `git cherry-pick <commit>...` 而不是在 Swift 层逐个调用，
    /// 这样冲突时 Git 会保留完整的 sequencer 状态；解决并 Continue 后，
    /// Git 能继续应用剩余提交，和 IntelliJ 的多选 Cherry-pick 交互一致。
    pub fn cherry_pick_many(&self, commit_ids: Vec<String>) -> Result<String, EngineError> {
        self.cherry_pick_many_with_options(commit_ids, CherryPickEmptyPolicy::Skip, false)
    }

    /// 按给定顺序执行 Cherry-pick，并处理 IntelliJ 风格的空提交策略。
    ///
    /// `append_suffix` 对应 Git 的 `-x`：调用方应只在所选提交全部已发布到
    /// 受保护远程分支时打开它。旧的 `cherry_pick_many` 保持 Skip + 不追加尾缀。
    pub fn cherry_pick_many_with_options(
        &self,
        commit_ids: Vec<String>,
        empty_policy: CherryPickEmptyPolicy,
        append_suffix: bool,
    ) -> Result<String, EngineError> {
        let commit_ids = normalize_commit_sequence(commit_ids, "cherry-pick")?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?;
        let mut spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::CherryPick,
            "cherry-pick",
        )
        .working_dir(workdir);
        if append_suffix {
            spec = spec.arg("-x");
        }
        let commit_count = commit_ids.len();
        for commit_id in commit_ids {
            spec = spec.arg(commit_id);
        }
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return resolve_cherry_pick_sequence(
                &repo,
                workdir,
                empty_policy,
                outcome,
                spec,
                commit_count,
            );
        }
        current_head_for_category(workdir, crate::gitprocess::GitCommandCategory::CherryPick)
    }

    /// Cherry-pick with IntelliJ's Save local changes and retry lifecycle.
    /// Local changes are saved only when this policy-enabled entry point is
    /// used; the clean-worktree API above remains a direct Git operation.
    pub fn cherry_pick_many_with_options_and_policy(
        &self,
        commit_ids: Vec<String>,
        empty_policy: CherryPickEmptyPolicy,
        append_suffix: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<String, EngineError> {
        let saved = prepare_apply_local_changes(self, "cherry-pick", save_policy)?;
        finish_apply_local_changes(
            self,
            "cherry-pick",
            saved,
            self.cherry_pick_many_with_options(commit_ids, empty_policy, append_suffix),
        )
    }

    /// 创建轻量 tag，默认指向 HEAD。
    pub fn tag_create(&self, name: String, at: Option<String>) -> Result<(), EngineError> {
        self.tag_create_with_force(name, at, false)
    }

    /// 创建或显式覆盖轻量 tag，默认指向 HEAD。
    ///
    /// `force` 只影响已存在的目标 tag；调用方必须把它作为明确的用户
    /// 选择传入，默认路径仍然保持 Git 的 MustNotExist 保护。
    pub fn tag_create_with_force(
        &self,
        name: String,
        at: Option<String>,
        force: bool,
    ) -> Result<(), EngineError> {
        use gix::refs::transaction::PreviousValue;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let target = match at.filter(|s| !s.trim().is_empty()) {
            Some(spec) => repo
                .rev_parse_single(BStr::new(spec.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach(),
            None => repo.head_id().map_err(EngineError::from_gix)?.detach(),
        };
        let full: gix::refs::FullName = format!("refs/tags/{name}")
            .as_str()
            .try_into()
            .map_err(EngineError::from_gix)?;
        repo.reference(
            full,
            target,
            if force {
                PreviousValue::Any
            } else {
                PreviousValue::MustNotExist
            },
            if force {
                "tag: forced update"
            } else {
                "tag: created"
            },
        )
        .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 创建 annotated tag；`sign_key` 非空时使用系统 Git 创建签名 tag。
    pub fn tag_create_with_options(
        &self,
        name: String,
        at: Option<String>,
        message: String,
        sign_key: Option<String>,
    ) -> Result<(), EngineError> {
        self.tag_create_with_options_and_force(name, at, message, sign_key, false)
    }

    /// 创建 annotated tag，并允许调用方显式覆盖已有 tag。
    pub fn tag_create_with_options_and_force(
        &self,
        name: String,
        at: Option<String>,
        message: String,
        sign_key: Option<String>,
        force: bool,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "tag creation requires a non-bare worktree".into(),
        })?;
        let message = message.trim().to_string();
        if message.is_empty() {
            return Err(EngineError::GitOperation {
                message: "annotated tag message must not be empty".into(),
            });
        }
        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        command.arg("tag");
        if force {
            command.arg("--force");
        }
        if let Some(key) = sign_key.filter(|key| !key.trim().is_empty()) {
            command.args(["--sign", "--local-user", key.trim()]);
        } else {
            command.arg("--annotate");
        }
        command.args(["--message", &message, &name]);
        if let Some(revision) = at.filter(|revision| !revision.trim().is_empty()) {
            command.arg(revision);
        }
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git tag creation failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        Ok(())
    }

    /// 删除 tag。
    pub fn tag_delete(&self, name: String) -> Result<(), EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit, RefLog};
        use gix::refs::Target;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let full = format!("refs/tags/{name}");
        let target = repo
            .find_reference(full.as_str())
            .map_err(EngineError::from_gix)?
            .try_id()
            .ok_or_else(|| EngineError::GitOperation {
                message: "tag has no object id".into(),
            })?
            .detach();
        let full_name: gix::refs::FullName =
            full.as_str().try_into().map_err(EngineError::from_gix)?;
        repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::MustExistAndMatch(Target::Object(target)),
                log: RefLog::AndReference,
            },
            name: full_name,
            deref: false,
        })
        .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// Phase 5：重命名 tag（git 无原生 rename：新 tag 指向原 tag 的提交，再删旧 tag）。
    pub fn tag_rename(&self, old: String, new: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let target = repo
            .rev_parse_single(BStr::new(old.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "tag rename requires a non-bare worktree".into(),
        })?;
        let create = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Tag,
            "tag",
        )
        .args([&new, &target.to_hex().to_string()])
        .working_dir(&workdir);
        let outcome = crate::gitprocess::run_to_completion(&create)?;
        if !outcome.success() {
            return Err(outcome.into_error(&create));
        }
        let remove = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Tag,
            "tag",
        )
        .args(["-d", &old])
        .working_dir(&workdir);
        let outcome = crate::gitprocess::run_to_completion(&remove)?;
        if !outcome.success() {
            return Err(outcome.into_error(&remove));
        }
        Ok(())
    }

    /// 列出 tag。
    pub fn tag_list(&self) -> Result<Vec<crate::branch::TagInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::branch::list_tags(&repo)
    }

    /// List tags directly from a configured remote. This intentionally does
    /// not update remote-tracking refs or the local tag list.
    pub fn remote_tag_list(&self, remote: String) -> Result<Vec<RemoteTagInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        list_remote_tags_locked(&repo, &remote, None, None)
    }

    /// List remote tags through the credential broker for explicit UI actions.
    pub fn remote_tag_list_with_auth(
        &self,
        remote: String,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<Vec<RemoteTagInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        list_remote_tags_locked(&repo, &remote, Some(&broker), None)
    }

    /// List remote tags through the credential broker with process-group
    /// cancellation for an explicit UI operation.
    pub fn remote_tag_list_with_auth_and_cancel(
        &self,
        remote: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<Vec<RemoteTagInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        list_remote_tags_locked(&repo, &remote, Some(&broker), Some(cancel.token()))
    }

    /// Check configured upstream branches against the live remote without
    /// updating local remote-tracking refs. This is IntelliJ's LS_REMOTE
    /// incoming-change strategy: callers can show an "unfetched" signal while
    /// leaving the user's local refs untouched until an explicit Fetch.
    pub fn remote_incoming_branches_with_auth_and_cancel(
        &self,
        remote: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        remote_incoming_branches_locked(&repo, &remote, Some(&broker), Some(cancel.token()))
    }

    /// Cancellable incoming check with no credential interaction.  This is
    /// the IntelliJ `AuthenticationMode.NONE` pass used before a remote has
    /// successfully authenticated in this app session.
    pub fn remote_incoming_branches_without_auth_and_cancel(
        &self,
        remote: String,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        remote_incoming_branches_locked_with_auth_mode(
            &repo,
            &remote,
            None,
            Some(cancel.token()),
            RemoteAuthMode::NoAuthentication,
        )
    }

    /// Cancellable incoming check that reuses stored credentials only.  It
    /// never opens the SwiftUI credential dialog.
    pub fn remote_incoming_branches_with_silent_auth_and_cancel(
        &self,
        remote: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        remote_incoming_branches_locked_with_auth_mode(
            &repo,
            &remote,
            Some(&broker),
            Some(cancel.token()),
            RemoteAuthMode::Silent,
        )
    }

    /// 将 tag 推送到远程；tag_push 不隐式推送整个分支。
    pub fn tag_push(&self, remote: Option<String>, tag: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = remote.unwrap_or(crate::remote::default_remote_name(&repo)?);
        let name = name.trim();
        remote_name_ok(name)?;
        let spec = tag_refspec(&tag)?;
        push_refspec_inner(&repo, name, &spec, false, false, None, false, None, None)
    }

    /// Push one tag through the same credential broker and cancellation path
    /// as branch pushes. The tag refspec is explicit so this never publishes
    /// the current branch as a side effect.
    pub fn tag_push_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        tag: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = remote.unwrap_or(crate::remote::default_remote_name(&repo)?);
        let name = name.trim();
        remote_name_ok(name)?;
        let spec = tag_refspec(&tag)?;
        push_refspec_inner(
            &repo,
            name,
            &spec,
            false,
            false,
            None,
            false,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// 删除指定 remote 上的 tag。
    ///
    /// 先读取远端当前的 tag object id，再用 `--force-with-lease` 删除，
    /// 避免在确认后远端 tag 被其他人改写时误删新值。返回值表示远端
    /// 是否曾存在这个 tag；不存在时按 IntelliJ 的幂等语义返回 false。
    pub fn delete_remote_tag(&self, remote: String, tag: String) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_tag_locked(&repo, &remote, &tag, None, None, None)
    }

    /// Delete a remote tag using a force-with-lease and the credential broker.
    pub fn delete_remote_tag_with_auth(
        &self,
        remote: String,
        tag: String,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_tag_locked(&repo, &remote, &tag, None, Some(&broker), None)
    }

    /// Delete a remote tag only if it still points at the object shown to the
    /// user. The final force-with-lease remains the server-side race guard;
    /// this precondition prevents deleting a newer tag after a stale list.
    pub fn delete_remote_tag_with_auth_lease(
        &self,
        remote: String,
        tag: String,
        expected_object_id: String,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_tag_locked(
            &repo,
            &remote,
            &tag,
            Some(expected_object_id.trim()),
            Some(&broker),
            None,
        )
    }

    /// Delete a remote tag with the displayed object-id lease and a
    /// process-group cancellation handle. Cancellation applies to both the
    /// preflight `ls-remote` and the final lease-protected push.
    pub fn delete_remote_tag_with_auth_lease_and_cancel(
        &self,
        remote: String,
        tag: String,
        expected_object_id: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_tag_locked(
            &repo,
            &remote,
            &tag,
            Some(expected_object_id.trim()),
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// 添加子模块（stretch）：委托系统 git，保留 .gitmodules 的标准语义。
    pub fn submodule_add(&self, url: String, path: String) -> Result<(), EngineError> {
        self.submodule_add_inner(url, path, None, None)
    }

    /// 使用凭证代理并支持进程组取消添加子模块。
    pub fn submodule_add_with_auth_and_cancel(
        &self,
        url: String,
        path: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.submodule_add_inner(url, path, Some(broker), Some(cancel))
    }

    fn submodule_add_inner(
        &self,
        url: String,
        path: String,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<(), EngineError> {
        let url = url.trim().to_owned();
        let path = path.trim().to_owned();
        if url.is_empty() || url.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "submodule URL must not be empty or start with '-'".into(),
            });
        }
        if path.is_empty()
            || path.starts_with('-')
            || path.starts_with('/')
            || path.ends_with('/')
            || path
                .split('/')
                .any(|component| component.is_empty() || component == ".")
            || path.split('/').any(|component| component == "..")
        {
            return Err(EngineError::GitOperation {
                message: "submodule path must be a non-empty relative path".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?;
        let is_local_url = url.starts_with('/')
            || url.starts_with("./")
            || url.starts_with("../")
            || url.starts_with("file://");
        let mut spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args(["add", "--"])
        .arg(url)
        .arg(path)
        .working_dir(workdir);
        // `git submodule add` launches a nested clone which does not inherit
        // the parent's local protocol.file.allow setting. The user explicitly
        // supplied a local URL here, so opt in for this command only; remote
        // URLs retain Git's default transport policy.
        if is_local_url {
            spec.global_args = vec!["-c".into(), "protocol.file.allow=always".into()];
        }
        run_submodule_command_spec(
            &spec,
            broker.as_deref(),
            cancel.as_ref().map(|cancel| cancel.token()),
        )
    }

    /// 更新所有子模块。
    pub fn submodule_update(&self) -> Result<(), EngineError> {
        self.submodule_update_with_options(true, true, false)
    }

    /// 更新所有子模块，并通过凭证代理传播到嵌套 clone/fetch；支持取消。
    pub fn submodule_update_with_options_with_auth_and_cancel(
        &self,
        init: bool,
        recursive: bool,
        remote: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.submodule_update_with_options_inner(
            init,
            recursive,
            remote,
            Some(broker),
            Some(cancel),
        )
    }

    /// 同步 `.gitmodules` 中的 URL 到本地配置。
    pub fn submodule_sync(&self) -> Result<(), EngineError> {
        self.run_submodule_command(vec!["sync".into(), "--recursive".into()])
    }

    /// 同步 `.gitmodules` 配置，并支持凭证代理和取消。
    pub fn submodule_sync_with_auth_and_cancel(
        &self,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.run_submodule_command_with_auth_and_cancel(
            vec!["sync".into(), "--recursive".into()],
            Some(broker),
            Some(cancel),
        )
    }

    /// 初始化并更新指定子模块；path 为空时处理全部子模块。
    pub fn submodule_list(&self) -> Result<Vec<SubmoduleInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule status requires a non-bare worktree".into(),
        })?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["submodule", "status", "--recursive"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() && output.stdout.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git submodule status failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        let mut modules = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let line = line.trim_end();
            let Some((state_char, rest)) = line.split_at_checked(1) else {
                continue;
            };
            let mut fields = rest.trim_start().splitn(3, char::is_whitespace);
            let Some(head_id) = fields.next() else {
                continue;
            };
            let Some(path) = fields.next() else { continue };
            let state = match state_char {
                "-" => SubmoduleState::Uninitialized,
                "+" => SubmoduleState::Modified,
                "U" => SubmoduleState::Conflict,
                " " => SubmoduleState::Clean,
                _ => SubmoduleState::Unknown,
            };
            let path = path.trim().to_string();
            let state = if !workdir.join(&path).exists() && state == SubmoduleState::Clean {
                SubmoduleState::Missing
            } else {
                state
            };
            // dirty:子模块工作区有未提交变更
            let dirty = workdir.join(&path).join(".git").exists()
                && crate::gitprocess::git_command_for_working_dir(workdir.join(&path))
                    .args(["status", "--porcelain"])
                    .current_dir(workdir.join(&path))
                    .output()
                    .map(|o| !o.stdout.is_empty())
                    .unwrap_or(false);
            // branch:.gitmodules 中该子模块段的 branch 配置
            let gitmodules =
                std::fs::read_to_string(workdir.join(".gitmodules")).unwrap_or_default();
            let mut branch = None;
            let mut in_module = false;
            for line in gitmodules.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("[submodule ") {
                    in_module = trimmed.contains(&format!("\"{path}\""));
                    continue;
                }
                if in_module {
                    if let Some(value) = trimmed.strip_prefix("branch =") {
                        branch = Some(value.trim().to_string());
                        break;
                    }
                }
            }
            modules.push(SubmoduleInfo {
                path,
                head_id: head_id.to_string(),
                state,
                branch,
                dirty,
            });
        }
        Ok(modules)
    }

    /// Check the nested worktree for untracked or ignored files before a
    /// forced remove. Ordinary `SubmoduleInfo.dirty` intentionally describes
    /// Git changes, but a forced remove also deletes ignored build artifacts;
    /// an expected-state Undo must refuse that irreversible boundary.
    pub fn submodule_worktree_has_untracked_or_ignored_files(
        &self,
        path: String,
    ) -> Result<bool, EngineError> {
        let relative = worktree_relative_path(path.trim())?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "submodule worktree status requires a path".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule worktree status requires a non-bare worktree".into(),
        })?;
        let nested_path = workdir.join(relative);
        if !nested_path.is_dir() {
            return Err(EngineError::GitOperation {
                message: "submodule worktree status requires an initialized worktree".into(),
            });
        }
        let output = crate::gitprocess::git_command_for_working_dir(&nested_path)
            .args([
                "status",
                "--porcelain",
                "--untracked-files=all",
                "--ignored",
            ])
            .current_dir(&nested_path)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git submodule worktree status failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        Ok(!output.stdout.is_empty())
    }

    /// 打开指定子模块自己的提交日志。
    ///
    /// IntelliJ 将子模块视为嵌套 Git root，而不是把 gitlink 当作普通文件；
    /// 因此这里必须在子模块仓库上收集 refs/graph，不能复用父仓库的 log。
    pub fn submodule_log(&self, path: String, limit: u32) -> Result<Vec<CommitInfo>, EngineError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let relative = worktree_relative_path(path.trim())?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "submodule log requires a submodule path".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let head_tree_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        let head_tree = repo
            .find_tree(head_tree_id)
            .map_err(EngineError::from_gix)?;
        let relative_string = relative.to_string_lossy();
        let entry = head_tree
            .lookup_entry_by_path(relative_string.as_ref())
            .map_err(EngineError::from_gix)?;
        if !entry.is_some_and(|entry| entry.mode().is_commit()) {
            return Err(EngineError::GitOperation {
                message: format!("{relative_string} is not a submodule in HEAD"),
            });
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule log requires a non-bare worktree".into(),
        })?;
        let submodule_workdir = workdir.join(&relative);
        if !submodule_workdir.is_dir() {
            return Err(EngineError::GitOperation {
                message: format!("submodule {relative_string} is not initialized"),
            });
        }
        if !submodule_workdir.join(".git").exists() {
            return Err(EngineError::GitOperation {
                message: format!("submodule {relative_string} is not initialized"),
            });
        }
        let submodule_repo = gix::open(&submodule_workdir).map_err(EngineError::from_gix)?;
        crate::log::collect_log(
            &submodule_repo,
            None,
            limit,
            false,
            None,
            None,
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            None,
            crate::log::LogGraphSortMode::ByCommitDate,
        )
    }

    /// Describe a gitlink change between two superproject revisions.
    ///
    /// The nested commit range is intentionally read from the initialized
    /// submodule repository, while the old/new pointers come from the parent
    /// trees. This mirrors IntelliJ's split model: the parent diff owns the
    /// gitlink, and the nested Git root owns the commit history.
    pub fn submodule_change(
        &self,
        rev1: String,
        rev2: String,
        path: String,
        limit: u32,
    ) -> Result<SubmoduleChange, EngineError> {
        let relative = worktree_relative_path(path.trim())?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "submodule change requires a submodule path".into(),
            });
        }
        let path = relative.to_string_lossy().into_owned();
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let old_id = submodule_gitlink_at_revision(&repo, rev1.trim(), &path)?;
        let new_id = submodule_gitlink_at_revision(&repo, rev2.trim(), &path)?;
        if old_id.is_none() && new_id.is_none() {
            return Err(EngineError::GitOperation {
                message: format!("{path} is not a gitlink in either revision"),
            });
        }

        let nested_path = repo
            .workdir()
            .ok_or_else(|| EngineError::GitOperation {
                message: "submodule change requires a non-bare worktree".into(),
            })?
            .join(&relative);
        let nested_repo = if nested_path.is_dir() {
            gix::open(&nested_path).ok()
        } else {
            None
        };
        let initialized = nested_repo.is_some();
        let current_commit = nested_repo.as_ref().and_then(|nested| {
            nested
                .head_commit()
                .ok()
                .map(|commit| commit.id().to_hex().to_string())
        });
        let dirty = initialized
            && crate::gitprocess::git_command_for_working_dir(&nested_path)
                .args(["status", "--porcelain"])
                .current_dir(&nested_path)
                .output()
                .map(|output| !output.stdout.is_empty())
                .unwrap_or(false);

        let nested_changes = match (nested_repo.as_ref(), old_id, new_id) {
            (Some(nested), old_id, new_id) => {
                let empty_tree = nested.empty_tree().id;
                let tree_id = |commit_id: Option<gix::ObjectId>| match commit_id {
                    None => Some(empty_tree),
                    Some(id) => nested
                        .find_commit(id)
                        .ok()
                        .and_then(|commit| commit.tree().ok())
                        .map(|tree| tree.id),
                };
                match (tree_id(old_id), tree_id(new_id)) {
                    (Some(old_tree), Some(new_tree)) => {
                        crate::tree::diff_trees(nested, old_tree, new_tree).unwrap_or_default()
                    }
                    // A gitlink can point at an object that is not present in
                    // the shallow/local nested repository. Do not turn that
                    // unavailable commit into a fake all-added/all-deleted
                    // diff; the commit range above already reports it as
                    // unavailable by remaining empty.
                    _ => Vec::new(),
                }
            }
            (None, _, _) => Vec::new(),
        };

        let commits = match (nested_repo.as_ref(), new_id, old_id) {
            (Some(nested), Some(new_id), old_id)
                if nested.find_commit(new_id).is_ok()
                    && old_id
                        .map(|old_id| nested.find_commit(old_id).is_ok())
                        .unwrap_or(true) =>
            {
                crate::log::collect_log(
                    nested,
                    None,
                    limit,
                    false,
                    Some(vec![new_id]),
                    old_id.map(|id| vec![id]),
                    None,
                    None,
                    None,
                    None,
                    false,
                    false,
                    false,
                    None,
                    crate::log::LogGraphSortMode::ByCommitDate,
                )?
            }
            _ => Vec::new(),
        };

        Ok(SubmoduleChange {
            path,
            old_commit: old_id.map(|id| id.to_hex().to_string()),
            new_commit: new_id.map(|id| id.to_hex().to_string()),
            current_commit,
            initialized,
            dirty,
            commits,
            nested_changes,
        })
    }

    /// Phase 5：反初始化子模块（`git submodule deinit -f <path>`），
    /// 清空其工作区内容（.gitmodules 配置保留）。
    pub fn submodule_deinit(&self, path: String, force: bool) -> Result<(), EngineError> {
        self.submodule_deinit_inner(path, force, None, None)
    }

    /// 反初始化子模块并支持凭证代理/取消。
    pub fn submodule_deinit_with_auth_and_cancel(
        &self,
        path: String,
        force: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.submodule_deinit_inner(path, force, Some(broker), Some(cancel))
    }

    fn submodule_deinit_inner(
        &self,
        path: String,
        force: bool,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule deinit requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args(["deinit"])
        .flag_if("--force", force)
        .arg(&path)
        .working_dir(workdir);
        run_submodule_command_spec(
            &spec,
            broker.as_deref(),
            cancel.as_ref().map(|cancel| cancel.token()),
        )
    }

    /// Phase 5：带选项的子模块更新（`git submodule update`），
    /// 支持 init、递归与 `--remote`（按 .gitmodules 的 branch 更新）。
    pub fn submodule_update_with_options(
        &self,
        init: bool,
        recursive: bool,
        remote: bool,
    ) -> Result<(), EngineError> {
        self.submodule_update_with_options_inner(init, recursive, remote, None, None)
    }

    fn submodule_update_with_options_inner(
        &self,
        init: bool,
        recursive: bool,
        remote: bool,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule update requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args(["update"])
        .flag_if("--init", init)
        .flag_if("--recursive", recursive)
        .flag_if("--remote", remote)
        .working_dir(workdir);
        run_submodule_command_spec(
            &spec,
            broker.as_deref(),
            cancel.as_ref().map(|cancel| cancel.token()),
        )
    }

    /// Update one submodule from its parent repository with cancellation.
    ///
    /// This is the operation IntelliJ uses for a detached submodule root:
    /// the parent gitlink is authoritative, so the update must run from the
    /// parent with `git submodule update --recursive -- <path>`.
    pub fn submodule_update_path_with_cancel(
        &self,
        path: String,
        recursive: bool,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.submodule_update_path_inner(path, recursive, None, cancel)
    }

    /// Update one detached submodule through the credential broker and the
    /// same process-group cancellation used by Update Project.
    pub fn submodule_update_path_with_auth_and_cancel(
        &self,
        path: String,
        recursive: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.submodule_update_path_inner(path, recursive, Some(broker), cancel)
    }

    fn submodule_update_path_inner(
        &self,
        path: String,
        recursive: bool,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let relative = worktree_relative_path(path.trim())?;
        if relative.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "submodule path must not be empty".into(),
            });
        }
        let relative = relative.to_string_lossy().into_owned();
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule update requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        // A nested local submodule fetch is executed by a child Git process;
        // the parent repository's local protocol setting is not inherited.
        // This is the same explicit local-transport allowance used by
        // submodule add and keeps Update Project usable for local fixtures.
        .global_arg("-c")
        .global_arg("protocol.file.allow=always")
        .args(["update"])
        .flag_if("--recursive", recursive)
        .separator()
        .arg(relative)
        .working_dir(workdir);
        run_submodule_command_spec(&spec, broker.as_deref(), Some(cancel.token()))
    }

    /// Phase 5：配置子模块跟踪的分支（.gitmodules 的 submodule.<path>.branch）。
    pub fn submodule_set_branch(&self, path: String, branch: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule branch requires a non-bare worktree".into(),
        })?;
        let key = format!("submodule.{path}.branch");
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "config",
        )
        .args(["-f", ".gitmodules", &key, &branch])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 反初始化指定子模块并从索引/工作树移除它。
    pub fn submodule_remove(&self, path: String) -> Result<(), EngineError> {
        self.submodule_remove_inner(path, None, None)
    }

    /// 从 `.gitmodules`、索引和工作树移除子模块，并支持凭证代理/取消。
    pub fn submodule_remove_with_auth_and_cancel(
        &self,
        path: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.submodule_remove_inner(path, Some(broker), Some(cancel))
    }

    /// Undo a clean submodule add after validating the complete post-add
    /// compare-and-swap boundary. It refuses to remove the nested worktree
    /// when the child has any tracked, untracked, or ignored changes.
    pub fn submodule_add_undo_with_auth_and_cancel(
        &self,
        target: SubmoduleAddUndoTarget,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let path = worktree_relative_path(target.path.trim())?;
        if path.as_os_str().is_empty()
            || target.expected_parent_head_id.trim().is_empty()
            || target.expected_submodule_head_id.trim().is_empty()
        {
            return Err(EngineError::GitOperation {
                message: "submodule add undo is missing its expected Git state".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule add undo requires a non-bare worktree".into(),
        })?;
        let current_head =
            current_head_for_category(workdir, crate::gitprocess::GitCommandCategory::Submodule)?;
        if current_head != target.expected_parent_head_id.trim() {
            return Err(EngineError::GitOperation {
                message: "submodule add undo refused: parent HEAD changed".into(),
            });
        }

        let gitmodules = workdir.join(".gitmodules");
        if optional_text_file(&gitmodules)?
            != (
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.clone(),
            )
        {
            return Err(EngineError::GitOperation {
                message: "submodule add undo refused: .gitmodules changed".into(),
            });
        }

        let indexed_id = index_gitlink_id(workdir, &path)?;
        if indexed_id.as_deref() != Some(target.expected_submodule_head_id.trim()) {
            return Err(EngineError::GitOperation {
                message: "submodule add undo refused: the gitlink changed".into(),
            });
        }
        let status = submodule_status_line(workdir, &path)?;
        let status_id = status
            .as_deref()
            .and_then(|line| line.split_whitespace().next());
        if status
            .as_deref()
            .map_or(true, |line| !line.starts_with(' '))
            || status_id != Some(target.expected_submodule_head_id.trim())
        {
            return Err(EngineError::GitOperation {
                message: "submodule add undo refused: the nested checkout changed".into(),
            });
        }
        if nested_worktree_has_changes(&workdir.join(&path))? {
            return Err(EngineError::GitOperation {
                message: "submodule add undo refused: the nested worktree has changes".into(),
            });
        }

        if cancel.is_cancelled() {
            return Err(EngineError::Cancelled);
        }

        let deinit = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args([
            "deinit".to_string(),
            "--force".to_string(),
            "--".to_string(),
            path.to_string_lossy().into_owned(),
        ])
        .working_dir(workdir);
        if let Err(error) = run_submodule_command_spec(&deinit, Some(&broker), Some(cancel.token()))
        {
            return Err(error);
        }

        let remove_index = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "rm",
        )
        .args([
            "--cached".to_string(),
            "--force".to_string(),
            "--".to_string(),
            path.to_string_lossy().into_owned(),
        ])
        .working_dir(workdir);
        if let Err(error) =
            crate::gitprocess::run_to_completion(&remove_index).and_then(|outcome| {
                if outcome.success() {
                    Ok(())
                } else {
                    Err(outcome.into_error(&remove_index))
                }
            })
        {
            let cleanup = restore_added_submodule_post_state(
                workdir,
                &path,
                target.expected_submodule_head_id.trim(),
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
                &broker,
                &cancel,
            );
            return Err(append_recovery_cleanup_error(error, cleanup));
        }

        if cancel.is_cancelled() {
            let cleanup = restore_added_submodule_post_state(
                workdir,
                &path,
                target.expected_submodule_head_id.trim(),
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
                &broker,
                &cancel,
            );
            return Err(append_recovery_cleanup_error(
                EngineError::Cancelled,
                cleanup,
            ));
        }

        if let Err(error) = write_optional_text_file(
            &gitmodules,
            target.restore_gitmodules_present,
            target.restore_gitmodules_contents.as_deref(),
        ) {
            let cleanup = restore_added_submodule_post_state(
                workdir,
                &path,
                target.expected_submodule_head_id.trim(),
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
                &broker,
                &cancel,
            );
            return Err(append_recovery_cleanup_error(error, cleanup));
        }
        if let Err(error) = stage_gitmodules(workdir, target.restore_gitmodules_present) {
            let cleanup = restore_added_submodule_post_state(
                workdir,
                &path,
                target.expected_submodule_head_id.trim(),
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
                &broker,
                &cancel,
            );
            return Err(append_recovery_cleanup_error(error, cleanup));
        }

        if workdir.join(&path).exists() {
            ensure_empty_or_missing_path(&workdir.join(&path))?;
            std::fs::remove_dir(workdir.join(&path)).map_err(EngineError::from_gix)?;
        }
        let restored_gitmodules = optional_text_file(&gitmodules)?;
        let restored_index_entry = index_entry_exists(workdir, &path)?;
        let restored_path_exists = workdir.join(&path).exists();
        if restored_gitmodules
            != (
                target.restore_gitmodules_present,
                target.restore_gitmodules_contents.clone(),
            )
            || restored_index_entry
            || restored_path_exists
        {
            return Err(EngineError::GitOperation {
                message: "submodule add undo did not restore the pre-add state".into(),
            });
        }
        Ok(())
    }

    /// Undo a clean submodule removal after validating the complete
    /// post-remove compare-and-swap boundary. The command restores the
    /// captured `.gitmodules` bytes and gitlink index entry, then lets native
    /// Git initialize the nested worktree again. It never overwrites a path
    /// that appeared after the original remove.
    pub fn submodule_remove_undo_with_auth_and_cancel(
        &self,
        target: SubmoduleRemoveUndoTarget,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let path = worktree_relative_path(target.path.trim())?;
        if path.as_os_str().is_empty() {
            return Err(EngineError::GitOperation {
                message: "submodule remove undo requires a path".into(),
            });
        }
        if target.restore_gitlink_id.trim().is_empty()
            || target.expected_parent_head_id.trim().is_empty()
        {
            return Err(EngineError::GitOperation {
                message: "submodule remove undo is missing its expected Git state".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule remove undo requires a non-bare worktree".into(),
        })?;
        let current_head =
            current_head_for_category(workdir, crate::gitprocess::GitCommandCategory::Submodule)?;
        if current_head != target.expected_parent_head_id.trim() {
            return Err(EngineError::GitOperation {
                message: "submodule remove undo refused: parent HEAD changed".into(),
            });
        }

        let gitmodules = workdir.join(".gitmodules");
        if optional_text_file(&gitmodules)?
            != (
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.clone(),
            )
        {
            return Err(EngineError::GitOperation {
                message: "submodule remove undo refused: .gitmodules changed".into(),
            });
        }
        if index_entry_exists(workdir, &path)? {
            return Err(EngineError::GitOperation {
                message: "submodule remove undo refused: the gitlink is already in the index"
                    .into(),
            });
        }
        ensure_empty_or_missing_path(&workdir.join(&path))?;

        if cancel.is_cancelled() {
            return Err(EngineError::Cancelled);
        }

        write_optional_text_file(
            &gitmodules,
            target.restore_gitmodules_present,
            target.restore_gitmodules_contents.as_deref(),
        )?;

        if let Err(error) = stage_gitmodules(workdir, target.restore_gitmodules_present) {
            let cleanup = restore_removed_submodule_post_state(
                workdir,
                &path,
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
            );
            return Err(append_recovery_cleanup_error(error, cleanup));
        }

        let update_index = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "update-index",
        )
        .args([
            "--add".to_string(),
            "--cacheinfo".to_string(),
            format!(
                "160000,{},{}",
                target.restore_gitlink_id.trim(),
                path.to_string_lossy()
            ),
        ])
        .working_dir(workdir);
        if let Err(error) =
            crate::gitprocess::run_to_completion(&update_index).and_then(|outcome| {
                if outcome.success() {
                    Ok(())
                } else {
                    Err(outcome.into_error(&update_index))
                }
            })
        {
            let cleanup = restore_removed_submodule_post_state(
                workdir,
                &path,
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
            );
            return Err(append_recovery_cleanup_error(error, cleanup));
        }

        if cancel.is_cancelled() {
            let cleanup = restore_removed_submodule_post_state(
                workdir,
                &path,
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
            );
            return Err(append_recovery_cleanup_error(
                EngineError::Cancelled,
                cleanup,
            ));
        }

        let update = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args([
            "update".to_string(),
            "--init".to_string(),
            "--".to_string(),
            path.to_string_lossy().into_owned(),
        ])
        .working_dir(workdir);
        if let Err(error) = run_submodule_command_spec(&update, Some(&broker), Some(cancel.token()))
        {
            let cleanup = restore_removed_submodule_post_state(
                workdir,
                &path,
                target.expected_gitmodules_present,
                target.expected_gitmodules_contents.as_deref(),
            );
            return Err(append_recovery_cleanup_error(error, cleanup));
        }

        let restored_status = submodule_status_line(workdir, &path)?;
        let restored_id = restored_status
            .as_deref()
            .and_then(|line| line.split_whitespace().next());
        if restored_status
            .as_deref()
            .map_or(true, |line| !line.starts_with(' '))
            || restored_id != Some(target.restore_gitlink_id.trim())
        {
            return Err(EngineError::GitOperation {
                message: "submodule remove undo did not restore the expected clean gitlink".into(),
            });
        }
        Ok(())
    }

    fn submodule_remove_inner(
        &self,
        path: String,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<(), EngineError> {
        let path = path.trim();
        if path.is_empty() || path.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "submodule path must not be empty or start with '-'".into(),
            });
        }
        self.run_submodule_command_with_auth_and_cancel(
            vec!["deinit".into(), "--force".into(), "--".into(), path.into()],
            broker.clone(),
            cancel.clone(),
        )?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if cancel.as_ref().is_some_and(|cancel| cancel.is_cancelled()) {
            return Err(EngineError::Cancelled);
        }
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule remove requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "rm",
        )
        .args(["--force", "--", path])
        .working_dir(workdir);
        run_submodule_command_spec(
            &spec,
            broker.as_deref(),
            cancel.as_ref().map(|cancel| cancel.token()),
        )
    }

    fn run_submodule_command(&self, args: Vec<String>) -> Result<(), EngineError> {
        self.run_submodule_command_with_auth_and_cancel(args, None, None)
    }

    fn run_submodule_command_with_auth_and_cancel(
        &self,
        args: Vec<String>,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "submodule operation requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "submodule",
        )
        .args(&args)
        .working_dir(workdir);
        run_submodule_command_spec(
            &spec,
            broker.as_deref(),
            cancel.as_ref().map(|cancel| cancel.token()),
        )
    }

    /// 列出主工作树和 linked worktrees，解析 Git 的 porcelain 输出。
    pub fn worktree_list(&self) -> Result<Vec<WorktreeInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "worktree list requires a non-bare repository".into(),
        })?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["worktree", "list", "--porcelain"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git worktree list failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        let mut result = Vec::new();
        let mut current: Option<WorktreeInfo> = None;
        let flush = |current: &mut Option<WorktreeInfo>, result: &mut Vec<WorktreeInfo>| {
            if let Some(item) = current.take() {
                result.push(item);
            }
        };
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if line.is_empty() {
                flush(&mut current, &mut result);
                continue;
            }
            let Some((key, value)) = line.split_once(' ') else {
                if let Some(item) = current.as_mut() {
                    match line {
                        "bare" => item.is_bare = true,
                        "locked" => item.locked = true,
                        // A detached worktree is represented by an empty
                        // branch, which is already the default value.
                        "detached" => {}
                        _ => {}
                    }
                }
                continue;
            };
            match key {
                "worktree" => {
                    flush(&mut current, &mut result);
                    current = Some(WorktreeInfo {
                        path: value.to_string(),
                        head_id: String::new(),
                        branch: String::new(),
                        is_bare: false,
                        locked: false,
                        prunable: false,
                    });
                }
                "HEAD" => {
                    if let Some(item) = current.as_mut() {
                        item.head_id = value.to_string();
                    }
                }
                "branch" => {
                    if let Some(item) = current.as_mut() {
                        item.branch = value
                            .strip_prefix("refs/heads/")
                            .unwrap_or(value)
                            .to_string();
                    }
                }
                "locked" => {
                    if let Some(item) = current.as_mut() {
                        item.locked = true;
                    }
                }
                "prunable" => {
                    if let Some(item) = current.as_mut() {
                        item.prunable = true;
                    }
                }
                _ => {}
            }
        }
        flush(&mut current, &mut result);
        Ok(result)
    }

    /// 创建 linked worktree；`new_branch` 非空时以 `-b new_branch` 创建分支。
    pub fn worktree_add(
        &self,
        path: String,
        new_branch: Option<String>,
        revision: Option<String>,
    ) -> Result<(), EngineError> {
        let path = path.trim();
        if path.is_empty() {
            return Err(EngineError::GitOperation {
                message: "worktree path must not be empty".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "worktree add requires a non-bare repository".into(),
        })?;
        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        command.args(["worktree", "add"]);
        if let Some(branch) = new_branch.filter(|branch| !branch.trim().is_empty()) {
            command.args(["-b", branch.trim()]);
        }
        command.arg(path);
        if let Some(revision) = revision.filter(|revision| !revision.trim().is_empty()) {
            command.arg(revision.trim());
        }
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git worktree add failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        Ok(())
    }

    /// 删除 linked worktree；主工作树由 Git 拒绝删除。
    pub fn worktree_remove(&self, path: String, force: bool) -> Result<(), EngineError> {
        self.run_worktree_command(if force {
            vec!["remove".into(), "--force".into(), path.trim().into()]
        } else {
            vec!["remove".into(), path.trim().into()]
        })
    }

    pub fn worktree_lock(&self, path: String) -> Result<(), EngineError> {
        self.run_worktree_command(vec!["lock".into(), path.trim().into()])
    }

    pub fn worktree_unlock(&self, path: String) -> Result<(), EngineError> {
        self.run_worktree_command(vec!["unlock".into(), path.trim().into()])
    }

    pub fn worktree_prune(&self) -> Result<(), EngineError> {
        self.run_worktree_command(vec!["prune".into()])
    }

    fn run_worktree_command(&self, args: Vec<String>) -> Result<(), EngineError> {
        if args.iter().any(|arg| arg.is_empty()) {
            return Err(EngineError::GitOperation {
                message: "worktree argument must not be empty".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "worktree operation requires a non-bare repository".into(),
        })?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .arg("worktree")
            .args(&args)
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git worktree operation failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        Ok(())
    }

    /// 执行不经过 shell 的原始 Git 子命令，并返回 stdout/stderr、退出码和耗时。
    /// `command` 只接受 Git 子命令，例如 `show`、`diff` 或 `config`。
    pub fn run_git_command(
        &self,
        command: String,
        args: Vec<String>,
    ) -> Result<GitCommandResult, EngineError> {
        let command = command.trim().to_string();
        if command.is_empty() || command.starts_with('-') || command.contains('/') {
            return Err(EngineError::GitOperation {
                message: "git console command must be a subcommand".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "git console requires a non-bare worktree".into(),
        })?;
        let mut process = crate::gitprocess::git_command_for_working_dir(workdir);
        process.arg(&command).args(&args).current_dir(workdir);
        let display = std::iter::once("git".to_string())
            .chain(std::iter::once(command.clone()))
            .chain(args.iter().map(|arg| shell_quote_for_display(arg)))
            .collect::<Vec<_>>()
            .join(" ");
        let started = std::time::Instant::now();
        let output = process.output().map_err(EngineError::from_gix)?;
        Ok(GitCommandResult {
            command: display,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stdout_bytes: output.stdout,
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            exit_code: output.status.code().unwrap_or(-1),
            duration_ms: started.elapsed().as_millis() as u64,
        })
    }

    /// Execute a raw Git subcommand with process-group cancellation. This is
    /// the cancellable counterpart used by explicit GUI-backed actions such
    /// as Diff Viewer External Diff; non-zero exit codes remain structured
    /// results, while a cancelled process is surfaced as EngineError::Cancelled.
    pub fn run_git_command_with_cancel(
        &self,
        command: String,
        args: Vec<String>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<GitCommandResult, EngineError> {
        let command = command.trim().to_string();
        if command.is_empty() || command.starts_with('-') || command.contains('/') {
            return Err(EngineError::GitOperation {
                message: "git console command must be a subcommand".into(),
            });
        }
        let workdir = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            repo.workdir()
                .ok_or_else(|| EngineError::GitOperation {
                    message: "git console requires a non-bare worktree".into(),
                })?
                .to_path_buf()
        };
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Other,
            &command,
        )
        .args(args)
        .working_dir(workdir);
        let display = spec.display();
        let outcome = crate::gitprocess::run(&spec, Some(cancel.token()), |_| {})?;
        if outcome.cancelled {
            return Err(EngineError::Cancelled);
        }
        Ok(GitCommandResult {
            command: display,
            stdout: outcome.stdout,
            stdout_bytes: outcome.stdout_bytes,
            stderr: outcome.stderr,
            exit_code: outcome.exit_code,
            duration_ms: outcome.duration_ms,
        })
    }

    // MARK: 三栏冲突合并

    /// 合并指定分支到当前 HEAD，使用 Git 默认的 fast-forward 优先策略。
    pub fn merge(&self, branch: String) -> Result<MergeOutcome, EngineError> {
        self.merge_with_options(branch, MergeMode::FastForward)
    }

    /// 兼容旧调用方：保留现有“显式完成合并”语义。
    pub fn merge_with_options(
        &self,
        branch: String,
        mode: MergeMode,
    ) -> Result<MergeOutcome, EngineError> {
        self.merge_with_settings(
            branch,
            MergeOptions {
                mode,
                commit_message: None,
                no_commit: true,
                no_verify: false,
                allow_unrelated_histories: false,
            },
        )
    }

    /// 合并指定分支到当前 HEAD。支持 IntelliJ GitMergeDialog 的提交信息、
    /// no-commit、no-verify 与 allow-unrelated-histories 选项。
    pub fn merge_with_settings(
        &self,
        branch: String,
        options: MergeOptions,
    ) -> Result<MergeOutcome, EngineError> {
        let mode = options.mode;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if load_merge_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "merge: another merge is already in progress".into(),
            });
        }
        let theirs_id = repo
            .rev_parse_single(BStr::new(branch.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let ours_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();

        let ours_reachable = reachable_from(&repo, ours_id)?;
        if ours_reachable.contains(&theirs_id) {
            return Ok(MergeOutcome {
                conflicts: Vec::new(),
                updated_commits: 0,
                upstream: String::new(),
                branch: String::new(),
                completed: true,
                requires_finish: false,
                squashed: false,
            });
        }

        // Match `git merge`'s default fast-forward behavior. `--no-ff` and
        // `--squash` intentionally skip this branch. `--no-commit` does not
        // prevent a fast-forward in Git either.
        if matches!(mode, MergeMode::FastForward | MergeMode::FastForwardOnly) {
            let theirs_reachable = reachable_from(&repo, theirs_id)?;
            if theirs_reachable.contains(&ours_id) {
                let ours_tree = repo
                    .head_commit()
                    .map_err(EngineError::from_gix)?
                    .tree_id()
                    .map_err(EngineError::from_gix)?
                    .detach();
                let theirs_tree = repo
                    .find_commit(theirs_id)
                    .map_err(EngineError::from_gix)?
                    .tree_id()
                    .map_err(EngineError::from_gix)?
                    .detach();
                crate::merge::guard_uncommitted_overwrite(&repo, ours_tree, theirs_tree)?;
                let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                    message: "merge requires a non-bare worktree".into(),
                })?;
                materialize_tree(&repo, ours_tree, theirs_tree, workdir)?;
                move_head_to(&repo, theirs_id)?;
                reset_index_to_tree(&repo, theirs_tree)?;
                return Ok(MergeOutcome {
                    conflicts: Vec::new(),
                    updated_commits: theirs_reachable.difference(&ours_reachable).count() as u32,
                    upstream: String::new(),
                    branch: String::new(),
                    completed: true,
                    requires_finish: false,
                    squashed: false,
                });
            }
            if mode == MergeMode::FastForwardOnly {
                return Err(EngineError::GitOperation {
                    message: "merge: fast-forward only is not possible".into(),
                });
            }
        }

        let unrelated_ancestor = if options.allow_unrelated_histories {
            let theirs_reachable = reachable_from(&repo, theirs_id)?;
            (!ours_reachable
                .iter()
                .any(|id| theirs_reachable.contains(id)))
            .then_some(repo.empty_tree().id)
        } else {
            None
        };
        let mut outcome = apply_merge_with_ancestor(&repo, theirs_id, &branch, unrelated_ancestor)?;
        outcome.completed = false;
        outcome.requires_finish = true;
        outcome.squashed = mode == MergeMode::Squash;
        let message = options
            .commit_message
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| format!("Merge branch '{branch}'"));
        save_merge_state(
            &repo,
            ours_id,
            theirs_id,
            &branch,
            &message,
            mode,
            options.no_verify,
        )?;
        if outcome.conflicts.is_empty() && !options.no_commit {
            let parents = match mode {
                MergeMode::Squash => vec![ours_id],
                MergeMode::FastForward | MergeMode::FastForwardOnly | MergeMode::NoFastForward => {
                    vec![ours_id, theirs_id]
                }
            };
            commit_inner(&repo, &message, &parents, options.no_verify)?;
            clear_merge_state(&repo);
            outcome.completed = true;
            outcome.requires_finish = false;
        }
        Ok(outcome)
    }

    /// Smart Merge preserving lifecycle. The direct merge entry point first
    /// reports an overwrite conflict; this policy-enabled retry saves the
    /// exact Stash/Shelf reference, runs the same merge, and restores it once
    /// the merge operation reaches a terminal state.
    pub fn merge_with_settings_and_policy(
        &self,
        branch: String,
        options: MergeOptions,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<MergeOutcome, EngineError> {
        let saved = prepare_apply_local_changes(self, "merge", save_policy)?;
        finish_apply_local_changes(
            self,
            "merge",
            saved,
            self.merge_with_settings(branch, options),
        )
    }

    /// 完成已经物化到索引的 merge：要求所有冲突已解决，然后按 merge mode
    /// 创建双父或 squash 单父提交。
    ///
    /// `merge()`/pull 的冲突路径只负责把三方结果放进工作区和 index；
    /// 这个显式收尾步骤对应 IntelliJ 的「完成合并」，避免把“文件已解决”
    /// 错当成“历史已提交”。
    pub fn finish_merge(&self, message: Option<String>) -> Result<String, EngineError> {
        let result = self.finish_merge_inner(message);
        finish_apply_local_changes(self, "merge", true, result)
    }

    fn finish_merge_inner(&self, message: Option<String>) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let Some(state) = load_merge_state(&repo)? else {
            return Err(EngineError::GitOperation {
                message: "merge: no merge in progress".into(),
            });
        };
        let unresolved: Vec<String> = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                entry.staged == crate::status::ChangeKind::Conflicted
                    || entry.unstaged == crate::status::ChangeKind::Conflicted
            })
            .map(|entry| entry.path)
            .collect();
        if !unresolved.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!("merge: 仍有未解决冲突：{}", unresolved.join(", ")),
            });
        }
        let head_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        if head_id != state.ours {
            return Err(EngineError::GitOperation {
                message: "merge: HEAD changed while merge was in progress".into(),
            });
        }
        let msg = message.unwrap_or(state.message);
        let parents = match state.mode {
            MergeMode::Squash => vec![state.ours],
            MergeMode::FastForward | MergeMode::FastForwardOnly | MergeMode::NoFastForward => {
                vec![state.ours, state.theirs]
            }
        };
        let commit_id = commit_inner(&repo, &msg, &parents, state.no_verify)?;
        clear_merge_state(&repo);
        Ok(commit_id.to_hex().to_string())
    }

    /// Whether a merge result is waiting for the explicit finish step.
    /// Used by the UI to restore the closeout action after reopening a repo.
    pub fn merge_in_progress(&self) -> bool {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        load_merge_state(&repo).ok().flatten().is_some()
    }

    /// The source reference captured when the current engine merge started.
    /// This survives an app restart so the UI can restore post-merge actions
    /// such as IntelliJ's Delete-on-Merge proposal after conflict resolution.
    pub fn merge_source_reference(&self) -> Option<String> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        load_merge_state(&repo)
            .ok()
            .flatten()
            .and_then(|state| (!state.reference.is_empty()).then_some(state.reference))
    }

    // MARK: OPS-001 统一操作状态与恢复

    /// 当前进行中的操作（merge/rebase/cherry-pick/revert），供 Operation
    /// Recovery Bar 订阅；无进行中操作返回 None。
    pub fn operation_state(&self) -> Result<Option<crate::opstate::OperationState>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let state = crate::opstate::detect(&repo)?;
        if state.is_none() {
            crate::conflict::clear_resolved_ledger(&repo);
        }
        Ok(state)
    }

    /// 完成进行中的 merge：engine 状态走 finish_merge，系统 MERGE_HEAD 走
    /// `git merge --continue`（编辑器固定为 true，接受已有 MERGE_MSG）。
    /// 返回新提交 id。
    pub fn merge_continue(&self, message: Option<String>) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if repo.git_dir().join("MERGE_HEAD").exists() {
            let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                message: "merge continue requires a non-bare worktree".into(),
            })?;
            let (ok, output) = crate::opstate::run_recovery(
                workdir,
                crate::opstate::OperationKind::Merge,
                crate::opstate::RecoveryAction::Continue,
            )?;
            if !ok {
                return Err(EngineError::GitOperation {
                    message: format!("git merge --continue failed: {output}"),
                });
            }
            let spec = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Merge,
                "rev-parse",
            )
            .arg("HEAD")
            .working_dir(workdir);
            let head = crate::gitprocess::run_to_completion(&spec)?;
            if !head.success() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "merge continue: rev-parse HEAD failed: {}",
                        head.stderr.trim()
                    ),
                });
            }
            crate::conflict::clear_resolved_ledger(&repo);
            return Ok(head.stdout.trim().to_string());
        }
        drop(repo);
        self.finish_merge(message)
    }

    // MARK: CFG-001 config / attributes / CRLF

    /// 三层（system/global/local）config 条目，带来源文件与层级。
    /// 同 key 多条时后面的覆盖前面的（git 语义）。
    pub fn git_config_entries(&self) -> Result<Vec<crate::attributes::ConfigEntry>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "config listing requires a non-bare worktree".into(),
        })?;
        crate::attributes::list_config(workdir)
    }

    /// 生效的 config 值（同 key 取最后一条）。
    pub fn config_value(&self, key: String) -> Result<Option<String>, EngineError> {
        let entries = self.git_config_entries()?;
        Ok(
            crate::attributes::effective_config_value(&entries, &key)
                .map(|value| value.to_string()),
        )
    }

    /// 配置仓库级 SSH 命令（等价 `git config --local core.sshCommand ...`）。
    /// 空字符串清除覆盖，后续系统 Git 的 fetch/push 会使用全局/默认 SSH。
    pub fn set_ssh_command(&self, command: String) -> Result<(), EngineError> {
        if command.contains('\0') || command.contains('\n') || command.contains('\r') {
            return Err(EngineError::GitOperation {
                message: "SSH command cannot contain NUL or newline characters".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "SSH command requires a non-bare worktree".into(),
        })?;
        let command = command.trim();
        if command.is_empty() {
            unset_git_config_value(workdir, "core.sshCommand")?;
        } else {
            set_git_config_value(workdir, "core.sshCommand", command)?;
        }
        clear_structured_ssh_config(workdir)
    }

    /// 读取仓库级 SSH command 及其结构化 host-key/authentication 选项。
    pub fn ssh_connection_settings(&self) -> Result<SshConnectionSettings, EngineError> {
        let entries = self.git_config_entries()?;
        let value = |key: &str| {
            crate::attributes::effective_config_value(&entries, key)
                .map(str::to_string)
                .unwrap_or_default()
        };
        let command = {
            let base = value(SSH_BASE_COMMAND_KEY);
            if base.is_empty() {
                value("core.sshCommand")
            } else {
                base
            }
        };
        let host_key_policy = match value(SSH_HOST_KEY_POLICY_KEY).as_str() {
            "accept-new" => SshHostKeyPolicy::AcceptNew,
            "ask" => SshHostKeyPolicy::Ask,
            "no-check" => SshHostKeyPolicy::NoCheck,
            _ => SshHostKeyPolicy::Strict,
        };
        let auth_method = match value(SSH_AUTH_METHOD_KEY).as_str() {
            "public-key" => SshAuthMethod::PublicKey,
            "password" => SshAuthMethod::Password,
            _ => SshAuthMethod::Auto,
        };
        Ok(SshConnectionSettings {
            command,
            known_hosts_file: value(SSH_KNOWN_HOSTS_KEY),
            identity_file: value(SSH_IDENTITY_FILE_KEY),
            host_key_policy,
            auth_method,
        })
    }

    /// 保存结构化 SSH 选项，并将其编译为 Git 实际读取的
    /// `core.sshCommand`。所有值都以 argv/配置值写入，不经过 shell。
    pub fn set_ssh_connection_settings(
        &self,
        command: String,
        known_hosts_file: String,
        identity_file: String,
        host_key_policy: SshHostKeyPolicy,
        auth_method: SshAuthMethod,
    ) -> Result<(), EngineError> {
        for (label, value) in [
            ("SSH command", &command),
            ("known-hosts path", &known_hosts_file),
            ("SSH identity path", &identity_file),
        ] {
            if value.contains('\0') || value.contains('\n') || value.contains('\r') {
                return Err(EngineError::GitOperation {
                    message: format!("{label} cannot contain NUL or newline characters"),
                });
            }
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "SSH settings require a non-bare worktree".into(),
        })?;
        let command = command.trim();
        let known_hosts_file = known_hosts_file.trim();
        let identity_file = identity_file.trim();
        let is_default = command.is_empty()
            && known_hosts_file.is_empty()
            && identity_file.is_empty()
            && host_key_policy == SshHostKeyPolicy::Strict
            && auth_method == SshAuthMethod::Auto;
        if is_default {
            unset_git_config_value(workdir, "core.sshCommand")?;
            return clear_structured_ssh_config(workdir);
        }

        let effective = build_ssh_command(
            command,
            known_hosts_file,
            identity_file,
            host_key_policy,
            auth_method,
        );
        set_git_config_value(workdir, "core.sshCommand", &effective)?;
        if command.is_empty() {
            unset_git_config_value(workdir, SSH_BASE_COMMAND_KEY)?;
        } else {
            set_git_config_value(workdir, SSH_BASE_COMMAND_KEY, command)?;
        }
        set_or_unset_config_value(workdir, SSH_KNOWN_HOSTS_KEY, known_hosts_file)?;
        set_or_unset_config_value(workdir, SSH_IDENTITY_FILE_KEY, identity_file)?;
        set_or_unset_config_value(
            workdir,
            SSH_HOST_KEY_POLICY_KEY,
            host_key_policy.config_value(),
        )?;
        set_or_unset_config_value(workdir, SSH_AUTH_METHOD_KEY, auth_method.config_value())
    }

    /// 文件的 attributes（text/eol/binary/diff/merge/filter/encoding），
    /// 由 git check-attr 解析，与命令行行为一致。
    pub fn file_attributes(
        &self,
        paths: Vec<String>,
    ) -> Result<Vec<crate::attributes::FileAttributes>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "check-attr requires a non-bare worktree".into(),
        })?;
        crate::attributes::check_attributes(workdir, &paths)
    }

    /// 单个文件的有效换行行为：入库是否规范为 LF + 检出换行方向。
    /// diff、staging、blame 应共用该结果，保证 CRLF 场景与命令行一致。
    pub fn effective_line_endings(
        &self,
        path: String,
    ) -> Result<crate::attributes::EffectiveLineEndings, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "line-ending detection requires a non-bare worktree".into(),
        })?;
        let config = crate::attributes::list_config(workdir)?;
        let mut attrs = crate::attributes::check_attributes(workdir, &[path])?;
        let Some(attrs) = attrs.pop() else {
            return Err(EngineError::GitOperation {
                message: "check-attr returned no result".into(),
            });
        };
        Ok(crate::attributes::effective_line_endings(&config, &attrs))
    }

    /// 中止进行中的 merge：engine 状态恢复 ours 的树与 HEAD，系统
    /// MERGE_HEAD 走 `git merge --abort`。
    pub fn merge_abort(&self) -> Result<(), EngineError> {
        let result = self.merge_abort_inner();
        finish_apply_local_changes(self, "merge", true, result)
    }

    fn merge_abort_inner(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if repo.git_dir().join("MERGE_HEAD").exists() {
            let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                message: "merge abort requires a non-bare worktree".into(),
            })?;
            let (ok, output) = crate::opstate::run_recovery(
                workdir,
                crate::opstate::OperationKind::Merge,
                crate::opstate::RecoveryAction::Abort,
            )?;
            if !ok {
                return Err(EngineError::GitOperation {
                    message: format!("git merge --abort failed: {output}"),
                });
            }
            crate::conflict::clear_resolved_ledger(&repo);
            return Ok(());
        }
        let Some(state) = load_merge_state(&repo)? else {
            return Err(EngineError::GitOperation {
                message: "merge: no merge in progress".into(),
            });
        };
        restore_head_from_tree(&repo, state.ours, None)?;
        clear_merge_state(&repo);
        Ok(())
    }

    /// 跳过 rebase 当前步（冲突或 edit 暂停）：系统 rebase 走 `git rebase
    /// --skip`，engine 状态丢弃当前步并继续应用剩余动作。
    pub fn rebase_skip(&self) -> Result<RebaseOutcome, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if system_rebase_active(&repo) {
            let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                message: "rebase skip requires a non-bare worktree".into(),
            })?;
            let (ok, output) = crate::opstate::run_recovery(
                workdir,
                crate::opstate::OperationKind::Rebase,
                crate::opstate::RecoveryAction::Skip,
            )?;
            if !ok && system_rebase_active(&repo) {
                return Err(EngineError::GitOperation {
                    message: format!("git rebase --skip failed: {output}"),
                });
            }
            let result = finish_rebase_local_changes_locked(
                &repo,
                system_rebase_outcome(&repo, system_rebase_active(&repo)),
                None,
            );
            if result.is_ok() {
                crate::conflict::clear_resolved_ledger(&repo);
            }
            return result;
        }
        let Some(state) = load_rebase_state(&repo)? else {
            return Err(EngineError::GitOperation {
                message: "rebase: no rebase in progress".into(),
            });
        };
        let result = skip_conflicted_rebase(&repo, &state);
        let result = finish_rebase_local_changes_locked(&repo, result, None);
        if result.is_ok() {
            crate::conflict::clear_resolved_ledger(&repo);
        }
        result
    }

    /// 完成进行中的 cherry-pick（系统 CHERRY_PICK_HEAD 状态）。
    /// 要求冲突已解决并 stage；失败时状态保留，可重试或 abort。
    pub fn cherry_pick_continue(&self) -> Result<(), EngineError> {
        self.cherry_pick_continue_with_options(CherryPickEmptyPolicy::Skip)
    }

    /// 继续 Cherry-pick，并在后续步骤再次变为空时复用指定策略。
    pub fn cherry_pick_continue_with_options(
        &self,
        empty_policy: CherryPickEmptyPolicy,
    ) -> Result<(), EngineError> {
        let result = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                message: "cherry-pick: requires a non-bare worktree".into(),
            })?;
            if !cherry_pick_state_exists(&repo) {
                return Err(EngineError::GitOperation {
                    message: "cherry-pick: no cherry-pick in progress".into(),
                });
            }
            let result = continue_cherry_pick_sequence(&repo, workdir, empty_policy);
            if result.is_ok() {
                crate::conflict::clear_resolved_ledger(&repo);
            }
            result
        };
        finish_apply_local_changes(self, "cherry-pick", true, result)
    }

    /// 中止进行中的 cherry-pick，恢复到 pick 开始前的状态。
    pub fn cherry_pick_abort(&self) -> Result<(), EngineError> {
        let result = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            pick_recovery_impl(
                &repo,
                crate::opstate::OperationKind::CherryPick,
                crate::opstate::RecoveryAction::Abort,
                "cherry-pick",
            )
        };
        finish_apply_local_changes(self, "cherry-pick", true, result)
    }

    /// 判断提交是否能从指定 revision 到达；用于识别已发布到受保护远程分支
    /// 的 Cherry-pick 提交，并保持分支保护判断与 Git 提交图一致。
    pub fn is_commit_reachable_from(
        &self,
        commit_id: String,
        descendant_id: String,
    ) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let commit = repo
            .rev_parse_single(BStr::new(commit_id.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let descendant = repo
            .rev_parse_single(BStr::new(descendant_id.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        Ok(reachable_from(&repo, descendant)?.contains(&commit))
    }

    /// Return local and remote branch refs whose tips contain the commit.
    ///
    /// The default graph owns this adjacency/reachability index, so callers
    /// that need to choose a source branch do not have to walk every branch
    /// independently. Tags are intentionally excluded: IntelliJ's containing
    /// branch contract is about branch refs, while tag decoration remains a
    /// separate Log concern.
    pub fn commit_containing_branches(
        &self,
        commit_id: String,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let commit = repo
            .rev_parse_single(BStr::new(commit_id.trim().as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        with_permanent_log_graph(
            self,
            &repo,
            crate::log::LogGraphSortMode::ByCommitDate,
            |graph| graph.containing_branches(commit),
        )
    }

    /// 完成进行中的 revert（系统 REVERT_HEAD 状态）。
    pub fn revert_continue(&self) -> Result<(), EngineError> {
        let result = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            pick_recovery_impl(
                &repo,
                crate::opstate::OperationKind::Revert,
                crate::opstate::RecoveryAction::Continue,
                "revert",
            )
        };
        finish_apply_local_changes(self, "revert", true, result)
    }

    /// 中止进行中的 revert。
    pub fn revert_abort(&self) -> Result<(), EngineError> {
        let result = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            pick_recovery_impl(
                &repo,
                crate::opstate::OperationKind::Revert,
                crate::opstate::RecoveryAction::Abort,
                "revert",
            )
        };
        finish_apply_local_changes(self, "revert", true, result)
    }

    /// Read the effective Git mergetool selectors.
    pub fn external_merge_tool_settings(&self) -> Result<ExternalMergeToolSettings, EngineError> {
        let entries = self.git_config_entries()?;
        let value = |key: &str| {
            crate::attributes::effective_config_value(&entries, key)
                .map(str::to_string)
                .unwrap_or_default()
        };
        Ok(ExternalMergeToolSettings {
            merge_tool: value("merge.tool"),
            merge_gui_tool: value("merge.guitool"),
        })
    }

    /// Save repository-local Git mergetool selectors. Empty values remove
    /// only the local override; global/system config remains effective.
    pub fn set_external_merge_tool_settings(
        &self,
        merge_tool: String,
        merge_gui_tool: String,
    ) -> Result<(), EngineError> {
        let merge_tool = validated_merge_tool_name("merge.tool", &merge_tool)?;
        let merge_gui_tool = validated_merge_tool_name("merge.guitool", &merge_gui_tool)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "mergetool settings require a non-bare worktree".into(),
        })?;
        set_or_unset_config_value(workdir, "merge.tool", &merge_tool)?;
        set_or_unset_config_value(workdir, "merge.guitool", &merge_gui_tool)
    }

    /// Run the configured Git external merge tool for one unresolved path.
    ///
    /// Git owns the tool command and its environment (`$BASE`, `$LOCAL`,
    /// `$REMOTE`, `$MERGED`). Once the process exits, the index is read again
    /// so the UI can distinguish a resolved file from a tool that returned
    /// without completing the merge.
    pub fn open_external_merge_tool(
        &self,
        path: String,
    ) -> Result<ExternalMergeToolResult, EngineError> {
        self.run_external_merge_tool(path, None)
    }

    /// Run the configured Git external merge tool with a process-group
    /// cancellation handle. Cancelling terminates Git and the tool it spawned.
    pub fn open_external_merge_tool_with_cancel(
        &self,
        path: String,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<ExternalMergeToolResult, EngineError> {
        self.run_external_merge_tool(path, Some(cancel))
    }

    fn run_external_merge_tool(
        &self,
        path: String,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<ExternalMergeToolResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "external merge tool requires a worktree".into(),
        })?;
        let relative = worktree_relative_path(path.trim())?;
        let relative = relative.to_string_lossy().into_owned();
        let relative = relative.trim_start_matches("./").to_string();
        if relative.is_empty() {
            return Err(EngineError::GitOperation {
                message: "external merge tool requires a conflicted file path".into(),
            });
        }

        let workspace = crate::conflict::build_workspace(&repo)?;
        if !workspace.files.iter().any(|file| file.path == relative) {
            return Err(EngineError::GitOperation {
                message: format!("path is not an unresolved conflict: {relative}"),
            });
        }

        let (tool, use_gui) = configured_external_merge_tool(workdir)?;
        let mut spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Merge,
            "mergetool",
        )
        .arg("--no-prompt");
        if use_gui {
            spec = spec.arg("--gui");
        }
        spec = spec
            .args([String::from("--"), relative.clone()])
            .working_dir(workdir);
        let outcome = match cancel.as_deref() {
            Some(cancel) => crate::gitprocess::run(&spec, Some(cancel.token()), |_| {})?,
            None => crate::gitprocess::run_to_completion(&spec)?,
        };
        let remaining_conflicts = crate::conflict::build_workspace(&repo)?
            .files
            .into_iter()
            .map(|file| file.path)
            .collect::<Vec<_>>();
        if !outcome.success() {
            if outcome.cancelled {
                return Err(EngineError::Cancelled);
            }
            return Err(EngineError::GitOperation {
                message: format!(
                    "external merge tool '{tool}' failed for {relative}; remaining conflicts: {}; {}",
                    if remaining_conflicts.is_empty() {
                        "none".to_string()
                    } else {
                        remaining_conflicts.join(", ")
                    },
                    outcome.into_error(&spec)
                ),
            });
        }

        Ok(ExternalMergeToolResult {
            path: relative.clone(),
            tool,
            resolved: !remaining_conflicts.iter().any(|path| path == &relative),
            remaining_conflicts,
        })
    }

    /// 读取一个冲突文件的三方内容 + 冲突块（marker 解析）。
    pub fn conflict_file(&self, path: String) -> Result<ConflictFile, EngineError> {
        use gix::index::entry::Stage;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let index = repo.index().map_err(EngineError::from_gix)?;
        let path_bstr = path.as_bytes().as_bstr();
        let read_stage = |stage: Stage| -> Result<String, EngineError> {
            match index.entry_by_path_and_stage(path_bstr, stage) {
                Some(e) => {
                    let data = blob_bytes(&repo, e.id, "read conflict stage")?;
                    Ok(String::from_utf8_lossy(&data).into_owned())
                }
                None => Ok(String::new()),
            }
        };
        let base = read_stage(Stage::Base)?;
        let ours = read_stage(Stage::Ours)?;
        let theirs = read_stage(Stage::Theirs)?;
        let result = String::from_utf8_lossy(&worktree_bytes(&repo, &path)).into_owned();
        let blocks = parse_marker_blocks(&result, &ours, &theirs);
        Ok(ConflictFile {
            path,
            base,
            ours,
            theirs,
            result,
            blocks,
        })
    }

    // MARK: CONFLICT-001 统一冲突工作台

    /// 统一冲突工作台：进行中的操作 + 未解决冲突文件（三方内容 + 块 + 二进制标记）。
    /// merge / rebase / cherry-pick / revert 都从这里进入同一工作台。
    pub fn conflict_workspace(&self) -> Result<crate::conflict::ConflictWorkspace, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::conflict::build_workspace(&repo)
    }

    /// 文件级接受方向（IntelliJ Accept Yours/Theirs/Both）：写工作区 + 清
    /// stages + 索引 stage 0；二进制安全。解决后该文件从工作台列表移除。
    pub fn accept_conflict(
        &self,
        path: String,
        pick: crate::conflict::FilePick,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::conflict::accept(&repo, &path, pick)
    }

    /// 重置冲突现场：从 index stages 重新生成 marker 写回工作区，
    /// 不碰 stages（放弃当前编辑）。二进制文件不支持（返回明确提示）。
    pub fn reset_conflict(&self, path: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::conflict::reset(&repo, &path)
    }

    /// IntelliJ Git.RevertResolved：把已经解决的文件重新物化为冲突态，
    /// 等价于 `git checkout -m -- <path>`。仅允许当前操作中由工作台记录
    /// 为 resolved 的路径，避免把普通文件误当成冲突回滚目标。
    pub fn revert_resolved_conflict(&self, path: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::conflict::revert_resolved(&repo, &path)
    }

    /// 按块决策解决冲突：替换 result 内容 -> 写工作区 + 清索引 stages + upsert stage 0。
    /// 按块选边是快捷路径；自由编辑后的结果用 `resolve_edited`。
    pub fn resolve(&self, path: String, decisions: Vec<BlockDecision>) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?;
        let file_path = workdir.join(&path);
        let result = std::fs::read_to_string(&file_path).map_err(EngineError::from_gix)?;

        let blocks = parse_marker_blocks(&result, "", "");
        let by_index: std::collections::HashMap<u32, &BlockDecision> =
            decisions.iter().map(|d| (d.block_index, d)).collect();
        let mut lines: Vec<String> = result.lines().map(|s| s.to_string()).collect();
        for (idx, block) in blocks.iter().enumerate().rev() {
            if let Some(decision) = by_index.get(&(idx as u32)) {
                let start = (block.result_start - 1) as usize;
                let end = block.result_end as usize;
                let picked = match decision.pick {
                    PickKind::Ours => &block.ours_lines,
                    PickKind::Theirs => &block.theirs_lines,
                };
                lines.splice(start..end, picked.iter().cloned());
            }
        }
        let trailing = if result.ends_with('\n') { "\n" } else { "" };
        let final_content = lines.join("\n") + trailing;
        let index_entries = crate::conflict::capture_index_entries(&repo, &path)?;
        write_resolved(&repo, &path, &final_content)?;
        crate::conflict::mark_resolved(&repo, &path, index_entries)
    }

    /// 接受自由编辑后的结果文本解决冲突：写工作区 content -> 清 stages 1/2/3
    /// -> upsert stage 0（写 blob + stat + mode）。与 `resolve` 共用 `write_resolved`。
    pub fn resolve_edited(&self, path: String, content: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let index_entries = crate::conflict::capture_index_entries(&repo, &path)?;
        write_resolved(&repo, &path, &content)?;
        crate::conflict::mark_resolved(&repo, &path, index_entries)
    }

    // MARK: stash

    /// 保存 stash（索引树 + 工作区树双提交 -> refs/stash），重置工作区/索引到 HEAD。返回 stash id。
    pub fn stash_save(&self, message: Option<String>) -> Result<String, EngineError> {
        save_stash(&self.inner, message, false, false, false)
    }

    /// 保存 stash，同时保留保存时的 index 在工作区中（等价于
    /// `git stash push --keep-index`）。
    pub fn stash_save_with_keep_index(
        &self,
        message: Option<String>,
    ) -> Result<String, EngineError> {
        save_stash(&self.inner, message, false, false, true)
    }

    /// 保存 stash，并把未跟踪/ignored 文件一起放入临时本地现场。
    /// 供 Pull/Update 在不要求用户 Add 或 Commit 的情况下保存工作区。
    pub fn stash_save_including_untracked(
        &self,
        message: Option<String>,
    ) -> Result<String, EngineError> {
        save_stash(&self.inner, message, true, true, false)
    }

    /// STASH-001：带 tracked/untracked/ignored 选项的 stash 保存
    /// （等价 `git stash push -u` / `git stash push -u -a`；ignored 隐含 untracked）。
    pub fn stash_save_with_options(
        &self,
        message: Option<String>,
        include_untracked: bool,
        include_ignored: bool,
    ) -> Result<String, EngineError> {
        let include_untracked = include_untracked || include_ignored;
        save_stash(
            &self.inner,
            message,
            include_untracked,
            include_ignored,
            false,
        )
    }

    /// STASH-002：只保存指定路径的工作区现场，等价于
    /// `git stash push [-u] -- <paths>`。这是 IntelliJ Git 的
    /// `Stash Files` 语义：未选中的文件继续留在工作区，选中的 tracked
    /// 文件同时保存 index/worktree 变更。
    pub fn stash_save_paths(
        &self,
        message: Option<String>,
        paths: Vec<String>,
        include_untracked: bool,
    ) -> Result<String, EngineError> {
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "at least one worktree path is required to stash files".into(),
            });
        }
        let relative_paths = paths
            .iter()
            .map(|path| {
                let relative = worktree_relative_path(path)?;
                if relative.as_os_str().is_empty() {
                    return Err(EngineError::GitOperation {
                        message: "worktree path must not be empty".into(),
                    });
                }
                Ok(relative)
            })
            .collect::<Result<Vec<_>, EngineError>>()?;

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "path stash requires a non-bare worktree".into(),
        })?;
        let current_stash = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["rev-parse", "--verify", "refs/stash^{commit}"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        let previous_id = if current_stash.status.success() {
            Some(
                String::from_utf8_lossy(&current_stash.stdout)
                    .trim()
                    .to_string(),
            )
        } else {
            None
        };

        let stash_message = message.unwrap_or_else(|| "Arbor: Stash selected files".into());
        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        command.arg("stash").arg("push");
        if include_untracked {
            command.arg("--include-untracked");
        }
        command.arg("--message").arg(&stash_message).arg("--");
        command.args(&relative_paths);
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git stash selected files failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }

        let latest = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["rev-parse", "--verify", "refs/stash^{commit}"])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        let latest_id = if latest.status.success() {
            String::from_utf8_lossy(&latest.stdout).trim().to_string()
        } else {
            String::new()
        };
        if latest_id.is_empty() || previous_id.as_deref() == Some(latest_id.as_str()) {
            return Err(EngineError::GitOperation {
                message: "no changes matched the selected paths".into(),
            });
        }
        Ok(latest_id)
    }

    /// STASH-001：清空整个 stash 栈（等价 `git stash clear`）。
    pub fn stash_clear(&self) -> Result<(), EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let stash_name: gix::refs::FullName =
            "refs/stash".try_into().map_err(EngineError::from_gix)?;
        repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::Any,
                log: gix::refs::transaction::RefLog::AndReference,
            },
            name: stash_name,
            deref: true,
        })
        .map_err(EngineError::from_gix)?;
        let _ = std::fs::remove_file(repo.git_dir().join("logs").join("refs").join("stash"));
        Ok(())
    }

    /// 列出 stash（新→旧）。
    pub fn stash_list(&self) -> Result<Vec<StashInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let mut out = Vec::new();
        for id in walk_stash_chain(&repo)? {
            let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
            let message = commit
                .message()
                .map(|m| m.title.trim_end().to_str_lossy().into_owned())
                .unwrap_or_default();
            let id_hex = id.to_hex().to_string();
            out.push(StashInfo {
                id: id_hex.clone(),
                short_id: id_hex.chars().take(7).collect(),
                message,
            });
        }
        Ok(out)
    }

    /// 弹出 stash（同 HEAD 语义：diff 干净应用到工作区，变更显示为未暂存），并移动 refs/stash。
    pub fn stash_apply(&self, index: u32) -> Result<(), EngineError> {
        self.stash_apply_with_index(index, false)
    }

    /// 应用 stash，并可选恢复保存时的 index（等价 `git stash apply --index`）。
    /// 预检、冲突和 stash 保留语义与普通 Apply 相同。
    pub fn stash_apply_with_index(
        &self,
        index: u32,
        restore_index: bool,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let chain = walk_stash_chain(&repo)?;
        let stash_id = *chain
            .get(index as usize)
            .ok_or_else(|| EngineError::GitOperation {
                message: "stash index out of range".into(),
            })?;
        let untracked = untracked_paths(&repo, stash_id)?;
        apply_stash_with_merge(&repo, stash_id)?;
        restore_stashed_untracked(&repo, stash_id, &untracked)?;
        restore_untracked_index_state(&repo, &untracked)?;
        if restore_index {
            restore_stash_index(&repo, stash_id, stash_saved_base_tree(&repo, stash_id)?)?;
        }
        Ok(())
    }

    /// 应用并删除 stash（与 `git stash pop` 语义一致）。
    pub fn stash_pop(&self, index: u32) -> Result<(), EngineError> {
        self.stash_pop_with_index(index, false)
    }

    /// 应用并删除 stash，可选恢复保存时的 index（等价 `git stash pop --index`）。
    pub fn stash_pop_with_index(&self, index: u32, restore_index: bool) -> Result<(), EngineError> {
        let stash_id = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            let chain = walk_stash_chain(&repo)?;
            *chain
                .get(index as usize)
                .ok_or_else(|| EngineError::GitOperation {
                    message: "stash index out of range".into(),
                })?
        };
        stash_pop_with_id(self, stash_id, restore_index)
    }

    /// Cancellable Pull recovery boundary for a stash. Cancellation is
    /// honored before the worktree/index mutation begins; once gix starts
    /// restoring the stash, the restore completes as one non-interruptible
    /// local transaction so a late cancel cannot leave a half-applied scene.
    pub fn stash_pop_with_index_and_cancel(
        &self,
        index: u32,
        restore_index: bool,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        ensure_not_cancelled(Some(cancel.token()))?;
        self.stash_pop_with_index(index, restore_index)
    }

    /// 丢弃 stash 并移动 refs/stash。
    pub fn stash_drop(&self, index: u32) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let chain = walk_stash_chain(&repo)?;
        let stash_id = *chain
            .get(index as usize)
            .ok_or_else(|| EngineError::GitOperation {
                message: "stash index out of range".into(),
            })?;
        let next_top = if index == 0 {
            chain.get(1).copied()
        } else {
            chain.first().copied()
        };
        remove_stash_entry(&repo, stash_id, next_top)?;
        Ok(())
    }

    // MARK: BRANCH-001 分支弹窗与 tracking

    /// 最近检出的本地分支（HEAD reflog 的 checkout 记录，最近在前、去重）。
    /// Branches Popup 的 Recent 分组数据源。
    pub fn recent_branches(&self, limit: u32) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let path = repo.git_dir().join("logs").join("HEAD");
        let Ok(text) = std::fs::read_to_string(path) else {
            return Ok(Vec::new());
        };
        let mut seen = std::collections::HashSet::new();
        let mut recent = Vec::new();
        for line in text.lines().rev() {
            let Some((_, message)) = line.split_once('\t') else {
                continue;
            };
            let Some(target) = message.strip_prefix("checkout: moving from ") else {
                continue;
            };
            let Some((_, to)) = target.split_once(" to ") else {
                continue;
            };
            let to = to.trim();
            // 跳过 detached HEAD 的哈希与当前分支本身
            if to.len() == 40 && to.chars().all(|c| c.is_ascii_hexdigit()) {
                continue;
            }
            if seen.insert(to.to_string()) {
                recent.push(to.to_string());
                if recent.len() as u32 >= limit {
                    break;
                }
            }
        }
        Ok(recent)
    }

    /// 设置分支的 upstream（`git branch --set-upstream-to=<upstream> <branch>`），
    /// 建立/修改 tracking 关系。
    pub fn branch_set_upstream(&self, branch: String, upstream: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "branch upstream requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Branch,
            "branch",
        )
        .args(["--set-upstream-to", &upstream, &branch])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 解除分支的 upstream（`git branch --unset-upstream <branch>`）。
    pub fn branch_unset_upstream(&self, branch: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "branch upstream requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Branch,
            "branch",
        )
        .args(["--unset-upstream", &branch])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 从 stash 创建并切换到一个新分支，语义等价于 `git stash branch`。
    /// 应用冲突时 Git 会保留 stash，成功时 Git 会删除已应用的 stash。
    pub fn stash_branch(&self, index: u32, branch: String) -> Result<(), EngineError> {
        let branch = branch.trim().to_string();
        if branch.is_empty() || branch.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "stash branch name must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "stash branch requires a non-bare worktree".into(),
        })?;
        let stash = format!("stash@{{{index}}}");
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["stash", "branch", &branch, &stash])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git stash branch failed: {}",
                    command_output_message(&output)
                ),
            });
        }
        Ok(())
    }

    /// 返回 stash 的完整补丁文本，包含 rename/binary 元数据。
    pub fn stash_diff(&self, index: u32) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "stash diff requires a non-bare worktree".into(),
        })?;
        let stash = format!("stash@{{{index}}}");
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args([
                "stash",
                "show",
                "--format=",
                "--patch",
                "--binary",
                "--include-untracked",
                &stash,
            ])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!("git stash show failed: {}", command_output_message(&output)),
            });
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    /// 返回 stash 中单个文件的结构化 diff。
    ///
    /// Arbor 自己创建的 stash 把 untracked 文件放进工作树提交；系统 Git
    /// 则把它们放进第三父提交。两种布局都以保存时 HEAD（第一父）为基线，
    /// 这样 Stash Preview 可以复用与提交/Shelf 相同的 side-by-side 组件。
    pub fn stash_file_diff(
        &self,
        index: u32,
        path: String,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.stash_file_diff_with_settings(
            index,
            path,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// DIFF-002：Stash file diff with opt-in textconv.
    pub fn stash_file_diff_with_settings(
        &self,
        index: u32,
        path: String,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let stash_id = *walk_stash_chain(&repo)?
            .get(index as usize)
            .ok_or_else(|| EngineError::GitOperation {
                message: "stash index out of range".into(),
            })?;
        let stash = repo.find_commit(stash_id).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = stash.parent_ids().map(|parent| parent.detach()).collect();
        let base = parents.first().ok_or_else(|| EngineError::GitOperation {
            message: "stash commit has no base parent".into(),
        })?;
        let old = rev_blob_bytes(&repo, &base.to_hex().to_string(), &path)?;

        let stash_revision = stash_id.to_hex().to_string();
        let stash_path_spec = format!("{stash_revision}:{path}");
        let stash_contains_path = repo
            .rev_parse_single(BStr::new(stash_path_spec.as_bytes()))
            .is_ok();
        let new_revision = if stash_contains_path {
            Some(stash_revision.clone())
        } else if let Some(untracked_parent) = parents.get(2) {
            Some(untracked_parent.to_hex().to_string())
        } else {
            None
        };
        if let Some(new_revision) = new_revision.as_deref() {
            if let Some(diff) = textconv_revision_diff_if_enabled(
                &repo,
                &base.to_hex().to_string(),
                new_revision,
                &path,
                &settings,
            )? {
                return Ok(diff);
            }
        }
        let new = if let Some(new_revision) = new_revision {
            crate::diff::rev_content_bytes(&repo, &new_revision, &path)?
        } else {
            Vec::new()
        };

        if is_binary(&old) || is_binary(&new) {
            return Ok(FileDiff {
                path,
                binary: true,
                hunks: Vec::new(),
            });
        }
        let hunks = compute_hunks_with(&old, &new, settings.ignore_all_space);
        let mut diff = FileDiff {
            path,
            binary: false,
            hunks,
        };
        let path = diff.path.clone();
        attach_highlights(&path, &old, &new, &mut diff);
        Ok(diff)
    }

    // MARK: shelve（JetBrains 本地补丁抽象）

    /// 保存指定路径的变更为命名补丁，并把工作区/索引重置回 HEAD。
    pub fn shelve(&self, name: String, paths: Vec<String>) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_locked(&repo, name, paths, false)
    }

    /// 保存供 Pull/Checkout/Rebase 临时使用的 Shelf，同时记录保存前的
    /// index entries。恢复该 Shelf 时会把 staged/unstaged 的原始边界一并
    /// 还原；普通用户 Shelve 保持原有“恢复为 unstaged”语义。
    pub fn shelve_for_preservation(
        &self,
        name: String,
        paths: Vec<String>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_locked(&repo, name, paths, true)
    }

    /// 导入一个 unified/binary patch 为独立 Shelf 文件。
    ///
    /// IntelliJ 不要求导入时 patch 能匹配当前 HEAD；它把原始 patch 持久化，
    /// 直到真正 Unshelve 时才做 clean/three-way apply。这里保留一个空的
    /// anchor commit 供现有 refs/list 格式和 UI id 使用，patch 文件才是
    /// imported shelf 的语义来源。
    pub fn shelve_import(&self, name: String, patch: String) -> Result<(), EngineError> {
        use crate::shelve::{
            load_deleted_shelves, load_shelves, patch_paths, sanitize_ref_name, save_shelves,
            upsert_shelf_metadata, write_shelf_patch,
        };
        use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
        use gix::refs::Target;

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = name.trim().to_string();
        if name.is_empty() || patch.trim().is_empty() {
            return Err(EngineError::GitOperation {
                message: "shelve: import requires a name and a non-empty patch".into(),
            });
        }
        if name
            .chars()
            .any(|character| matches!(character, '\t' | '\r' | '\n'))
        {
            return Err(EngineError::GitOperation {
                message: "shelve: name must not contain tabs or line breaks".into(),
            });
        }

        let shelves = load_shelves(&repo)?;
        let deleted_shelves = load_deleted_shelves(&repo)?;
        let ref_name = sanitize_ref_name(&name);
        if shelves
            .iter()
            .chain(deleted_shelves.iter())
            .any(|(candidate, _)| *candidate == name || sanitize_ref_name(candidate) == ref_name)
        {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: {name} already exists or conflicts with an existing shelf ref"
                ),
            });
        }
        let paths = patch_paths(&patch).map_err(|error| EngineError::GitOperation {
            message: format!("shelve: imported patch could not be applied: {error}"),
        })?;
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "shelve: imported patch contains no file changes".into(),
            });
        }
        let head_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        let head_tree = repo
            .find_commit(head_id)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        let patch_id = repo
            .new_commit(&name, head_tree, [head_id])
            .map_err(EngineError::from_gix)?
            .id;
        let full_name: gix::refs::FullName = format!("refs/shelved/{ref_name}")
            .as_str()
            .try_into()
            .map_err(EngineError::from_gix)?;
        write_shelf_patch(&repo, &name, false, patch.as_bytes(), false)?;
        if let Err(error) = repo.edit_reference(RefEdit {
            change: Change::Update {
                log: LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: true,
                    message: format!("{name}: imported patch").into(),
                },
                expected: PreviousValue::MustNotExist,
                new: Target::Object(patch_id),
            },
            name: full_name.clone(),
            deref: false,
        }) {
            let _ = crate::shelve::remove_shelf_patch(&repo, &name, false);
            return Err(EngineError::from_gix(error));
        }

        let shelves_file = crate::shelve::shelves_file(&repo);
        let original_shelves_file = std::fs::read(&shelves_file).ok();
        let metadata_file = crate::shelve::shelf_metadata_file(&repo);
        let original_metadata_file = std::fs::read(&metadata_file).ok();
        let mut list = load_shelves(&repo)?;
        list.insert(0, (name.clone(), patch_id));
        if let Err(error) = save_shelves(&repo, &list).and_then(|_| {
            upsert_shelf_metadata(&repo, &name, patch_id, current_unix_seconds(), &name)
        }) {
            match original_shelves_file {
                Some(bytes) => {
                    let _ = std::fs::write(&shelves_file, bytes);
                }
                None => {
                    let _ = std::fs::remove_file(&shelves_file);
                }
            }
            match original_metadata_file {
                Some(bytes) => {
                    let _ = std::fs::write(&metadata_file, bytes);
                }
                None => {
                    let _ = std::fs::remove_file(&metadata_file);
                }
            }
            let _ = repo.edit_reference(RefEdit {
                change: Change::Delete {
                    expected: PreviousValue::Any,
                    log: RefLog::AndReference,
                },
                name: full_name,
                deref: false,
            });
            let _ = crate::shelve::remove_shelf_patch(&repo, &name, false);
            return Err(error);
        }
        Ok(())
    }

    /// Apply a portable patch directly to the worktree without creating a
    /// persistent Shelf. File selection and base/path-strip mapping use the
    /// same raw-patch engine as imported Shelves.
    pub fn apply_imported_patch(
        &self,
        name: String,
        patch: String,
        paths: Vec<String>,
        base_path: String,
        path_strip: u32,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::apply_raw_shelve(
            &repo,
            &patch,
            &name,
            false,
            false,
            Some(&paths),
            Some(&base_path),
            Some(path_strip),
            true,
        )
    }

    /// Apply selected hunks from a portable patch directly to the worktree.
    pub fn apply_imported_patch_selections(
        &self,
        name: String,
        patch: String,
        selections: Vec<crate::shelve::ShelvePatchSelection>,
        base_path: String,
        path_strip: u32,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::apply_raw_shelve_selections(
            &repo,
            &patch,
            &name,
            false,
            false,
            &selections,
            Some(&base_path),
            Some(path_strip),
            true,
        )
    }

    /// Apply a direct imported patch with IntelliJ's differentiated per-file
    /// semantics: each file member is attempted independently, successful
    /// members remain in the worktree, and ordinary failures are returned to
    /// the caller instead of being collapsed into one atomic error. A real
    /// conflict still pauses the operation through the existing restore
    /// snapshot so the conflict resolver can continue or cancel it.
    pub fn apply_imported_patch_differentiated(
        &self,
        name: String,
        patch: String,
        paths: Vec<String>,
        selections: Vec<crate::shelve::ShelvePatchSelection>,
        base_path: String,
        path_strip: u32,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        apply_imported_patch_differentiated_locked(
            &repo,
            &name,
            &patch,
            &paths,
            &selections,
            &base_path,
            path_strip,
            None,
        )
    }

    /// Cancellable Apply Patch entry point. Cancellation returns a structured
    /// Abort result after restoring the exact pre-apply worktree and index.
    pub fn apply_imported_patch_differentiated_with_cancel(
        &self,
        name: String,
        patch: String,
        paths: Vec<String>,
        selections: Vec<crate::shelve::ShelvePatchSelection>,
        base_path: String,
        path_strip: u32,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        apply_imported_patch_differentiated_locked(
            &repo,
            &name,
            &patch,
            &paths,
            &selections,
            &base_path,
            path_strip,
            Some(cancel.token()),
        )
    }

    /// 列出 shelf 补丁（新→旧）。
    pub fn shelve_list(&self) -> Result<Vec<ShelveInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        finalize_pending_shelve_deletes_locked(&repo)?;
        let list = crate::shelve::load_shelves(&repo)?;
        list.iter()
            .map(|(name, id)| shelve_info_for(&repo, name, *id, false))
            .collect()
    }

    /// Permanently remove recycled Shelf lists older than the supplied
    /// lifecycle cutoff. This is the explicit IntelliJ "clean already
    /// unshelved" action; ordinary active and Recently Deleted shelves are
    /// left untouched.
    pub fn shelve_clean_recycled(&self, before_timestamp: i64) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        finalize_pending_shelve_deletes_locked(&repo)?;
        clean_recycled_shelves_locked(&repo, before_timestamp)
    }

    /// 列出 Recently Deleted 中可恢复的 shelf（新→旧）。
    pub fn shelve_deleted_list(&self) -> Result<Vec<ShelveInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        finalize_pending_shelve_deletes_locked(&repo)?;
        purge_expired_deleted_shelves_locked(&repo)?;
        let list = crate::shelve::load_deleted_shelves(&repo)?;
        list.iter()
            .map(|(name, id)| shelve_info_for(&repo, name, *id, true))
            .collect()
    }

    /// Return the persisted pre-apply snapshot for a shelf conflict, if one
    /// exists. This lets the UI reconstruct the resolver after an app restart.
    pub fn shelve_restore_info(
        &self,
    ) -> Result<Option<crate::shelve::ShelveRestoreInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::restore_info(&repo)
    }

    /// Return the persisted preserving-operation marker, if local changes are
    /// waiting to be restored. Unlike a message or numeric stash index, this
    /// identity remains stable when another root or the user changes a stash
    /// stack during a multi-root operation.
    pub fn apply_local_changes_restore_info(
        &self,
    ) -> Result<Option<LocalChangesRestoreInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let Some(saved) = load_apply_local_changes(&repo)? else {
            return Ok(None);
        };
        let (kind, identifier) = match saved.saved {
            RebaseLocalChanges::Stash(stash_id) => {
                ("stash".to_string(), stash_id.to_hex().to_string())
            }
            RebaseLocalChanges::Shelf(name) => ("shelf".to_string(), name),
        };
        Ok(Some(LocalChangesRestoreInfo {
            operation: saved.kind,
            kind,
            identifier,
        }))
    }

    /// Return the persisted local-changes artifact for a rebase, if one is
    /// waiting to be restored. Rebase uses its own marker because Git keeps
    /// the operation alive across Continue/Abort and process restarts.
    pub fn rebase_local_changes_restore_info(
        &self,
    ) -> Result<Option<LocalChangesRestoreInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let Some(saved) = load_rebase_local_changes(&repo)? else {
            return Ok(None);
        };
        let (kind, identifier) = match saved {
            RebaseLocalChanges::Stash(stash_id) => {
                ("stash".to_string(), stash_id.to_hex().to_string())
            }
            RebaseLocalChanges::Shelf(name) => ("shelf".to_string(), name),
        };
        Ok(Some(LocalChangesRestoreInfo {
            operation: "rebase".to_string(),
            kind,
            identifier,
        }))
    }

    /// Persist the local Changelist target for a paused Shelf unshelve.
    /// The target is written only after the apply has entered conflict, so a
    /// normal clean unshelve does not create extra restore state.
    pub fn shelve_set_restore_target(
        &self,
        name: String,
        target_change_list: String,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::set_restore_target(&repo, &name, &target_change_list)
    }

    /// Persist one resolved text hunk for a paused Shelf or direct Apply Patch
    /// restore so the conflict workbench can reconstruct it after restart.
    pub fn shelve_set_restore_hunk_resolution(
        &self,
        name: String,
        path: String,
        hunk_index: u32,
        resolution: String,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::set_restore_hunk_resolution(&repo, &name, &path, hunk_index, &resolution)
    }

    /// Clear persisted hunk decisions for one file after Reset. Other files
    /// in the same paused restore remain untouched.
    pub fn shelve_clear_restore_hunk_resolutions(
        &self,
        name: String,
        path: String,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::clear_restore_hunk_resolutions(&repo, &name, &path)
    }

    /// Rename a shelf without rewriting its patch object. The display name is
    /// persisted in `.git/arbor-shelves`; the custom ref is moved only when
    /// the sanitized ref name changes.
    pub fn shelve_rename(&self, old_name: String, new_name: String) -> Result<(), EngineError> {
        use crate::shelve::{
            load_shelves, rename_shelf_metadata, sanitize_ref_name, save_shelves,
            shelf_metadata_file,
        };
        use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
        use gix::refs::Target;

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let old_name = old_name.trim().to_string();
        let new_name = new_name.trim().to_string();
        ensure_shelve_not_pending_restore(&repo, &old_name)?;
        if old_name.is_empty() || new_name.is_empty() {
            return Err(EngineError::GitOperation {
                message: "shelve: old and new names are required".into(),
            });
        }
        if new_name
            .chars()
            .any(|character| matches!(character, '\t' | '\r' | '\n'))
        {
            return Err(EngineError::GitOperation {
                message: "shelve: name must not contain tabs or line breaks".into(),
            });
        }
        if old_name == new_name {
            return Ok(());
        }

        let mut shelves = load_shelves(&repo)?;
        let index = shelves
            .iter()
            .position(|(name, _)| *name == old_name)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {old_name} not found"),
            })?;
        let new_ref_name = sanitize_ref_name(&new_name);
        let deleted_shelves = crate::shelve::load_deleted_shelves(&repo)?;
        if shelves
            .iter()
            .enumerate()
            .any(|(candidate_index, (name, _))| {
                candidate_index != index
                    && (*name == new_name || sanitize_ref_name(name) == new_ref_name)
            })
            || deleted_shelves
                .iter()
                .any(|(name, _)| *name == new_name || sanitize_ref_name(name) == new_ref_name)
        {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: {new_name} already exists or conflicts with an existing shelf ref"
                ),
            });
        }

        let patch_id = shelves[index].1;
        let shelves_file = crate::shelve::shelves_file(&repo);
        let original_shelves_file = std::fs::read(&shelves_file).map_err(EngineError::from_gix)?;
        let original_metadata_file = std::fs::read(shelf_metadata_file(&repo)).ok();
        let old_ref_name = sanitize_ref_name(&old_name);
        let refs_changed = old_ref_name != new_ref_name;
        if refs_changed {
            let new_ref: gix::refs::FullName = format!("refs/shelved/{new_ref_name}")
                .as_str()
                .try_into()
                .map_err(EngineError::from_gix)?;
            repo.edit_reference(RefEdit {
                change: Change::Update {
                    log: LogChange {
                        mode: RefLog::AndReference,
                        force_create_reflog: true,
                        message: new_name.clone().into(),
                    },
                    expected: PreviousValue::MustNotExist,
                    new: Target::Object(patch_id),
                },
                name: new_ref,
                deref: false,
            })
            .map_err(EngineError::from_gix)?;

            let old_ref: gix::refs::FullName = format!("refs/shelved/{old_ref_name}")
                .as_str()
                .try_into()
                .map_err(EngineError::from_gix)?;
            if let Err(error) = repo.edit_reference(RefEdit {
                change: Change::Delete {
                    expected: PreviousValue::Any,
                    log: RefLog::AndReference,
                },
                name: old_ref,
                deref: false,
            }) {
                let rollback_ref: gix::refs::FullName = format!("refs/shelved/{new_ref_name}")
                    .as_str()
                    .try_into()
                    .map_err(EngineError::from_gix)?;
                let _ = repo.edit_reference(RefEdit {
                    change: Change::Delete {
                        expected: PreviousValue::Any,
                        log: RefLog::AndReference,
                    },
                    name: rollback_ref,
                    deref: false,
                });
                return Err(EngineError::GitOperation {
                    message: format!("shelve: could not remove old ref: {error}"),
                });
            }
        }

        let raw_patch_moved = if refs_changed {
            match crate::shelve::rename_shelf_patch(&repo, &old_name, &new_name, false) {
                Ok(moved) => moved,
                Err(error) => {
                    let old_ref: gix::refs::FullName = format!("refs/shelved/{old_ref_name}")
                        .as_str()
                        .try_into()
                        .map_err(EngineError::from_gix)?;
                    let _ = repo.edit_reference(RefEdit {
                        change: Change::Update {
                            log: LogChange {
                                mode: RefLog::AndReference,
                                force_create_reflog: true,
                                message: old_name.clone().into(),
                            },
                            expected: PreviousValue::MustNotExist,
                            new: Target::Object(patch_id),
                        },
                        name: old_ref,
                        deref: false,
                    });
                    let new_ref: gix::refs::FullName = format!("refs/shelved/{new_ref_name}")
                        .as_str()
                        .try_into()
                        .map_err(EngineError::from_gix)?;
                    let _ = repo.edit_reference(RefEdit {
                        change: Change::Delete {
                            expected: PreviousValue::Any,
                            log: RefLog::AndReference,
                        },
                        name: new_ref,
                        deref: false,
                    });
                    return Err(error);
                }
            }
        } else {
            false
        };

        shelves[index].0 = new_name.clone();
        if let Err(error) = save_shelves(&repo, &shelves).and_then(|_| {
            let fallback_timestamp = repo
                .find_commit(patch_id)
                .ok()
                .and_then(|commit| commit.time().ok().map(|time| time.seconds))
                .unwrap_or_else(current_unix_seconds);
            rename_shelf_metadata(
                &repo,
                &old_name,
                &new_name,
                patch_id,
                fallback_timestamp,
                &new_name,
            )
        }) {
            let _ = std::fs::write(&shelves_file, original_shelves_file);
            let metadata_file = shelf_metadata_file(&repo);
            match original_metadata_file {
                Some(bytes) => {
                    let _ = std::fs::write(&metadata_file, bytes);
                }
                None => {
                    let _ = std::fs::remove_file(&metadata_file);
                }
            }
            if raw_patch_moved {
                let _ = crate::shelve::rename_shelf_patch(&repo, &new_name, &old_name, false);
            }
            if refs_changed {
                let old_ref: gix::refs::FullName = format!("refs/shelved/{old_ref_name}")
                    .as_str()
                    .try_into()
                    .map_err(EngineError::from_gix)?;
                let _ = repo.edit_reference(RefEdit {
                    change: Change::Update {
                        log: LogChange {
                            mode: RefLog::AndReference,
                            force_create_reflog: true,
                            message: old_name.clone().into(),
                        },
                        expected: PreviousValue::MustNotExist,
                        new: Target::Object(patch_id),
                    },
                    name: old_ref,
                    deref: false,
                });
                let new_ref: gix::refs::FullName = format!("refs/shelved/{new_ref_name}")
                    .as_str()
                    .try_into()
                    .map_err(EngineError::from_gix)?;
                let _ = repo.edit_reference(RefEdit {
                    change: Change::Delete {
                        expected: PreviousValue::Any,
                        log: RefLog::AndReference,
                    },
                    name: new_ref,
                    deref: false,
                });
            }
            return Err(error);
        }
        Ok(())
    }

    /// Update only the user-facing Shelf description. IntelliJ's Rename
    /// action edits the ShelvedChangeList description while keeping its
    /// stable list name, ref, and patch object unchanged.
    pub fn shelve_set_description(
        &self,
        name: String,
        description: String,
    ) -> Result<(), EngineError> {
        use crate::shelve::{
            load_deleted_shelves, load_shelf_metadata, load_shelves, save_shelf_metadata,
            ShelfMetadata,
        };

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = name.trim().to_string();
        let description = description.trim().to_string();
        if name.is_empty() {
            return Err(EngineError::GitOperation {
                message: "shelve: name is required".into(),
            });
        }
        if description
            .chars()
            .any(|character| matches!(character, '\t' | '\r' | '\n'))
        {
            return Err(EngineError::GitOperation {
                message: "shelve: description must not contain tabs or line breaks".into(),
            });
        }
        ensure_shelve_not_pending_restore(&repo, &name)?;

        let (patch_id, is_deleted) = if let Some((_, id)) = load_shelves(&repo)?
            .into_iter()
            .find(|(candidate, _)| candidate == &name)
        {
            (id, false)
        } else if let Some((_, id)) = load_deleted_shelves(&repo)?
            .into_iter()
            .find(|(candidate, _)| candidate == &name)
        {
            (id, true)
        } else {
            return Err(EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            });
        };

        let mut metadata = load_shelf_metadata(&repo)?;
        if let Some(item) = metadata.iter_mut().find(|item| item.name == name) {
            item.id = patch_id;
            item.description = description;
        } else {
            let timestamp = repo
                .find_commit(patch_id)
                .ok()
                .and_then(|commit| commit.time().ok().map(|time| time.seconds))
                .unwrap_or_else(current_unix_seconds);
            metadata.insert(
                0,
                ShelfMetadata {
                    name,
                    id: patch_id,
                    timestamp,
                    description,
                    recycled: false,
                    to_delete: false,
                    deleted: is_deleted,
                },
            );
        }
        save_shelf_metadata(&repo, &metadata)
    }

    /// 返回 shelf 的完整 patch 文本，包含 rename/binary 元数据。
    /// 禁用 external diff 与 textconv，预览不会执行仓库配置中的外部命令。
    pub fn shelve_diff(&self, name: String) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_diff_locked(&repo, &name)
    }

    /// Return whether an active Shelf was imported from an external patch.
    /// Imported patches support IntelliJ-style manual base-directory mapping;
    /// revision-backed shelves use the repository's own tree paths instead.
    pub fn shelve_is_imported(&self, name: String) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        Ok(crate::shelve::read_shelf_patch(&repo, &name, false)?.is_some())
    }

    /// Return the complete patch text for a Recently Deleted shelf.
    pub fn shelve_deleted_diff(&self, name: String) -> Result<String, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_diff_locked_from_collection(&repo, &name, true)
    }

    /// 返回 Shelf 中单个文件的结构化 diff。
    ///
    /// 默认比较保存时 HEAD 与 Shelved version；`with_local` 模式改为当前
    /// 工作区与 Shelved version。这对应 IntelliJ 的 View Diff 与
    /// Diff Shelved Changes with Local 两条路径。导入的纯 patch 没有可寻址
    /// 的 shelf tree，因此保留 raw patch 回退，由 UI 展示明确的降级原因。
    pub fn shelve_file_diff(
        &self,
        name: String,
        path: String,
        with_local: bool,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.shelve_file_diff_with_settings(
            name,
            path,
            with_local,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// DIFF-002：revision-backed Shelf file diff with opt-in textconv.
    pub fn shelve_file_diff_with_settings(
        &self,
        name: String,
        path: String,
        with_local: bool,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_file_diff_locked(&repo, &name, &path, with_local, &settings, false)
    }

    /// Recently Deleted Shelf 的结构化文件 Diff。与 active Shelf 共用
    /// revision-backed tree 语义；导入型 patch 没有可寻址 tree，明确回退
    /// 到上层 raw patch 预览。
    pub fn shelve_deleted_file_diff(
        &self,
        name: String,
        path: String,
        with_local: bool,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        self.shelve_deleted_file_diff_with_settings(
            name,
            path,
            with_local,
            crate::diff::DiffSettings {
                ignore_all_space: ignore_whitespace,
                ..crate::diff::DiffSettings::default()
            },
        )
    }

    /// Recently Deleted Shelf file diff with explicit Diff settings.
    pub fn shelve_deleted_file_diff_with_settings(
        &self,
        name: String,
        path: String,
        with_local: bool,
        settings: crate::diff::DiffSettings,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_file_diff_locked(&repo, &name, &path, with_local, &settings, true)
    }

    /// Preview one member of an imported Shelf or direct Apply Patch against
    /// the current worktree. Unlike parsing the patch's own old/new lines,
    /// this reflects local edits, application offsets, and the selected base
    /// directory/path strip. The preview is isolated from the real worktree.
    pub fn imported_patch_file_diff(
        &self,
        patch: String,
        path: String,
        base_directory: String,
        path_strip: u32,
        ignore_whitespace: bool,
    ) -> Result<FileDiff, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        imported_patch_file_diff_inner(
            &repo,
            &patch,
            &path,
            &base_directory,
            path_strip,
            ignore_whitespace,
        )
    }

    /// 把补丁应用回工作区（未暂存），补丁保留。
    pub fn shelve_unshelve(&self, name: String) -> Result<(), EngineError> {
        self.shelve_unshelve_with_options(name, false)?;
        Ok(())
    }

    /// Apply all members of a Shelf with differentiated per-file results.
    /// Clean members remain applied when another member cannot be applied.
    pub fn shelve_unshelve_with_options_differentiated(
        &self,
        name: String,
        remove_applied: bool,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch = shelve_diff_locked(&repo, &name)?;
        let paths = crate::shelve::patch_member_paths(&patch)?;
        apply_differentiated_shelf_selection_locked(
            &repo,
            &name,
            false,
            &paths,
            false,
            remove_applied,
        )
    }

    /// Apply all members of a Recently Deleted Shelf with differentiated
    /// per-file results.
    pub fn shelve_unshelve_deleted_with_options_differentiated(
        &self,
        name: String,
        remove_applied: bool,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch = shelve_diff_locked_from_collection(&repo, &name, true)?;
        let paths = crate::shelve::patch_member_paths(&patch)?;
        apply_differentiated_shelf_selection_locked(
            &repo,
            &name,
            true,
            &paths,
            false,
            remove_applied,
        )
    }

    /// Apply selected active Shelf members with differentiated results.
    pub fn shelve_unshelve_paths_with_options_differentiated(
        &self,
        name: String,
        paths: Vec<String>,
        remove_applied: bool,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        apply_differentiated_shelf_selection_locked(
            &repo,
            &name,
            false,
            &paths,
            false,
            remove_applied,
        )
    }

    /// Apply selected Recently Deleted Shelf members with differentiated
    /// results.
    pub fn shelve_unshelve_deleted_paths_with_options_differentiated(
        &self,
        name: String,
        paths: Vec<String>,
        remove_applied: bool,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        apply_differentiated_shelf_selection_locked(
            &repo,
            &name,
            true,
            &paths,
            false,
            remove_applied,
        )
    }

    /// Apply and permanently consume the successful members of an active
    /// Shelf. A failed member stays in the active remainder and a conflict
    /// pauses the durable restore snapshot for the resolver.
    pub fn shelve_pop_differentiated(&self, name: String) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let source_patch = shelve_diff_locked(&repo, &name)?;
        let paths = crate::shelve::patch_member_paths(&source_patch)?;
        apply_differentiated_shelf_selection_locked(&repo, &name, false, &paths, true, true)
    }

    /// Apply a shelf and optionally remove the successfully applied files from
    /// the shelf. The default API keeps the shelf and marks it recycled.
    pub fn shelve_unshelve_with_options(
        &self,
        name: String,
        remove_applied: bool,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let list = crate::shelve::load_shelves(&repo)?;
        let is_imported = crate::shelve::read_shelf_patch(&repo, &name, false)?.is_some();
        let patch_id = list
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let applied_paths = crate::shelve::apply_shelve_with_options(
            &repo,
            patch_id,
            &name,
            false,
            remove_applied,
        )?;
        if is_imported {
            let source_paths = source_shelve_paths_for_apply_locked(
                &repo,
                &name,
                false,
                None,
                &applied_paths,
                None,
                1,
            )?;
            if !source_paths.is_empty() {
                finalize_unshelve_selection_locked(&repo, &name, &source_paths, remove_applied)?;
            }
            return Ok(applied_paths);
        }
        if remove_applied {
            archive_shelve_locked(&repo, &name)?;
        } else {
            mark_shelve_recycled_locked(&repo, &name)?;
        }
        Ok(applied_paths)
    }

    /// Apply a patch selected from Recently Deleted without first restoring
    /// its list. This mirrors IntelliJ's UnshelveSilently data context, where
    /// deleted changelists remain deleted unless applied members are removed.
    pub fn shelve_unshelve_deleted_with_options(
        &self,
        name: String,
        remove_applied: bool,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let list = crate::shelve::load_deleted_shelves(&repo)?;
        let patch_id = list
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: deleted shelf {name} not found"),
            })?;
        let applied_paths = crate::shelve::apply_deleted_shelve_with_options(
            &repo,
            patch_id,
            &name,
            false,
            remove_applied,
        )?;
        if remove_applied && applied_paths.is_empty() {
            delete_deleted_shelve_locked(&repo, &name)?;
        } else if remove_applied {
            let source_paths = source_shelve_paths_for_apply_locked(
                &repo,
                &name,
                true,
                None,
                &applied_paths,
                None,
                1,
            )?;
            if !source_paths.is_empty() {
                finalize_unshelve_selection_locked(&repo, &name, &source_paths, true)?;
            }
        }
        Ok(applied_paths)
    }

    /// Apply only selected members from Recently Deleted. Keeping the list
    /// leaves the deleted changelist intact; removing applied members updates
    /// the same deleted patch and deletes it only when no remainder remains.
    pub fn shelve_unshelve_deleted_paths_with_options(
        &self,
        name: String,
        paths: Vec<String>,
        remove_applied: bool,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch_id = crate::shelve::load_deleted_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: deleted shelf {name} not found"),
            })?;
        let applied_paths = crate::shelve::apply_deleted_shelve_paths_with_options(
            &repo,
            patch_id,
            &paths,
            &name,
            remove_applied,
        )?;
        let source_paths = source_shelve_paths_for_apply_locked(
            &repo,
            &name,
            true,
            Some(&paths),
            &applied_paths,
            None,
            1,
        )?;
        if !source_paths.is_empty() {
            finalize_unshelve_selection_locked(&repo, &name, &source_paths, remove_applied)?;
        }
        Ok(applied_paths)
    }

    /// 应用 shelf 中选中的文件变更但保留整个 shelf。
    ///
    /// 这是 IntelliJ Changes Browser 在 ShelvedChange 节点上的 Unshelve
    /// 语义：未选中的成员不能被顺带写回工作区。
    pub fn shelve_unshelve_paths(
        &self,
        name: String,
        paths: Vec<String>,
    ) -> Result<(), EngineError> {
        self.shelve_unshelve_paths_with_options(name, paths, false)?;
        Ok(())
    }

    /// Apply selected shelf members and optionally move the applied members to
    /// Recently Deleted instead of the recycled collection.
    pub fn shelve_unshelve_paths_with_options(
        &self,
        name: String,
        paths: Vec<String>,
        remove_applied: bool,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let list = crate::shelve::load_shelves(&repo)?;
        let patch_id = list
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let applied_paths = crate::shelve::apply_shelve_paths_with_options(
            &repo,
            patch_id,
            &paths,
            &name,
            remove_applied,
        )?;
        let source_paths = source_shelve_paths_for_apply_locked(
            &repo,
            &name,
            false,
            Some(&paths),
            &applied_paths,
            None,
            1,
        )?;
        if !source_paths.is_empty() {
            finalize_unshelve_selection_locked(&repo, &name, &source_paths, remove_applied)?;
        }
        Ok(applied_paths)
    }

    /// Apply selected members of an imported active Shelf relative to a
    /// mapped repository subdirectory.
    pub fn shelve_unshelve_paths_with_options_and_base(
        &self,
        name: String,
        paths: Vec<String>,
        remove_applied: bool,
        base_path: String,
        path_strip: u32,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch_id = crate::shelve::load_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let applied_paths = crate::shelve::apply_shelve_paths_with_options_and_base(
            &repo,
            patch_id,
            &paths,
            &name,
            remove_applied,
            &base_path,
            path_strip,
        )?;
        let source_paths = source_shelve_paths_for_apply_locked(
            &repo,
            &name,
            false,
            Some(&paths),
            &applied_paths,
            Some(&base_path),
            path_strip,
        )?;
        if !source_paths.is_empty() {
            finalize_unshelve_selection_locked(&repo, &name, &source_paths, remove_applied)?;
        }
        Ok(applied_paths)
    }

    /// Apply selected members of an imported Recently Deleted Shelf relative
    /// to a mapped repository subdirectory.
    pub fn shelve_unshelve_deleted_paths_with_options_and_base(
        &self,
        name: String,
        paths: Vec<String>,
        remove_applied: bool,
        base_path: String,
        path_strip: u32,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch_id = crate::shelve::load_deleted_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: deleted shelf {name} not found"),
            })?;
        let applied_paths = crate::shelve::apply_deleted_shelve_paths_with_options_and_base(
            &repo,
            patch_id,
            &paths,
            &name,
            remove_applied,
            &base_path,
            path_strip,
        )?;
        let source_paths = source_shelve_paths_for_apply_locked(
            &repo,
            &name,
            true,
            Some(&paths),
            &applied_paths,
            Some(&base_path),
            path_strip,
        )?;
        if !source_paths.is_empty() {
            finalize_unshelve_selection_locked(&repo, &name, &source_paths, remove_applied)?;
        }
        Ok(applied_paths)
    }

    /// Apply selected file/hunk members of an active Shelf with differentiated
    /// file-level results. A conflict pauses the restore snapshot so the
    /// existing resolver can complete or roll it back.
    pub fn shelve_unshelve_selections_with_options_differentiated(
        &self,
        name: String,
        selections: Vec<crate::shelve::ShelvePatchSelection>,
        remove_applied: bool,
    ) -> Result<PatchApplyResult, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch_id = crate::shelve::load_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let source_patch = shelve_diff_locked(&repo, &name)?;
        let result = crate::shelve::apply_raw_shelve_selections_differentiated(
            &repo,
            &source_patch,
            &name,
            &selections,
            None,
            Some(1),
            false,
            remove_applied,
            false,
            None,
        )?;
        let requested_paths = selections
            .iter()
            .map(|selection| selection.path.clone())
            .collect::<Vec<_>>();
        let result = source_shelve_patch_apply_result_locked(
            &repo,
            &name,
            false,
            Some(&requested_paths),
            result,
            None,
            1,
        )?;
        let applied_selections = crate::shelve::applied_patch_selections_for_target_paths(
            &source_patch,
            &selections,
            &result.applied_paths,
            None,
            1,
        )?;
        if !applied_selections.is_empty() {
            let selected_patch =
                crate::shelve::select_patch_selections(&source_patch, &applied_selections)?;
            let remaining_patch =
                crate::shelve::remove_patch_selections(&source_patch, &applied_selections)?;
            finalize_unshelve_patch_locked(
                &repo,
                &name,
                patch_id,
                false,
                selected_patch,
                remaining_patch,
                remove_applied,
            )?;
        }
        Ok(result)
    }

    /// Apply selected text hunks from an active Shelf. Binary, rename-only,
    /// and mode-only members use `hunk_index = None` and are applied as a
    /// whole file. The same selection is used to update the Shelf remainder,
    /// so Remove Applied Files does not accidentally discard unselected hunks.
    pub fn shelve_unshelve_selections_with_options(
        &self,
        name: String,
        selections: Vec<crate::shelve::ShelvePatchSelection>,
        remove_applied: bool,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let patch_id = crate::shelve::load_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let source_patch = shelve_diff_locked(&repo, &name)?;
        let applied_paths = crate::shelve::apply_raw_shelve_selections(
            &repo,
            &source_patch,
            &name,
            false,
            remove_applied,
            &selections,
            None,
            None,
            false,
        )?;
        let applied_selections = crate::shelve::applied_patch_selections_for_target_paths(
            &source_patch,
            &selections,
            &applied_paths,
            None,
            1,
        )?;
        if !applied_selections.is_empty() {
            let selected_patch =
                crate::shelve::select_patch_selections(&source_patch, &applied_selections)?;
            let remaining_patch =
                crate::shelve::remove_patch_selections(&source_patch, &applied_selections)?;
            finalize_unshelve_patch_locked(
                &repo,
                &name,
                patch_id,
                false,
                selected_patch,
                remaining_patch,
                remove_applied,
            )?;
        }
        Ok(applied_paths)
    }

    /// Apply selected hunks from an imported active Shelf relative to a
    /// mapped repository subdirectory. The Shelf remainder is computed in the
    /// original patch coordinates, while Git receives the mapped paths.
    pub fn shelve_unshelve_selections_with_options_and_base(
        &self,
        name: String,
        selections: Vec<crate::shelve::ShelvePatchSelection>,
        remove_applied: bool,
        base_path: String,
        path_strip: u32,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if crate::shelve::read_shelf_patch(&repo, &name, false)?.is_none() {
            return Err(EngineError::GitOperation {
                message: "shelve: base directory mapping is only available for imported patches"
                    .into(),
            });
        }
        let patch_id = crate::shelve::load_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let source_patch = shelve_diff_locked(&repo, &name)?;
        let applied_paths = crate::shelve::apply_raw_shelve_selections(
            &repo,
            &source_patch,
            &name,
            false,
            remove_applied,
            &selections,
            Some(&base_path),
            Some(path_strip),
            false,
        )?;
        let applied_selections = crate::shelve::applied_patch_selections_for_target_paths(
            &source_patch,
            &selections,
            &applied_paths,
            Some(&base_path),
            path_strip,
        )?;
        if !applied_selections.is_empty() {
            let selected_patch =
                crate::shelve::select_patch_selections(&source_patch, &applied_selections)?;
            let remaining_patch =
                crate::shelve::remove_patch_selections(&source_patch, &applied_selections)?;
            finalize_unshelve_patch_locked(
                &repo,
                &name,
                patch_id,
                false,
                selected_patch,
                remaining_patch,
                remove_applied,
            )?;
        }
        Ok(applied_paths)
    }

    /// Roll back a paused shelf restore to the exact worktree and index state
    /// captured immediately before the shelf was applied. The shelf remains.
    pub fn shelve_abort_restore(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let is_pop = crate::shelve::restore_info(&repo)?
            .filter(|info| info.name == name)
            .map(|info| info.is_pop)
            .unwrap_or(false);
        crate::shelve::abort_restore(&repo, &name)?;
        if is_pop {
            crate::shelve::clear_temporary_index_snapshot(&repo)?;
        }
        // A failed rebase restore has already completed the Git operation;
        // aborting only the Shelf apply must not leave a stale rebase-local
        // marker that blocks future rebases. The Shelf itself remains.
        clear_rebase_local_stash_if_shelf(&repo, &name);
        clear_apply_local_changes_if_shelf(&repo, &name);
        Ok(())
    }

    /// Finalize a paused restoration created by the apply preserving flow.
    /// Stash entries are removed by object id, never by a moving numeric
    /// index. Ordinary user stash conflicts return `false` and keep their
    /// existing index-based lifecycle unchanged.
    pub fn finalize_apply_local_changes_restore(&self) -> Result<bool, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let Some(saved) = load_apply_local_changes(&repo)? else {
            return Ok(false);
        };
        let conflicts = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                entry.staged == crate::status::ChangeKind::Conflicted
                    || entry.unstaged == crate::status::ChangeKind::Conflicted
            })
            .map(|entry| entry.path)
            .collect::<Vec<_>>();
        if !conflicts.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "{}: unresolved local-change restore conflicts remain: {}",
                    saved.kind,
                    conflicts.join(", ")
                ),
            });
        }
        let ApplyLocalChanges { kind, saved } = saved;
        match saved {
            RebaseLocalChanges::Stash(stash_id) => {
                // A submodule Update can crash after the stash pop has
                // removed the artifact but before the marker is cleared.
                // Treat that narrow, already-restored state as finalized;
                // other preserving operations still fail closed if their
                // exact stash identity disappeared.
                if kind != "submodule-update" || walk_stash_chain(&repo)?.contains(&stash_id) {
                    drop_stash_with_id_locked(&repo, stash_id)?;
                }
            }
            RebaseLocalChanges::Shelf(name) => {
                if crate::shelve::load_shelves(&repo)?
                    .iter()
                    .any(|(candidate, _)| candidate == &name)
                {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "{}: the temporary Shelf is still present; complete its restore first",
                            kind
                        ),
                    });
                }
            }
        }
        clear_apply_local_changes(&repo);
        Ok(true)
    }

    /// Finish a paused shelf restore after all conflicts are resolved. Pop
    /// consumes the shelf; Unshelve keeps it. The snapshot is cleared only
    /// after the requested lifecycle action succeeds.
    pub fn shelve_complete_restore(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let Some(info) = crate::shelve::restore_info(&repo)? else {
            return Err(EngineError::GitOperation {
                message: format!("shelve: no pending restore for {name}"),
            });
        };
        if info.name != name {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: pending restore belongs to '{}', not '{name}'",
                    info.name
                ),
            });
        }
        let conflicts = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                entry.staged == crate::status::ChangeKind::Conflicted
                    || entry.unstaged == crate::status::ChangeKind::Conflicted
            })
            .map(|entry| entry.path)
            .collect::<Vec<_>>();
        if !conflicts.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: unresolved conflicts remain: {}",
                    conflicts.join(", ")
                ),
            });
        }
        let is_imported = crate::shelve::read_shelf_patch(&repo, &name, false)?.is_some();
        if info.is_pop {
            let had_temporary_index_snapshot = crate::shelve::has_temporary_index_snapshot(&repo)?;
            if had_temporary_index_snapshot {
                crate::shelve::restore_temporary_index_snapshot(&repo, &name)?;
            }
            if let Some(source_paths) =
                crate::shelve::differentiated_restore_source_paths(&repo, &name)?
            {
                if !had_temporary_index_snapshot {
                    crate::shelve::restore_differentiated_index_snapshot(&repo, &name)?;
                }
                if !source_paths.is_empty() {
                    consume_shelve_selection_locked(&repo, &name, &source_paths)?;
                }
            } else if is_imported {
                drop_shelve_locked(&repo, &name)?;
            } else {
                drop_shelve_locked(&repo, &name)?;
            }
            clear_rebase_local_stash_if_shelf(&repo, &name);
            clear_apply_local_changes_if_shelf(&repo, &name);
        } else if let Some(source_paths) =
            crate::shelve::differentiated_restore_source_paths(&repo, &name)?
        {
            crate::shelve::restore_differentiated_index_snapshot(&repo, &name)?;
            if !source_paths.is_empty() {
                finalize_unshelve_selection_locked(
                    &repo,
                    &name,
                    &source_paths,
                    info.remove_applied,
                )?;
            }
        } else if is_imported {
            finalize_unshelve_selection_locked(&repo, &name, &info.paths, info.remove_applied)?;
        } else {
            finalize_unshelve_selection_locked(&repo, &name, &info.paths, info.remove_applied)?;
        }
        crate::shelve::clear_restore_snapshot(&repo)?;
        Ok(())
    }

    /// Finish a direct imported-patch apply after the conflict resolver has
    /// cleared every conflict. No Shelf metadata or ref is created.
    pub fn apply_imported_patch_complete_restore(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::shelve::complete_raw_restore(&repo, &name)
    }

    /// 从 shelf 中删除选中的成员；未选中的变更继续保留在同一个 shelf。
    /// 被删除的成员会进入独立的 Recently Deleted changelist，保留原始
    /// description，并可在之后 Restore 为一个可恢复的 Shelf。
    pub fn shelve_drop_paths(&self, name: String, paths: Vec<String>) -> Result<(), EngineError> {
        use crate::shelve::{
            load_shelf_metadata, load_shelves, remove_shelf_patch, write_shelf_patch,
        };

        let repo = self.inner.lock().expect("repo mutex poisoned");
        ensure_shelve_not_pending_restore(&repo, &name)?;
        let patch_id = load_shelves(&repo)?
            .iter()
            .find(|(candidate, _)| *candidate == name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {name} not found"),
            })?;
        let source_patch = shelve_diff_locked(&repo, &name)?;
        let selected_patch = crate::shelve::select_patch_chunks(&source_patch, &paths)?;
        let Some(remaining_patch) = crate::shelve::remove_patch_chunks(&source_patch, &paths)?
        else {
            archive_shelve_locked(&repo, &name)?;
            return Ok(());
        };

        let source_original = crate::shelve::read_shelf_patch(&repo, &name, false)?;
        let description = load_shelf_metadata(&repo)?
            .into_iter()
            .find(|item| item.name == name)
            .map(|item| item.description)
            .unwrap_or_else(|| name.clone());
        write_shelf_patch(
            &repo,
            &name,
            false,
            remaining_patch.as_bytes(),
            source_original.is_some(),
        )?;

        if let Err(error) = create_deleted_shelve_from_patch_locked(
            &repo,
            &name,
            patch_id,
            &selected_patch,
            &description,
        ) {
            match source_original {
                Some(bytes) => {
                    let _ = write_shelf_patch(&repo, &name, false, &bytes, true);
                }
                None => {
                    let _ = remove_shelf_patch(&repo, &name, false);
                }
            }
            return Err(error);
        }
        Ok(())
    }

    /// Move selected members between two ShelvedChangeLists. The destination
    /// is normalized to a raw patch file so commit-backed and imported shelves
    /// share one lossless path/chunk representation; the shelf refs remain
    /// stable and can still be renamed or recovered normally.
    pub fn shelve_move_paths(
        &self,
        source_name: String,
        target_name: String,
        paths: Vec<String>,
    ) -> Result<(), EngineError> {
        use crate::shelve::{load_shelves, remove_shelf_patch, write_shelf_patch};

        if source_name == target_name {
            return Err(EngineError::GitOperation {
                message: "shelve: source and target changelist must differ".into(),
            });
        }
        if paths.is_empty() {
            return Err(EngineError::GitOperation {
                message: "shelve: select at least one change to move".into(),
            });
        }

        let repo = self.inner.lock().expect("repo mutex poisoned");
        ensure_shelve_not_pending_restore(&repo, &source_name)?;
        ensure_shelve_not_pending_restore(&repo, &target_name)?;
        let shelves = load_shelves(&repo)?;
        let source_id = shelves
            .iter()
            .find(|(name, _)| *name == source_name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {source_name} not found"),
            })?;
        let target_id = shelves
            .iter()
            .find(|(name, _)| *name == target_name)
            .map(|(_, id)| *id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: {target_name} not found"),
            })?;

        let source_patch = shelve_diff_locked(&repo, &source_name)?;
        let target_patch = shelve_diff_locked(&repo, &target_name)?;
        let selected_patch = crate::shelve::select_patch_chunks(&source_patch, &paths)?;
        let source_endpoints = crate::shelve::patch_endpoint_paths(&selected_patch)?;
        let target_endpoints = crate::shelve::patch_endpoint_paths(&target_patch)?;
        if source_endpoints
            .iter()
            .any(|path| target_endpoints.contains(path))
        {
            return Err(EngineError::GitOperation {
                message: "shelve: target changelist already contains one of the selected paths"
                    .into(),
            });
        }
        let remaining_source = crate::shelve::remove_patch_chunks(&source_patch, &paths)?;
        let mut combined_target = target_patch.trim_end().to_string();
        // Git's binary patch parser needs a blank line before the next
        // `diff --git` header; a single newline makes that header look like
        // another binary payload line.
        combined_target.push_str("\n\n");
        combined_target.push_str(selected_patch.trim_start());
        if !combined_target.ends_with('\n') {
            combined_target.push('\n');
        }

        let target_original = crate::shelve::read_shelf_patch(&repo, &target_name, false)?;
        let source_original = crate::shelve::read_shelf_patch(&repo, &source_name, false)?;
        let target_replace = target_original.is_some();
        if let Err(error) = write_shelf_patch(
            &repo,
            &target_name,
            false,
            combined_target.as_bytes(),
            target_replace,
        ) {
            return Err(error);
        }

        let source_result = if let Some(remaining) = remaining_source {
            write_shelf_patch(
                &repo,
                &source_name,
                false,
                remaining.as_bytes(),
                source_original.is_some(),
            )
        } else {
            archive_shelve_locked(&repo, &source_name)
        };
        if let Err(error) = source_result {
            if let Some(bytes) = target_original {
                let _ = write_shelf_patch(&repo, &target_name, false, &bytes, true);
            } else {
                let _ = remove_shelf_patch(&repo, &target_name, false);
            }
            return Err(error);
        }

        // Keep the ids alive for the list/ref model; they are intentionally
        // read above so a future ref refresh cannot make the transaction
        // silently target a different shelf.
        let _ = (source_id, target_id);
        Ok(())
    }

    /// 应用补丁并删除。
    pub fn shelve_pop(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_pop_locked(&repo, &name)
    }

    /// Apply and remove a Shelf saved by a preserving Git process. Unlike
    /// ordinary user Pop, this keeps differentiated per-file recovery even
    /// when an older or damaged restore marker no longer has its temporary
    /// index snapshot.
    pub fn shelve_pop_preservation(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_pop_preservation_locked(&repo, &name)
    }

    /// Apply and remove a Shelf with process-group cancellation for the
    /// differentiated preservation restore path. A cancelled restore keeps
    /// the Shelf and its temporary index snapshot so the caller can retry or
    /// surface an explicit recovery action.
    pub fn shelve_pop_with_cancel(
        &self,
        name: String,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        shelve_pop_preservation_locked_with_cancel(&repo, &name, Some(cancel.token()))
    }

    /// 删除补丁并移入持久化 Recently Deleted 列表。
    pub fn shelve_drop(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        ensure_shelve_not_pending_restore(&repo, &name)?;
        mark_shelve_pending_delete_locked(&repo, &name)?;
        archive_shelve_locked(&repo, &name)
    }

    /// 从 Recently Deleted 恢复 shelf，并把生命周期时间更新为当前时间。
    /// 这是用户主动点击 Recently Deleted 的 Restore 动作。
    pub fn shelve_restore_deleted(&self, name: String) -> Result<(), EngineError> {
        self.shelve_restore_deleted_with_timestamp(name, None)
    }

    /// 从 Recently Deleted 恢复 shelf。
    ///
    /// `timestamp` 仅供删除通知的 Undo 使用：IntelliJ 的 Undo 删除会
    /// 恢复原始 ShelvedChangeList 日期，而普通 Restore 会使用当前日期。
    pub fn shelve_restore_deleted_with_timestamp(
        &self,
        name: String,
        timestamp: Option<i64>,
    ) -> Result<(), EngineError> {
        use crate::shelve::{
            deleted_shelves_file, load_deleted_shelves, load_shelf_metadata, load_shelves,
            save_deleted_shelves, save_shelves, shelf_metadata_file, upsert_shelf_metadata,
        };
        use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
        use gix::refs::Target;

        let repo = self.inner.lock().expect("repo mutex poisoned");
        let shelves_file = crate::shelve::shelves_file(&repo);
        let deleted_file = deleted_shelves_file(&repo);
        let metadata_file = shelf_metadata_file(&repo);
        let original_shelves_file = std::fs::read(&shelves_file).map_err(EngineError::from_gix)?;
        let original_deleted_file = std::fs::read(&deleted_file).map_err(EngineError::from_gix)?;
        let original_metadata_file = std::fs::read(&metadata_file).ok();
        let mut shelves = load_shelves(&repo)?;
        let mut deleted = load_deleted_shelves(&repo)?;
        let index = deleted
            .iter()
            .position(|(candidate, _)| *candidate == name)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("shelve: deleted shelf {name} not found"),
            })?;
        let patch_id = deleted[index].1;
        let restored_metadata = load_shelf_metadata(&repo)?
            .into_iter()
            .find(|item| item.name == name);
        let restored_description = restored_metadata
            .as_ref()
            .map(|item| item.description.clone())
            .unwrap_or_else(|| name.clone());
        let restored_recycled = restored_metadata
            .as_ref()
            .map(|item| item.recycled)
            .unwrap_or(false);
        let ref_name = crate::shelve::sanitize_ref_name(&name);
        if shelves
            .iter()
            .any(|(candidate, _)| crate::shelve::sanitize_ref_name(candidate) == ref_name)
        {
            return Err(EngineError::GitOperation {
                message: format!("shelve: active shelf ref already exists for {name}"),
            });
        }

        deleted.remove(index);
        shelves.insert(0, (name.clone(), patch_id));
        let active_ref = shelf_ref_name("shelved", &name)?;
        let deleted_ref = shelf_ref_name("shelved-deleted", &name)?;
        repo.edit_reference(RefEdit {
            change: Change::Update {
                log: LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: true,
                    message: format!("{name}: restored from Recently Deleted").into(),
                },
                expected: PreviousValue::MustNotExist,
                new: Target::Object(patch_id),
            },
            name: active_ref.clone(),
            deref: false,
        })
        .map_err(EngineError::from_gix)?;
        if let Err(error) = repo.edit_reference(RefEdit {
            change: Change::Delete {
                expected: PreviousValue::MustExistAndMatch(Target::Object(patch_id)),
                log: RefLog::AndReference,
            },
            name: deleted_ref.clone(),
            deref: false,
        }) {
            let _ = repo.edit_reference(RefEdit {
                change: Change::Delete {
                    expected: PreviousValue::Any,
                    log: RefLog::AndReference,
                },
                name: active_ref,
                deref: false,
            });
            return Err(EngineError::GitOperation {
                message: format!("shelve: could not restore deleted shelf ref: {error}"),
            });
        }
        let raw_patch_moved = match crate::shelve::move_shelf_patch(&repo, &name, true, false) {
            Ok(moved) => moved,
            Err(error) => {
                let _ = repo.edit_reference(RefEdit {
                    change: Change::Update {
                        log: LogChange {
                            mode: RefLog::AndReference,
                            force_create_reflog: true,
                            message: name.clone().into(),
                        },
                        expected: PreviousValue::MustNotExist,
                        new: Target::Object(patch_id),
                    },
                    name: deleted_ref.clone(),
                    deref: false,
                });
                let _ = repo.edit_reference(RefEdit {
                    change: Change::Delete {
                        expected: PreviousValue::Any,
                        log: RefLog::AndReference,
                    },
                    name: active_ref.clone(),
                    deref: false,
                });
                return Err(error);
            }
        };
        if let Err(error) = save_shelves(&repo, &shelves)
            .and_then(|_| save_deleted_shelves(&repo, &deleted))
            .and_then(|_| {
                upsert_shelf_metadata(
                    &repo,
                    &name,
                    patch_id,
                    timestamp.unwrap_or_else(current_unix_seconds),
                    &restored_description,
                )
            })
            .and_then(|_| {
                crate::shelve::set_shelf_metadata_state(
                    &repo,
                    &name,
                    restored_recycled,
                    false,
                    false,
                )
            })
        {
            let _ = std::fs::write(&shelves_file, original_shelves_file);
            let _ = std::fs::write(&deleted_file, original_deleted_file);
            match original_metadata_file {
                Some(bytes) => {
                    let _ = std::fs::write(&metadata_file, bytes);
                }
                None => {
                    let _ = std::fs::remove_file(&metadata_file);
                }
            }
            if raw_patch_moved {
                let _ = crate::shelve::move_shelf_patch(&repo, &name, false, true);
            }
            let _ = repo.edit_reference(RefEdit {
                change: Change::Update {
                    log: LogChange {
                        mode: RefLog::AndReference,
                        force_create_reflog: true,
                        message: name.clone().into(),
                    },
                    expected: PreviousValue::MustNotExist,
                    new: Target::Object(patch_id),
                },
                name: deleted_ref.clone(),
                deref: false,
            });
            let _ = repo.edit_reference(RefEdit {
                change: Change::Delete {
                    expected: PreviousValue::Any,
                    log: RefLog::AndReference,
                },
                name: active_ref,
                deref: false,
            });
            return Err(error);
        }
        Ok(())
    }

    /// 永久删除 Recently Deleted 中的 shelf，不影响工作区。
    pub fn shelve_delete_deleted(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        delete_deleted_shelve_locked(&repo, &name)
    }

    /// Permanently remove selected members from a Recently Deleted shelf.
    /// Unselected members remain in the deleted list; removing its last
    /// member removes the deleted shelf itself.
    pub fn shelve_delete_deleted_paths(
        &self,
        name: String,
        paths: Vec<String>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        delete_deleted_shelve_paths_locked(&repo, &name, &paths)
    }

    // MARK: 分支管理

    /// 创建分支（at=None -> HEAD）。
    pub fn branch_create(&self, name: String, at: Option<String>) -> Result<(), EngineError> {
        use gix::refs::transaction::PreviousValue;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = name.trim();
        validate_branch_name_inner(&repo, name)?;
        let full = format!("refs/heads/{name}");
        let target = match &at {
            Some(spec) if !spec.trim().is_empty() => repo
                .rev_parse_single(BStr::new(spec.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach(),
            _ => repo.head_id().map_err(EngineError::from_gix)?.detach(),
        };
        let full_name: gix::refs::FullName =
            full.as_str().try_into().map_err(EngineError::from_gix)?;
        repo.reference(
            full_name,
            target,
            PreviousValue::MustNotExist,
            "branch: created",
        )
        .map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 创建并检出本地分支（等价 `git switch -c <name> [<start-point>]`）。
    ///
    /// 该路径交给 Git 原生命令处理工作区覆盖检查，失败时不会把“已创建但
    /// 未检出”的半完成状态暴露给调用方。
    pub fn branch_create_and_switch(
        &self,
        name: String,
        at: Option<String>,
    ) -> Result<(), EngineError> {
        let name = name.trim();
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        validate_branch_name_inner(&repo, name)?;
        let base = at
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "branch checkout requires a non-bare worktree".into(),
        })?;
        let branch_ref = format!("refs/heads/{name}");
        let branch_exists = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["show-ref", "--verify", "--quiet", &branch_ref])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)
            .and_then(|output| match output.status.code() {
                Some(0) => Ok(true),
                Some(1) => Ok(false),
                _ => Err(EngineError::GitOperation {
                    message: format!(
                        "cannot inspect branch before checkout: {}",
                        command_output_message(&output)
                    ),
                }),
            })?;
        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        command.args(["switch", "-c", name]);
        if let Some(base) = base {
            command.arg(base);
        }
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            let message = format!("git switch -c failed: {}", command_output_message(&output));
            if !branch_exists {
                let created = crate::gitprocess::git_command_for_working_dir(workdir)
                    .args(["show-ref", "--verify", "--quiet", &branch_ref])
                    .current_dir(workdir)
                    .output()
                    .map_err(EngineError::from_gix)?;
                let branch_created = match created.status.code() {
                    Some(0) => true,
                    Some(1) => false,
                    _ => {
                        return Err(EngineError::GitOperation {
                            message: format!(
                                "{message}; cleanup verification failed: {}",
                                command_output_message(&created)
                            ),
                        })
                    }
                };
                if !branch_created {
                    return Err(EngineError::GitOperation { message });
                }
                let cleanup = crate::gitprocess::git_command_for_working_dir(workdir)
                    .args(["branch", "-D", "--", name])
                    .current_dir(workdir)
                    .output()
                    .map_err(EngineError::from_gix)?;
                if !cleanup.status.success() {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "{message}; cleanup failed: {}",
                            command_output_message(&cleanup)
                        ),
                    });
                }
            }
            return Err(EngineError::GitOperation { message });
        }
        // The ref and HEAD were mutated by the external Git process. Refresh
        // gix's view before the Swift layer asks for the updated branch list.
        repo.reload().map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// Create a branch, or explicitly reset an existing branch to the start
    /// point. This is the destructive option behind IntelliJ's New Branch
    /// dialog overwrite checkbox: a non-current branch uses `git branch -f`,
    /// while the current branch must use `git switch -C` so its worktree and
    /// index move with the ref.
    pub fn branch_create_or_reset(
        &self,
        name: String,
        at: Option<String>,
        checkout: bool,
        reset: bool,
    ) -> Result<(), EngineError> {
        if !reset {
            return if checkout {
                self.branch_create_and_switch(name, at)
            } else {
                self.branch_create(name, at)
            };
        }

        let name = name.trim();
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        validate_branch_name_syntax_inner(name)?;
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "branch reset requires a non-bare worktree".into(),
        })?;
        let base = at
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("HEAD");
        if base.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "start point must not start with '-'".into(),
            });
        }
        let current_branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|head| shorten_ref_name(head.as_bstr()));

        let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
        if checkout || current_branch.as_deref() == Some(name) {
            command.args(["switch", "-C", name, base]);
        } else {
            command.args(["branch", "-f", name, base]);
        }
        let output = command
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!("reset branch failed: {}", command_output_message(&output)),
            });
        }
        repo.reload().map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 删除本地分支。
    ///
    /// 普通删除使用 `git branch -d` 的安全检查；只有用户明确确认后才允许
    /// `force=true` 对未合并分支执行 `-D`。当前分支始终由 Git 拒绝删除。
    pub fn branch_delete(&self, name: String, force: bool) -> Result<(), EngineError> {
        let name = name.trim();
        if name.is_empty() || name.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "branch name must not be empty or start with '-'".into(),
            });
        }
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "branch deletion requires a non-bare worktree".into(),
        })?;
        let flag = if force { "-D" } else { "-d" };
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["branch", flag, "--", name])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git branch {flag} failed: {}",
                    command_output_message(&output)
                ),
            });
        }
        repo.reload().map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// Capture the information IntelliJ shows before force-deleting an
    /// unmerged local branch. The snapshot is read before any ref mutation so
    /// the UI can both explain the risk and restore the exact old tip later.
    pub fn branch_delete_preview(&self, name: String) -> Result<BranchDeletePreview, EngineError> {
        let name = name.trim();
        if name.is_empty() || name.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "branch name must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let tip = repo
            .rev_parse_single(BStr::new(name.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let tip_id = tip.to_hex().to_string();

        let head_id = if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
            None
        } else {
            Some(
                repo.head_commit()
                    .map_err(EngineError::from_gix)?
                    .id()
                    .detach(),
            )
        };

        let upstream = configured_upstream(&repo, name).ok().map(|configured| {
            if configured.remote == "." {
                configured.branch
            } else {
                format!("{}/{}", configured.remote, configured.branch)
            }
        });

        // A base branch is any local or remote-tracking branch that already
        // contains this tip. This is the same useful set IntelliJ exposes in
        // its "not fully merged" confirmation instead of assuming only the
        // currently checked-out branch matters.
        let mut base_branches = Vec::new();
        let platform = repo.references().map_err(EngineError::from_gix)?;
        for reference in platform
            .local_branches()
            .map_err(EngineError::from_gix)?
            .peeled()
            .map_err(EngineError::from_gix)?
        {
            let reference = reference.map_err(crate::log::boxed_err)?;
            let Some(candidate) = reference.try_id().map(|id| id.detach()) else {
                continue;
            };
            let candidate_name = shorten_ref_name(reference.name().as_bstr());
            if candidate_name == name {
                continue;
            }
            if repo
                .merge_base(tip, candidate)
                .is_ok_and(|base| base == tip)
            {
                base_branches.push(candidate_name);
            }
        }
        let platform = repo.references().map_err(EngineError::from_gix)?;
        for reference in platform
            .remote_branches()
            .map_err(EngineError::from_gix)?
            .peeled()
            .map_err(EngineError::from_gix)?
        {
            let reference = reference.map_err(crate::log::boxed_err)?;
            let Some(candidate) = reference.try_id().map(|id| id.detach()) else {
                continue;
            };
            let candidate_name = shorten_ref_name(reference.name().as_bstr());
            if candidate_name.ends_with("/HEAD") {
                continue;
            }
            if repo
                .merge_base(tip, candidate)
                .is_ok_and(|base| base == tip)
            {
                base_branches.push(candidate_name);
            }
        }
        base_branches.sort();
        base_branches.dedup();

        // `git branch -d` also refuses a branch which is merged into the
        // current HEAD but not into its configured upstream. IntelliJ keeps
        // that distinction and the later View Commits action shows
        // `upstream..branch`, not an empty HEAD-relative range.
        let upstream_id = upstream.as_deref().and_then(|reference| {
            repo.rev_parse_single(BStr::new(reference.as_bytes()))
                .ok()
                .map(|id| id.detach())
        });
        let unmerged_base = upstream_id
            .filter(|candidate| {
                repo.merge_base(tip, *candidate)
                    .map(|base| base != tip)
                    .unwrap_or(true)
            })
            .or_else(|| {
                head_id.filter(|head| {
                    repo.merge_base(tip, *head)
                        .map(|base| base != tip)
                        .unwrap_or(true)
                })
            });

        let mut unmerged_commits = Vec::new();
        let walk = match unmerged_base {
            Some(base) => repo.rev_walk([tip]).with_hidden([base]).all(),
            None => {
                return Ok(BranchDeletePreview {
                    branch_name: name.to_string(),
                    tip_id,
                    upstream,
                    base_branches,
                    unmerged_commits,
                })
            }
        }
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot inspect unmerged branch commits: {error}"),
        })?;
        for item in walk {
            let info = item.map_err(|error| EngineError::GitOperation {
                message: format!("cannot inspect unmerged branch commits: {error}"),
            })?;
            let id = info.id;
            let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
            let id_text = id.to_hex().to_string();
            unmerged_commits.push(BranchDeleteCommit {
                short_id: id_text.chars().take(7).collect(),
                id: id_text,
                summary: commit
                    .message()
                    .map(|message| message.title.trim_end().to_str_lossy().into_owned())
                    .unwrap_or_default(),
                time: commit.time().map(|time| time.seconds).unwrap_or(0),
            });
        }

        Ok(BranchDeletePreview {
            branch_name: name.to_string(),
            tip_id,
            upstream,
            base_branches,
            unmerged_commits,
        })
    }

    /// 重命名分支（当前分支重命名时 HEAD 跟随，并迁移 branch 配置）。
    ///
    /// 使用 Git 原生命令以保留 `branch.<name>.*` 的 upstream、rebase、描述
    /// 等配置；仅改 refs 会让重命名后的分支失去 tracking 关系。
    pub fn branch_rename(&self, old: String, new: String) -> Result<(), EngineError> {
        let old = old.trim();
        let new = new.trim();
        if old.is_empty() || new.is_empty() || old.starts_with('-') || new.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "branch names must not be empty or start with '-'".into(),
            });
        }
        if old == new {
            return Err(EngineError::GitOperation {
                message: "new branch name must differ from the old name".into(),
            });
        }
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "branch rename requires a non-bare worktree".into(),
        })?;
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["branch", "-m", "--", old, new])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!("git branch -m failed: {}", command_output_message(&output)),
            });
        }
        repo.reload().map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 列出本地分支。
    pub fn branch_list(&self) -> Result<Vec<BranchInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        list_branches(&repo)
    }

    /// 列出已合并入当前 HEAD 的本地与 remote-tracking 分支。
    ///
    /// Merge Dialog 的“已合并”校验必须与 IntelliJ 的
    /// `git branch --all --no-merged` 反向结果一致，不能只检查本地分支。
    pub fn branch_list_merged_all(&self) -> Result<Vec<BranchInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        list_all_merged_branches(&repo)
    }

    /// List local and remote branches whose exclusive commits are authored by
    /// the repository's configured Git identity.
    pub fn my_branch_names(&self) -> Result<crate::branch::MyBranchNames, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::branch::list_my_branches(&repo)
    }

    /// Validate a new local branch name before the create dialog submits it.
    /// This mirrors Git's ref-name rules and rejects an existing local branch.
    pub fn validate_branch_name(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        validate_branch_name_inner(&repo, name.trim())
    }

    /// 列出 remote-tracking 分支。
    pub fn remote_branch_list(&self) -> Result<Vec<RemoteBranchInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::branch::list_remote_branches(&repo)
    }

    /// Return full object ids for refs that can affect VCS Log decoration.
    /// Display-facing branch models keep short ids; cache invalidation must
    /// use the complete tips so a short-hash collision cannot reuse history.
    pub fn ref_tip_snapshot(&self) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::branch::ref_tip_snapshot(&repo)
    }

    /// Prepare a new tip for IntelliJ's "Add Commits to Remote Branch" action.
    ///
    /// The caller must fetch the selected remote branch first. This method is
    /// deliberately object-only: it cherry-picks the selected linear commits
    /// onto `refs/remotes/<remote>/<branch>` without moving HEAD, touching the
    /// index, or changing the worktree. The returned object id can be passed to
    /// the normal Push dialog as a detached source revision. A `None` result
    /// means every selected change is already present on the remote tip.
    pub fn prepare_add_commits_to_remote_branch(
        &self,
        remote: String,
        branch: String,
        commit_ids: Vec<String>,
    ) -> Result<Option<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let remote = remote.trim().to_string();
        remote_name_ok(&remote)?;
        let branch = branch.trim();
        if branch.is_empty()
            || branch.starts_with('-')
            || branch.contains('\n')
            || branch.contains('\r')
        {
            return Err(EngineError::GitOperation {
                message: "invalid remote branch name".into(),
            });
        }
        let remote_ref = format!("refs/remotes/{remote}/{branch}");
        let _: gix::refs::FullName = remote_ref
            .as_str()
            .try_into()
            .map_err(EngineError::from_gix)?;
        let remote_tip = repo
            .rev_parse_single(BStr::new(remote_ref.as_bytes()))
            .map_err(|_| EngineError::GitOperation {
                message: format!(
                    "remote branch '{remote}/{branch}' is not available; fetch it before retrying"
                ),
            })?
            .detach();
        let mut current_tree = repo
            .find_commit(remote_tip)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        let mut current_tip = remote_tip;

        for commit_id in normalize_commit_sequence(commit_ids, "add commits to remote branch")? {
            let commit_id = repo
                .rev_parse_single(BStr::new(commit_id.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let commit = repo.find_commit(commit_id).map_err(EngineError::from_gix)?;
            if commit.parent_ids().nth(1).is_some() {
                return Err(EngineError::GitOperation {
                    message: format!("cannot add merge commit {commit_id} to a remote branch"),
                });
            }
            let message = full_commit_message(&repo, commit_id)?;
            let replayed_tree =
                cherry_pick_tree(&repo, &commit, current_tree).map_err(|error| {
                    EngineError::GitOperation {
                        message: format!(
                            "cannot add commit {commit_id} to '{remote}/{branch}': {error}"
                        ),
                    }
                })?;
            if replayed_tree == current_tree {
                continue;
            }
            current_tip = new_commit_preserving_author(
                &repo,
                commit_id,
                &message,
                replayed_tree,
                [current_tip],
            )?;
            current_tree = replayed_tree;
        }

        Ok((current_tip != remote_tip).then(|| current_tip.to_hex().to_string()))
    }

    /// 返回所有配置了 upstream 的本地分支同步状态。
    pub fn sync_status(&self) -> Result<Vec<SyncStatus>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::branch::sync_statuses(&repo)
    }

    /// 比较两个 revision 的 ahead/behind 提交数。
    pub fn branch_compare(&self, a: String, b: String) -> Result<BranchCompare, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        compare_branches(&repo, &a, &b)
    }

    /// Return source commits whose patches are already present in the target.
    ///
    /// This is Git's patch-equivalence comparison (`git cherry`), not a
    /// commit-message heuristic. It therefore detects cherry-picks with a
    /// different commit id, message, or committer timestamp without changing
    /// HEAD, the index, or the worktree.
    pub fn cherry_picked_commits(
        &self,
        source: String,
        target: String,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let source_id = repo
            .rev_parse_single(BStr::new(source.trim().as_bytes()))
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot resolve cherry-pick source '{source}': {error}"),
            })?
            .detach();
        let target_id = repo
            .rev_parse_single(BStr::new(target.trim().as_bytes()))
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot resolve cherry-pick target '{target}': {error}"),
            })?
            .detach();
        Ok(git_cherry_statuses(&repo, target_id, source_id)?
            .into_iter()
            .filter_map(|(status, id)| (status == '-').then_some(id))
            .collect())
    }

    /// Cancellable patch-equivalence comparison for the Log highlighter.
    ///
    /// The normal method remains a compatibility API for synchronous callers;
    /// this variant kills the complete Git process group when the SwiftUI
    /// comparison is cancelled, including a Git-spawned helper or wrapper.
    pub fn cherry_picked_commits_with_cancel(
        &self,
        source: String,
        target: String,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<Vec<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let source_id = repo
            .rev_parse_single(BStr::new(source.trim().as_bytes()))
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot resolve cherry-pick source '{source}': {error}"),
            })?
            .detach();
        let target_id = repo
            .rev_parse_single(BStr::new(target.trim().as_bytes()))
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot resolve cherry-pick target '{target}': {error}"),
            })?
            .detach();
        Ok(
            git_cherry_statuses_with_cancel(&repo, target_id, source_id, Some(cancel.token()))?
                .into_iter()
                .filter_map(|(status, id)| (status == '-').then_some(id))
                .collect(),
        )
    }

    /// 一次计算所有本地分支相对 HEAD 的 ahead/behind。
    pub fn branch_compare_all(&self) -> Result<Vec<BranchCompareEntry>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        compare_branches_all(&repo)
    }

    /// 切换到分支：工作区物化 + 索引重建 + HEAD symbolic 更新。
    pub fn switch_branch(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        switch_branch_inner(&repo, &name, false)
    }

    /// Smart Checkout：先按 IntelliJ 的 preserving-process 语义保存本地
    /// tracked/untracked 变更，再切换分支，最后把现场恢复到目标分支。
    ///
    /// 目标分支的变更与本地现场冲突时，stash 会保留在 refs/stash，返回
    /// `StashApplyConflict`，由 Swift 冲突工作台继续处理；切换失败时则
    /// 尽力恢复原分支现场，避免把一次失败的 checkout 变成数据丢失。
    pub fn smart_switch_branch(&self, name: String) -> Result<(), EngineError> {
        self.smart_switch_branch_with_policy(name, LocalChangesSavePolicy::Stash)
    }

    /// Smart branch checkout with IntelliJ's local-changes save policy.
    pub fn smart_switch_branch_with_policy(
        &self,
        name: String,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<(), EngineError> {
        self.smart_switch_branch_with_policy_and_cancel(
            name,
            save_policy,
            crate::gitprocess::GitCancelHandle::new(),
        )
    }

    /// Cancellable Smart branch checkout with IntelliJ's local-changes policy.
    pub fn smart_switch_branch_with_policy_and_cancel(
        &self,
        name: String,
        save_policy: LocalChangesSavePolicy,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let message = format!("Arbor: Smart Checkout to {name}");
        smart_checkout_with_policy(
            self,
            message,
            save_policy,
            Some(cancel.token()),
            move |repo| switch_branch_inner(repo, &name, false),
        )
    }

    /// Force Checkout：明确放弃会被目标分支覆盖的 tracked/untracked 工作区
    /// 内容。调用方必须先获得用户确认；普通 `switch_branch` 永远不会走这里。
    pub fn force_switch_branch(&self, name: String) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        switch_branch_inner(&repo, &name, true)
    }

    /// Smart Checkout：保存本地变更后，从 remote-tracking ref 创建并切换
    /// 本地跟踪分支，最后恢复现场。
    pub fn smart_checkout_remote_branch(
        &self,
        remote_branch: String,
        local_name: Option<String>,
    ) -> Result<(), EngineError> {
        self.smart_checkout_remote_branch_with_policy(
            remote_branch,
            local_name,
            LocalChangesSavePolicy::Stash,
        )
    }

    /// Smart remote-branch checkout with IntelliJ's local-changes policy.
    pub fn smart_checkout_remote_branch_with_policy(
        &self,
        remote_branch: String,
        local_name: Option<String>,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<(), EngineError> {
        self.smart_checkout_remote_branch_with_policy_and_cancel(
            remote_branch,
            local_name,
            save_policy,
            crate::gitprocess::GitCancelHandle::new(),
        )
    }

    /// Cancellable Smart remote-branch checkout with IntelliJ's policy.
    pub fn smart_checkout_remote_branch_with_policy_and_cancel(
        &self,
        remote_branch: String,
        local_name: Option<String>,
        save_policy: LocalChangesSavePolicy,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let label = format!("Arbor: Smart Checkout to {remote_branch}");
        smart_checkout_with_policy(
            self,
            label,
            save_policy,
            Some(cancel.token()),
            move |repo| {
                checkout_remote_branch_inner(repo, &remote_branch, local_name.as_deref(), false)
            },
        )
    }

    /// Force Checkout：明确允许远程分支 checkout 覆盖本地工作区。
    pub fn force_checkout_remote_branch(
        &self,
        remote_branch: String,
        local_name: Option<String>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        checkout_remote_branch_inner(&repo, &remote_branch, local_name.as_deref(), true)
    }

    /// 从 remote-tracking 分支创建并切换到本地跟踪分支。
    /// `remote_branch` 形如 `origin/feature/login`；local_name 为空时使用末段名称。
    pub fn checkout_remote_branch(
        &self,
        remote_branch: String,
        local_name: Option<String>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        checkout_remote_branch_inner(&repo, &remote_branch, local_name.as_deref(), false)
    }

    /// 更新一个未签出的本地分支到其 configured upstream。
    ///
    /// 这对应 Rebased 的 Branches -> Update：先 fetch，再只移动目标 refs/heads/<branch>，
    /// 当前工作区和 HEAD 都不会被切换。为避免静默丢弃本地提交，只接受 fast-forward；
    /// 分叉时交给 checkout 后的 Merge/Rebase 流程处理。
    pub fn update_branch(&self, branch: String) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        update_branch_locked(&mut repo, &branch, FetchTagsMode::Default, None, None)
    }

    /// Authenticated, cancellable counterpart used by IntelliJ's
    /// Branches -> Update Selected action. Non-current branches are fetched
    /// directly into their configured tracking refs and fast-forwarded without
    /// checking them out.
    pub fn update_branch_with_options_and_auth_and_cancel(
        &self,
        branch: String,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        update_branch_locked(
            &mut repo,
            &branch,
            tag_mode,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// Rebuild the current branch after a force-pushed upstream update.
    ///
    /// This follows IntelliJ's linear-history path: fetch the configured
    /// upstream, back up the current tip, hard-reset to the fetched tip, then
    /// replay local non-merge commits oldest-first. Local uncommitted changes
    /// use the same persisted Stash/Shelf marker as Smart Merge/Reset. If the
    /// local-only range contains a merge commit, use the normal merge update
    /// path instead because cherry-picking would lose its topology.
    pub fn force_pushed_branch_update_with_auth_and_cancel(
        &self,
        save_policy: LocalChangesSavePolicy,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<ForcePushedBranchUpdateOutcome, EngineError> {
        self.force_pushed_branch_update_with_auth_and_cancel_internal(
            save_policy,
            broker,
            cancel,
            false,
        )
    }

    /// Explicit destructive variant used by the Smart Operation dialog's
    /// Force action. It discards tracked local changes before rebuilding the
    /// branch; the normal entry point always preserves them.
    pub fn force_pushed_branch_update_with_auth_and_cancel_force(
        &self,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<ForcePushedBranchUpdateOutcome, EngineError> {
        self.force_pushed_branch_update_with_auth_and_cancel_internal(
            LocalChangesSavePolicy::Stash,
            broker,
            cancel,
            true,
        )
    }
}

impl Repository {
    /// Persist a root-scoped preserving-operation marker without exposing a
    /// second UI-only recovery protocol. Standalone submodule Update saves
    /// nested worktrees before Git changes them, so a process crash must leave
    /// the same marker consumed by the existing startup recovery scanner.
    pub(crate) fn persist_apply_local_changes_restore(
        &self,
        operation: &str,
        kind: &str,
        identifier: &str,
    ) -> Result<(), EngineError> {
        let operation = operation.trim();
        let identifier = identifier.trim();
        if operation.is_empty() || identifier.is_empty() {
            return Err(EngineError::GitOperation {
                message: "apply: saved local-changes marker requires an operation and artifact"
                    .into(),
            });
        }
        let saved = match kind.trim() {
            "stash" => RebaseLocalChanges::Stash(
                gix::hash::ObjectId::from_hex(identifier.as_bytes()).map_err(|_| {
                    EngineError::GitOperation {
                        message: "apply: invalid saved local-changes stash".into(),
                    }
                })?,
            ),
            "shelf" => RebaseLocalChanges::Shelf(identifier.to_string()),
            _ => {
                return Err(EngineError::GitOperation {
                    message: "apply: invalid saved local-changes artifact kind".into(),
                })
            }
        };
        let repo = self.inner.lock().expect("repo mutex poisoned");
        save_apply_local_changes(&repo, operation, &saved)
    }

    /// Clear only the preserving-operation marker. The caller owns the
    /// matching stash/Shelf lifecycle and must remove it only after a
    /// successful restore or explicit conflict finalization.
    pub(crate) fn clear_apply_local_changes_restore(&self) {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        clear_apply_local_changes(&repo);
    }

    /// Execute a structured preserve-merges todo whose visible row identities
    /// were edited outside the repository. Multi-root rebase cannot safely use
    /// the legacy action-only API: once a row moves, an action list without
    /// commit IDs can be paired with the wrong native commit. This path builds
    /// the same merge-preserving plan as the single-root editor, validates the
    /// edited topology, and only then invokes Git's native sequence editor.
    pub(crate) fn rebase_branch_with_ordered_merge_todo_and_policy(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        ordered_commit_ids: Vec<String>,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_ordered_merge_todo_and_policy_inner(
            onto,
            branch,
            actions,
            ordered_commit_ids,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable counterpart of
    /// `rebase_branch_with_ordered_merge_todo_and_policy`.
    pub(crate) fn rebase_branch_with_ordered_merge_todo_and_policy_and_cancel(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        ordered_commit_ids: Vec<String>,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_ordered_merge_todo_and_policy_inner(
            onto,
            branch,
            actions,
            ordered_commit_ids,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_branch_with_ordered_merge_todo_and_policy_inner(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        ordered_commit_ids: Vec<String>,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        if ordered_commit_ids.is_empty() {
            return Err(EngineError::GitOperation {
                message:
                    "rebase todo: ordered commit IDs are required for preserve-merges execution"
                        .into(),
            });
        }
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let onto_id = resolve_rebase_onto(&repo, &onto, root)?;
            let original_head = repo
                .rev_parse_single(BStr::new(branch.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let original_tree = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let native_order = rebase_merge_order(&repo, onto_id, original_head, root)?;
            let ordered_ids = ordered_commit_ids
                .iter()
                .map(|id| {
                    gix::hash::ObjectId::from_hex(id.as_bytes()).map_err(|_| {
                        EngineError::GitOperation {
                            message: format!("rebase todo: invalid order commit {id}"),
                        }
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
            if ordered_ids.len() != actions.len() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "rebase todo: {} commit IDs for {} actions",
                        ordered_ids.len(),
                        actions.len()
                    ),
                });
            }

            let mut todo = match onto_id {
                Some(onto_id) => {
                    crate::rebasetodo::build_todo_from_ids(&repo, onto_id, ordered_ids, false)?
                }
                None => {
                    crate::rebasetodo::build_todo_from_ids_without_onto(&repo, ordered_ids, false)?
                }
            };
            for (item, action) in todo.items.iter_mut().zip(actions) {
                item.action = match &action {
                    RebaseAction::Pick => crate::rebasetodo::RebaseTodoAction::Pick,
                    RebaseAction::Drop => crate::rebasetodo::RebaseTodoAction::Drop,
                    RebaseAction::Reword { .. } => crate::rebasetodo::RebaseTodoAction::Reword,
                    RebaseAction::Squash | RebaseAction::SquashWithMessage { .. } => {
                        crate::rebasetodo::RebaseTodoAction::Squash
                    }
                    RebaseAction::Fixup => crate::rebasetodo::RebaseTodoAction::Fixup,
                    RebaseAction::Edit => crate::rebasetodo::RebaseTodoAction::Edit,
                };
                item.message = match action {
                    RebaseAction::Reword { message }
                    | RebaseAction::SquashWithMessage { message } => Some(message),
                    _ => None,
                };
            }
            let plan = merge_preserving_action_plan(&repo, &native_order, &todo)?;
            rebase_with_system_options(
                &repo,
                onto_id,
                original_head,
                original_tree,
                plan.non_merge_actions,
                true,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                Some(&branch),
                Some(&plan.non_merge_order),
                Some(plan.merge_actions),
                true,
                cancel_token,
            )
        })
    }

    fn force_pushed_branch_update_with_auth_and_cancel_internal(
        &self,
        save_policy: LocalChangesSavePolicy,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
        discard_local_changes: bool,
    ) -> Result<ForcePushedBranchUpdateOutcome, EngineError> {
        let (branch, remote, upstream_branch, old_upstream_tip) = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            let branch = repo
                .head_name()
                .map_err(EngineError::from_gix)?
                .map(|name| shorten_ref_name(name.as_bstr()))
                .ok_or_else(|| EngineError::GitOperation {
                    message: "force-pushed update requires a checked-out branch".into(),
                })?;
            let upstream = configured_upstream(&repo, &branch)?;
            if upstream.remote == "." {
                return Err(EngineError::GitOperation {
                    message: "force-pushed update requires a remote upstream".into(),
                });
            }
            let tracking = format!("{}/{}", upstream.remote, upstream.branch);
            let old_upstream_tip = repo
                .rev_parse_single(BStr::new(tracking.as_bytes()))
                .ok()
                .map(|id| id.detach());
            (branch, upstream.remote, upstream.branch, old_upstream_tip)
        };

        self.fetch_with_auth_and_cancel(
            Some(remote.clone()),
            Arc::clone(&broker),
            Arc::clone(&cancel),
        )?;

        let upstream = format!("{remote}/{upstream_branch}");
        let (
            local_id,
            remote_id,
            local_commits,
            contains_merge_commit,
            update_summary,
            update_range_start,
        ) = {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            let local_id = repo.head_id().map_err(EngineError::from_gix)?.detach();
            let remote_id = repo
                .rev_parse_single(BStr::new(upstream.as_bytes()))
                .map_err(|_| EngineError::TrackingMissing {
                    branch: branch.clone(),
                    upstream: upstream.clone(),
                })?
                .detach();
            if local_id == remote_id {
                return Ok(ForcePushedBranchUpdateOutcome {
                    branch,
                    upstream,
                    replayed_commits: 0,
                    used_merge_update: false,
                    received_commits_count: 0,
                    updated_files_count: 0,
                    update_range_start: old_upstream_tip.map(|id| id.to_hex().to_string()),
                    new_upstream_tip: remote_id.to_hex().to_string(),
                });
            }

            let update_range_start = old_upstream_tip
                .and_then(|old| repo.merge_base(local_id, old).ok().map(|id| id.detach()))
                .or(old_upstream_tip);
            let update_summary = force_pushed_update_summary(&repo, update_range_start, remote_id);

            let mut commits = Vec::new();
            let mut contains_merge_commit = false;
            let walk = repo
                .rev_walk([local_id])
                .with_hidden([remote_id])
                .all()
                .map_err(|error| EngineError::GitOperation {
                    message: format!("cannot inspect force-pushed local commits: {error}"),
                })?;
            for item in walk {
                let info = item.map_err(|error| EngineError::GitOperation {
                    message: format!("cannot inspect force-pushed local commits: {error}"),
                })?;
                let commit = repo.find_commit(info.id).map_err(EngineError::from_gix)?;
                contains_merge_commit |= commit.parent_ids().nth(1).is_some();
                commits.push(info.id.to_hex().to_string());
            }
            commits.reverse();
            (
                local_id,
                remote_id,
                commits,
                contains_merge_commit,
                update_summary,
                update_range_start,
            )
        };

        if contains_merge_commit {
            let saved = if discard_local_changes {
                self.reset_hard(local_id.to_hex().to_string())?;
                false
            } else {
                prepare_apply_local_changes(self, "merge", save_policy)?
            };
            let result = self.pull_with_auth_and_cancel(Some(remote), false, broker, cancel);
            let _ = finish_apply_local_changes(self, "merge", saved, result)?;
            return Ok(ForcePushedBranchUpdateOutcome {
                branch,
                upstream,
                replayed_commits: 0,
                used_merge_update: true,
                received_commits_count: update_summary.0,
                updated_files_count: update_summary.1,
                update_range_start: update_range_start.map(|id| id.to_hex().to_string()),
                new_upstream_tip: remote_id.to_hex().to_string(),
            });
        }

        let operation_kind = if local_commits.is_empty() {
            "reset"
        } else {
            "cherry-pick"
        };
        let saved = if discard_local_changes {
            false
        } else {
            prepare_apply_local_changes(self, operation_kind, save_policy)?
        };
        let backup_branch = if local_commits.is_empty() {
            None
        } else {
            let suffix = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let name = format!("arbor-force-pushed-backup-{suffix}");
            if let Err(error) =
                self.branch_create(name.clone(), Some(local_id.to_hex().to_string()))
            {
                return finish_apply_local_changes(self, operation_kind, saved, Err(error));
            }
            Some(name)
        };
        let replayed_commits = local_commits.len() as u32;
        let operation = self
            .reset_hard(remote_id.to_hex().to_string())
            .and_then(|_| {
                if local_commits.is_empty() {
                    Ok(())
                } else {
                    self.cherry_pick_many_with_options(
                        local_commits,
                        CherryPickEmptyPolicy::Skip,
                        false,
                    )
                    .map(|_| ())
                }
            });
        let result = finish_apply_local_changes(self, operation_kind, saved, operation);
        match result {
            Ok(()) => {
                if let Some(name) = backup_branch {
                    if let Err(error) = self.branch_delete(name.clone(), true) {
                        return Err(EngineError::GitOperation {
                            message: format!(
                                "force-pushed update completed, but backup branch '{name}' could not be deleted: {error}"
                            ),
                        });
                    }
                }
                Ok(ForcePushedBranchUpdateOutcome {
                    branch,
                    upstream,
                    replayed_commits,
                    used_merge_update: false,
                    received_commits_count: update_summary.0,
                    updated_files_count: update_summary.1,
                    update_range_start: update_range_start.map(|id| id.to_hex().to_string()),
                    new_upstream_tip: remote_id.to_hex().to_string(),
                })
            }
            Err(error) => {
                if let Some(backup_name) = backup_branch {
                    Err(EngineError::GitOperation {
                        message: format!(
                            "force-pushed update incomplete; backup branch '{backup_name}' was kept: {error}"
                        ),
                    })
                } else {
                    Err(error)
                }
            }
        }
    }
}

#[uniffi::export]
impl Repository {
    /// Pull 一个未签出的本地分支到它自己的 configured upstream。
    ///
    /// 目标分支在临时 detached worktree 中执行标准 Git merge/rebase，成功后
    /// 只移动 refs/heads/<branch>；当前 HEAD、当前工作区和当前索引完全不动。
    /// 非当前分支发生冲突时不把冲突现场写入当前工作区，而是保持目标分支不变，
    /// 返回提示让用户先 checkout 该分支后再解决冲突。
    pub fn pull_branch(&self, branch: String, rebase: bool) -> Result<MergeOutcome, EngineError> {
        use gix::refs::transaction::PreviousValue;
        use gix::refs::Target;

        let branch = branch.trim().to_string();
        if branch.is_empty() || branch.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "branch name must not be empty or start with '-'".into(),
            });
        }
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        if load_merge_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: merge is already in progress".into(),
            });
        }
        if load_rebase_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: rebase is already in progress".into(),
            });
        }
        let current = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        if current.as_deref() == Some(branch.as_str()) {
            return Err(EngineError::GitOperation {
                message: format!(
                    "branch '{branch}' is checked out; use pull for the current branch"
                ),
            });
        }

        let upstream = configured_upstream(&repo, &branch)?;
        if upstream.remote == "." {
            return Err(EngineError::GitOperation {
                message: "pull: local repository upstream is not supported".into(),
            });
        }
        let (_, remote_name) = run_fetch_with_system_git_locked(
            &mut repo,
            &Some(upstream.remote.clone()),
            &[],
            None,
            None,
        )?;
        let tracking_label = format!("{remote_name}/{}", upstream.branch);
        let tracking_ref = format!("refs/remotes/{tracking_label}");
        let tracking_id = repo
            .rev_parse_single(BStr::new(tracking_ref.as_bytes()))
            .map_err(|_| EngineError::TrackingMissing {
                branch: branch.clone(),
                upstream: tracking_label.clone(),
            })?
            .detach();
        let local_ref = format!("refs/heads/{branch}");
        let local_id = repo
            .find_reference(local_ref.as_str())
            .map_err(EngineError::from_gix)?
            .try_id()
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("branch '{branch}' has no object id"),
            })?
            .detach();
        if local_id == tracking_id {
            return Ok(MergeOutcome {
                conflicts: Vec::new(),
                updated_commits: 0,
                upstream: String::new(),
                branch: String::new(),
                completed: true,
                requires_finish: false,
                squashed: false,
            });
        }

        let upstream_reachable = reachable_from(&repo, tracking_id)?;
        let local_reachable = reachable_from(&repo, local_id)?;
        let updated_commits = upstream_reachable.difference(&local_reachable).count() as u32;
        let workdir = repo
            .workdir()
            .ok_or_else(|| EngineError::GitOperation {
                message: "pull branch requires a worktree".into(),
            })?
            .to_path_buf();
        let temp_worktree = std::env::temp_dir().join(format!(
            "arbor-pull-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            local_id.to_hex()
        ));
        if temp_worktree.exists() {
            return Err(EngineError::GitOperation {
                message: "pull branch temporary worktree already exists".into(),
            });
        }

        let add = crate::gitprocess::git_command_for_working_dir(&workdir)
            .args([
                "worktree",
                "add",
                "--detach",
                "--quiet",
                temp_worktree.to_string_lossy().as_ref(),
                local_ref.as_str(),
            ])
            .current_dir(&workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !add.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull branch temporary worktree failed: {}",
                    command_output_message(&add)
                ),
            });
        }

        let operation = if rebase {
            crate::gitprocess::git_command_for_working_dir(&temp_worktree)
                .args(["rebase", tracking_ref.as_str()])
                .current_dir(&temp_worktree)
                .output()
        } else {
            crate::gitprocess::git_command_for_working_dir(&temp_worktree)
                .args(["merge", "--no-edit", tracking_ref.as_str()])
                .current_dir(&temp_worktree)
                .output()
        }
        .map_err(EngineError::from_gix)?;
        if !operation.status.success() {
            let abort_command = if rebase { "rebase" } else { "merge" };
            let _ = crate::gitprocess::git_command_for_working_dir(&temp_worktree)
                .args([abort_command, "--abort"])
                .current_dir(&temp_worktree)
                .output();
            let _ = crate::gitprocess::git_command_for_working_dir(&workdir)
                .args(["worktree", "remove", "--force"])
                .arg(&temp_worktree)
                .current_dir(&workdir)
                .output();
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull branch '{}' {} failed: {} (checkout the branch to resolve conflicts)",
                    branch,
                    if rebase { "rebase" } else { "merge" },
                    command_output_message(&operation)
                ),
            });
        }

        let new_head_output = crate::gitprocess::git_command_for_working_dir(&temp_worktree)
            .args(["rev-parse", "HEAD"])
            .current_dir(&temp_worktree)
            .output()
            .map_err(EngineError::from_gix)?;
        let new_head_text = String::from_utf8_lossy(&new_head_output.stdout)
            .trim()
            .to_string();
        let new_head = gix::hash::ObjectId::from_hex(new_head_text.as_bytes()).map_err(|_| {
            EngineError::GitOperation {
                message: "pull branch returned an invalid target HEAD".into(),
            }
        })?;
        let remove = crate::gitprocess::git_command_for_working_dir(&workdir)
            .args(["worktree", "remove", "--force"])
            .arg(&temp_worktree)
            .current_dir(&workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !remove.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull branch temporary worktree cleanup failed: {}",
                    command_output_message(&remove)
                ),
            });
        }

        let local_name: gix::refs::FullName = local_ref
            .as_str()
            .try_into()
            .map_err(EngineError::from_gix)?;
        repo.reference(
            local_name,
            new_head,
            PreviousValue::MustExistAndMatch(Target::Object(local_id)),
            "branch: pull",
        )
        .map_err(EngineError::from_gix)?;
        Ok(MergeOutcome {
            conflicts: Vec::new(),
            updated_commits,
            upstream: tracking_label,
            branch,
            completed: true,
            requires_finish: false,
            squashed: false,
        })
    }

    /// 删除远程分支（例如 `origin/feature/login`）。
    pub fn delete_remote_branch(&self, remote_branch: String) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_branch_locked(&mut repo, &remote_branch, None, None)
    }

    /// Delete a remote branch through the credential broker for explicit UI
    /// actions. The local tracking ref is pruned only after the remote
    /// deletion succeeds (or is proven to have already happened).
    pub fn delete_remote_branch_with_auth(
        &self,
        remote_branch: String,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_branch_locked(&mut repo, &remote_branch, Some(&broker), None)
    }

    /// Delete a remote branch with credential prompting and process-group
    /// cancellation. Cancellation covers both the remote push deletion and
    /// the stale tracking-ref prune path.
    pub fn delete_remote_branch_with_auth_and_cancel(
        &self,
        remote_branch: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        delete_remote_branch_locked(
            &mut repo,
            &remote_branch,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    // MARK: 远程操作

    /// 列出远程（名字 + fetch url）。
    pub fn remote_list(&self) -> Result<Vec<RemoteInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        list_remotes(&repo)
    }

    /// 添加远程（写入 .git/config，带默认 fetch refspec）。
    pub fn remote_add(&self, name: String, url: String) -> Result<(), EngineError> {
        remote_name_ok(&name)?;
        let url = url.trim();
        if url.is_empty() || url.contains('\n') || url.contains('\r') {
            return Err(EngineError::GitOperation {
                message: "remote URL must be non-empty and single-line".into(),
            });
        }
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "remote config requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "remote",
        )
        .args(["add", &name, url])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        repo.reload().map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 移除远程（等价 `git remote remove`，同时清理 remote-tracking refs）。
    pub fn remote_remove(&self, name: String) -> Result<(), EngineError> {
        remote_name_ok(&name)?;
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "remote config requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "remote",
        )
        .args(["remove", &name])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        repo.reload().map_err(EngineError::from_gix)?;
        Ok(())
    }

    // MARK: REMOTE-001 远程配置与高级传输

    /// 修改远程 URL（等价 `git remote set-url <name> <url>`）。
    pub fn remote_set_url(&self, name: String, url: String) -> Result<(), EngineError> {
        remote_name_ok(&name)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "remote config requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "config",
        )
        .args(["remote.".to_string() + &name + ".url", url])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 设置 push URL（`git remote set-url --push <name> <url>`；空串清除）。
    pub fn remote_set_push_url(&self, name: String, push_url: String) -> Result<(), EngineError> {
        remote_name_ok(&name)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "remote config requires a non-bare worktree".into(),
        })?;
        if push_url.trim().is_empty() {
            let spec = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Config,
                "config",
            )
            .args(["--unset-all", &format!("remote.{name}.pushurl")])
            .working_dir(&workdir);
            let outcome = crate::gitprocess::run_to_completion(&spec)?;
            if !outcome.success() && outcome.exit_code != 5 {
                return Err(outcome.into_error(&spec));
            }
            return Ok(());
        }
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "config",
        )
        .args([&format!("remote.{name}.pushurl"), push_url.trim()])
        .working_dir(&workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// 编辑 fetch/push refspec（`git config remote.<name>.fetch/push`；
    /// None = 清除该 refspec）。
    pub fn remote_set_refspecs(
        &self,
        name: String,
        fetch_refspec: Option<String>,
        push_refspec: Option<String>,
    ) -> Result<(), EngineError> {
        remote_name_ok(&name)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "remote config requires a non-bare worktree".into(),
        })?;
        for (key, value) in [("fetch", fetch_refspec), ("push", push_refspec)] {
            let key_name = format!("remote.{name}.{key}");
            match value {
                Some(spec) if !spec.trim().is_empty() => {
                    let spec = crate::gitprocess::GitCommandSpec::new(
                        crate::gitprocess::GitCommandCategory::Config,
                        "config",
                    )
                    .args([&key_name, spec.trim()])
                    .working_dir(&workdir);
                    let outcome = crate::gitprocess::run_to_completion(&spec)?;
                    if !outcome.success() {
                        return Err(outcome.into_error(&spec));
                    }
                }
                _ => {
                    let spec = crate::gitprocess::GitCommandSpec::new(
                        crate::gitprocess::GitCommandCategory::Config,
                        "config",
                    )
                    .args(["--unset-all", &key_name])
                    .working_dir(&workdir);
                    let outcome = crate::gitprocess::run_to_completion(&spec)?;
                    if !outcome.success() && outcome.exit_code != 5 {
                        return Err(outcome.into_error(&spec));
                    }
                }
            }
        }
        Ok(())
    }

    /// 重命名远程（等价 `git remote rename`：config 与 refs/remotes 一并处理）。
    pub fn remote_rename(&self, old: String, new: String) -> Result<(), EngineError> {
        remote_name_ok(&old)?;
        remote_name_ok(&new)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "remote rename requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "remote",
        )
        .args(["rename", &old, &new])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        Ok(())
    }

    /// fetch 所有远程，返回每个远程的更新（逐 remote 结果，UI 可展示部分成功）。
    pub fn fetch_all(&self) -> Result<Vec<FetchOutcome>, EngineError> {
        self.fetch_all_with_options(FetchTagsMode::Default)
    }

    /// Fetch all configured remotes with an explicit tag policy.
    pub fn fetch_all_with_options(
        &self,
        tag_mode: FetchTagsMode,
    ) -> Result<Vec<FetchOutcome>, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        let remotes = list_remotes(&repo)?;
        let mut outcomes = Vec::new();
        for remote in remotes {
            let (outcome, _) = run_fetch_with_tag_mode_locked(
                &mut repo,
                &Some(remote.name),
                &[],
                tag_mode,
                None,
                None,
            )?;
            outcomes.push(outcome);
        }
        Ok(outcomes)
    }

    /// 带认证代理 fetch：沿用系统 Git 的凭证、SSH askpass 和错误分类，
    /// 完成后 reload gix 句柄以丢弃旧的 refs/config 缓存。
    pub fn fetch_with_auth(
        &self,
        remote: Option<String>,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<FetchOutcome, EngineError> {
        self.fetch_with_options_and_auth(remote, FetchTagsMode::Default, broker)
    }

    /// Fetch with an explicit project tag policy without an auth broker.
    pub fn fetch_with_options(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_tag_mode_locked(&mut repo, &remote, &[], tag_mode, None, None)
            .map(|(outcome, _)| outcome)
    }

    /// Cancellable fetch using no interactive authentication.  This is the
    /// first pass of IntelliJ's background incoming check: credential helpers
    /// and terminal prompts are disabled so the check cannot interrupt the
    /// user with an authentication dialog.
    pub fn fetch_with_options_without_auth_and_cancel(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_refspecs_and_tag_mode_locked_with_auth_mode(
            &mut repo,
            &remote,
            &[],
            &[],
            tag_mode,
            None,
            Some(cancel.token()),
            RemoteAuthMode::NoAuthentication,
        )
        .map(|(outcome, _)| outcome)
    }

    /// Fetch with an explicit project tag policy and credential broker.
    pub fn fetch_with_options_and_auth(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        fetch_with_tag_mode_locked(&mut repo, &remote, tag_mode, &broker, None)
    }

    /// 可取消的认证 fetch。
    pub fn fetch_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<FetchOutcome, EngineError> {
        self.fetch_with_options_and_auth_and_cancel(remote, FetchTagsMode::Default, broker, cancel)
    }

    /// Cancellable authenticated fetch with an explicit project tag policy.
    pub fn fetch_with_options_and_auth_and_cancel(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        fetch_with_tag_mode_locked(&mut repo, &remote, tag_mode, &broker, Some(cancel.token()))
    }

    /// Cancellable fetch with stored credentials only.  Unlike explicit
    /// Fetch, a background incoming check never opens the SwiftUI credential
    /// dialog.
    pub fn fetch_with_options_and_silent_auth_and_cancel(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_refspecs_and_tag_mode_locked_with_auth_mode(
            &mut repo,
            &remote,
            &[],
            &[],
            tag_mode,
            Some(&broker),
            Some(cancel.token()),
            RemoteAuthMode::Silent,
        )
        .map(|(outcome, _)| outcome)
    }

    /// 只获取一个 remote branch，不刷新同一 remote 的其他分支。
    /// `branch` 可传 `main`、`origin/main` 或 `refs/heads/main`，结果只更新对应
    /// `refs/remotes/<remote>/<branch>`。
    pub fn fetch_remote_branch(
        &self,
        remote: String,
        branch: String,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        fetch_remote_branch_locked(&mut repo, &remote, &branch, None, None)
    }

    /// 带认证代理的单分支 fetch。
    pub fn fetch_remote_branch_with_auth(
        &self,
        remote: String,
        branch: String,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<FetchOutcome, EngineError> {
        self.fetch_remote_branch_with_options_and_auth(
            remote,
            branch,
            FetchTagsMode::Default,
            broker,
        )
    }

    /// Authenticated branch fetch with an explicit project tag policy.
    pub fn fetch_remote_branch_with_options_and_auth(
        &self,
        remote: String,
        branch: String,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        fetch_remote_branch_locked_with_tag_mode(
            &mut repo,
            &remote,
            &branch,
            tag_mode,
            Some(&broker),
            None,
        )
    }

    /// 可取消、带认证代理的单分支 fetch。
    pub fn fetch_remote_branch_with_auth_and_cancel(
        &self,
        remote: String,
        branch: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<FetchOutcome, EngineError> {
        self.fetch_remote_branch_with_options_and_auth_and_cancel(
            remote,
            branch,
            FetchTagsMode::Default,
            broker,
            cancel,
        )
    }

    /// Cancellable authenticated branch fetch with an explicit project tag policy.
    pub fn fetch_remote_branch_with_options_and_auth_and_cancel(
        &self,
        remote: String,
        branch: String,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        fetch_remote_branch_locked_with_tag_mode(
            &mut repo,
            &remote,
            &branch,
            tag_mode,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// fetch 并 prune 已删除的远程分支（`git fetch --prune`）。
    pub fn fetch_prune(&self, remote: Option<String>) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_system_git_locked(&mut repo, &remote, &["--prune"], None, None).map(|_| ())
    }

    /// 带认证代理 fetch --prune。
    pub fn fetch_prune_with_auth(
        &self,
        remote: Option<String>,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        self.fetch_prune_with_options_and_auth(remote, FetchTagsMode::Default, broker)
    }

    /// Authenticated `fetch --prune` with an explicit project tag policy.
    pub fn fetch_prune_with_options_and_auth(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_tag_mode_locked(
            &mut repo,
            &remote,
            &["--prune"],
            tag_mode,
            Some(&broker),
            None,
        )
        .map(|_| ())
    }

    /// 可取消的认证 fetch --prune。
    pub fn fetch_prune_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.fetch_prune_with_options_and_auth_and_cancel(
            remote,
            FetchTagsMode::Default,
            broker,
            cancel,
        )
    }

    /// Cancellable authenticated `fetch --prune` with an explicit tag policy.
    pub fn fetch_prune_with_options_and_auth_and_cancel(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_tag_mode_locked(
            &mut repo,
            &remote,
            &["--prune"],
            tag_mode,
            Some(&broker),
            Some(cancel.token()),
        )
        .map(|_| ())
    }

    /// 完整获取浅克隆历史（`git fetch --unshallow`）。
    pub fn fetch_unshallow(&self, remote: Option<String>) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_system_git_locked(&mut repo, &remote, &["--unshallow"], None, None)
            .map(|_| ())
    }

    /// 带认证代理 fetch --unshallow。
    pub fn fetch_unshallow_with_auth(
        &self,
        remote: Option<String>,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        self.fetch_unshallow_with_options_and_auth(remote, FetchTagsMode::Default, broker)
    }

    /// Authenticated `fetch --unshallow` with an explicit project tag policy.
    pub fn fetch_unshallow_with_options_and_auth(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_tag_mode_locked(
            &mut repo,
            &remote,
            &["--unshallow"],
            tag_mode,
            Some(&broker),
            None,
        )
        .map(|_| ())
    }

    /// 可取消的认证 fetch --unshallow。
    pub fn fetch_unshallow_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.fetch_unshallow_with_options_and_auth_and_cancel(
            remote,
            FetchTagsMode::Default,
            broker,
            cancel,
        )
    }

    /// Cancellable authenticated `fetch --unshallow` with an explicit tag policy.
    pub fn fetch_unshallow_with_options_and_auth_and_cancel(
        &self,
        remote: Option<String>,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_tag_mode_locked(
            &mut repo,
            &remote,
            &["--unshallow"],
            tag_mode,
            Some(&broker),
            Some(cancel.token()),
        )
        .map(|_| ())
    }

    /// force-with-lease 推送（拒绝覆盖远程新提交；失败分类复用 PushRejected）。
    pub fn push_force_with_lease(
        &self,
        remote: Option<String>,
        branch: String,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "push requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Push,
            "push",
        )
        .args(["--force-with-lease", &name, &branch])
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(push_rejected_error(outcome, &spec, &name, &branch));
        }
        Ok(())
    }

    /// 带认证代理的 force-with-lease 推送。
    pub fn push_force_with_lease_with_auth(
        &self,
        remote: Option<String>,
        branch: String,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "push requires a non-bare worktree".into(),
        })?;
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Push,
            "push",
        )
        .args(["--force-with-lease", &name, &branch])
        .working_dir(workdir);
        let outcome = crate::auth::run_with_askpass(&spec, &broker, None)?;
        if !outcome.success() {
            return Err(push_rejected_error(outcome, &spec, &name, &branch));
        }
        Ok(())
    }

    /// 可取消的认证 force-with-lease push。
    pub fn push_force_with_lease_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        branch: String,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        push_inner(
            &repo,
            &name,
            &branch,
            true,
            true,
            false,
            None,
            false,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// fetch 远程（默认或指定）：更新 remote-tracking refs，返回更新的引用短名。
    pub fn fetch(&self, remote: Option<String>) -> Result<FetchOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        run_fetch_with_system_git_locked(&mut repo, &remote, &[], None, None)
            .map(|(outcome, _)| outcome)
    }

    /// push 到远程（gix 0.86 无 send-pack，调用系统 git，D12 允许）。`force` 走 `--force`。
    pub fn push(
        &self,
        remote: Option<String>,
        branch: String,
        force: bool,
    ) -> Result<(), EngineError> {
        self.push_with_options(remote, branch, force, false)
    }

    /// push 的完整入口；`set_upstream` 对应 Rebased 的 Publish Branch。
    pub fn push_with_options(
        &self,
        remote: Option<String>,
        branch: String,
        force: bool,
        set_upstream: bool,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        push_inner(
            &repo,
            &name,
            &branch,
            force,
            false,
            set_upstream,
            None,
            false,
            None,
            None,
        )
    }

    /// 带认证代理的 push（AUTH-001）：HTTPS token / SSH passphrase 首次提示
    /// 走 Swift 的 handler；用户取消返回 `Cancelled` 分类。
    pub fn push_with_auth(
        &self,
        remote: Option<String>,
        branch: String,
        force: bool,
        set_upstream: bool,
        broker: std::sync::Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        push_inner(
            &repo,
            &name,
            &branch,
            force,
            false,
            set_upstream,
            None,
            false,
            Some(&broker),
            None,
        )
    }

    /// 可取消的认证 push；取消会终止 git/ssh 子进程组。
    pub fn push_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        branch: String,
        force: bool,
        set_upstream: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        push_inner(
            &repo,
            &name,
            &branch,
            force,
            false,
            set_upstream,
            None,
            false,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// Authenticated, cancellable branch push with IntelliJ-compatible tag and
    /// pre-push-hook options. `tag_mode` is omitted for a normal branch-only
    /// push; `skip_hooks` maps to Git's `--no-verify`.
    pub fn push_with_options_and_auth_and_cancel(
        &self,
        remote: Option<String>,
        branch: String,
        force: bool,
        force_with_lease: bool,
        set_upstream: bool,
        tag_mode: Option<crate::remote::PushTagMode>,
        skip_hooks: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let name = match &remote {
            Some(n) => n.clone(),
            None => crate::remote::default_remote_name(&repo)?,
        };
        push_inner(
            &repo,
            &name,
            &branch,
            force,
            force_with_lease,
            set_upstream,
            tag_mode,
            skip_hooks,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// 推送任意 refspec（例如 `HEAD:refs/heads/release`）。
    pub fn push_refspec(
        &self,
        remote: String,
        refspec: String,
        force: bool,
    ) -> Result<(), EngineError> {
        let remote = remote.trim().to_string();
        let refspec = refspec.trim().to_string();
        if remote.is_empty()
            || refspec.is_empty()
            || remote.starts_with('-')
            || refspec.starts_with('-')
        {
            return Err(EngineError::GitOperation {
                message: "remote and refspec must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        push_refspec_inner(
            &repo, &remote, &refspec, force, false, None, false, None, None,
        )
    }

    /// 带认证代理推送任意 refspec；force 时可选择 force-with-lease。
    pub fn push_refspec_with_auth(
        &self,
        remote: String,
        refspec: String,
        force: bool,
        force_with_lease: bool,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<(), EngineError> {
        let remote = remote.trim().to_string();
        let refspec = refspec.trim().to_string();
        if remote.is_empty()
            || refspec.is_empty()
            || remote.starts_with('-')
            || refspec.starts_with('-')
        {
            return Err(EngineError::GitOperation {
                message: "remote and refspec must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        push_refspec_inner(
            &repo,
            &remote,
            &refspec,
            force,
            force_with_lease,
            None,
            false,
            Some(&broker),
            None,
        )
    }

    /// 可取消的认证 refspec push。
    pub fn push_refspec_with_auth_and_cancel(
        &self,
        remote: String,
        refspec: String,
        force: bool,
        force_with_lease: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let remote = remote.trim().to_string();
        let refspec = refspec.trim().to_string();
        if remote.is_empty()
            || refspec.is_empty()
            || remote.starts_with('-')
            || refspec.starts_with('-')
        {
            return Err(EngineError::GitOperation {
                message: "remote and refspec must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        push_refspec_inner(
            &repo,
            &remote,
            &refspec,
            force,
            force_with_lease,
            None,
            false,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// Authenticated, cancellable refspec push with IntelliJ-compatible tag
    /// and pre-push-hook options.
    pub fn push_refspec_with_options_and_auth_and_cancel(
        &self,
        remote: String,
        refspec: String,
        force: bool,
        force_with_lease: bool,
        tag_mode: Option<crate::remote::PushTagMode>,
        skip_hooks: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        let remote = remote.trim().to_string();
        let refspec = refspec.trim().to_string();
        if remote.is_empty()
            || refspec.is_empty()
            || remote.starts_with('-')
            || refspec.starts_with('-')
        {
            return Err(EngineError::GitOperation {
                message: "remote and refspec must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        push_refspec_inner(
            &repo,
            &remote,
            &refspec,
            force,
            force_with_lease,
            tag_mode,
            skip_hooks,
            Some(&broker),
            Some(cancel.token()),
        )
    }

    /// pull：fetch + 使用 branch.<name>.remote/merge 解析出的 upstream。
    ///
    /// `rebase=false` 走 fast-forward/三方 merge，干净时自动创建双父提交；
    /// `rebase=true` 走与交互式 rebase 相同的暂停/继续/中止状态机。
    /// 已跟踪 dirty tree 由 UI 编排 stash -> pull -> stash pop；未跟踪文件
    /// 保留在工作区，只有远程树实际覆盖其路径时才由 merge/rebase guard 拒绝。
    pub fn pull(&self, remote: Option<String>, rebase: bool) -> Result<MergeOutcome, EngineError> {
        self.pull_with_broker(
            remote,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            None,
            None,
            None,
            FetchTagsMode::Default,
        )
    }

    /// 带认证代理 pull：fetch 使用系统 Git askpass，后续 merge/rebase 仍由
    /// Arbor 引擎负责，从而保持现有冲突工作区和恢复状态机。
    pub fn pull_with_auth(
        &self,
        remote: Option<String>,
        rebase: bool,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_with_broker(
            remote,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            Some(broker),
            None,
            None,
            FetchTagsMode::Default,
        )
    }

    /// 可取消的认证 pull；fetch 子进程被终止后不会进入 merge/rebase 阶段。
    pub fn pull_with_auth_and_cancel(
        &self,
        remote: Option<String>,
        rebase: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_with_options_and_auth_and_cancel(
            remote,
            rebase,
            FetchTagsMode::Default,
            broker,
            cancel,
        )
    }

    /// Cancellable authenticated pull using the project's explicit tag policy.
    pub fn pull_with_options_and_auth_and_cancel(
        &self,
        remote: Option<String>,
        rebase: bool,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_with_broker(
            remote,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            Some(broker),
            Some(cancel),
            None,
            tag_mode,
        )
    }

    /// Cancellable authenticated Pull with the full GitPullDialog option set.
    pub fn pull_with_settings_and_auth_and_cancel(
        &self,
        remote: Option<String>,
        options: PullOptions,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_with_broker(remote, options, Some(broker), Some(cancel), None, tag_mode)
    }

    /// Pull with root-local dirty-change preservation. The marker is written
    /// before fetch/merge/rebase so a secondary Git root has the same
    /// crash-safe restore lifecycle as the primary root.
    pub fn pull_with_settings_and_policy(
        &self,
        remote: Option<String>,
        options: PullOptions,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<MergeOutcome, EngineError> {
        let saved = prepare_apply_local_changes(self, "pull", save_policy)?;
        finish_apply_local_changes(
            self,
            "pull",
            saved,
            self.pull_with_broker(remote, options, Some(broker), Some(cancel), None, tag_mode),
        )
    }

    /// Update Project 用的可取消 pull：父仓库在更新前已保存的 submodule
    /// 工作区不应再次被父仓库的 dirty guard 阻塞。
    pub fn pull_with_auth_and_cancel_ignoring_paths(
        &self,
        remote: Option<String>,
        rebase: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
        ignored_paths: Vec<String>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_with_options_and_auth_and_cancel_ignoring_paths(
            remote,
            rebase,
            FetchTagsMode::Default,
            broker,
            cancel,
            ignored_paths,
        )
    }

    /// Update Project pull with an explicit tag policy and ignored submodule paths.
    pub fn pull_with_options_and_auth_and_cancel_ignoring_paths(
        &self,
        remote: Option<String>,
        rebase: bool,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
        ignored_paths: Vec<String>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_with_broker(
            remote,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            Some(broker),
            Some(cancel),
            Some(ignored_paths),
            tag_mode,
        )
    }

    /// Integrate the already-fetched configured upstream without fetching
    /// again. Update Project uses this after its rebase-over-merge preflight;
    /// the helper keeps the same clean-worktree and tracking checks as pull.
    pub(crate) fn pull_after_fetch_with_options_ignoring_paths(
        &self,
        rebase: bool,
        ignored_paths: Vec<String>,
    ) -> Result<MergeOutcome, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if load_merge_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: merge is already in progress".into(),
            });
        }
        if load_rebase_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: rebase is already in progress".into(),
            });
        }
        let ignored_paths = ignored_paths.as_slice();
        let dirty = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                !ignored_paths.iter().any(|path| {
                    entry.path == *path
                        || entry
                            .path
                            .strip_prefix(path)
                            .is_some_and(|suffix| suffix.starts_with('/'))
                })
            })
            .filter(|entry| {
                entry.staged != crate::status::ChangeKind::Unchanged
                    || (entry.unstaged != crate::status::ChangeKind::Unchanged
                        && entry.unstaged != crate::status::ChangeKind::Untracked
                        && entry.unstaged != crate::status::ChangeKind::Ignored)
            })
            .count();
        if dirty != 0 {
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull requires a clean worktree; stash or commit first ({} changed path{})",
                    dirty,
                    if dirty == 1 { "" } else { "s" }
                ),
            });
        }
        let branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()))
            .ok_or_else(|| EngineError::GitOperation {
                message: "HEAD is detached".into(),
            })?;
        let upstream = configured_upstream(&repo, &branch)?;
        if upstream.remote == "." {
            return Err(EngineError::GitOperation {
                message: "pull: local repository upstream is not supported".into(),
            });
        }
        let tracking = format!("refs/remotes/{}/{}", upstream.remote, upstream.branch);
        let tracking_id = repo
            .rev_parse_single(BStr::new(tracking.as_bytes()))
            .map_err(|_| EngineError::TrackingMissing {
                branch: branch.clone(),
                upstream: format!("{}/{}", upstream.remote, upstream.branch),
            })?
            .detach();
        pull_tracking_locked(
            &repo,
            branch,
            format!("{}/{}", upstream.remote, upstream.branch),
            tracking_id,
            &PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            ignored_paths,
        )
    }

    fn pull_with_broker(
        &self,
        remote: Option<String>,
        options: PullOptions,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
        ignored_paths: Option<Vec<String>>,
        tag_mode: FetchTagsMode,
    ) -> Result<MergeOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        if load_merge_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: merge is already in progress".into(),
            });
        }
        if load_rebase_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: rebase is already in progress".into(),
            });
        }
        let ignored_paths = ignored_paths.as_deref().unwrap_or(&[]);
        let dirty = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                !ignored_paths.iter().any(|path| {
                    entry.path == *path
                        || entry
                            .path
                            .strip_prefix(path)
                            .is_some_and(|suffix| suffix.starts_with('/'))
                })
            })
            .filter(|entry| {
                entry.staged != crate::status::ChangeKind::Unchanged
                    || (entry.unstaged != crate::status::ChangeKind::Unchanged
                        && entry.unstaged != crate::status::ChangeKind::Untracked
                        && entry.unstaged != crate::status::ChangeKind::Ignored)
            })
            .map(|entry| entry.path)
            .collect::<Vec<_>>();
        if !dirty.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull requires a clean worktree; stash or commit first ({} changed path{})",
                    dirty.len(),
                    if dirty.len() == 1 { "" } else { "s" }
                ),
            });
        }
        let branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|n| shorten_ref_name(n.as_bstr()))
            .ok_or_else(|| EngineError::GitOperation {
                message: "HEAD is detached".into(),
            })?;
        let upstream = configured_upstream(&repo, &branch)?;
        let fetch_remote = remote.clone().unwrap_or_else(|| upstream.remote.clone());
        if fetch_remote == "." {
            return Err(EngineError::GitOperation {
                message: "pull: local repository upstream is not supported".into(),
            });
        }
        let fetch_flags: &[&str] = if ignored_paths.is_empty() {
            &[]
        } else {
            &["--no-recurse-submodules"]
        };
        let (_, name) = fetch_with_optional_auth_and_flags_and_tag_mode(
            &mut repo,
            &Some(fetch_remote.clone()),
            fetch_flags,
            tag_mode,
            broker.as_deref(),
            cancel
                .as_deref()
                .map(crate::gitprocess::GitCancelHandle::token),
        )?;
        if name != upstream.remote && remote.is_none() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull: configured upstream remote is '{}', fetched '{}' instead",
                    upstream.remote, name
                ),
            });
        }
        let tracking = format!("refs/remotes/{name}/{}", upstream.branch);
        let tracking_id = match repo.rev_parse_single(BStr::new(tracking.as_bytes())) {
            Ok(id) => id.detach(),
            Err(_) => {
                return Err(EngineError::TrackingMissing {
                    branch: branch.clone(),
                    upstream: format!("{name}/{}", upstream.branch),
                });
            }
        };
        pull_tracking_locked(
            &repo,
            branch,
            format!("{name}/{}", upstream.branch),
            tracking_id,
            &options,
            ignored_paths,
        )
    }

    /// 将指定 remote-tracking 分支 pull 到当前分支。
    ///
    /// 这是 Rebased 分支列表中选中远程分支后的 Pull into Current 语义；
    /// 它不会把当前分支的 configured upstream 偷换成所选分支。
    pub fn pull_remote_branch(
        &self,
        remote_branch: String,
        rebase: bool,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_remote_branch_with_broker(
            remote_branch,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            None,
            None,
            FetchTagsMode::Default,
        )
    }

    /// 带认证代理将指定 remote-tracking branch pull 到当前分支。
    pub fn pull_remote_branch_with_auth(
        &self,
        remote_branch: String,
        rebase: bool,
        broker: Arc<crate::auth::CredentialBroker>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_remote_branch_with_broker(
            remote_branch,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            Some(broker),
            None,
            FetchTagsMode::Default,
        )
    }

    /// 可取消的认证 remote branch pull。
    pub fn pull_remote_branch_with_auth_and_cancel(
        &self,
        remote_branch: String,
        rebase: bool,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_remote_branch_with_options_and_auth_and_cancel(
            remote_branch,
            rebase,
            FetchTagsMode::Default,
            broker,
            cancel,
        )
    }

    /// Cancellable authenticated remote-branch pull using the project's tag policy.
    pub fn pull_remote_branch_with_options_and_auth_and_cancel(
        &self,
        remote_branch: String,
        rebase: bool,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_remote_branch_with_broker(
            remote_branch,
            PullOptions {
                rebase,
                mode: MergeMode::FastForward,
                no_commit: false,
                no_verify: false,
            },
            Some(broker),
            Some(cancel),
            tag_mode,
        )
    }

    /// Cancellable authenticated remote-branch Pull with GitPullDialog options.
    pub fn pull_remote_branch_with_settings_and_auth_and_cancel(
        &self,
        remote_branch: String,
        options: PullOptions,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<MergeOutcome, EngineError> {
        self.pull_remote_branch_with_broker(
            remote_branch,
            options,
            Some(broker),
            Some(cancel),
            tag_mode,
        )
    }

    /// Pull an explicit remote-tracking branch with root-local dirty-change
    /// preservation. This is the selected-secondary-root Pull dialog path.
    pub fn pull_remote_branch_with_settings_and_policy(
        &self,
        remote_branch: String,
        options: PullOptions,
        tag_mode: FetchTagsMode,
        broker: Arc<crate::auth::CredentialBroker>,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<MergeOutcome, EngineError> {
        let saved = prepare_apply_local_changes(self, "pull", save_policy)?;
        finish_apply_local_changes(
            self,
            "pull",
            saved,
            self.pull_remote_branch_with_broker(
                remote_branch,
                options,
                Some(broker),
                Some(cancel),
                tag_mode,
            ),
        )
    }

    fn pull_remote_branch_with_broker(
        &self,
        remote_branch: String,
        options: PullOptions,
        broker: Option<Arc<crate::auth::CredentialBroker>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
        tag_mode: FetchTagsMode,
    ) -> Result<MergeOutcome, EngineError> {
        let mut repo = self.inner.lock().expect("repo mutex poisoned");
        if load_merge_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: merge is already in progress".into(),
            });
        }
        if load_rebase_state(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "pull: rebase is already in progress".into(),
            });
        }
        let dirty = crate::status::compute_status(&repo)?
            .into_iter()
            .filter(|entry| {
                entry.staged != crate::status::ChangeKind::Unchanged
                    || (entry.unstaged != crate::status::ChangeKind::Unchanged
                        && entry.unstaged != crate::status::ChangeKind::Untracked
                        && entry.unstaged != crate::status::ChangeKind::Ignored)
            })
            .map(|entry| entry.path)
            .collect::<Vec<_>>();
        if !dirty.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "pull requires a clean worktree; stash or commit first ({} changed path{})",
                    dirty.len(),
                    if dirty.len() == 1 { "" } else { "s" }
                ),
            });
        }
        let branch = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()))
            .ok_or_else(|| EngineError::GitOperation {
                message: "HEAD is detached".into(),
            })?;
        let remote_branch = remote_branch.trim();
        let (remote_name, upstream_branch) =
            remote_branch
                .split_once('/')
                .ok_or_else(|| EngineError::GitOperation {
                    message: "remote branch must look like remote/branch".into(),
                })?;
        if remote_name.is_empty() || upstream_branch.is_empty() || remote_name.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "remote branch must look like remote/branch".into(),
            });
        }
        let (_, fetched_name) = fetch_with_optional_auth_and_tag_mode(
            &mut repo,
            &Some(remote_name.to_string()),
            tag_mode,
            broker.as_deref(),
            cancel
                .as_deref()
                .map(crate::gitprocess::GitCancelHandle::token),
        )?;
        let tracking = format!("refs/remotes/{fetched_name}/{upstream_branch}");
        let tracking_id = repo
            .rev_parse_single(BStr::new(tracking.as_bytes()))
            .map_err(|_| EngineError::TrackingMissing {
                branch: branch.clone(),
                upstream: remote_branch.to_string(),
            })?
            .detach();
        pull_tracking_locked(
            &repo,
            branch,
            remote_branch.to_string(),
            tracking_id,
            &options,
            &[],
        )
    }

    // MARK: 交互式 rebase

    /// 变基：把 HEAD 上 onto 之后的提交按 actions（旧→新）重放到 onto 上。
    /// 支持 pick / drop / reword / squash / edit；保持原有线性 rebase 语义。
    pub fn rebase(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_options(onto, actions, false, false)
    }

    /// 将指定的本地分支 rebase 到当前分支，并让指定分支成为新的 HEAD。
    ///
    /// 这对应 IntelliJ Branches Popup 的“Checkout and Rebase onto Current”
    /// 语义：不是 pull 目标分支的 upstream，而是执行
    /// `git rebase --autostash HEAD <branch>`。系统 Git 保留原生 rebase
    /// 状态文件，因此冲突时可以通过 operation_state() 进入统一的
    /// Continue/Skip/Abort 恢复路径。
    pub fn rebase_branch_on_current(&self, branch: String) -> Result<(), EngineError> {
        self.rebase_branch_on_current_with_policy(branch, LocalChangesSavePolicy::Stash)
    }

    /// Checkout with Rebase using IntelliJ's configured local-changes policy.
    /// The saved reference remains in `.git` while native rebase is paused and
    /// is consumed only after the rebase result has been restored.
    pub fn rebase_branch_on_current_with_policy(
        &self,
        branch: String,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<(), EngineError> {
        self.rebase_branch_on_current_with_policy_inner(branch, save_policy, None)
    }

    /// Cancellable Checkout with Rebase using IntelliJ's local-changes policy.
    pub fn rebase_branch_on_current_with_policy_and_cancel(
        &self,
        branch: String,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<(), EngineError> {
        self.rebase_branch_on_current_with_policy_inner(branch, save_policy, Some(cancel))
    }

    fn rebase_branch_on_current_with_policy_inner(
        &self,
        branch: String,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<(), EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        ensure_not_cancelled(cancel_token)?;
        let saved = prepare_rebase_local_changes(self, save_policy)?;
        if cancel_token.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
            if saved {
                let repo = self.inner.lock().expect("repo mutex poisoned");
                return match restore_rebase_local_stash_locked(&repo, None) {
                    Ok(()) => Err(EngineError::Cancelled),
                    Err(restore_error) => Err(EngineError::GitOperation {
                        message: format!(
                            "checkout with rebase was cancelled, but saved local changes could not be restored: {restore_error}"
                        ),
                    }),
                };
            }
            return Err(EngineError::Cancelled);
        }
        let result = self.rebase_branch_on_current_clean(branch);
        if !saved {
            return result;
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        finish_rebase_abort_locked(&repo, result, cancel_token)
    }

    fn rebase_branch_on_current_clean(&self, branch: String) -> Result<(), EngineError> {
        let branch = branch.trim().to_string();
        if branch.is_empty() || branch.starts_with('-') {
            return Err(EngineError::GitOperation {
                message: "rebase branch must not be empty or start with '-'".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if crate::opstate::detect(&repo)?.is_some() {
            return Err(EngineError::GitOperation {
                message: "rebase: another Git operation is in progress; continue or abort it first"
                    .into(),
            });
        }
        let current = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        if current.as_deref() == Some(branch.as_str()) {
            return Err(EngineError::GitOperation {
                message: format!("rebase: branch '{branch}' is already checked out"),
            });
        }
        let full_branch = format!("refs/heads/{branch}");
        repo.find_reference(full_branch.as_str())
            .map_err(EngineError::from_gix)?
            .try_id()
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("rebase: branch '{branch}' has no object id"),
            })?;
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "rebase: bare repository has no worktree".into(),
        })?;
        let support = repo.git_dir().join("arbor-rebase-support");
        if let Some(current) = current.as_deref() {
            std::fs::create_dir_all(&support).map_err(EngineError::from_gix)?;
            std::fs::write(support.join("original-branch"), current)
                .map_err(EngineError::from_gix)?;
        }
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Rebase,
            "rebase",
        )
        .args(["--autostash", "HEAD", branch.as_str()])
        .working_dir(workdir);
        let outcome = match crate::gitprocess::run_to_completion(&spec) {
            Ok(outcome) => outcome,
            Err(error) => {
                if !system_rebase_active(&repo) {
                    cleanup_system_rebase_support(&repo);
                }
                return Err(error);
            }
        };
        if !outcome.success() {
            if !system_rebase_active(&repo) {
                cleanup_system_rebase_support(&repo);
            }
            return Err(outcome.into_error(&spec));
        }
        cleanup_system_rebase_support(&repo);
        Ok(())
    }

    /// 丢弃日志提交中选中的文件变更。
    ///
    /// 这对应 IntelliJ 的 Drop Selected Changes：把选中路径恢复到目标提交
    /// 的第一父版本，并重写目标提交之后当前分支上的线性提交。为了避免在
    /// 无法可靠保存本地修改时破坏工作区，这个对象级实现会先保存并在
    /// rewrite 后恢复完整本地现场，并明确拒绝 submodule 或无法安全
    /// 重放的冲突场景。
    pub fn drop_selected_changes(
        &self,
        commit_id: String,
        paths: Vec<String>,
    ) -> Result<RebaseOutcome, EngineError> {
        with_preserved_local_changes(self, "Drop Selected Changes", |repo| {
            ensure_history_change_operation_is_safe(repo)?;
            let target = repo
                .rev_parse_single(BStr::new(commit_id.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let target_commit = repo.find_commit(target).map_err(EngineError::from_gix)?;
            let parents: Vec<_> = target_commit.parent_ids().map(|id| id.detach()).collect();
            let parent_tree = parents
                .first()
                .map(|parent| {
                    repo.find_commit(*parent)
                        .map_err(EngineError::from_gix)?
                        .tree_id()
                        .map_err(EngineError::from_gix)
                        .map(|tree| tree.detach())
                })
                .transpose()?
                .unwrap_or_else(|| repo.empty_tree().id);
            let target_tree = target_commit
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let selected_paths =
                validate_selected_history_paths(repo, parent_tree, target_tree, &paths)?;
            let dropped_tree = replace_tree_paths(repo, target_tree, parent_tree, &selected_paths)?;
            rewrite_selected_commit_history(repo, target, dropped_tree, None, None)
        })
    }

    /// 从日志提交中抽取选中的文件变更为一个新的提交。
    ///
    /// 第一提交保留未选中的目标变更，第二提交恢复完整目标树并使用新消息；
    /// 然后按原顺序重放目标之后的线性提交。操作前后保存并恢复本地现场。
    pub fn extract_selected_changes(
        &self,
        commit_id: String,
        paths: Vec<String>,
        new_message: String,
    ) -> Result<RebaseOutcome, EngineError> {
        let message = new_message.trim();
        if message.is_empty() {
            return Err(EngineError::GitOperation {
                message: "extract selected changes requires a non-empty commit message".into(),
            });
        }
        with_preserved_local_changes(self, "Extract Selected Changes", |repo| {
            ensure_history_change_operation_is_safe(repo)?;
            let target = repo
                .rev_parse_single(BStr::new(commit_id.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let target_commit = repo.find_commit(target).map_err(EngineError::from_gix)?;
            let parents: Vec<_> = target_commit.parent_ids().map(|id| id.detach()).collect();
            let parent_tree = parents
                .first()
                .map(|parent| {
                    repo.find_commit(*parent)
                        .map_err(EngineError::from_gix)?
                        .tree_id()
                        .map_err(EngineError::from_gix)
                        .map(|tree| tree.detach())
                })
                .transpose()?
                .unwrap_or_else(|| repo.empty_tree().id);
            let target_tree = target_commit
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let selected_paths =
                validate_selected_history_paths(repo, parent_tree, target_tree, &paths)?;
            let remaining_tree =
                replace_tree_paths(repo, target_tree, parent_tree, &selected_paths)?;
            rewrite_selected_commit_history(
                repo,
                target,
                remaining_tree,
                Some(target_tree),
                Some(message),
            )
        })
    }

    /// 可选语义的 rebase。
    ///
    /// `preserve_merges` 使用图重放并保留范围内的 merge commit；merge commit
    /// 自动重放，不占 `actions` 槽位。`auto_squash` 按 `squash!`/`fixup!` 标题
    /// 自动重排线性动作。
    pub fn rebase_with_options(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_advanced_options(
            onto,
            actions,
            preserve_merges,
            auto_squash,
            false,
            false,
            false,
        )
    }

    /// 带 IntelliJ/Git 高级选项的交互式 rebase。
    ///
    /// `keep_empty`、`update_refs` 和 `root` 需要 Git 原生 interactive
    /// rebase 才能完整保留其 todo/ref 语义；普通线性 rebase 仍使用 Rust
    /// 对象级重放，以保持现有暂停与冲突工作台路径。
    pub fn rebase_with_advanced_options(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_advanced_options_and_policy(
            onto,
            actions,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            LocalChangesSavePolicy::Stash,
        )
    }

    /// IntelliJ GitPreservingProcess variant that uses the configured local
    /// changes policy. The legacy method above intentionally keeps its old
    /// stash default for ABI and behavior compatibility with existing clients.
    pub fn rebase_with_advanced_options_and_policy(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        with_rebase_local_changes(self, save_policy, None, || {
            self.rebase_with_advanced_options_clean(
                onto,
                actions,
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                None,
                None,
            )
        })
    }

    /// Cancellable current-HEAD counterpart used when the caller explicitly
    /// disables IntelliJ's in-memory commit-editing optimization. The current
    /// HEAD form is also needed for detached HEAD; branch-targeted callers use
    /// the positional-branch API below.
    pub fn rebase_with_advanced_options_and_policy_and_cancel(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        with_rebase_local_changes(self, save_policy, Some(cancel.token()), || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let onto_id = resolve_rebase_onto(&repo, &onto, root)?;
            let original_head = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach();
            let original_tree = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            // This entry point deliberately bypasses the optimized dispatcher
            // above: callers use it when the IntelliJ registry switch says to
            // force native Git, even for a plain linear rebase.
            rebase_with_system_options(
                &repo,
                onto_id,
                original_head,
                original_tree,
                actions,
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                None,
                None,
                None,
                true,
                Some(cancel.token()),
            )
        })
    }

    /// 在指定分支上执行交互式 rebase，并让 Git 保持 IntelliJ 的分支语义：
    /// 目标分支作为命令最后的 positional branch 参数被 checkout、重写并留在
    /// HEAD。当前 checkout 的分支会记录在支持目录中，供 abort 恢复。
    pub fn rebase_branch_with_advanced_options(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_advanced_options_and_policy(
            onto,
            branch,
            actions,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            LocalChangesSavePolicy::Stash,
        )
    }

    /// Branch-targeted rebase with IntelliJ's persisted save policy.
    pub fn rebase_branch_with_advanced_options_and_policy(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_advanced_options_and_policy_inner(
            onto,
            branch,
            actions,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable branch-targeted interactive rebase. Cancellation during
    /// Preservation Shelf restore keeps the Shelf and its staged/unstaged
    /// snapshot for a later retry.
    pub fn rebase_branch_with_advanced_options_and_policy_and_cancel(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_advanced_options_and_policy_inner(
            onto,
            branch,
            actions,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_branch_with_advanced_options_and_policy_inner(
        &self,
        onto: String,
        branch: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            self.rebase_with_advanced_options_clean(
                onto,
                actions,
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                Some(branch),
                cancel.clone(),
            )
        })
    }

    /// Capture Git's native interactive-rebase todo for an explicit branch.
    /// This is the multi-root counterpart of `rebase_raw_todo_with_options`:
    /// the branch is passed to Git as the target ref instead of assuming that
    /// the repository's current HEAD is the branch being edited.
    pub fn rebase_raw_todo_for_branch_with_options_and_policy(
        &self,
        onto: String,
        branch: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<String, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_raw_todo_for_branch_with_options_and_policy_inner(
            onto,
            branch,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable native todo capture for an explicit branch.
    pub fn rebase_raw_todo_for_branch_with_options_and_policy_and_cancel(
        &self,
        onto: String,
        branch: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<String, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_raw_todo_for_branch_with_options_and_policy_inner(
            onto,
            branch,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_raw_todo_for_branch_with_options_and_policy_inner(
        &self,
        onto: String,
        branch: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<String, EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes_value(self, save_policy, cancel_token, || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let onto_id = resolve_rebase_onto(&repo, &onto, root)?;
            let original_head = repo
                .rev_parse_single(BStr::new(branch.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            capture_raw_rebase_todo(
                &repo,
                onto_id,
                original_head,
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                Some(&branch),
                cancel_token,
            )
        })
    }

    /// Execute caller-edited native todo text against an explicit branch.
    /// The native Git command owns branch checkout, topology, control rows,
    /// message editing and pause semantics exactly as it does for a single
    /// current-HEAD rebase.
    pub fn rebase_branch_with_raw_todo_and_policy(
        &self,
        onto: String,
        branch: String,
        raw_todo: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_raw_todo_and_policy_inner(
            onto,
            branch,
            raw_todo,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable native raw-todo rebase for an explicit branch. Cancelling
    /// kills Git's process group; an already-active rebase retains its saved
    /// local scene for the normal Continue/Abort recovery path.
    pub fn rebase_branch_with_raw_todo_and_policy_and_cancel(
        &self,
        onto: String,
        branch: String,
        raw_todo: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_raw_todo_and_policy_inner(
            onto,
            branch,
            raw_todo,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_branch_with_raw_todo_and_policy_inner(
        &self,
        onto: String,
        branch: String,
        raw_todo: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        if raw_todo.contains('\0') {
            return Err(EngineError::GitOperation {
                message: "rebase todo cannot contain NUL bytes".into(),
            });
        }
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            let command;
            {
                let repo = self.inner.lock().expect("repo mutex poisoned");
                ensure_history_change_operation_is_idle(&repo)?;
                let onto_id = resolve_rebase_onto(&repo, &onto, root)?;
                let original_head = repo
                    .rev_parse_single(BStr::new(branch.as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach();
                command = prepare_raw_rebase_todo_command(
                    &repo,
                    onto_id,
                    original_head,
                    raw_todo,
                    preserve_merges,
                    auto_squash,
                    keep_empty,
                    update_refs,
                    root,
                    Some(&branch),
                )?;
            }
            let output = crate::gitprocess::run(&command, cancel_token, |_| {})?;
            let repo = self.inner.lock().expect("repo mutex poisoned");
            if output.cancelled {
                if !system_rebase_active(&repo) {
                    cleanup_system_rebase_support(&repo);
                }
                return Err(EngineError::Cancelled);
            }
            if system_rebase_active(&repo) {
                return system_rebase_outcome(&repo, true);
            }
            if !output.success() {
                cleanup_system_rebase_support(&repo);
                return Err(EngineError::GitOperation {
                    message: format!("git rebase failed: {}", git_process_output_message(&output)),
                });
            }
            cleanup_system_rebase_support(&repo);
            system_rebase_outcome(&repo, false)
        })
    }

    /// Execute a non-interactive branch-targeted rebase with Git's native
    /// topology and option semantics. Unlike the interactive variant, this
    /// does not synthesize a todo list or install sequence/message editors.
    pub fn rebase_branch_with_options_and_policy(
        &self,
        onto: String,
        branch: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_options_and_policy_inner(
            onto,
            branch,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable branch-targeted non-interactive rebase.
    pub fn rebase_branch_with_options_and_policy_and_cancel(
        &self,
        onto: String,
        branch: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        self.rebase_branch_with_options_and_policy_inner(
            onto,
            branch,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_branch_with_options_and_policy_inner(
        &self,
        onto: String,
        branch: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let onto_id = if onto.trim().is_empty() {
                if !root {
                    return Err(EngineError::GitOperation {
                        message: "rebase: a non-root rebase requires an onto revision".into(),
                    });
                }
                None
            } else {
                Some(
                    repo.rev_parse_single(BStr::new(onto.trim().as_bytes()))
                        .map_err(EngineError::from_gix)?
                        .detach(),
                )
            };
            let original_head = repo
                .rev_parse_single(BStr::new(branch.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let original_tree = repo
                .find_commit(original_head)
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            rebase_with_system_options(
                &repo,
                onto_id,
                original_head,
                original_tree,
                Vec::new(),
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                Some(&branch),
                None,
                None,
                false,
                cancel_token,
            )
        })
    }

    fn rebase_with_options_clean(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_advanced_options_clean(
            onto,
            actions,
            preserve_merges,
            auto_squash,
            false,
            false,
            false,
            None,
            None,
        )
    }

    fn rebase_with_advanced_options_clean(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        branch: Option<String>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_advanced_options_clean_and_merge_actions(
            onto,
            actions,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            branch,
            None,
            None,
            cancel,
        )
    }

    fn rebase_with_advanced_options_clean_and_merge_actions(
        &self,
        onto: String,
        actions: Vec<RebaseAction>,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        branch: Option<String>,
        merge_reword_overrides: Option<Vec<String>>,
        desired_order: Option<Vec<String>>,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        ensure_history_change_operation_is_idle(&repo)?;
        let onto_id = if onto.trim().is_empty() {
            if !root {
                return Err(EngineError::GitOperation {
                    message: "rebase: a non-root rebase requires an onto revision".into(),
                });
            }
            None
        } else {
            Some(
                repo.rev_parse_single(BStr::new(onto.trim().as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach(),
            )
        };
        let original_head = match branch.as_deref() {
            Some(branch) => repo
                .rev_parse_single(BStr::new(branch.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach(),
            None => repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach(),
        };
        let original_tree = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        let desired_order = desired_order
            .map(|ids| {
                ids.into_iter()
                    .map(|id| {
                        gix::hash::ObjectId::from_hex(id.as_bytes()).map_err(|_| {
                            EngineError::GitOperation {
                                message: format!("rebase todo: invalid order commit {id}"),
                            }
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?;

        if preserve_merges || keep_empty || update_refs || root || branch.is_some() {
            return rebase_with_system_options(
                &repo,
                onto_id,
                original_head,
                original_tree,
                actions,
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                branch.as_deref(),
                desired_order.as_deref(),
                merge_reword_overrides
                    .as_deref()
                    .map(parse_merge_reword_overrides)
                    .transpose()?,
                true,
                cancel
                    .as_deref()
                    .map(crate::gitprocess::GitCancelHandle::token),
            );
        }

        let onto_id = onto_id.ok_or_else(|| EngineError::GitOperation {
            message: "rebase: a non-root rebase requires an onto revision".into(),
        })?;

        // 范围：沿 first-parent 从 HEAD 到 onto（不含），旧→新。
        // 若 onto 不是当前线的祖先，退化到 HEAD 与 onto 的 merge-base，
        // 这样才能覆盖真实 rebase onto 另一条分支时的冲突场景。
        // 默认 rebase 等价 git --no-rebase-merges：merge 提交本身跳过，
        // 其后的 first-parent 提交仍按自己的相对变更重放。
        let range_base = {
            let mut cursor = original_head;
            let mut ancestor = None;
            loop {
                if cursor == onto_id {
                    ancestor = Some(onto_id);
                    break;
                }
                let commit = repo.find_commit(cursor).map_err(EngineError::from_gix)?;
                let Some(first_parent) = commit.parent_ids().next() else {
                    break;
                };
                cursor = first_parent.detach();
            }
            ancestor.unwrap_or(
                repo.merge_base(original_head, onto_id)
                    .map_err(EngineError::from_gix)?
                    .detach(),
            )
        };
        let mut range = Vec::new();
        let mut cursor = original_head;
        let mut found_base = false;
        loop {
            if cursor == range_base {
                found_base = true;
                break;
            }
            let commit = repo.find_commit(cursor).map_err(EngineError::from_gix)?;
            let mut parents = commit.parent_ids();
            let Some(first_parent) = parents.next() else {
                break;
            };
            if commit.parent_ids().nth(1).is_none() {
                range.push(cursor);
            }
            cursor = first_parent.detach();
        }
        if !found_base {
            return Err(EngineError::GitOperation {
                message: "rebase: onto merge-base is not on HEAD first-parent line".into(),
            });
        }
        range.reverse();
        if range.len() != actions.len() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase: {} actions for {} commits",
                    actions.len(),
                    range.len()
                ),
            });
        }
        let mut pairs: Vec<(RebaseAction, gix::hash::ObjectId)> =
            actions.into_iter().zip(range).collect();
        if auto_squash {
            pairs = crate::rebasetodo::autosquash_pairs(&repo, pairs)?;
        }
        let onto_commit = repo.find_commit(onto_id).map_err(EngineError::from_gix)?;
        let start_tree = onto_commit
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();

        execute_linear_rebase(
            &repo,
            onto_id,
            original_head,
            original_tree,
            start_tree,
            &pairs,
            None,
        )
    }

    /// 返回 Rebase 对话框可编辑的提交范围，顺序为旧 -> 新。
    ///
    /// 默认 rebase 只暴露当前 HEAD 的 first-parent 线；preserve-merges
    /// 则暴露整个拓扑范围中的非 merge 提交，因为 merge 节点由 Git 原生
    /// `--rebase-merges` todo 自动生成，不占用户 action 槽位。UI 不应自行
    /// 从普通 log 切片推导范围，否则 merge 历史会把 side branch 提交误加
    /// 到默认 rebase，或在 preserve-merges 模式下漏掉它们。
    pub fn rebase_range(
        &self,
        onto: String,
        preserve_merges: bool,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        self.rebase_range_with_options(onto, preserve_merges, false)
    }

    /// 返回带 `--root` 语义的交互式 rebase 范围。
    pub fn rebase_range_with_options(
        &self,
        onto: String,
        preserve_merges: bool,
        root: bool,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let onto_id = if onto.trim().is_empty() {
            if !root {
                return Err(EngineError::GitOperation {
                    message: "rebase: a non-root rebase requires an onto revision".into(),
                });
            }
            None
        } else {
            Some(
                repo.rev_parse_single(BStr::new(onto.trim().as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach(),
            )
        };
        let head_id = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        rebase_range_with_options_for_head(&repo, onto_id, preserve_merges, root, head_id)
    }

    /// 返回指定本地/可解析分支的交互式 rebase 范围，而不是隐式使用当前 HEAD。
    /// 这对应 IntelliJ Rebase 对话框中的 Branch 选择器。
    pub fn rebase_range_for_branch(
        &self,
        onto: String,
        preserve_merges: bool,
        root: bool,
        branch: String,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let onto_id = if onto.trim().is_empty() {
            if !root {
                return Err(EngineError::GitOperation {
                    message: "rebase: a non-root rebase requires an onto revision".into(),
                });
            }
            None
        } else {
            Some(
                repo.rev_parse_single(BStr::new(onto.trim().as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach(),
            )
        };
        let head_id = repo
            .rev_parse_single(BStr::new(branch.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        rebase_range_with_options_for_head(&repo, onto_id, preserve_merges, root, head_id)
    }

    /// 继续被 edit 暂停的 rebase：amend 当前提交（树=当前工作区，信息=原信息）后应用剩余动作。

    pub fn rebase_continue(&self) -> Result<RebaseOutcome, EngineError> {
        use gix::refs::transaction::{Change, PreviousValue, RefEdit};
        use gix::refs::Target;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if system_rebase_active(&repo) {
            let mut command = prepare_continue_system_rebase_command(&repo)?;
            drop(repo);
            let output = command.output().map_err(EngineError::from_gix)?;
            let repo = self.inner.lock().expect("repo mutex poisoned");
            let result = finish_rebase_local_changes_locked(
                &repo,
                finish_continue_system_rebase(&repo, output),
                None,
            );
            if result.is_ok() {
                crate::conflict::clear_resolved_ledger(&repo);
            }
            return result;
        }
        let Some(state) = load_rebase_state(&repo)? else {
            return Err(EngineError::GitOperation {
                message: "rebase: no rebase in progress".into(),
            });
        };
        if matches!(state.reason, RebasePauseReason::Conflict) {
            let result = finish_rebase_local_changes_locked(
                &repo,
                continue_conflicted_rebase(&repo, &state),
                None,
            );
            if result.is_ok() {
                crate::conflict::clear_resolved_ledger(&repo);
            }
            return result;
        }
        // IntelliJ lets the user amend the commit while an object-level
        // rebase is paused at `edit`. In that case HEAD already moved from
        // the pause point. Reusing the current commit is important: creating
        // another synthetic commit would lose the user's amended message
        // and produce an extra history entry.
        let current_head = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        let (amended, amend_tree) = if current_head != state.head {
            let paused_commit = repo
                .find_commit(state.head)
                .map_err(EngineError::from_gix)?;
            let expected_parents = paused_commit
                .parent_ids()
                .map(|id| id.detach())
                .collect::<Vec<_>>();
            let amended_commit = repo
                .find_commit(current_head)
                .map_err(EngineError::from_gix)?;
            let actual_parents = amended_commit
                .parent_ids()
                .map(|id| id.detach())
                .collect::<Vec<_>>();
            if actual_parents != expected_parents {
                return Err(EngineError::GitOperation {
                    message: "rebase: HEAD changed without amending the paused commit; refusing to continue".into(),
                });
            }
            let amend_tree = amended_commit
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let tree = repo.find_tree(amend_tree).map_err(EngineError::from_gix)?;
            let mut dirty = Vec::new();
            for entry in crate::status::compute_status(&repo)? {
                let has_dirty_content = entry.staged != crate::status::ChangeKind::Unchanged
                    || (entry.unstaged != crate::status::ChangeKind::Unchanged
                        && entry.unstaged != crate::status::ChangeKind::Ignored);
                if has_dirty_content
                    && tree
                        .lookup_entry_by_path(entry.path.as_str())
                        .map_err(EngineError::from_gix)?
                        .is_some()
                {
                    dirty.push(entry.path);
                }
            }
            if !dirty.is_empty() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "rebase: amended commit has uncommitted changes; stage and amend them before continuing ({})",
                        dirty.join(", ")
                    ),
                });
            }
            (current_head, amend_tree)
        } else {
            let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
                message: "bare repository has no worktree".into(),
            })?;
            // No explicit amend has happened: preserve the existing Arbor
            // behavior and turn the current worktree into the paused commit.
            let index = repo
                .index_or_load_from_head_or_empty()
                .map_err(EngineError::from_gix)?
                .into_owned();
            let amend_tree = build_worktree_tree(&repo, &index, workdir, false, false)?;
            let current_commit = repo
                .find_commit(state.head)
                .map_err(EngineError::from_gix)?;
            let parents = current_commit
                .parent_ids()
                .map(|id| id.detach())
                .collect::<Vec<_>>();
            let message = crate::commit_message::format(&repo, state.message.clone())?;
            let amended = repo
                .new_commit(&message, amend_tree, parents)
                .map_err(EngineError::from_gix)?
                .id;
            // HEAD: state.head -> amended（CAS）
            match repo.head_name().map_err(EngineError::from_gix)? {
                Some(name) => {
                    repo.reference(
                        name,
                        amended,
                        PreviousValue::MustExistAndMatch(Target::Object(state.head)),
                        "rebase: amend",
                    )
                    .map_err(EngineError::from_gix)?;
                }
                None => {
                    let head_name: gix::refs::FullName =
                        "HEAD".try_into().map_err(EngineError::from_gix)?;
                    repo.edit_reference(RefEdit {
                        change: Change::Update {
                            log: Default::default(),
                            expected: PreviousValue::MustExistAndMatch(Target::Object(state.head)),
                            new: Target::Object(amended),
                        },
                        name: head_name,
                        deref: true,
                    })
                    .map_err(EngineError::from_gix)?;
                }
            }
            (amended, amend_tree)
        };

        let result =
            match apply_rebase_actions(&repo, amended, amend_tree, &state.remaining, true, None) {
                Ok(ApplyOutcome::Done { head, tree }) => {
                    clear_rebase_state(&repo);
                    finalize_rebase(&repo, amend_tree, head, tree)?;
                    Ok(RebaseOutcome {
                        head_id: head.to_hex().to_string(),
                        paused: false,
                        pause_reason: None,
                        conflicts: Vec::new(),
                    })
                }
                Ok(ApplyOutcome::Paused {
                    head,
                    tree,
                    message,
                    remaining,
                }) => {
                    save_rebase_state(
                        &repo,
                        &RebaseState {
                            original_head: state.original_head,
                            onto: state.onto,
                            head,
                            tree,
                            message,
                            reason: RebasePauseReason::Edit,
                            remaining,
                        },
                    )?;
                    Ok(RebaseOutcome {
                        head_id: head.to_hex().to_string(),
                        paused: true,
                        pause_reason: Some(RebasePauseReason::Edit),
                        conflicts: Vec::new(),
                    })
                }
                Ok(ApplyOutcome::PausedConflict {
                    head,
                    tree,
                    message,
                    remaining,
                    conflicts,
                }) => {
                    save_rebase_state(
                        &repo,
                        &RebaseState {
                            original_head: state.original_head,
                            onto: state.onto,
                            head,
                            tree,
                            message,
                            reason: RebasePauseReason::Conflict,
                            remaining,
                        },
                    )?;
                    Ok(RebaseOutcome {
                        head_id: head.to_hex().to_string(),
                        paused: true,
                        pause_reason: Some(RebasePauseReason::Conflict),
                        conflicts,
                    })
                }
                Err(e) => {
                    restore_head(&repo, state.original_head)?;
                    clear_rebase_state(&repo);
                    Err(e)
                }
            };
        let result = finish_rebase_local_changes_locked(&repo, result, None);
        if result.is_ok() {
            crate::conflict::clear_resolved_ledger(&repo);
        }
        result
    }

    // MARK: REBASE-001 显式 todo

    /// 生成交互式 rebase 的显式 todo：HEAD 沿第一父链到 onto 的所有提交，
    /// 全部 pick；`auto_squash` 时 fixup!/squash! 提交吸附到目标后（预览）。
    /// 顺序与 action 以返回的模型为准，UI 拖拽/批量修改后交回 `rebase_with_todo`。
    pub fn rebase_todo(
        &self,
        onto: String,
        auto_squash: bool,
    ) -> Result<crate::rebasetodo::RebaseTodo, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let onto_id = repo
            .rev_parse_single(BStr::new(onto.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let original_head = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        crate::rebasetodo::build_todo(&repo, onto_id, original_head, auto_squash)
    }

    /// 生成保留 merge 拓扑的结构化 todo。
    ///
    /// 原生 `--rebase-merges` todo 中的 label/reset/merge 控制行由 Git
    /// 管理；返回值额外包含只读 merge commit 行，让 UI 能展示完整拓扑，
    /// 但不能把它们当成普通提交改写。
    pub fn rebase_todo_with_options(
        &self,
        onto: String,
        auto_squash: bool,
        preserve_merges: bool,
    ) -> Result<crate::rebasetodo::RebaseTodo, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let onto_id = repo
            .rev_parse_single(BStr::new(onto.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let original_head = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        let ids = rebase_todo_ids_with_options_for_head(
            &repo,
            Some(onto_id),
            preserve_merges,
            false,
            original_head,
        )?;
        crate::rebasetodo::build_todo_from_ids(&repo, onto_id, ids, auto_squash)
    }

    /// Generate the same structured todo for a selected branch instead of
    /// implicitly using the current HEAD. Preserve-merges mode includes the
    /// visible merge rows so a multi-root editor can persist one action per
    /// displayed row; the native label/reset/merge control lines remain
    /// executor-owned.
    pub fn rebase_todo_for_branch_with_options(
        &self,
        onto: String,
        auto_squash: bool,
        preserve_merges: bool,
        root: bool,
        branch: String,
    ) -> Result<crate::rebasetodo::RebaseTodo, EngineError> {
        let branch = validate_rebase_branch_name(branch)?;
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let onto_id = if onto.trim().is_empty() {
            if !root {
                return Err(EngineError::GitOperation {
                    message: "rebase: a non-root rebase requires an onto revision".into(),
                });
            }
            None
        } else {
            Some(
                repo.rev_parse_single(BStr::new(onto.trim().as_bytes()))
                    .map_err(EngineError::from_gix)?
                    .detach(),
            )
        };
        let original_head = repo
            .rev_parse_single(BStr::new(branch.as_bytes()))
            .map_err(EngineError::from_gix)?
            .detach();
        let ids = rebase_todo_ids_with_options_for_head(
            &repo,
            onto_id,
            preserve_merges,
            root,
            original_head,
        )?;
        match onto_id {
            Some(onto_id) => {
                crate::rebasetodo::build_todo_from_ids(&repo, onto_id, ids, auto_squash)
            }
            None => crate::rebasetodo::build_todo_from_ids_without_onto(&repo, ids, auto_squash),
        }
    }

    /// Generate the explicit todo for IntelliJ's "Interactive Rebase from
    /// Here" when the selected commit is the repository root.  Unlike the
    /// transplant-style `root` option, this is true `git rebase -i --root`
    /// semantics and therefore has no upstream revision.
    pub fn rebase_root_todo(
        &self,
        auto_squash: bool,
        preserve_merges: bool,
    ) -> Result<crate::rebasetodo::RebaseTodo, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let original_head = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .id()
            .detach();
        let ids = rebase_todo_ids_with_options_for_head(
            &repo,
            None,
            preserve_merges,
            true,
            original_head,
        )?;
        crate::rebasetodo::build_todo_from_ids_without_onto(&repo, ids, auto_squash)
    }

    /// Capture Git's native interactive-rebase todo without starting the
    /// rewrite.  The sequence editor copies the generated file and exits
    /// non-zero; Git therefore cleans its temporary rebase state while the
    /// caller receives the exact native text, including control commands that
    /// the structured Arbor todo model intentionally does not represent.
    pub fn rebase_raw_todo_with_options(
        &self,
        onto: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
    ) -> Result<String, EngineError> {
        self.rebase_raw_todo_with_options_and_policy(
            onto,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            LocalChangesSavePolicy::Stash,
        )
    }

    /// Capture Git's native todo while applying IntelliJ's configured local
    /// changes preservation policy.  Preparation restores the saved worktree
    /// immediately because no rebase remains active after the capture editor
    /// exits.
    pub fn rebase_raw_todo_with_options_and_policy(
        &self,
        onto: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<String, EngineError> {
        self.rebase_raw_todo_with_options_and_policy_inner(
            onto,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable native interactive-rebase todo capture.
    pub fn rebase_raw_todo_with_options_and_policy_and_cancel(
        &self,
        onto: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<String, EngineError> {
        self.rebase_raw_todo_with_options_and_policy_inner(
            onto,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_raw_todo_with_options_and_policy_inner(
        &self,
        onto: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<String, EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes_value(self, save_policy, cancel_token, || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let onto_id = resolve_rebase_onto(&repo, &onto, root)?;
            let original_head = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach();
            capture_raw_rebase_todo(
                &repo,
                onto_id,
                original_head,
                preserve_merges,
                auto_squash,
                keep_empty,
                update_refs,
                root,
                None,
                cancel_token,
            )
        })
    }

    /// Execute caller-edited native todo text through Git's own interactive
    /// rebase machinery.  Unlike `rebase_with_todo`, this intentionally keeps
    /// every command understood by the installed Git version instead of
    /// parsing the file into Arbor's smaller structured action enum.
    pub fn rebase_with_raw_todo_and_policy(
        &self,
        onto: String,
        raw_todo: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_raw_todo_and_policy_inner(
            onto,
            raw_todo,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            None,
        )
    }

    /// Cancellable native raw-todo rebase. Git's process group is terminated
    /// on cancellation; if Git has already created rebase state, the saved
    /// local scene remains available for Continue/Abort recovery.
    pub fn rebase_with_raw_todo_and_policy_and_cancel(
        &self,
        onto: String,
        raw_todo: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_raw_todo_and_policy_inner(
            onto,
            raw_todo,
            preserve_merges,
            auto_squash,
            keep_empty,
            update_refs,
            root,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_with_raw_todo_and_policy_inner(
        &self,
        onto: String,
        raw_todo: String,
        preserve_merges: bool,
        auto_squash: bool,
        keep_empty: bool,
        update_refs: bool,
        root: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        if raw_todo.contains('\0') {
            return Err(EngineError::GitOperation {
                message: "rebase todo cannot contain NUL bytes".into(),
            });
        }
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            let command;
            {
                let repo = self.inner.lock().expect("repo mutex poisoned");
                ensure_history_change_operation_is_idle(&repo)?;
                let onto_id = resolve_rebase_onto(&repo, &onto, root)?;
                let original_head = repo
                    .head_commit()
                    .map_err(EngineError::from_gix)?
                    .id()
                    .detach();
                command = prepare_raw_rebase_todo_command(
                    &repo,
                    onto_id,
                    original_head,
                    raw_todo,
                    preserve_merges,
                    auto_squash,
                    keep_empty,
                    update_refs,
                    root,
                    None,
                )?;
            }
            let output = crate::gitprocess::run(&command, cancel_token, |_| {})?;
            let repo = self.inner.lock().expect("repo mutex poisoned");
            if output.cancelled {
                if !system_rebase_active(&repo) {
                    cleanup_system_rebase_support(&repo);
                }
                return Err(EngineError::Cancelled);
            }
            if system_rebase_active(&repo) {
                return system_rebase_outcome(&repo, true);
            }
            if !output.success() {
                cleanup_system_rebase_support(&repo);
                return Err(EngineError::GitOperation {
                    message: format!("git rebase failed: {}", git_process_output_message(&output)),
                });
            }
            cleanup_system_rebase_support(&repo);
            system_rebase_outcome(&repo, false)
        })
    }

    /// Return the commit message currently waiting for the native rebase
    /// message editor.  The raw-todo path uses a small file protocol so the
    /// blocking Git editor can be driven by SwiftUI without replacing Git's
    /// own rebase process.
    pub fn rebase_pending_message(&self) -> Result<Option<String>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if !system_rebase_active(&repo) {
            return Ok(None);
        }
        let request = repo
            .git_dir()
            .join("arbor-rebase-support/raw-message.request");
        if !request.exists() {
            return Ok(None);
        }
        // Git's editor removes the request only after it has consumed the
        // response. Treat an already-written response/cancel marker as
        // handled so a 100ms UI poll cannot reopen the same message sheet.
        if repo
            .git_dir()
            .join("arbor-rebase-support/raw-message.response")
            .exists()
            || repo
                .git_dir()
                .join("arbor-rebase-support/raw-message.cancel")
                .exists()
        {
            return Ok(None);
        }
        std::fs::read_to_string(request)
            .map(Some)
            .map_err(EngineError::from_gix)
    }

    /// Complete the pending native commit-message edit.
    pub fn rebase_set_pending_message(&self, message: String) -> Result<(), EngineError> {
        if message.contains('\0') {
            return Err(EngineError::GitOperation {
                message: "rebase message cannot contain NUL bytes".into(),
            });
        }
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let support = repo.git_dir().join("arbor-rebase-support");
        let request = support.join("raw-message.request");
        if !system_rebase_active(&repo) || !request.exists() {
            return Err(EngineError::GitOperation {
                message: "rebase: no native commit-message edit is waiting".into(),
            });
        }
        let response = support.join("raw-message.response");
        let temporary = support.join("raw-message.response.tmp");
        std::fs::write(&temporary, message).map_err(EngineError::from_gix)?;
        std::fs::rename(&temporary, &response).map_err(EngineError::from_gix)
    }

    /// Cancel the pending native commit-message edit.  Git receives the same
    /// non-zero editor result as IntelliJ's cancelled unstructured editor and
    /// the outer operation reports a normal rebase failure/recovery state.
    pub fn rebase_cancel_pending_message(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        let support = repo.git_dir().join("arbor-rebase-support");
        let request = support.join("raw-message.request");
        if !system_rebase_active(&repo) || !request.exists() {
            return Err(EngineError::GitOperation {
                message: "rebase: no native commit-message edit is waiting".into(),
            });
        }
        std::fs::write(support.join("raw-message.cancel"), b"cancel").map_err(EngineError::from_gix)
    }

    /// 按显式 todo 执行交互式 rebase：校验 todo 与范围提交一一对应后
    /// 按 todo 顺序与 action 执行（拖拽排序/批量 action 的最终权威）。
    pub fn rebase_with_todo(
        &self,
        onto: String,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_todo_and_policy(onto, todo, preserve_merges, LocalChangesSavePolicy::Stash)
    }

    /// Explicit interactive todo rebase with IntelliJ's persisted save
    /// policy. Paused continue/skip/abort read the saved operation reference,
    /// so the policy survives a process restart without adding UI state to the
    /// rebase operation itself.
    pub fn rebase_with_todo_and_policy(
        &self,
        onto: String,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_todo_and_policy_inner(onto, todo, preserve_merges, save_policy, None)
    }

    /// Cancellable explicit interactive todo rebase.
    pub fn rebase_with_todo_and_policy_and_cancel(
        &self,
        onto: String,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_with_todo_and_policy_inner(
            onto,
            todo,
            preserve_merges,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_with_todo_and_policy_inner(
        &self,
        onto: String,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let onto_id = repo
                .rev_parse_single(BStr::new(onto.as_bytes()))
                .map_err(EngineError::from_gix)?
                .detach();
            let original_head = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach();
            let original_tree = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            if preserve_merges {
                // preserve-merges 走系统 git --rebase-merges 的原生 todo 机制：
                // merge 行只作为拓扑锚点展示，action 按 commit id 映射到
                // 原生非 merge 顺序；merge root 允许 reword，拓扑本身仍由 Git 控制。
                let native_order = rebase_merge_order(&repo, Some(onto_id), original_head, false)?;
                let plan = merge_preserving_action_plan(&repo, &native_order, &todo)?;
                drop(repo);
                return self.rebase_with_advanced_options_clean_and_merge_actions(
                    onto,
                    plan.non_merge_actions,
                    true,
                    false,
                    false,
                    false,
                    false,
                    None,
                    Some(encode_merge_reword_overrides(plan.merge_actions)),
                    Some(
                        plan.non_merge_order
                            .iter()
                            .map(|id| id.to_hex().to_string())
                            .collect(),
                    ),
                    cancel.clone(),
                );
            }
            let pairs = crate::rebasetodo::validate_to_pairs(&repo, onto_id, original_head, &todo)?;
            let onto_commit = repo.find_commit(onto_id).map_err(EngineError::from_gix)?;
            let start_tree = onto_commit
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            // pairs 顺序 = todo 顺序：拖拽排序/批量 action 的最终拓扑。
            execute_linear_rebase(
                &repo,
                onto_id,
                original_head,
                original_tree,
                start_tree,
                &pairs,
                cancel_token,
            )
        })
    }

    /// Drop selected commits directly from the current linear history.
    ///
    /// IntelliJ executes the Log "Drop Commits" action without opening the
    /// interactive todo editor when the selected commits are on one linear
    /// HEAD path. Build the same explicit todo here, but keep the validation
    /// and preservation boundary in Rust so callers cannot bypass it.
    pub fn drop_selected_commits(
        &self,
        commit_ids: Vec<String>,
    ) -> Result<RebaseOutcome, EngineError> {
        self.drop_selected_commits_with_policy(commit_ids, LocalChangesSavePolicy::Stash)
    }

    /// Drop selected commits using IntelliJ's configured local-changes policy.
    pub fn drop_selected_commits_with_policy(
        &self,
        commit_ids: Vec<String>,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        let (onto, todo, root_rebase) = build_drop_selected_commits_plan(self, commit_ids)?;
        if root_rebase {
            self.rebase_root_with_todo_and_policy(todo, false, save_policy)
        } else {
            self.rebase_with_todo_and_policy(
                onto.expect("non-root drop requires onto"),
                todo,
                false,
                save_policy,
            )
        }
    }

    /// Cancellable counterpart used by the Log action. The native fallback
    /// already has a cancellation boundary; the object-level path must honor
    /// the same user-owned cancel handle before and during replay.
    pub fn drop_selected_commits_with_policy_and_cancel(
        &self,
        commit_ids: Vec<String>,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        let (onto, todo, root_rebase) = build_drop_selected_commits_plan(self, commit_ids)?;
        if root_rebase {
            self.rebase_root_with_todo_and_policy_and_cancel(todo, false, save_policy, cancel)
        } else {
            self.rebase_with_todo_and_policy_and_cancel(
                onto.expect("non-root drop requires onto"),
                todo,
                false,
                save_policy,
                cancel,
            )
        }
    }

    /// Native Git counterpart used when IntelliJ's in-memory commit-editing
    /// operation pauses on a conflict. It consumes the same validated plan as
    /// the object-level path, so the fallback cannot silently rewrite a
    /// different range or selection.
    pub fn drop_selected_commits_native_with_policy_and_cancel(
        &self,
        commit_ids: Vec<String>,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        let (onto, todo, root_rebase) = build_drop_selected_commits_plan(self, commit_ids)?;
        let actions = todo
            .items
            .iter()
            .map(|item| match item.action {
                crate::rebasetodo::RebaseTodoAction::Pick => Ok(RebaseAction::Pick),
                crate::rebasetodo::RebaseTodoAction::Drop => Ok(RebaseAction::Drop),
                _ => Err(EngineError::GitOperation {
                    message: "drop selected commits produced an unsupported native action".into(),
                }),
            })
            .collect::<Result<Vec<_>, _>>()?;
        self.rebase_with_advanced_options_and_policy_and_cancel(
            onto.unwrap_or_default(),
            actions,
            false,
            false,
            false,
            false,
            root_rebase,
            save_policy,
            cancel,
        )
    }

    /// Execute a true root interactive rebase.  The todo order is authoritative
    /// for a linear history; merge-preserving mode keeps Git's native topology
    /// control rows in their generated order while applying the edited action
    /// for each non-merge commit.
    pub fn rebase_root_with_todo_and_policy(
        &self,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
        save_policy: LocalChangesSavePolicy,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_root_with_todo_and_policy_inner(todo, preserve_merges, save_policy, None)
    }

    /// Cancellable root interactive todo rebase.
    pub fn rebase_root_with_todo_and_policy_and_cancel(
        &self,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<RebaseOutcome, EngineError> {
        self.rebase_root_with_todo_and_policy_inner(
            todo,
            preserve_merges,
            save_policy,
            Some(cancel),
        )
    }

    fn rebase_root_with_todo_and_policy_inner(
        &self,
        todo: crate::rebasetodo::RebaseTodo,
        preserve_merges: bool,
        save_policy: LocalChangesSavePolicy,
        cancel: Option<Arc<crate::gitprocess::GitCancelHandle>>,
    ) -> Result<RebaseOutcome, EngineError> {
        let cancel_token = cancel
            .as_deref()
            .map(crate::gitprocess::GitCancelHandle::token);
        with_rebase_local_changes(self, save_policy, cancel_token, || {
            let repo = self.inner.lock().expect("repo mutex poisoned");
            ensure_history_change_operation_is_idle(&repo)?;
            let original_head = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .id()
                .detach();
            let original_tree = repo
                .head_commit()
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach();
            let native_order = if preserve_merges {
                rebase_merge_order(&repo, None, original_head, true)?
            } else {
                rebase_root_graph_order(&repo, None, original_head)?
            };
            let (actions, desired_order): (Vec<RebaseAction>, Option<Vec<_>>) = if preserve_merges {
                let plan = merge_preserving_action_plan(&repo, &native_order, &todo)?;
                return rebase_with_system_options(
                    &repo,
                    None,
                    original_head,
                    original_tree,
                    plan.non_merge_actions,
                    true,
                    false,
                    false,
                    false,
                    true,
                    None,
                    Some(&plan.non_merge_order),
                    Some(plan.merge_actions),
                    true,
                    cancel_token,
                );
            } else {
                let expected_ids: Vec<_> = native_order
                    .iter()
                    .copied()
                    .filter(|id| {
                        repo.find_commit(*id)
                            .map(|commit| commit.parent_ids().nth(1).is_none())
                            .unwrap_or(false)
                    })
                    .collect();
                let pairs =
                    crate::rebasetodo::validate_to_pairs_from_ids(&repo, &expected_ids, &todo)?;
                let action_ids: Vec<_> = todo
                    .items
                    .iter()
                    .map(|item| {
                        gix::hash::ObjectId::from_hex(item.commit_id.as_bytes()).map_err(|_| {
                            EngineError::GitOperation {
                                message: format!(
                                    "rebase todo: invalid commit id {}",
                                    item.commit_id
                                ),
                            }
                        })
                    })
                    .collect::<Result<_, _>>()?;
                let mut actions_by_id = HashMap::with_capacity(pairs.len());
                for (action, id) in pairs {
                    actions_by_id.insert(id, action);
                }
                let actions = action_ids
                    .iter()
                    .map(|id| {
                        actions_by_id
                            .remove(id)
                            .ok_or_else(|| EngineError::GitOperation {
                                message: format!("rebase todo: missing commit {}", id.to_hex()),
                            })
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                (actions, Some(action_ids))
            };
            rebase_with_system_options(
                &repo,
                None,
                original_head,
                original_tree,
                actions,
                preserve_merges,
                false,
                false,
                false,
                true,
                None,
                desired_order.as_deref(),
                None,
                true,
                cancel_token,
            )
        })
    }

    /// 中止被 edit 或 conflict 暂停的 rebase：恢复原 HEAD/工作区/索引并清状态。
    pub fn rebase_abort(&self) -> Result<(), EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        if system_rebase_active(&repo) {
            let result = finish_rebase_abort_locked(&repo, abort_system_rebase(&repo), None);
            if result.is_ok() {
                crate::conflict::clear_resolved_ledger(&repo);
            }
            return result;
        }
        let Some(state) = load_rebase_state(&repo)? else {
            return Err(EngineError::GitOperation {
                message: "rebase: no rebase in progress".into(),
            });
        };
        if matches!(state.reason, RebasePauseReason::Conflict) {
            restore_head_from_tree(&repo, state.original_head, Some(state.tree))?;
        } else {
            restore_head(&repo, state.original_head)?;
        }
        clear_rebase_state(&repo);
        let result = finish_rebase_abort_locked(&repo, Ok(()), None);
        crate::conflict::clear_resolved_ledger(&repo);
        result
    }

    // MARK: 托管集成（最小）

    /// 生成提交 permalink（GitHub / GitLab / Bitbucket）；不支持的远程返回 None。
    pub fn permalink(&self, remote_url: String, commit_id: String) -> Option<String> {
        let url = remote_url.trim().trim_end_matches(".git");
        if let Some(rest) = url
            .strip_prefix("https://github.com/")
            .or_else(|| url.strip_prefix("http://github.com/"))
            .or_else(|| url.strip_prefix("git@github.com:"))
            .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        {
            return Some(format!("https://github.com/{rest}/commit/{commit_id}"));
        }
        if let Some(rest) = url
            .strip_prefix("https://gitlab.com/")
            .or_else(|| url.strip_prefix("git@gitlab.com:"))
        {
            return Some(format!("https://gitlab.com/{rest}/-/commit/{commit_id}"));
        }
        if let Some(rest) = url
            .strip_prefix("https://bitbucket.org/")
            .or_else(|| url.strip_prefix("git@bitbucket.org:"))
        {
            return Some(format!("https://bitbucket.org/{rest}/commits/{commit_id}"));
        }
        None
    }

    /// 生成提交中某个文件的托管页面链接。
    ///
    /// IntelliJ 的 HostedGitRepositoryReference 不只作用于 Log 提交行，
    /// 也作用于 Changes Browser / File History 的文件 revision。路径按
    /// URL path segment 编码，但保留目录分隔符，避免空格、`#`、`?` 等合法
    /// Git 文件名改变链接含义。
    pub fn permalink_for_path(
        &self,
        remote_url: String,
        commit_id: String,
        path: String,
    ) -> Option<String> {
        let url = remote_url.trim().trim_end_matches(".git");
        let commit = commit_id.trim();
        let path = path.trim_matches('/');
        if commit.is_empty() || path.is_empty() || path.contains('\0') {
            return None;
        }

        let encoded_commit = percent_encode_path_component(commit)?;
        let encoded_path = percent_encode_git_path(path)?;

        if let Some(rest) = url
            .strip_prefix("https://github.com/")
            .or_else(|| url.strip_prefix("http://github.com/"))
            .or_else(|| url.strip_prefix("git@github.com:"))
            .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        {
            return Some(format!(
                "https://github.com/{rest}/blob/{encoded_commit}/{encoded_path}"
            ));
        }
        if let Some(rest) = url
            .strip_prefix("https://gitlab.com/")
            .or_else(|| url.strip_prefix("http://gitlab.com/"))
            .or_else(|| url.strip_prefix("git@gitlab.com:"))
            .or_else(|| url.strip_prefix("ssh://git@gitlab.com/"))
        {
            return Some(format!(
                "https://gitlab.com/{rest}/-/blob/{encoded_commit}/{encoded_path}"
            ));
        }
        if let Some(rest) = url
            .strip_prefix("https://bitbucket.org/")
            .or_else(|| url.strip_prefix("http://bitbucket.org/"))
            .or_else(|| url.strip_prefix("git@bitbucket.org:"))
            .or_else(|| url.strip_prefix("ssh://git@bitbucket.org/"))
        {
            return Some(format!(
                "https://bitbucket.org/{rest}/src/{encoded_commit}/{encoded_path}"
            ));
        }
        None
    }

    /// 生成打开 PR / merge request 的链接（GitHub / GitLab / Bitbucket）；不支持的远程返回 None。
    pub fn pr_url(&self, remote_url: String, branch: String) -> Option<String> {
        let url = remote_url.trim().trim_end_matches(".git");
        let branch = branch.trim();
        if branch.is_empty() || branch.contains('\0') {
            return None;
        }
        let encoded_branch = percent_encode_path_component(branch)?;
        if let Some(rest) = url
            .strip_prefix("https://github.com/")
            .or_else(|| url.strip_prefix("http://github.com/"))
            .or_else(|| url.strip_prefix("git@github.com:"))
            .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        {
            return Some(format!(
                "https://github.com/{rest}/compare/{encoded_branch}?expand=1"
            ));
        }
        if let Some(rest) = url
            .strip_prefix("https://gitlab.com/")
            .or_else(|| url.strip_prefix("http://gitlab.com/"))
            .or_else(|| url.strip_prefix("git@gitlab.com:"))
            .or_else(|| url.strip_prefix("ssh://git@gitlab.com/"))
        {
            return Some(format!(
                "https://gitlab.com/{rest}/-/merge_requests/new?merge_request%5Bsource_branch%5D={encoded_branch}"
            ));
        }
        if let Some(rest) = url
            .strip_prefix("https://bitbucket.org/")
            .or_else(|| url.strip_prefix("http://bitbucket.org/"))
            .or_else(|| url.strip_prefix("git@bitbucket.org:"))
            .or_else(|| url.strip_prefix("ssh://git@bitbucket.org/"))
        {
            return Some(format!(
                "https://bitbucket.org/{rest}/pull-requests/new?source={encoded_branch}"
            ));
        }
        None
    }

    /// 生成 issue 链接（GitHub / GitLab / Bitbucket）；不支持的远程返回 None。
    pub fn issue_url(&self, remote_url: String, number: u32) -> Option<String> {
        let url = remote_url.trim().trim_end_matches(".git");
        if let Some(rest) = url
            .strip_prefix("https://github.com/")
            .or_else(|| url.strip_prefix("http://github.com/"))
            .or_else(|| url.strip_prefix("git@github.com:"))
            .or_else(|| url.strip_prefix("ssh://git@github.com/"))
        {
            return Some(format!("https://github.com/{rest}/issues/{number}"));
        }
        if let Some(rest) = url
            .strip_prefix("https://gitlab.com/")
            .or_else(|| url.strip_prefix("git@gitlab.com:"))
        {
            return Some(format!("https://gitlab.com/{rest}/-/issues/{number}"));
        }
        if let Some(rest) = url
            .strip_prefix("https://bitbucket.org/")
            .or_else(|| url.strip_prefix("git@bitbucket.org:"))
        {
            return Some(format!("https://bitbucket.org/{rest}/issues/{number}"));
        }
        None
    }

    /// HEAD 版本文件的逐行 blame（行号、提交、作者、时间、摘要、文本）。
    pub fn blame(&self, path: String) -> Result<Vec<BlameLine>, EngineError> {
        self.blame_with_options(path, BlameOptions::default())
    }

    /// HEAD blame with the same whitespace, movement, and date options as
    /// IntelliJ's Git annotation gutter.
    pub fn blame_with_options(
        &self,
        path: String,
        options: BlameOptions,
    ) -> Result<Vec<BlameLine>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::blame::blame(&repo, &path, options)
    }

    /// 当前工作区文件的逐行 blame，保留未提交内容与行号。
    pub fn blame_worktree(&self, path: String) -> Result<Vec<BlameLine>, EngineError> {
        self.blame_worktree_with_options(path, BlameOptions::default())
    }

    /// Current-worktree blame with IntelliJ-compatible annotation options.
    pub fn blame_worktree_with_options(
        &self,
        path: String,
        options: BlameOptions,
    ) -> Result<Vec<BlameLine>, EngineError> {
        let repo = self.inner.lock().expect("repo mutex poisoned");
        crate::blame::blame_worktree(&repo, &path, options)
    }
}

fn normalize_commit_sequence(
    commit_ids: Vec<String>,
    operation: &str,
) -> Result<Vec<String>, EngineError> {
    let commit_ids = commit_ids
        .into_iter()
        .map(|commit_id| commit_id.trim().to_string())
        .filter(|commit_id| !commit_id.is_empty())
        .collect::<Vec<_>>();
    if commit_ids.is_empty()
        || commit_ids
            .iter()
            .any(|commit_id| commit_id.starts_with('-'))
    {
        return Err(EngineError::GitOperation {
            message: format!("{operation}: commit sequence must contain safe revision names"),
        });
    }
    Ok(commit_ids)
}

fn current_head_after_git_command(workdir: &Path) -> Result<String, EngineError> {
    current_head_for_category(workdir, crate::gitprocess::GitCommandCategory::Revert)
}

fn current_head_for_category(
    workdir: &Path,
    category: crate::gitprocess::GitCommandCategory,
) -> Result<String, EngineError> {
    let head_spec = crate::gitprocess::GitCommandSpec::new(category, "rev-parse")
        .arg("HEAD")
        .working_dir(workdir);
    let head = crate::gitprocess::run_to_completion(&head_spec)?;
    if !head.success() {
        return Err(head.into_error(&head_spec));
    }
    Ok(head.stdout.trim().to_string())
}

fn cherry_pick_state_exists(repo: &gix::Repository) -> bool {
    repo.git_dir().join("CHERRY_PICK_HEAD").exists() || repo.git_dir().join("sequencer").exists()
}

fn is_empty_cherry_pick_output(output: &str) -> bool {
    let output = output.to_ascii_lowercase();
    output.contains("previous cherry-pick is now empty")
        || output.contains("nothing to commit")
        || output.contains("nothing added to commit")
}

fn create_empty_cherry_pick_commit(
    repo: &gix::Repository,
    workdir: &Path,
) -> Result<(), EngineError> {
    let diff_spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::CherryPick,
        "diff",
    )
    .args(["--cached", "--quiet"])
    .working_dir(workdir);
    let staged = crate::gitprocess::run_to_completion(&diff_spec)?;
    if !staged.success() {
        return Err(EngineError::GitOperation {
            message: "cherry-pick: cannot create an empty commit while staged changes exist".into(),
        });
    }

    let cherry_pick_head = repo.git_dir().join("CHERRY_PICK_HEAD");
    if !cherry_pick_head.exists() {
        return Err(EngineError::GitOperation {
            message: "cherry-pick: empty commit has no CHERRY_PICK_HEAD state".into(),
        });
    }
    std::fs::remove_file(&cherry_pick_head).map_err(|error| EngineError::GitOperation {
        message: format!("cherry-pick: cannot clear CHERRY_PICK_HEAD: {error}"),
    })?;

    let message_file = repo.git_dir().join("MERGE_MSG");
    let mut commit_spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::CherryPick,
        "commit",
    )
    .arg("--allow-empty")
    .working_dir(workdir);
    if message_file.is_file() {
        commit_spec = commit_spec
            .arg("-F")
            .arg(message_file.to_string_lossy().into_owned());
    } else {
        commit_spec = commit_spec.arg("-m").arg("Cherry-pick empty commit");
    }
    let outcome = crate::gitprocess::run_to_completion(&commit_spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&commit_spec));
    }
    Ok(())
}

fn resolve_cherry_pick_sequence(
    repo: &gix::Repository,
    workdir: &Path,
    empty_policy: CherryPickEmptyPolicy,
    initial_failure: crate::gitprocess::GitProcessOutcome,
    initial_spec: crate::gitprocess::GitCommandSpec,
    commit_count: usize,
) -> Result<String, EngineError> {
    let initial_output = format!("{}\n{}", initial_failure.stdout, initial_failure.stderr);
    if !is_empty_cherry_pick_output(&initial_output) || !cherry_pick_state_exists(repo) {
        return Err(initial_failure.into_error(&initial_spec));
    }

    let max_empty_steps = commit_count.saturating_mul(2).max(1);
    for _ in 0..max_empty_steps {
        match empty_policy {
            CherryPickEmptyPolicy::Skip => {
                let (ok, output) = crate::opstate::run_recovery(
                    workdir,
                    crate::opstate::OperationKind::CherryPick,
                    crate::opstate::RecoveryAction::Skip,
                )?;
                if ok {
                    if !cherry_pick_state_exists(repo) {
                        return current_head_for_category(
                            workdir,
                            crate::gitprocess::GitCommandCategory::CherryPick,
                        );
                    }
                    continue;
                }
                if !is_empty_cherry_pick_output(&output) || !cherry_pick_state_exists(repo) {
                    return Err(EngineError::GitOperation {
                        message: format!("git cherry-pick --skip failed: {output}"),
                    });
                }
            }
            CherryPickEmptyPolicy::CreateEmpty => {
                create_empty_cherry_pick_commit(repo, workdir)?;
                if !cherry_pick_state_exists(repo) {
                    return current_head_for_category(
                        workdir,
                        crate::gitprocess::GitCommandCategory::CherryPick,
                    );
                }
                let (ok, output) = crate::opstate::run_recovery(
                    workdir,
                    crate::opstate::OperationKind::CherryPick,
                    crate::opstate::RecoveryAction::Continue,
                )?;
                if ok {
                    if !cherry_pick_state_exists(repo) {
                        return current_head_for_category(
                            workdir,
                            crate::gitprocess::GitCommandCategory::CherryPick,
                        );
                    }
                    continue;
                }
                if !is_empty_cherry_pick_output(&output) || !cherry_pick_state_exists(repo) {
                    return Err(EngineError::GitOperation {
                        message: format!("git cherry-pick --continue failed: {output}"),
                    });
                }
            }
        }
    }
    Err(EngineError::GitOperation {
        message: "cherry-pick: empty commit resolution exceeded the sequence limit".into(),
    })
}

fn continue_cherry_pick_sequence(
    repo: &gix::Repository,
    workdir: &Path,
    empty_policy: CherryPickEmptyPolicy,
) -> Result<(), EngineError> {
    for _ in 0..128 {
        let (ok, output) = crate::opstate::run_recovery(
            workdir,
            crate::opstate::OperationKind::CherryPick,
            crate::opstate::RecoveryAction::Continue,
        )?;
        if ok {
            return Ok(());
        }
        if !is_empty_cherry_pick_output(&output) || !cherry_pick_state_exists(repo) {
            return Err(EngineError::GitOperation {
                message: format!("git cherry-pick --continue failed: {output}"),
            });
        }
        match empty_policy {
            CherryPickEmptyPolicy::Skip => {
                let (skipped, skip_output) = crate::opstate::run_recovery(
                    workdir,
                    crate::opstate::OperationKind::CherryPick,
                    crate::opstate::RecoveryAction::Skip,
                )?;
                if !skipped
                    && (!is_empty_cherry_pick_output(&skip_output)
                        || !cherry_pick_state_exists(repo))
                {
                    return Err(EngineError::GitOperation {
                        message: format!("git cherry-pick --skip failed: {skip_output}"),
                    });
                }
                if skipped && !cherry_pick_state_exists(repo) {
                    return Ok(());
                }
            }
            CherryPickEmptyPolicy::CreateEmpty => {
                create_empty_cherry_pick_commit(repo, workdir)?;
                if !cherry_pick_state_exists(repo) {
                    return Ok(());
                }
            }
        }
    }
    Err(EngineError::GitOperation {
        message: "cherry-pick: continue exceeded the sequence limit".into(),
    })
}

/// cherry-pick/revert 恢复的实现（uniffi 导出块外，参数可用内部类型）。
fn pick_recovery_impl(
    repo: &gix::Repository,
    kind: crate::opstate::OperationKind,
    action: crate::opstate::RecoveryAction,
    name: &str,
) -> Result<(), EngineError> {
    let state_file = match kind {
        crate::opstate::OperationKind::CherryPick => "CHERRY_PICK_HEAD",
        crate::opstate::OperationKind::Revert => "REVERT_HEAD",
        _ => {
            return Err(EngineError::GitOperation {
                message: format!("{name}: unsupported recovery kind"),
            })
        }
    };
    if !repo.git_dir().join(state_file).exists() {
        return Err(EngineError::GitOperation {
            message: format!("{name}: no {name} in progress"),
        });
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: format!("{name}: requires a non-bare worktree"),
    })?;
    let (ok, output) = crate::opstate::run_recovery(workdir, kind, action)?;
    if !ok {
        let flag = match action {
            crate::opstate::RecoveryAction::Continue => "--continue",
            crate::opstate::RecoveryAction::Skip => "--skip",
            crate::opstate::RecoveryAction::Abort => "--abort",
        };
        return Err(EngineError::GitOperation {
            message: format!("git {name} {flag} failed: {output}"),
        });
    }
    crate::conflict::clear_resolved_ledger(repo);
    Ok(())
}

/// 跳过 conflict 暂停的当前步：把工作区/索引恢复到暂停点（state.tree），
/// 不提交当前步，从 state.head 继续应用剩余动作。失败时状态保留，
/// 用户仍可选择继续跳过、重试 continue 或 abort。
fn skip_conflicted_rebase(
    repo: &gix::Repository,
    state: &RebaseState,
) -> Result<RebaseOutcome, EngineError> {
    restore_head_from_tree(repo, state.head, Some(state.tree))?;
    let applied = apply_rebase_actions(repo, state.head, state.tree, &state.remaining, true, None);
    match applied {
        Ok(ApplyOutcome::Done { head, tree }) => {
            clear_rebase_state(repo);
            finalize_rebase(repo, state.tree, head, tree)?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: false,
                pause_reason: None,
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::Paused {
            head,
            tree,
            message,
            remaining,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head: state.original_head,
                    onto: state.onto,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Edit,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Edit),
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::PausedConflict {
            head,
            tree,
            message,
            remaining,
            conflicts,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head: state.original_head,
                    onto: state.onto,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Conflict,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Conflict),
                conflicts,
            })
        }
        Err(e) => Err(e),
    }
}

/// 继续一个 conflict 暂停：已解决的索引直接形成新提交（不是 amend），
/// 再从该提交继续应用剩余动作；未解决时保留暂停状态，方便用户返回编辑器。
fn continue_conflicted_rebase(
    repo: &gix::Repository,
    state: &RebaseState,
) -> Result<RebaseOutcome, EngineError> {
    let unresolved: Vec<String> = crate::status::compute_status(repo)?
        .into_iter()
        .filter(|entry| {
            entry.staged == crate::status::ChangeKind::Conflicted
                || entry.unstaged == crate::status::ChangeKind::Conflicted
        })
        .map(|entry| entry.path)
        .collect();
    if !unresolved.is_empty() {
        return Err(EngineError::GitOperation {
            message: format!("rebase: 仍有未解决冲突：{}", unresolved.join(", ")),
        });
    }

    let resolved_tree = index_tree(repo)?;
    let committed = commit_rebase_group(
        repo,
        &[state.message.clone()],
        resolved_tree,
        state.head,
        None,
    )?;
    let applied =
        apply_rebase_actions(repo, committed, resolved_tree, &state.remaining, true, None);
    match applied {
        Ok(ApplyOutcome::Done { head, tree }) => {
            clear_rebase_state(repo);
            finalize_rebase(repo, resolved_tree, head, tree)?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: false,
                pause_reason: None,
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::Paused {
            head,
            tree,
            message,
            remaining,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head: state.original_head,
                    onto: state.onto,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Edit,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Edit),
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::PausedConflict {
            head,
            tree,
            message,
            remaining,
            conflicts,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head: state.original_head,
                    onto: state.onto,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Conflict,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Conflict),
                conflicts,
            })
        }
        Err(error) => {
            // The resolution commit is provisional until the remaining actions
            // have been applied. A non-conflict error must not strand HEAD or
            // leave a stale rebase state behind.
            if let Err(restore_error) =
                restore_head_from_tree(repo, state.original_head, Some(resolved_tree))
            {
                clear_rebase_state(repo);
                return Err(restore_error);
            }
            clear_rebase_state(repo);
            Err(error)
        }
    }
}

/// 提交一个 rebase 组（首条 + squash 信息拼接）。
fn commit_rebase_group(
    repo: &gix::Repository,
    group: &[String],
    tree: gix::hash::ObjectId,
    head_id: gix::hash::ObjectId,
    message_override: Option<&str>,
) -> Result<gix::hash::ObjectId, EngineError> {
    let msg = message_override.map(str::to_owned).unwrap_or_else(|| {
        let mut msg = group[0].clone();
        for m in &group[1..] {
            msg.push_str(&format!("\n\n{m}"));
        }
        msg
    });
    let new_id = repo
        .commit("HEAD", &msg, tree, [head_id])
        .map_err(EngineError::from_gix)?
        .detach();
    Ok(new_id)
}

/// 使用指定 remote-tracking commit 执行 pull 的共同核心。
/// 调用方已完成 worktree dirty 检查和 fetch。
fn pull_tracking_locked(
    repo: &gix::Repository,
    branch: String,
    upstream_label: String,
    tracking_id: gix::hash::ObjectId,
    options: &PullOptions,
    ignored_paths: &[String],
) -> Result<MergeOutcome, EngineError> {
    if options.rebase && options.mode != MergeMode::FastForward {
        return Err(EngineError::GitOperation {
            message: "pull: rebase cannot be combined with merge strategy options".into(),
        });
    }
    if options.rebase && options.no_commit {
        return Err(EngineError::GitOperation {
            message: "pull: --no-commit cannot be combined with --rebase".into(),
        });
    }
    let head_commit = repo.head_commit().map_err(EngineError::from_gix)?;
    let head_id = head_commit.id().detach();
    if head_id == tracking_id {
        return Ok(MergeOutcome {
            conflicts: Vec::new(),
            updated_commits: 0,
            upstream: String::new(),
            branch: String::new(),
            completed: true,
            requires_finish: false,
            squashed: false,
        });
    }
    let upstream_reachable = reachable_from(repo, tracking_id)?;
    let head_reachable = reachable_from(repo, head_id)?;
    let updated_commits = upstream_reachable.difference(&head_reachable).count() as u32;
    if head_reachable.contains(&tracking_id) {
        return Ok(MergeOutcome {
            conflicts: Vec::new(),
            updated_commits: 0,
            upstream: String::new(),
            branch: String::new(),
            completed: true,
            requires_finish: false,
            squashed: false,
        });
    }
    let head_tree = head_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let tracking_tree = repo
        .find_commit(tracking_id)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    if upstream_reachable.contains(&head_id)
        && matches!(
            options.mode,
            MergeMode::FastForward | MergeMode::FastForwardOnly
        )
    {
        crate::merge::guard_uncommitted_overwrite_ignoring_paths(
            repo,
            head_tree,
            tracking_tree,
            ignored_paths,
        )?;
        move_head_to(repo, tracking_id)?;
        finalize_rebase_with_ignored_paths(
            repo,
            head_tree,
            tracking_id,
            tracking_tree,
            ignored_paths,
        )?;
        return Ok(MergeOutcome {
            conflicts: Vec::new(),
            updated_commits,
            upstream: upstream_label,
            branch: branch.clone(),
            completed: true,
            requires_finish: false,
            squashed: false,
        });
    }
    if options.rebase {
        crate::merge::guard_uncommitted_overwrite_ignoring_paths(
            repo,
            head_tree,
            tracking_tree,
            ignored_paths,
        )?;
        let outcome = pull_rebase_locked(repo, tracking_id, &upstream_label)?;
        return Ok(MergeOutcome {
            conflicts: outcome.conflicts,
            updated_commits,
            upstream: upstream_label,
            branch,
            completed: !outcome.paused,
            requires_finish: outcome.paused,
            squashed: false,
        });
    }

    if options.mode == MergeMode::FastForwardOnly {
        return Err(EngineError::GitOperation {
            message: "pull: fast-forward only is not possible".into(),
        });
    }

    let outcome = crate::merge::apply_merge_with_ancestor_ignoring_paths(
        repo,
        tracking_id,
        &upstream_label,
        None,
        ignored_paths,
    )?;
    save_merge_state(
        repo,
        head_id,
        tracking_id,
        &upstream_label,
        &format!("Merge remote-tracking branch '{upstream_label}'"),
        options.mode,
        options.no_verify,
    )?;
    if outcome.conflicts.is_empty() && !options.no_commit {
        let msg = format!("Merge remote-tracking branch '{upstream_label}'");
        let parents = match options.mode {
            MergeMode::Squash => vec![head_id],
            MergeMode::FastForward | MergeMode::FastForwardOnly | MergeMode::NoFastForward => {
                vec![head_id, tracking_id]
            }
        };
        commit_inner(repo, &msg, &parents, options.no_verify)?;
        clear_merge_state(repo);
    }
    Ok(MergeOutcome {
        conflicts: outcome.conflicts.clone(),
        updated_commits,
        upstream: upstream_label,
        branch,
        completed: outcome.conflicts.is_empty() && !options.no_commit,
        requires_finish: !outcome.conflicts.is_empty() || options.no_commit,
        squashed: options.mode == MergeMode::Squash,
    })
}

fn reachable_from(
    repo: &gix::Repository,
    start: gix::hash::ObjectId,
) -> Result<HashSet<gix::hash::ObjectId>, EngineError> {
    let mut stack = vec![start];
    let mut seen = HashSet::new();
    while let Some(id) = stack.pop() {
        if !seen.insert(id) {
            continue;
        }
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        stack.extend(commit.parent_ids().map(|parent| parent.detach()));
    }
    Ok(seen)
}

/// Summarize the fetched upstream range without making notification data a
/// reason for the actual branch update to fail. IntelliJ's UpdateSession
/// counts commits in the UpdateSession range-start..new-tip range and reports the changed paths
/// in the endpoint diff with rename detection disabled; a force-pushed range
/// may not be linear, so the hidden old tip is used instead of assuming
/// ancestry.
fn force_pushed_update_summary(
    repo: &gix::Repository,
    old_tip: Option<gix::hash::ObjectId>,
    new_tip: gix::hash::ObjectId,
) -> (u32, u32) {
    let Some(old_tip) = old_tip else {
        return (0, 0);
    };

    let received_commits_count = repo
        .rev_walk([new_tip])
        .with_hidden([old_tip])
        .all()
        .map(|walk| walk.filter_map(Result::ok).count() as u32)
        .unwrap_or(0);
    let updated_files_count = (|| {
        let old_tree = repo.find_commit(old_tip).ok()?.tree_id().ok()?.detach();
        let new_tree = repo.find_commit(new_tip).ok()?.tree_id().ok()?.detach();
        let changes = crate::tree::diff_trees(repo, old_tree, new_tree).ok()?;
        let mut paths = HashSet::new();
        for change in changes {
            paths.insert(change.path);
            if let Some(old_path) = change.old_path {
                paths.insert(old_path);
            }
        }
        Some(paths.len() as u32)
    })()
    .unwrap_or(0);

    (received_commits_count, updated_files_count)
}

/// 递归产生 parent→child 的稳定拓扑序。
fn visit_rebase_graph(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
    range: &HashSet<gix::hash::ObjectId>,
    visited: &mut HashSet<gix::hash::ObjectId>,
    order: &mut Vec<gix::hash::ObjectId>,
) -> Result<(), EngineError> {
    if !range.contains(&id) || !visited.insert(id) {
        return Ok(());
    }
    let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
    for parent in commit.parent_ids() {
        visit_rebase_graph(repo, parent.detach(), range, visited, order)?;
    }
    order.push(id);
    Ok(())
}

fn rebase_graph_order(
    repo: &gix::Repository,
    onto: gix::hash::ObjectId,
    original_head: gix::hash::ObjectId,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    let head_reachable = reachable_from(repo, original_head)?;
    if !head_reachable.contains(&onto) {
        return Err(EngineError::GitOperation {
            message: "rebase: onto is not an ancestor of HEAD".into(),
        });
    }
    let onto_reachable = reachable_from(repo, onto)?;
    let range: HashSet<_> = head_reachable
        .difference(&onto_reachable)
        .copied()
        .collect();
    let mut visited = HashSet::new();
    let mut order = Vec::with_capacity(range.len());
    visit_rebase_graph(repo, original_head, &range, &mut visited, &mut order)?;
    Ok(order)
}

/// `--root` 的拓扑范围：允许 onto 不在 HEAD 历史中，并排除 onto 已经
/// 包含的对象。这样生成的非 merge 集合与 Git 原生 `rebase --root` 的
/// interactive todo 一致，也能覆盖把当前历史移植到另一条独立历史。
fn rebase_root_graph_order(
    repo: &gix::Repository,
    onto: Option<gix::hash::ObjectId>,
    original_head: gix::hash::ObjectId,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    let head_reachable = reachable_from(repo, original_head)?;
    let range: HashSet<_> = match onto {
        Some(onto) => {
            let onto_reachable = reachable_from(repo, onto)?;
            head_reachable
                .difference(&onto_reachable)
                .copied()
                .collect()
        }
        None => head_reachable.clone(),
    };
    let mut visited = HashSet::new();
    let mut order = Vec::with_capacity(range.len());
    visit_rebase_graph(repo, original_head, &range, &mut visited, &mut order)?;
    Ok(order)
}

/// 产生与 Git `--rebase-merges` todo 相同的 commit 拓扑顺序。
///
/// Git 会先展开 merge 的第二父分支，随后展开第一父分支，最后执行
/// merge 控制行。Arbor 用 merge commit 行标识不可编辑的 merge 控制位置，
/// 但必须保留这个顺序，避免 UI 列表与 Git 的拓扑语义分离。
fn visit_rebase_merge_order(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
    range: &HashSet<gix::hash::ObjectId>,
    visited: &mut HashSet<gix::hash::ObjectId>,
    order: &mut Vec<gix::hash::ObjectId>,
) -> Result<(), EngineError> {
    if !range.contains(&id) || !visited.insert(id) {
        return Ok(());
    }
    let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
    let mut parents = commit.parent_ids();
    let Some(first_parent) = parents.next() else {
        order.push(id);
        return Ok(());
    };
    let secondary_parents = parents.map(|parent| parent.detach()).collect::<Vec<_>>();
    for parent in secondary_parents {
        visit_rebase_merge_order(repo, parent, range, visited, order)?;
    }
    visit_rebase_merge_order(repo, first_parent.detach(), range, visited, order)?;
    order.push(id);
    Ok(())
}

fn rebase_merge_order(
    repo: &gix::Repository,
    onto: Option<gix::hash::ObjectId>,
    original_head: gix::hash::ObjectId,
    root: bool,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    let head_reachable = reachable_from(repo, original_head)?;
    if !root && !onto.is_some_and(|onto| head_reachable.contains(&onto)) {
        return Err(EngineError::GitOperation {
            message: "rebase: onto is not an ancestor of HEAD".into(),
        });
    }
    let range: HashSet<_> = match onto {
        Some(onto) => {
            let onto_reachable = reachable_from(repo, onto)?;
            head_reachable
                .difference(&onto_reachable)
                .copied()
                .collect()
        }
        None => head_reachable.clone(),
    };
    let mut visited = HashSet::new();
    let mut order = Vec::with_capacity(range.len());
    visit_rebase_merge_order(repo, original_head, &range, &mut visited, &mut order)?;
    Ok(order)
}

struct MergePreservingActionPlan {
    non_merge_actions: Vec<RebaseAction>,
    non_merge_order: Vec<gix::hash::ObjectId>,
    merge_actions: HashMap<gix::hash::ObjectId, RebaseAction>,
}

fn merge_preserving_action_plan(
    repo: &gix::Repository,
    native_order: &[gix::hash::ObjectId],
    todo: &crate::rebasetodo::RebaseTodo,
) -> Result<MergePreservingActionPlan, EngineError> {
    if todo.items.len() != native_order.len() {
        return Err(EngineError::GitOperation {
            message: format!(
                "rebase todo: {} items for {} rows in native merge order",
                todo.items.len(),
                native_order.len()
            ),
        });
    }
    let expected_set: HashSet<_> = native_order.iter().copied().collect();
    let mut items_by_id = HashMap::with_capacity(todo.items.len());
    for (index, item) in todo.items.iter().enumerate() {
        let id = gix::hash::ObjectId::from_hex(item.commit_id.as_bytes()).map_err(|_| {
            EngineError::GitOperation {
                message: format!("rebase todo: invalid commit id {}", item.commit_id),
            }
        })?;
        if !expected_set.contains(&id) {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: commit {} is not in the native merge-preserving order",
                    id.to_hex()
                ),
            });
        }
        let is_merge_commit = repo
            .find_commit(id)
            .map_err(EngineError::from_gix)?
            .parent_ids()
            .nth(1)
            .is_some();
        if item.is_merge_commit != is_merge_commit {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: merge-row marker mismatch for commit {}",
                    id.to_hex()
                ),
            });
        }
        if items_by_id.insert(id, index).is_some() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: duplicate commit {} in merge-preserving todo",
                    id.to_hex()
                ),
            });
        }
    }
    let item_indices_by_id = items_by_id;
    let native_merge_flags: Vec<bool> = native_order
        .iter()
        .map(|id| {
            repo.find_commit(*id)
                .map_err(EngineError::from_gix)
                .map(|commit| commit.parent_ids().nth(1).is_some())
        })
        .collect::<Result<_, _>>()?;

    // Merge rows are the visible anchors for Git's hidden label/reset/merge
    // block. Keep those anchors at their original positions and compare each
    // contiguous branch segment by set, which permits local row reordering
    // without allowing a commit to cross a topology boundary.
    for (index, ((native_id, is_merge), item)) in native_order
        .iter()
        .zip(&native_merge_flags)
        .zip(&todo.items)
        .enumerate()
    {
        let item_id = gix::hash::ObjectId::from_hex(item.commit_id.as_bytes()).map_err(|_| {
            EngineError::GitOperation {
                message: format!("rebase todo: invalid commit id {}", item.commit_id),
            }
        })?;
        if item.is_merge_commit != *is_merge {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: merge-row marker mismatch for commit {}",
                    item.commit_id
                ),
            });
        }
        if *is_merge && item_id != *native_id {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: merge control row at position {} cannot be moved",
                    index + 1
                ),
            });
        }
    }

    let mut segment_ranges = Vec::new();
    let mut segment_start = None;
    for index in 0..native_order.len() {
        if native_merge_flags[index] {
            if let Some(start) = segment_start.take() {
                segment_ranges.push(start..index);
            }
            continue;
        }
        let starts_segment = if index == 0 || native_merge_flags[index - 1] {
            true
        } else {
            let previous_id = native_order[index - 1];
            let first_parent = repo
                .find_commit(native_order[index])
                .map_err(EngineError::from_gix)?
                .parent_ids()
                .next()
                .map(|parent| parent.detach());
            first_parent != Some(previous_id)
        };
        if starts_segment {
            if let Some(start) = segment_start.replace(index) {
                segment_ranges.push(start..index);
            }
        }
    }
    if let Some(start) = segment_start {
        segment_ranges.push(start..native_order.len());
    }
    for range in segment_ranges {
        let native_ids: HashSet<_> = native_order[range.clone()].iter().copied().collect();
        let todo_ids: HashSet<_> = todo.items[range.clone()]
            .iter()
            .map(|item| {
                gix::hash::ObjectId::from_hex(item.commit_id.as_bytes()).map_err(|_| {
                    EngineError::GitOperation {
                        message: format!("rebase todo: invalid commit id {}", item.commit_id),
                    }
                })
            })
            .collect::<Result<_, _>>()?;
        if native_ids != todo_ids {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: rows cannot cross a merge control boundary (segment {}..{})",
                    range.start + 1,
                    range.end
                ),
            });
        }
    }

    let non_merge_order: Vec<_> = todo
        .items
        .iter()
        .filter(|item| !item.is_merge_commit)
        .map(|item| {
            gix::hash::ObjectId::from_hex(item.commit_id.as_bytes()).map_err(|_| {
                EngineError::GitOperation {
                    message: format!("rebase todo: invalid commit id {}", item.commit_id),
                }
            })
        })
        .collect::<Result<_, _>>()?;

    let mut non_merge_actions = Vec::with_capacity(non_merge_order.len());
    let mut merge_actions = HashMap::new();
    for id in native_order {
        let index = *item_indices_by_id
            .get(id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!(
                    "rebase todo: missing commit {} from merge-preserving todo",
                    id.to_hex()
                ),
            })?;
        let item = &todo.items[index];
        if !item.is_merge_commit {
            continue;
        }
        let action = match item.action {
            crate::rebasetodo::RebaseTodoAction::Pick if item.message.is_none() => {
                RebaseAction::Pick
            }
            crate::rebasetodo::RebaseTodoAction::Reword => RebaseAction::Reword {
                message: match &item.message {
                    Some(message) => message.clone(),
                    None => crate::rebasetodo::commit_title(repo, *id)?,
                },
            },
            _ => {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "rebase todo: merge commit {} must remain pick or reword",
                        id.to_hex()
                    ),
                });
            }
        };
        merge_actions.insert(*id, action);
    }

    // Actions must follow the edited visible order. The sequence editor uses
    // the same order file to put those actions back into the native pick
    // slots; topology controls stay anchored, while each pick's contiguous
    // update-ref block moves with that pick.
    for id in &non_merge_order {
        let index = *item_indices_by_id
            .get(id)
            .ok_or_else(|| EngineError::GitOperation {
                message: format!(
                    "rebase todo: missing commit {} from merge-preserving todo",
                    id.to_hex()
                ),
            })?;
        let item = &todo.items[index];
        let previous_item = index
            .checked_sub(1)
            .and_then(|previous| todo.items.get(previous));
        let previous_id = previous_item
            .map(|previous| {
                gix::hash::ObjectId::from_hex(previous.commit_id.as_bytes()).map_err(|_| {
                    EngineError::GitOperation {
                        message: format!("rebase todo: invalid commit id {}", previous.commit_id),
                    }
                })
            })
            .transpose()?;
        let first_parent = repo
            .find_commit(*id)
            .map_err(EngineError::from_gix)?
            .parent_ids()
            .next()
            .map(|parent| parent.detach());
        let action = match item.action {
            crate::rebasetodo::RebaseTodoAction::Pick => RebaseAction::Pick,
            crate::rebasetodo::RebaseTodoAction::Drop => RebaseAction::Drop,
            crate::rebasetodo::RebaseTodoAction::Edit => RebaseAction::Edit,
            crate::rebasetodo::RebaseTodoAction::Squash
            | crate::rebasetodo::RebaseTodoAction::Fixup => {
                if previous_item
                    .map(|previous| previous.is_merge_commit)
                    .unwrap_or(true)
                    || first_parent != previous_id
                {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "rebase todo: squash/fixup for merge-preserving commit {} crosses a merge control row or branch boundary",
                            id.to_hex()
                        ),
                    });
                }
                if matches!(
                    previous_item.map(|previous| previous.action),
                    Some(crate::rebasetodo::RebaseTodoAction::Drop)
                ) {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "rebase todo: squash/fixup for merge-preserving commit {} has no valid kept predecessor",
                            id.to_hex()
                        ),
                    });
                }
                match item.action {
                    crate::rebasetodo::RebaseTodoAction::Squash => match item
                        .message
                        .as_deref()
                        .map(str::trim)
                        .filter(|message| !message.is_empty())
                    {
                        Some(message) => RebaseAction::SquashWithMessage {
                            message: message.to_string(),
                        },
                        None => RebaseAction::Squash,
                    },
                    crate::rebasetodo::RebaseTodoAction::Fixup => RebaseAction::Fixup,
                    _ => unreachable!(),
                }
            }
            crate::rebasetodo::RebaseTodoAction::Reword => match &item.message {
                Some(message) => RebaseAction::Reword {
                    message: message.clone(),
                },
                None => RebaseAction::Reword {
                    message: crate::rebasetodo::commit_title(repo, *id)?,
                },
            },
        };
        non_merge_actions.push(action);
    }
    Ok(MergePreservingActionPlan {
        non_merge_actions,
        non_merge_order,
        merge_actions,
    })
}

#[allow(dead_code)]
fn replay_merge_tree(
    repo: &gix::Repository,
    original_merge: &gix::Commit<'_>,
    ours_tree: gix::hash::ObjectId,
    theirs_tree: gix::hash::ObjectId,
) -> Result<gix::hash::ObjectId, EngineError> {
    use gix::merge::blob::builtin_driver::text::Labels;
    use gix::merge::blob::Resolution;

    let mut parents = original_merge.parent_ids();
    let first = parents
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "rebase: merge commit has no first parent".into(),
        })?
        .detach();
    let second = parents
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "rebase: merge commit has no second parent".into(),
        })?
        .detach();
    let base = repo
        .merge_base(first, second)
        .map_err(EngineError::from_gix)?
        .detach();
    let ancestor_tree = repo
        .find_commit(base)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let labels = Labels {
        ancestor: Some(BStr::new("merge-base")),
        current: Some(BStr::new("ours")),
        other: Some(BStr::new("theirs")),
    };
    let options = repo.tree_merge_options().map_err(EngineError::from_gix)?;
    let mut outcome = repo
        .merge_trees(ancestor_tree, ours_tree, theirs_tree, labels, options)
        .map_err(EngineError::from_gix)?;
    if outcome.conflicts.iter().any(|conflict| {
        conflict
            .content_merge()
            .map(|merge| merge.resolution == Resolution::Conflict)
            .unwrap_or(false)
    }) {
        return Err(EngineError::GitOperation {
            message: "rebase: conflict while replaying merge commit".into(),
        });
    }
    outcome
        .tree
        .write()
        .map_err(EngineError::from_gix)
        .map(|tree| tree.detach())
}

/// 使用 Git 原生 interactive todo 执行需要 Git 原生语义的 rebase。
///
/// Merge label/reset/merge 行、squash/fixup、edit 和冲突恢复全部交给 Git
/// 管理；Arbor 只把用户动作映射到 todo，并把 continue/abort 状态转换成
/// 现有 RebaseOutcome。
fn encode_merge_reword_overrides(
    actions: HashMap<gix::hash::ObjectId, RebaseAction>,
) -> Vec<String> {
    actions
        .into_iter()
        .filter_map(|(id, action)| match action {
            RebaseAction::Reword { message } => Some(format!("{}\n{message}", id.to_hex())),
            RebaseAction::Pick => None,
            RebaseAction::Drop
            | RebaseAction::Edit
            | RebaseAction::Squash
            | RebaseAction::SquashWithMessage { .. }
            | RebaseAction::Fixup => None,
        })
        .collect()
}

fn parse_merge_reword_overrides(
    values: &[String],
) -> Result<HashMap<gix::hash::ObjectId, RebaseAction>, EngineError> {
    let mut actions = HashMap::with_capacity(values.len());
    for value in values {
        let (id, message) = value
            .split_once('\n')
            .ok_or_else(|| EngineError::GitOperation {
                message: "rebase todo: malformed merge reword override".into(),
            })?;
        let id = gix::hash::ObjectId::from_hex(id.as_bytes()).map_err(|_| {
            EngineError::GitOperation {
                message: format!("rebase todo: invalid merge commit id {id}"),
            }
        })?;
        if actions
            .insert(
                id,
                RebaseAction::Reword {
                    message: message.to_string(),
                },
            )
            .is_some()
        {
            return Err(EngineError::GitOperation {
                message: format!("rebase todo: duplicate merge reword override {id}"),
            });
        }
    }
    Ok(actions)
}

fn validate_rebase_branch_name(branch: String) -> Result<String, EngineError> {
    let branch = branch.trim().to_string();
    if branch.is_empty() || branch.starts_with('-') || branch == "HEAD" {
        return Err(EngineError::GitOperation {
            message: "rebase branch must be a non-HEAD revision and must not start with '-'".into(),
        });
    }
    Ok(branch)
}

fn build_drop_selected_commits_plan(
    repository: &Repository,
    commit_ids: Vec<String>,
) -> Result<(Option<String>, crate::rebasetodo::RebaseTodo, bool), EngineError> {
    if commit_ids.is_empty() {
        return Err(EngineError::GitOperation {
            message: "drop selected commits requires at least one commit".into(),
        });
    }

    let repo = repository.inner.lock().expect("repo mutex poisoned");
    ensure_history_change_operation_is_idle(&repo)?;
    let requested = commit_ids
        .iter()
        .map(|value| {
            repo.rev_parse_single(BStr::new(value.trim().as_bytes()))
                .map(|id| id.detach())
                .map_err(EngineError::from_gix)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut requested_set = HashSet::with_capacity(requested.len());
    for id in requested {
        if !requested_set.insert(id) {
            return Err(EngineError::GitOperation {
                message: format!("drop selected commits contains duplicate {}", id.to_hex()),
            });
        }
    }

    let head = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let mut reverse_path = Vec::new();
    let mut remaining = requested_set.clone();
    let mut cursor = head;
    loop {
        let commit = repo.find_commit(cursor).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|id| id.detach()).collect();
        if parents.len() > 1 {
            return Err(EngineError::GitOperation {
                message: format!(
                    "drop selected commits requires a linear current branch; merge commit {} is in the rewrite range",
                    cursor.to_hex()
                ),
            });
        }
        reverse_path.push(cursor);
        remaining.remove(&cursor);
        if remaining.is_empty() {
            break;
        }
        let Some(parent) = parents.first().copied() else {
            break;
        };
        cursor = parent;
    }
    if !remaining.is_empty() {
        return Err(EngineError::GitOperation {
            message: "drop selected commits are not on the current branch history".into(),
        });
    }
    let oldest = *reverse_path.last().expect("selected history is not empty");
    let oldest_commit = repo.find_commit(oldest).map_err(EngineError::from_gix)?;
    let onto_id = oldest_commit.parent_ids().next().map(|id| id.detach());
    let root_rebase = onto_id.is_none();
    let onto = onto_id.map(|id| id.to_hex().to_string());
    let mut range = reverse_path;
    range.reverse();
    let mut todo = if root_rebase {
        crate::rebasetodo::build_todo_from_ids_without_onto(&repo, range, false)?
    } else {
        crate::rebasetodo::build_todo_from_ids(
            &repo,
            gix::hash::ObjectId::from_hex(
                onto.as_deref()
                    .expect("non-root drop requires onto")
                    .as_bytes(),
            )
            .map_err(EngineError::from_gix)?,
            range,
            false,
        )?
    };
    let mut mapped = HashSet::with_capacity(todo.items.len());
    for item in &mut todo.items {
        let id = gix::hash::ObjectId::from_hex(item.commit_id.as_bytes())
            .map_err(EngineError::from_gix)?;
        mapped.insert(id);
        if requested_set.contains(&id) {
            item.action = crate::rebasetodo::RebaseTodoAction::Drop;
            item.message = None;
        }
    }
    if !requested_set.is_subset(&mapped) {
        return Err(EngineError::GitOperation {
            message: "drop selected commits could not be mapped to the rebase todo".into(),
        });
    }
    Ok((onto, todo, root_rebase))
}

fn resolve_rebase_onto(
    repo: &gix::Repository,
    onto: &str,
    root: bool,
) -> Result<Option<gix::hash::ObjectId>, EngineError> {
    if onto.trim().is_empty() {
        if !root {
            return Err(EngineError::GitOperation {
                message: "rebase: a non-root rebase requires an onto revision".into(),
            });
        }
        return Ok(None);
    }
    repo.rev_parse_single(BStr::new(onto.trim().as_bytes()))
        .map(|id| Some(id.detach()))
        .map_err(EngineError::from_gix)
}

fn native_rebase_command_spec(
    workdir: &std::path::Path,
    onto: Option<gix::hash::ObjectId>,
    preserve_merges: bool,
    auto_squash: bool,
    keep_empty: bool,
    update_refs: bool,
    root: bool,
    branch: Option<&str>,
    interactive: bool,
) -> Result<crate::gitprocess::GitCommandSpec, EngineError> {
    let mut spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Rebase,
        "rebase",
    )
    .working_dir(workdir);
    if interactive {
        spec = spec.arg("--interactive");
    }
    if preserve_merges {
        spec = spec.arg("--rebase-merges");
    }
    if keep_empty {
        spec = spec.arg("--keep-empty");
    }
    if update_refs {
        spec = spec.arg("--update-refs");
    }
    if let Some(onto) = onto {
        spec = spec.arg("--onto").arg(onto.to_hex().to_string());
    }
    if root {
        spec = spec.arg("--root");
    } else {
        spec = spec.arg(
            onto.ok_or_else(|| EngineError::GitOperation {
                message: "rebase: non-root rebase requires an onto revision".into(),
            })?
            .to_hex()
            .to_string(),
        );
    }
    if let Some(branch) = branch {
        spec = spec.arg(branch);
    }
    if auto_squash {
        spec = spec.arg("--autosquash");
    }
    Ok(spec)
}

fn capture_raw_rebase_todo(
    repo: &gix::Repository,
    onto: Option<gix::hash::ObjectId>,
    _original_head: gix::hash::ObjectId,
    preserve_merges: bool,
    auto_squash: bool,
    keep_empty: bool,
    update_refs: bool,
    root: bool,
    branch: Option<&str>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<String, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "rebase requires a non-bare worktree".into(),
    })?;
    let support = repo.git_dir().join("arbor-rebase-support");
    cleanup_system_rebase_support(repo);
    std::fs::create_dir_all(&support).map_err(EngineError::from_gix)?;
    let capture = support.join("raw-todo.capture");
    let editor = support.join("raw-sequence-editor.sh");
    let _ = std::fs::remove_file(&capture);
    write_raw_rebase_capture_editor(&editor, &capture)?;

    let mut command = native_rebase_command_spec(
        workdir,
        onto,
        preserve_merges,
        auto_squash,
        keep_empty,
        update_refs,
        root,
        branch,
        true,
    )?;
    command = command.env("GIT_SEQUENCE_EDITOR", editor.to_string_lossy().into_owned());
    let output = crate::gitprocess::run(&command, cancel, |_| {})?;
    if output.cancelled {
        if system_rebase_active(repo) {
            return Err(EngineError::Cancelled);
        }
        cleanup_system_rebase_support(repo);
        return Err(EngineError::Cancelled);
    }
    let captured = if capture.exists() {
        Some(std::fs::read_to_string(&capture).map_err(EngineError::from_gix)?)
    } else {
        None
    };
    if system_rebase_active(repo) {
        return Err(EngineError::GitOperation {
            message: "rebase todo capture left an active native rebase; abort it before retrying"
                .into(),
        });
    }
    cleanup_system_rebase_support(repo);
    if let Some(raw_todo) = captured {
        return Ok(raw_todo);
    }
    Err(EngineError::GitOperation {
        message: format!(
            "git rebase did not produce a todo file: {}",
            git_process_output_message(&output)
        ),
    })
}

fn prepare_raw_rebase_todo_command(
    repo: &gix::Repository,
    onto: Option<gix::hash::ObjectId>,
    _original_head: gix::hash::ObjectId,
    raw_todo: String,
    preserve_merges: bool,
    auto_squash: bool,
    keep_empty: bool,
    update_refs: bool,
    root: bool,
    branch: Option<&str>,
) -> Result<crate::gitprocess::GitCommandSpec, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "rebase requires a non-bare worktree".into(),
    })?;
    let support = repo.git_dir().join("arbor-rebase-support");
    cleanup_system_rebase_support(repo);
    std::fs::create_dir_all(&support).map_err(EngineError::from_gix)?;
    let input = support.join("raw-todo.input");
    let editor = support.join("raw-sequence-editor.sh");
    let message_editor = support.join("raw-message-editor.sh");
    std::fs::write(&input, raw_todo).map_err(EngineError::from_gix)?;
    write_raw_rebase_editor(&editor, &input, true)?;
    write_raw_rebase_message_editor(&message_editor, &support)?;

    let mut command = native_rebase_command_spec(
        workdir,
        onto,
        preserve_merges,
        auto_squash,
        keep_empty,
        update_refs,
        root,
        branch,
        true,
    )?;
    command = command
        .env("GIT_SEQUENCE_EDITOR", editor.to_string_lossy().into_owned())
        .env("GIT_EDITOR", message_editor.to_string_lossy().into_owned());
    Ok(command)
}

fn write_raw_rebase_editor(
    editor: &std::path::Path,
    source: &std::path::Path,
    success: bool,
) -> Result<(), EngineError> {
    use std::os::unix::fs::PermissionsExt;
    let source = shell_quote_for_script(source);
    let ending = if success { "0" } else { "1" };
    let script = format!(
        "#!/bin/sh\nset -eu\ncp {source} \"$1\"\nexit {ending}\n",
        source = source,
        ending = ending
    );
    std::fs::write(editor, script).map_err(EngineError::from_gix)?;
    let mut permissions = std::fs::metadata(editor)
        .map_err(EngineError::from_gix)?
        .permissions();
    permissions.set_mode(0o700);
    std::fs::set_permissions(editor, permissions).map_err(EngineError::from_gix)
}

fn write_raw_rebase_capture_editor(
    editor: &std::path::Path,
    destination: &std::path::Path,
) -> Result<(), EngineError> {
    use std::os::unix::fs::PermissionsExt;
    let destination = shell_quote_for_script(destination);
    let script = format!(
        "#!/bin/sh\nset -eu\ncp \"$1\" {destination}\nexit 1\n",
        destination = destination
    );
    std::fs::write(editor, script).map_err(EngineError::from_gix)?;
    let mut permissions = std::fs::metadata(editor)
        .map_err(EngineError::from_gix)?
        .permissions();
    permissions.set_mode(0o700);
    std::fs::set_permissions(editor, permissions).map_err(EngineError::from_gix)
}

fn write_raw_rebase_message_editor(
    editor: &std::path::Path,
    support: &std::path::Path,
) -> Result<(), EngineError> {
    use std::os::unix::fs::PermissionsExt;
    let support = shell_quote_for_script(support);
    let script = format!(
        "#!/bin/sh\nset -eu\nrequest={support}/raw-message.request\nresponse={support}/raw-message.response\ncancel={support}/raw-message.cancel\nrm -f \"$request\" \"$response\" \"$cancel\"\ncp \"$1\" \"$request\"\nwhile [ ! -f \"$response\" ] && [ ! -f \"$cancel\" ]; do\n  sleep 0.1\ndone\nif [ -f \"$cancel\" ]; then\n  rm -f \"$request\" \"$response\" \"$cancel\"\n  exit 1\nfi\ncp \"$response\" \"$1\"\nrm -f \"$request\" \"$response\" \"$cancel\"\nexit 0\n",
        support = support
    );
    std::fs::write(editor, script).map_err(EngineError::from_gix)?;
    let mut permissions = std::fs::metadata(editor)
        .map_err(EngineError::from_gix)?
        .permissions();
    permissions.set_mode(0o700);
    std::fs::set_permissions(editor, permissions).map_err(EngineError::from_gix)
}

fn rebase_with_system_options(
    repo: &gix::Repository,
    onto: Option<gix::hash::ObjectId>,
    original_head: gix::hash::ObjectId,
    _original_tree: gix::hash::ObjectId,
    actions: Vec<RebaseAction>,
    preserve_merges: bool,
    auto_squash: bool,
    keep_empty: bool,
    update_refs: bool,
    root: bool,
    branch: Option<&str>,
    desired_order: Option<&[gix::hash::ObjectId]>,
    merge_action_overrides: Option<std::collections::HashMap<gix::hash::ObjectId, RebaseAction>>,
    interactive: bool,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<RebaseOutcome, EngineError> {
    if system_rebase_active(repo) {
        return Err(EngineError::GitOperation {
            message: "rebase: another rebase is already in progress".into(),
        });
    }
    let mut actions = actions;
    let mut merge_action_overrides = merge_action_overrides;
    let order = if interactive {
        if preserve_merges {
            rebase_merge_order(repo, onto, original_head, root)?
        } else if root {
            rebase_root_graph_order(repo, onto, original_head)?
        } else {
            let onto = onto.ok_or_else(|| EngineError::GitOperation {
                message: "rebase: non-root rebase requires an onto revision".into(),
            })?;
            if reachable_from(repo, original_head)?.contains(&onto) {
                rebase_graph_order(repo, onto, original_head)?
            } else {
                let merge_base = repo
                    .merge_base(original_head, onto)
                    .map_err(EngineError::from_gix)?
                    .detach();
                rebase_graph_order(repo, merge_base, original_head)?
            }
        }
    } else {
        Vec::new()
    };
    let non_merges: Vec<_> = if interactive {
        order
            .iter()
            .copied()
            .filter(|id| {
                repo.find_commit(*id)
                    .map(|commit| commit.parent_ids().nth(1).is_none())
                    .unwrap_or(false)
            })
            .collect()
    } else {
        Vec::new()
    };

    // The single-root structured todo path already separates merge rows from
    // non-merge actions before reaching this function. Multi-root rebase
    // persists one action per visible row, however, so a preserve-merges todo
    // can arrive with merge rows included. Keep that public row model while
    // translating it to Git's native sequence-editor model here: merge rows
    // only support pick/reword, and their reword messages become the same
    // merge overrides used by the single-root path.
    if interactive
        && preserve_merges
        && order.len() != non_merges.len()
        && actions.len() == order.len()
    {
        let full_actions = std::mem::take(&mut actions);
        let mut non_merge_actions = Vec::with_capacity(non_merges.len());
        let mut inferred_merge_actions = HashMap::new();
        for (id, action) in order.iter().copied().zip(full_actions) {
            if non_merges.contains(&id) {
                non_merge_actions.push(action);
                continue;
            }
            match action {
                RebaseAction::Pick => {
                    inferred_merge_actions.insert(id, RebaseAction::Pick);
                }
                RebaseAction::Reword { message } => {
                    inferred_merge_actions.insert(id, RebaseAction::Reword { message });
                }
                RebaseAction::Drop
                | RebaseAction::Edit
                | RebaseAction::Squash
                | RebaseAction::SquashWithMessage { .. }
                | RebaseAction::Fixup => {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "rebase todo: merge commit {} only supports pick or reword",
                            id.to_hex()
                        ),
                    });
                }
            }
        }
        actions = non_merge_actions;
        if let Some(existing) = merge_action_overrides.as_mut() {
            existing.extend(inferred_merge_actions);
        } else {
            merge_action_overrides = Some(inferred_merge_actions);
        }
    }

    if interactive && non_merges.len() != actions.len() {
        return Err(EngineError::GitOperation {
            message: format!(
                "rebase: {} actions for {} non-merge commits",
                actions.len(),
                non_merges.len()
            ),
        });
    }
    if !interactive && (desired_order.is_some() || merge_action_overrides.is_some()) {
        return Err(EngineError::GitOperation {
            message: "rebase: todo actions require interactive mode".into(),
        });
    }
    let support = repo.git_dir().join("arbor-rebase-support");
    std::fs::create_dir_all(&support).map_err(EngineError::from_gix)?;
    if let Some(branch) = branch {
        let current = repo
            .head_name()
            .map_err(EngineError::from_gix)?
            .map(|name| shorten_ref_name(name.as_bstr()));
        if current.as_deref() != Some(branch) {
            if let Some(current) = current {
                std::fs::write(support.join("original-branch"), current)
                    .map_err(EngineError::from_gix)?;
            }
        }
    }
    let (sequence_editor, message_editor) = if interactive {
        let action_map = support.join("actions.tsv");
        let order_file = support.join("order.tsv");
        let sequence_editor = support.join("sequence-editor.sh");
        let message_editor = support.join("message-editor.sh");
        let mut map = String::new();
        let action_ids = desired_order.unwrap_or(&non_merges);
        if action_ids.len() != non_merges.len()
            || !action_ids.iter().all(|id| non_merges.contains(id))
        {
            return Err(EngineError::GitOperation {
                message: "rebase: requested todo order does not match the native commit range"
                    .into(),
            });
        }
        for (id, action) in action_ids.iter().zip(actions.iter()) {
            let code = match action {
                RebaseAction::Pick => "pick",
                RebaseAction::Drop => "drop",
                RebaseAction::Reword { message } => {
                    std::fs::write(
                        support.join(id.to_hex().to_string()),
                        format!("{message}\n"),
                    )
                    .map_err(EngineError::from_gix)?;
                    "reword"
                }
                RebaseAction::Squash => "squash",
                RebaseAction::SquashWithMessage { message } => {
                    std::fs::write(
                        support.join(id.to_hex().to_string()),
                        format!("{message}\n"),
                    )
                    .map_err(EngineError::from_gix)?;
                    "squash"
                }
                RebaseAction::Fixup => "fixup",
                RebaseAction::Edit => "edit",
            };
            let hex = id.to_hex().to_string();
            for length in 4..=hex.len() {
                map.push_str(&format!("{}\t{code}\n", &hex[..length]));
            }
        }
        if let Some(merge_actions) = merge_action_overrides {
            for (id, action) in merge_actions {
                let code = match action {
                    RebaseAction::Pick => "pick",
                    RebaseAction::Reword { message } => {
                        std::fs::write(
                            support.join(id.to_hex().to_string()),
                            format!("{message}\n"),
                        )
                        .map_err(EngineError::from_gix)?;
                        "reword"
                    }
                    RebaseAction::Drop
                    | RebaseAction::Edit
                    | RebaseAction::Squash
                    | RebaseAction::SquashWithMessage { .. }
                    | RebaseAction::Fixup => {
                        return Err(EngineError::GitOperation {
                            message: format!(
                                "rebase todo: merge commit {} only supports pick or reword",
                                id.to_hex()
                            ),
                        });
                    }
                };
                let hex = id.to_hex().to_string();
                for length in 4..=hex.len() {
                    map.push_str(&format!("{}\t{code}\n", &hex[..length]));
                }
            }
        }
        std::fs::write(&action_map, map).map_err(EngineError::from_gix)?;
        if let Some(order) = desired_order {
            let contents = order
                .iter()
                .map(|id| id.to_hex().to_string())
                .collect::<Vec<_>>()
                .join("\n");
            std::fs::write(&order_file, format!("{contents}\n")).map_err(EngineError::from_gix)?;
        }
        write_rebase_editors(
            &sequence_editor,
            &message_editor,
            &action_map,
            &support,
            desired_order.map(|_| order_file.as_path()),
        )?;
        (Some(sequence_editor), Some(message_editor))
    } else {
        (None, None)
    };
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "rebase requires a non-bare worktree".into(),
    })?;
    let mut command = native_rebase_command_spec(
        workdir,
        onto,
        preserve_merges,
        auto_squash,
        keep_empty,
        update_refs,
        root,
        branch,
        interactive,
    )?;
    if let Some(sequence_editor) = sequence_editor {
        command = command.env("GIT_SEQUENCE_EDITOR", sequence_editor.to_string_lossy());
    }
    if let Some(message_editor) = message_editor {
        command = command.env("GIT_EDITOR", message_editor.to_string_lossy());
    }
    let output = crate::gitprocess::run(&command, cancel, |_| {})?;
    if output.cancelled {
        if !system_rebase_active(repo) {
            cleanup_system_rebase_support(repo);
        }
        return Err(EngineError::Cancelled);
    }
    if system_rebase_active(repo) {
        return system_rebase_outcome(repo, true);
    }
    if !output.success() {
        cleanup_system_rebase_support(repo);
        return Err(EngineError::GitOperation {
            message: format!("git rebase failed: {}", git_process_output_message(&output)),
        });
    }
    cleanup_system_rebase_support(repo);
    system_rebase_outcome(repo, false)
}

fn write_rebase_editors(
    sequence_editor: &std::path::Path,
    message_editor: &std::path::Path,
    action_map: &std::path::Path,
    support: &std::path::Path,
    order_file: Option<&std::path::Path>,
) -> Result<(), EngineError> {
    use std::os::unix::fs::PermissionsExt;
    let map = shell_quote_for_script(action_map);
    let dir = shell_quote_for_script(support);
    let ordering = order_file
        .map(|path| {
            let order = shell_quote_for_script(path);
            format!(
                "if [ -f {order} ]; then\n  ordered=\"$todo.arbor-order\"\n  awk -v order_file={order} '\nfunction add_block(line,    lookahead, saw_update, fields) {{\n  if (line !~ /^pick /) {{\n    skeleton[++skeleton_count] = line\n    return\n  }}\n  block_count++\n  split(line, fields, /[ \\t]+/)\n  block_id[block_count] = fields[2]\n  block[block_count] = line\n  saw_update = 0\n  while ((getline lookahead) > 0) {{\n    if (lookahead ~ /^update-ref / || (saw_update && lookahead == \"\")) {{\n      block[block_count] = block[block_count] \"\\n\" lookahead\n      if (lookahead ~ /^update-ref /) saw_update = 1\n    }} else {{\n      pending = lookahead\n      has_pending = 1\n      break\n    }}\n  }}\n  skeleton[++skeleton_count] = \"__ARBOR_PICK_BLOCK_\" block_count \"__\"\n}}\nBEGIN {{\n  while ((getline line < order_file) > 0) desired[++desired_count] = line\n  close(order_file)\n}}\n{{\n  if (has_pending) {{\n    current = pending\n    has_pending = 0\n    add_block(current)\n  }}\n  add_block($0)\n}}\nEND {{\n  if (has_pending) {{\n    current = pending\n    has_pending = 0\n    add_block(current)\n  }}\n  next_order = 1\n  for (i = 1; i <= skeleton_count; i++) {{\n    line = skeleton[i]\n    if (line ~ /^__ARBOR_PICK_BLOCK_[0-9]+__$/) {{\n      wanted = desired[next_order++]\n      selected = 0\n      for (j = 1; j <= block_count; j++) {{\n        if (index(wanted, block_id[j]) == 1) {{\n          selected = j\n          break\n        }}\n      }}\n      if (selected) print block[selected]\n      else print line\n    }} else print line\n  }}\n}}' \"$todo\" > \"$ordered\"\n  mv \"$ordered\" \"$todo\"\nfi\n",
                order = order
            )
        })
        .unwrap_or_default();
    let sequence = format!("#!/bin/sh\nset -eu\ntodo=\"$1\"\n{ordering}tmp=\"$todo.arbor-tmp\"\n: > \"$tmp\"\nwhile IFS= read -r line || [ -n \"$line\" ]; do\n  case \"$line\" in\n    pick\\ *)\n      id=$(printf '%s\\n' \"$line\" | awk '{{print $2}}')\n      action=$(awk -F '\\t' -v id=\"$id\" '$1 == id {{print $2; exit}}' {map})\n      case \"$action\" in\n        drop) continue ;;\n        reword|squash|fixup|edit) printf '%s %s\\n' \"$action\" \"$id\" >> \"$tmp\" ;;\n        *) printf '%s\\n' \"$line\" >> \"$tmp\" ;;\n      esac\n      ;;\n    merge\\ *)\n      mode=$(printf '%s\\n' \"$line\" | awk '{{print $2}}')\n      id=$(printf '%s\\n' \"$line\" | awk '{{print $3}}')\n      action=$(awk -F '\\t' -v id=\"$id\" '$1 == id {{print $2; exit}}' {map})\n      if [ \"$action\" = reword ] && [ \"$mode\" = -C ]; then\n        printf '%s\\n' \"$line\" | sed \"s/^merge -C $id/merge -c $id/\" >> \"$tmp\"\n      else\n        printf '%s\\n' \"$line\" >> \"$tmp\"\n      fi\n      ;;\n    *) printf '%s\\n' \"$line\" >> \"$tmp\" ;;\n  esac\ndone < \"$todo\"\nmv \"$tmp\" \"$todo\"\n", map = map, ordering = ordering);
    let editor = format!(
        "#!/bin/sh\nset -eu\ngit_dir=\"$(git rev-parse --git-dir)\"\nid=\"\"\nif [ -f \"$git_dir/rebase-merge/done\" ]; then\n  last=\"$(tail -n 1 \"$git_dir/rebase-merge/done\")\"\n  command=\"$(printf '%s\\n' \"$last\" | awk '{{print $1}}')\"\n  if [ \"$command\" = merge ]; then\n    id=\"$(printf '%s\\n' \"$last\" | awk '{{print $3}}')\"\n  else\n    id=\"$(printf '%s\\n' \"$last\" | awk '{{print $2}}')\"\n  fi\nfi\nif [ -z \"$id\" ]; then\n  id=\"$(git rev-parse --verify REBASE_HEAD 2>/dev/null || true)\"\nfi\nif [ -z \"$id\" ]; then exit 0; fi\nfor message in {dir}/*; do\n  name=\"$(basename \"$message\")\"\n  case \"$name\" in\n    \"$id\"*) cp \"$message\" \"$1\"; break ;;\n  esac\ndone\n",
        dir = dir
    );
    std::fs::write(sequence_editor, sequence).map_err(EngineError::from_gix)?;
    std::fs::write(message_editor, editor).map_err(EngineError::from_gix)?;
    for path in [sequence_editor, message_editor] {
        let mut permissions = std::fs::metadata(path)
            .map_err(EngineError::from_gix)?
            .permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(path, permissions).map_err(EngineError::from_gix)?;
    }
    Ok(())
}

fn shell_quote_for_script(path: &std::path::Path) -> String {
    let value = path.to_string_lossy();
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn system_rebase_active(repo: &gix::Repository) -> bool {
    repo.git_dir().join("rebase-merge").is_dir() || repo.git_dir().join("rebase-apply").is_dir()
}

fn system_rebase_outcome(
    repo: &gix::Repository,
    paused: bool,
) -> Result<RebaseOutcome, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "rebase requires a non-bare worktree".into(),
    })?;
    let head = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["rev-parse", "HEAD"])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    let head_id = String::from_utf8_lossy(&head.stdout).trim().to_string();
    if !paused {
        return Ok(RebaseOutcome {
            head_id,
            paused: false,
            pause_reason: None,
            conflicts: Vec::new(),
        });
    }
    let status = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["status", "--porcelain=v1", "-z"])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    let conflicts = status
        .stdout
        .split(|byte| *byte == 0)
        .filter_map(|entry| {
            if entry.len() < 3 {
                return None;
            }
            let code = &entry[..2];
            if code.contains(&b'U') || matches!(code, b"AA" | b"DD") {
                Some(String::from_utf8_lossy(&entry[3..]).into_owned())
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    Ok(RebaseOutcome {
        head_id,
        paused: true,
        pause_reason: Some(if conflicts.is_empty() {
            RebasePauseReason::Edit
        } else {
            RebasePauseReason::Conflict
        }),
        conflicts,
    })
}

fn prepare_continue_system_rebase_command(
    repo: &gix::Repository,
) -> Result<std::process::Command, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "rebase requires a non-bare worktree".into(),
    })?;
    let support = repo.git_dir().join("arbor-rebase-support");
    // `edit` pauses with the amended worktree unstaged in Arbor's UI. Git's
    // native continue requires the resolved tree in the index, so stage the
    // explicit edit result; unresolved conflict entries are left untouched.
    let status = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["status", "--porcelain=v1"])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    let has_unmerged = String::from_utf8_lossy(&status.stdout).lines().any(|line| {
        let bytes = line.as_bytes();
        bytes.len() >= 2
            && (bytes[0] == b'U'
                || bytes[1] == b'U'
                || line.starts_with("AA")
                || line.starts_with("DD"))
    });
    if !has_unmerged {
        let _ = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["add", "-A"])
            .current_dir(workdir)
            .output();
    }
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args(["rebase", "--continue"]).current_dir(workdir);
    let message_editor = support.join("message-editor.sh");
    let raw_message_editor = support.join("raw-message-editor.sh");
    if message_editor.exists() {
        command.env("GIT_EDITOR", message_editor);
    } else if raw_message_editor.exists() {
        command.env("GIT_EDITOR", raw_message_editor);
    }
    Ok(command)
}

fn finish_continue_system_rebase(
    repo: &gix::Repository,
    output: std::process::Output,
) -> Result<RebaseOutcome, EngineError> {
    if system_rebase_active(repo) {
        // An active rebase is also expected after a successful Continue that
        // reaches the next edit/conflict step. A non-zero exit, however, is
        // a failed Continue (most commonly unresolved conflicts) and must be
        // surfaced while retaining the native rebase metadata for retry/skip/
        // abort. Checking only the directory made failed Continue look like
        // a successful pause and left the UI with a stale operation snapshot.
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git rebase --continue failed: {}",
                    command_output_message(&output)
                ),
            });
        }
        return system_rebase_outcome(repo, true);
    }
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git rebase --continue failed: {}",
                command_output_message(&output)
            ),
        });
    }
    cleanup_system_rebase_support(repo);
    system_rebase_outcome(repo, false)
}

fn abort_system_rebase(repo: &gix::Repository) -> Result<(), EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "rebase requires a non-bare worktree".into(),
    })?;
    let original_branch =
        std::fs::read_to_string(repo.git_dir().join("arbor-rebase-support/original-branch"))
            .ok()
            .map(|branch| branch.trim().to_string())
            .filter(|branch| !branch.is_empty());
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["rebase", "--abort"])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        cleanup_system_rebase_support(repo);
        return Err(EngineError::GitOperation {
            message: format!(
                "git rebase --abort failed: {}",
                command_output_message(&output)
            ),
        });
    }
    cleanup_system_rebase_support(repo);
    if let Some(branch) = original_branch {
        let restore = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["switch", "--quiet", branch.as_str()])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !restore.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git rebase abort restored the commits but could not return to '{branch}': {}",
                    command_output_message(&restore)
                ),
            });
        }
    }
    Ok(())
}

fn cleanup_system_rebase_support(repo: &gix::Repository) {
    let _ = std::fs::remove_dir_all(repo.git_dir().join("arbor-rebase-support"));
}

/// 图语义的旧实现保留给历史数据兼容；新的 preserve-merges 入口走上面的
/// Git 原生 todo，以完整支持 squash/fixup/edit 和冲突恢复。
#[allow(dead_code)]
fn rebase_preserving_merges(
    repo: &gix::Repository,
    onto: gix::hash::ObjectId,
    original_head: gix::hash::ObjectId,
    original_tree: gix::hash::ObjectId,
    actions: Vec<RebaseAction>,
    auto_squash: bool,
) -> Result<RebaseOutcome, EngineError> {
    let order = rebase_graph_order(repo, onto, original_head)?;
    let non_merges: Vec<_> = order
        .iter()
        .copied()
        .filter(|id| {
            repo.find_commit(*id)
                .map(|commit| commit.parent_ids().nth(1).is_none())
                .unwrap_or(false)
        })
        .collect();
    if non_merges.len() != actions.len() {
        return Err(EngineError::GitOperation {
            message: format!(
                "rebase: {} actions for {} non-merge commits",
                actions.len(),
                non_merges.len()
            ),
        });
    }
    let mut pairs: Vec<_> = non_merges
        .into_iter()
        .zip(actions)
        .map(|(id, action)| (action, id))
        .collect();
    if auto_squash {
        pairs = crate::rebasetodo::autosquash_pairs(repo, pairs)?;
    }
    if pairs.iter().any(|(action, _)| {
        matches!(
            action,
            RebaseAction::Squash | RebaseAction::SquashWithMessage { .. } | RebaseAction::Fixup
        )
    }) {
        return Err(EngineError::GitOperation {
            message: "rebase: squash/fixup with preserved merge topology is not yet supported"
                .into(),
        });
    }
    let actions_by_id: HashMap<_, _> = pairs.into_iter().map(|(action, id)| (id, action)).collect();
    if actions_by_id
        .values()
        .any(|action| matches!(action, RebaseAction::Edit))
    {
        return Err(EngineError::GitOperation {
            message: "rebase: edit is not available while preserving merge topology".into(),
        });
    }

    let mut replayed_commits = HashMap::new();
    let mut replayed_trees = HashMap::new();
    replayed_commits.insert(onto, onto);
    replayed_trees.insert(
        onto,
        repo.find_commit(onto)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach(),
    );

    for id in order {
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let parents: Vec<_> = commit.parent_ids().map(|parent| parent.detach()).collect();
        let mapped_parents: Vec<_> = parents
            .iter()
            .map(|parent| replayed_commits.get(parent).copied().unwrap_or(*parent))
            .collect();
        let mapped_parent_trees: Vec<_> = parents
            .iter()
            .map(|parent| {
                replayed_trees
                    .get(parent)
                    .copied()
                    .map(Ok)
                    .unwrap_or_else(|| {
                        repo.find_commit(*parent)
                            .map_err(EngineError::from_gix)?
                            .tree_id()
                            .map_err(EngineError::from_gix)
                            .map(|tree| tree.detach())
                    })
            })
            .collect::<Result<_, EngineError>>()?;

        let (new_tree, message, new_parents) = if parents.len() > 1 {
            let tree = replay_merge_tree(
                repo,
                &commit,
                mapped_parent_trees[0],
                mapped_parent_trees[1],
            )?;
            let message = format!("{}\n\n(replayed merge)", commit_title(repo, id)?);
            (tree, message, mapped_parents)
        } else {
            let parent = parents
                .first()
                .copied()
                .ok_or_else(|| EngineError::GitOperation {
                    message: "rebase: cannot replay a root commit without an onto parent".into(),
                })?;
            let action = actions_by_id.get(&id).unwrap_or(&RebaseAction::Pick);
            if matches!(action, RebaseAction::Drop) {
                replayed_commits.insert(id, mapped_parents[0]);
                replayed_trees.insert(id, mapped_parent_trees[0]);
                continue;
            }
            let tree = cherry_pick_tree(repo, &commit, mapped_parent_trees[0])?;
            let message = match action {
                RebaseAction::Reword { message } => message.clone(),
                _ => commit_title(repo, id)?,
            };
            let _ = parent;
            (tree, message, mapped_parents)
        };
        let message = crate::commit_message::format(repo, message)?;
        let new_id = repo
            .new_commit(&message, new_tree, new_parents)
            .map_err(EngineError::from_gix)?
            .id;
        replayed_commits.insert(id, new_id);
        replayed_trees.insert(id, new_tree);
    }

    let final_head = replayed_commits
        .get(&original_head)
        .copied()
        .unwrap_or(onto);
    let final_tree = replayed_trees
        .get(&original_head)
        .copied()
        .unwrap_or_else(|| replayed_trees[&onto]);
    move_head_to(repo, final_head)?;
    finalize_rebase(repo, original_tree, final_head, final_tree)?;
    Ok(RebaseOutcome {
        head_id: final_head.to_hex().to_string(),
        paused: false,
        pause_reason: None,
        conflicts: Vec::new(),
    })
}

/// rebase 动作应用的结果。
enum ApplyOutcome {
    Done {
        head: gix::hash::ObjectId,
        tree: gix::hash::ObjectId,
    },
    /// 暂停在 Edit：head=edit 提交，remaining=剩余 (action, commit)
    Paused {
        head: gix::hash::ObjectId,
        tree: gix::hash::ObjectId,
        message: String,
        remaining: Vec<(RebaseAction, gix::hash::ObjectId)>,
    },
    /// 暂停在冲突：head 是最后一个已提交的重放提交，tree 是含 marker 的临时树。
    PausedConflict {
        head: gix::hash::ObjectId,
        tree: gix::hash::ObjectId,
        message: String,
        remaining: Vec<(RebaseAction, gix::hash::ObjectId)>,
        conflicts: Vec<String>,
    },
}

enum AppliedRebaseTree {
    Clean(gix::hash::ObjectId),
    Conflict {
        merged_tree: gix::hash::ObjectId,
        conflicts: Vec<ConflictEntry>,
    },
}

fn apply_rebase_cherry(
    repo: &gix::Repository,
    cherry: &gix::Commit<'_>,
    current_tree: gix::hash::ObjectId,
    pause_on_conflict: bool,
) -> Result<AppliedRebaseTree, EngineError> {
    if !pause_on_conflict {
        return cherry_pick_tree(repo, cherry, current_tree).map(AppliedRebaseTree::Clean);
    }
    match cherry_pick_tree_with_conflict(repo, cherry, current_tree)? {
        CherryPickOutcome::Clean(tree) => Ok(AppliedRebaseTree::Clean(tree)),
        CherryPickOutcome::Conflict {
            merged_tree,
            conflicts,
        } => Ok(AppliedRebaseTree::Conflict {
            merged_tree,
            conflicts,
        }),
    }
}

fn combined_rebase_message(group: &[String]) -> String {
    let mut message = group.first().cloned().unwrap_or_default();
    for item in &group[1..] {
        message.push_str(&format!("\n\n{item}"));
    }
    message
}

/// 应用 (action, commit) 序列（旧→新），head_id 为起点（onto 或 amend 提交）。
fn apply_rebase_actions(
    repo: &gix::Repository,
    mut head_id: gix::hash::ObjectId,
    mut current_tree: gix::hash::ObjectId,
    pairs: &[(RebaseAction, gix::hash::ObjectId)],
    pause_on_conflict: bool,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<ApplyOutcome, EngineError> {
    let mut group: Vec<String> = Vec::new();
    let mut group_message_override: Option<String> = None;
    let mut i = 0usize;
    while i < pairs.len() {
        ensure_not_cancelled(cancel)?;
        match &pairs[i].0 {
            RebaseAction::Drop => {
                i += 1;
            }
            RebaseAction::Squash | RebaseAction::SquashWithMessage { .. } | RebaseAction::Fixup => {
                if group.is_empty() {
                    return Err(EngineError::GitOperation {
                        message: "rebase: squash must follow a pick/reword".into(),
                    });
                }
                let cherry = repo
                    .find_commit(pairs[i].1)
                    .map_err(EngineError::from_gix)?;
                let msg = cherry
                    .message()
                    .map(|m| m.title.trim_end().to_str_lossy().into_owned())
                    .unwrap_or_default();
                match apply_rebase_cherry(repo, &cherry, current_tree, pause_on_conflict)? {
                    AppliedRebaseTree::Clean(tree) => current_tree = tree,
                    AppliedRebaseTree::Conflict {
                        merged_tree,
                        conflicts,
                    } => {
                        let mut message_group = group.clone();
                        if matches!(
                            pairs[i].0,
                            RebaseAction::Squash | RebaseAction::SquashWithMessage { .. }
                        ) {
                            message_group.push(msg.clone());
                        }
                        let message = match &pairs[i].0 {
                            RebaseAction::SquashWithMessage { message } => message.clone(),
                            _ => combined_rebase_message(&message_group),
                        };
                        let conflict_paths =
                            materialize_merge_outcome(repo, current_tree, merged_tree, &conflicts)?;
                        return Ok(ApplyOutcome::PausedConflict {
                            head: head_id,
                            tree: merged_tree,
                            message,
                            remaining: pairs[i + 1..].to_vec(),
                            conflicts: conflict_paths,
                        });
                    }
                }
                if matches!(
                    pairs[i].0,
                    RebaseAction::Squash | RebaseAction::SquashWithMessage { .. }
                ) {
                    group.push(msg);
                }
                if let RebaseAction::SquashWithMessage { message } = &pairs[i].0 {
                    group_message_override = Some(message.clone());
                }
                i += 1;
            }
            RebaseAction::Pick | RebaseAction::Reword { .. } | RebaseAction::Edit => {
                if !group.is_empty() {
                    head_id = commit_rebase_group(
                        repo,
                        &group,
                        current_tree,
                        head_id,
                        group_message_override.as_deref(),
                    )?;
                    group.clear();
                    group_message_override = None;
                }
                let cherry = repo
                    .find_commit(pairs[i].1)
                    .map_err(EngineError::from_gix)?;
                let msg = match &pairs[i].0 {
                    RebaseAction::Reword { message } => message.clone(),
                    _ => cherry
                        .message()
                        .map(|m| m.title.trim_end().to_str_lossy().into_owned())
                        .unwrap_or_default(),
                };
                let old_tree = current_tree;
                match apply_rebase_cherry(repo, &cherry, current_tree, pause_on_conflict)? {
                    AppliedRebaseTree::Clean(tree) => current_tree = tree,
                    AppliedRebaseTree::Conflict {
                        merged_tree,
                        conflicts,
                    } => {
                        let conflict_paths =
                            materialize_merge_outcome(repo, current_tree, merged_tree, &conflicts)?;
                        return Ok(ApplyOutcome::PausedConflict {
                            head: head_id,
                            tree: merged_tree,
                            message: msg,
                            remaining: pairs[i + 1..].to_vec(),
                            conflicts: conflict_paths,
                        });
                    }
                }
                if matches!(pairs[i].0, RebaseAction::Edit) {
                    // 提交 edit 组并暂停
                    head_id =
                        commit_rebase_group(repo, &[msg.clone()], current_tree, head_id, None)?;
                    // 暂停点必须把当前重放树落到工作区和索引；否则从
                    // conflict continue 转入 edit 时，新增文件会变成未跟踪文件。
                    finalize_rebase(repo, old_tree, head_id, current_tree)?;
                    return Ok(ApplyOutcome::Paused {
                        head: head_id,
                        tree: current_tree,
                        message: msg,
                        remaining: pairs[i + 1..].to_vec(),
                    });
                }
                group.push(msg);
                i += 1;
            }
        }
    }
    if !group.is_empty() {
        ensure_not_cancelled(cancel)?;
        head_id = commit_rebase_group(
            repo,
            &group,
            current_tree,
            head_id,
            group_message_override.as_deref(),
        )?;
    }
    Ok(ApplyOutcome::Done {
        head: head_id,
        tree: current_tree,
    })
}

/// rebase 完成收尾：工作区物化（old_tree -> final_tree）+ 索引重建。
fn finalize_rebase(
    repo: &gix::Repository,
    old_tree: gix::hash::ObjectId,
    head: gix::hash::ObjectId,
    final_tree: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    finalize_rebase_with_ignored_paths(repo, old_tree, head, final_tree, &[])
}

fn finalize_rebase_with_ignored_paths(
    repo: &gix::Repository,
    old_tree: gix::hash::ObjectId,
    head: gix::hash::ObjectId,
    final_tree: gix::hash::ObjectId,
    ignored_paths: &[String],
) -> Result<(), EngineError> {
    if let Some(workdir) = repo.workdir() {
        if ignored_paths.is_empty() {
            materialize_tree(repo, old_tree, final_tree, workdir)?;
        } else {
            crate::merge::materialize_tree_ignoring_paths(
                repo,
                old_tree,
                final_tree,
                workdir,
                ignored_paths,
            )?;
        }
    }
    let mut index = repo
        .index_from_tree(&final_tree)
        .map_err(EngineError::from_gix)?;
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;
    let _ = head;
    Ok(())
}

fn reset_index_to_tree(
    repo: &gix::Repository,
    tree: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    let mut index = repo.index_from_tree(&tree).map_err(EngineError::from_gix)?;
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)
}

#[derive(Clone, Debug)]
struct ResetRecoveryMarker {
    id: String,
    mode: ResetMode,
    initial_head: String,
    expected_head: String,
    initial_branch: String,
    expected_branch: String,
    pre_ref: Option<String>,
    post_ref: Option<String>,
}

fn reset_recovery_marker_path(repo: &gix::Repository) -> PathBuf {
    repo.git_dir().join("arbor-reset-rollback")
}

fn reset_mode_name_rust(mode: ResetMode) -> &'static str {
    match mode {
        ResetMode::Soft => "soft",
        ResetMode::Mixed => "mixed",
        ResetMode::Hard => "hard",
        ResetMode::Keep => "keep",
    }
}

fn parse_reset_mode(value: &str) -> Option<ResetMode> {
    match value {
        "soft" => Some(ResetMode::Soft),
        "mixed" => Some(ResetMode::Mixed),
        "hard" => Some(ResetMode::Hard),
        "keep" => Some(ResetMode::Keep),
        _ => None,
    }
}

fn head_branch_identity(repo: &gix::Repository) -> Result<String, EngineError> {
    Ok(repo
        .head_name()
        .map_err(EngineError::from_gix)?
        .map(|name| shorten_ref_name(name.as_bstr()))
        .unwrap_or_default())
}

fn parse_commit_id(
    repo: &gix::Repository,
    revision: &str,
) -> Result<gix::hash::ObjectId, EngineError> {
    repo.rev_parse_single(BStr::new(revision.as_bytes()))
        .map_err(EngineError::from_gix)
        .map(|id| id.detach())
}

fn allocate_reset_recovery_id(repository: &Repository) -> Result<String, EngineError> {
    let repo = repository.inner.lock().expect("repo mutex poisoned");
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| EngineError::GitOperation {
            message: format!("reset: could not allocate undo id: {error}"),
        })?
        .as_nanos();
    let prefix = format!("{}-{}", std::process::id(), nanos);
    for suffix in 0..1000u32 {
        let id = if suffix == 0 {
            prefix.clone()
        } else {
            format!("{prefix}-{suffix}")
        };
        let marker = reset_recovery_marker_path(&repo);
        if !marker.exists()
            && !repo
                .find_reference(format!("refs/arbor/reset-undo/{id}/pre").as_str())
                .is_ok()
            && !repo
                .find_reference(format!("refs/arbor/reset-undo/{id}/post").as_str())
                .is_ok()
        {
            return Ok(id);
        }
    }
    Err(EngineError::GitOperation {
        message: "reset: could not allocate a unique undo id".into(),
    })
}

/// Capture a complete local scene into a hidden ref, then restore the scene
/// immediately. Keeping the object out of `refs/stash` prevents a reset undo
/// from changing the user's visible stash stack while still making the object
/// durable across app restarts and repository maintenance.
fn capture_reset_snapshot(
    repository: &Repository,
    rollback_id: &str,
    slot: &str,
) -> Result<Option<String>, EngineError> {
    let has_local_changes = {
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        !crate::status::compute_status(&repo)?.is_empty()
    };
    if !has_local_changes {
        return Ok(None);
    }

    let stash_id = repository.stash_save_with_options(
        Some(format!("Arbor: reset undo {rollback_id} {slot}")),
        true,
        true,
    )?;
    let stash_id =
        gix::hash::ObjectId::from_hex(stash_id.as_bytes()).map_err(EngineError::from_gix)?;
    let reference = format!("refs/arbor/reset-undo/{rollback_id}/{slot}");
    let set_ref_result = {
        use gix::refs::transaction::PreviousValue;
        let repo = repository.inner.lock().expect("repo mutex poisoned");
        let name: gix::refs::FullName = reference
            .as_str()
            .try_into()
            .map_err(EngineError::from_gix)?;
        let result = repo
            .reference(
                name,
                stash_id,
                PreviousValue::Any,
                "reset: save undo snapshot",
            )
            .map(|_| ())
            .map_err(EngineError::from_gix);
        result
    };
    if let Err(error) = set_ref_result {
        let _ = stash_pop_with_id(repository, stash_id, true);
        return Err(error);
    }

    if let Err(error) = stash_pop_with_id(repository, stash_id, true) {
        return Err(EngineError::GitOperation {
            message: format!(
                "reset: undo snapshot was saved at {reference}, but the original local scene could not be restored: {error}"
            ),
        });
    }
    Ok(Some(reference))
}

fn write_reset_recovery_marker(
    repository: &Repository,
    marker: &ResetRecoveryMarker,
) -> Result<(), EngineError> {
    let repo = repository.inner.lock().expect("repo mutex poisoned");
    let path = reset_recovery_marker_path(&repo);
    let temporary = path.with_extension("tmp");
    let text = format!(
        "ARBOR_RESET_ROLLBACK_V1\nid={}\nmode={}\ninitial-head={}\nexpected-head={}\ninitial-branch={}\nexpected-branch={}\npre-ref={}\npost-ref={}\n",
        marker.id,
        reset_mode_name_rust(marker.mode),
        marker.initial_head,
        marker.expected_head,
        marker.initial_branch,
        marker.expected_branch,
        marker.pre_ref.as_deref().unwrap_or_default(),
        marker.post_ref.as_deref().unwrap_or_default(),
    );
    std::fs::write(&temporary, text).map_err(EngineError::from_gix)?;
    std::fs::rename(temporary, path).map_err(EngineError::from_gix)
}

fn load_reset_recovery_marker(repo: &gix::Repository) -> Result<ResetRecoveryMarker, EngineError> {
    let text = std::fs::read_to_string(reset_recovery_marker_path(repo)).map_err(|error| {
        EngineError::GitOperation {
            message: format!("reset rollback marker is unavailable: {error}"),
        }
    })?;
    let mut values = HashMap::<&str, &str>::new();
    for line in text.lines().skip(1) {
        if let Some((key, value)) = line.split_once('=') {
            values.insert(key, value);
        }
    }
    if text.lines().next() != Some("ARBOR_RESET_ROLLBACK_V1") {
        return Err(EngineError::GitOperation {
            message: "reset rollback marker has an unknown format".into(),
        });
    }
    let mode = values
        .get("mode")
        .and_then(|value| parse_reset_mode(value))
        .ok_or_else(|| EngineError::GitOperation {
            message: "reset rollback marker has an invalid mode".into(),
        })?;
    let required = |key: &str| {
        values
            .get(key)
            .filter(|value| !value.is_empty())
            .map(|value| (*value).to_string())
            .ok_or_else(|| EngineError::GitOperation {
                message: format!("reset rollback marker is missing {key}"),
            })
    };
    Ok(ResetRecoveryMarker {
        id: required("id")?,
        mode,
        initial_head: required("initial-head")?,
        expected_head: required("expected-head")?,
        initial_branch: values
            .get("initial-branch")
            .map(|value| (*value).to_string())
            .unwrap_or_default(),
        expected_branch: values
            .get("expected-branch")
            .map(|value| (*value).to_string())
            .unwrap_or_default(),
        pre_ref: values
            .get("pre-ref")
            .filter(|value| !value.is_empty())
            .map(|value| (*value).to_string()),
        post_ref: values
            .get("post-ref")
            .filter(|value| !value.is_empty())
            .map(|value| (*value).to_string()),
    })
}

fn reset_snapshot_ref_id(
    repo: &gix::Repository,
    reference: &str,
) -> Result<gix::hash::ObjectId, EngineError> {
    repo.find_reference(reference)
        .map_err(EngineError::from_gix)?
        .try_id()
        .map(|id| id.detach())
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("reset rollback snapshot ref '{reference}' has no object id"),
        })
}

fn delete_reset_snapshot_ref(repo: &mut gix::Repository, reference: &str) {
    use gix::refs::transaction::{Change, PreviousValue, RefEdit, RefLog};
    let Ok(name) = reference.try_into() else {
        return;
    };
    let _ = repo.edit_reference(RefEdit {
        change: Change::Delete {
            expected: PreviousValue::Any,
            log: RefLog::AndReference,
        },
        name,
        deref: false,
    });
}

fn cleanup_reset_recovery_locked(repo: &mut gix::Repository, marker: &ResetRecoveryMarker) {
    if let Some(reference) = marker.pre_ref.as_deref() {
        delete_reset_snapshot_ref(repo, reference);
    }
    if let Some(reference) = marker.post_ref.as_deref() {
        delete_reset_snapshot_ref(repo, reference);
    }
    let _ = std::fs::remove_file(reset_recovery_marker_path(repo));
}

fn cleanup_reset_recovery(
    repository: &Repository,
    rollback_id: &str,
    pre_ref: Option<&str>,
    post_ref: Option<&str>,
) {
    let mut repo = repository.inner.lock().expect("repo mutex poisoned");
    if let Some(reference) = pre_ref {
        delete_reset_snapshot_ref(&mut repo, reference);
    }
    if let Some(reference) = post_ref {
        delete_reset_snapshot_ref(&mut repo, reference);
    }
    if let Ok(marker) = load_reset_recovery_marker(&repo) {
        if marker.id == rollback_id {
            let _ = std::fs::remove_file(reset_recovery_marker_path(&repo));
        }
    }
}

fn reset_snapshot_tree(
    repo: &gix::Repository,
    snapshot_id: gix::hash::ObjectId,
) -> Result<gix::hash::ObjectId, EngineError> {
    let snapshot = repo
        .find_commit(snapshot_id)
        .map_err(EngineError::from_gix)?;
    let tree_id = if let Some(untracked_parent) = snapshot.parent_ids().nth(2) {
        repo.find_commit(untracked_parent)
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach()
    } else {
        snapshot.tree_id().map_err(EngineError::from_gix)?.detach()
    };
    Ok(tree_id)
}

fn reset_snapshot_untracked_matches(
    repo: &gix::Repository,
    snapshot_id: gix::hash::ObjectId,
    expected_tree_id: gix::hash::ObjectId,
) -> Result<bool, EngineError> {
    let expected_paths = untracked_paths(repo, snapshot_id)?
        .into_iter()
        .collect::<HashSet<_>>();
    let current_paths = crate::status::compute_status(repo)?
        .into_iter()
        .filter(|entry| {
            entry.staged == ChangeKind::Unchanged
                && matches!(entry.unstaged, ChangeKind::Untracked | ChangeKind::Ignored)
        })
        .map(|entry| entry.path)
        .collect::<HashSet<_>>();
    if expected_paths != current_paths {
        return Ok(false);
    }
    let tree = repo
        .find_tree(expected_tree_id)
        .map_err(EngineError::from_gix)?;
    let Some(workdir) = repo.workdir() else {
        return Err(EngineError::GitOperation {
            message: "reset rollback requires a non-bare worktree".into(),
        });
    };
    for path in expected_paths {
        let Some(entry) = tree
            .lookup_entry_by_path(path.as_str())
            .map_err(EngineError::from_gix)?
        else {
            return Ok(false);
        };
        if !entry.mode().is_blob_or_symlink() {
            return Ok(false);
        }
        let expected = crate::diff::blob_bytes(repo, entry.object_id(), "reset rollback")?;
        let actual_path = workdir.join(&path);
        let actual = if std::fs::symlink_metadata(&actual_path)
            .map_err(EngineError::from_gix)?
            .file_type()
            .is_symlink()
        {
            std::fs::read_link(actual_path)
                .map_err(EngineError::from_gix)?
                .to_string_lossy()
                .into_owned()
                .into_bytes()
        } else {
            std::fs::read(actual_path).map_err(EngineError::from_gix)?
        };
        if actual != expected {
            return Ok(false);
        }
    }
    Ok(true)
}

fn verify_reset_post_snapshot(
    repo: &gix::Repository,
    post_ref: Option<&str>,
    expected_head: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    let Some(post_ref) = post_ref else {
        if crate::status::compute_status(repo)?.is_empty() {
            return Ok(());
        }
        return Err(EngineError::GitOperation {
            message: "reset rollback refused: local state changed after the reset".into(),
        });
    };
    let post_id = reset_snapshot_ref_id(repo, post_ref)?;
    let snapshot = repo.find_commit(post_id).map_err(EngineError::from_gix)?;
    let expected_worktree_tree = snapshot.tree_id().map_err(EngineError::from_gix)?.detach();
    let expected_index_tree = snapshot
        .parent_ids()
        .nth(1)
        .ok_or_else(|| EngineError::GitOperation {
            message: "reset rollback snapshot has no index parent".into(),
        })
        .and_then(|id| {
            repo.find_commit(id)
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)
                .map(|tree| tree.detach())
        })?;
    let index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    let actual_index_tree = crate::index::build_tree(repo, &index)?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "reset rollback requires a non-bare worktree".into(),
    })?;
    let actual_worktree_tree = build_worktree_tree(repo, &index, workdir, true, true)?;
    let tracked_matches = actual_worktree_tree == expected_worktree_tree;
    let index_matches = actual_index_tree == expected_index_tree;
    let post_tree = reset_snapshot_tree(repo, post_id)?;
    let untracked_matches = reset_snapshot_untracked_matches(repo, post_id, post_tree)?;
    if tracked_matches && index_matches && untracked_matches {
        return Ok(());
    }
    let _ = expected_head;
    Err(EngineError::GitOperation {
        message: format!(
            "reset rollback refused: index or worktree changed after the reset (tracked={tracked_matches}, index={index_matches}, untracked={untracked_matches})"
        ),
    })
}

fn remove_reset_post_untracked(
    repo: &gix::Repository,
    post_ref: Option<&str>,
    initial_tree_id: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    let Some(post_ref) = post_ref else {
        return Ok(());
    };
    let post_id = reset_snapshot_ref_id(repo, post_ref)?;
    let post_paths = untracked_paths(repo, post_id)?
        .into_iter()
        .collect::<HashSet<_>>();
    let initial_tree = repo
        .find_tree(initial_tree_id)
        .map_err(EngineError::from_gix)?;
    let Some(workdir) = repo.workdir() else {
        return Err(EngineError::GitOperation {
            message: "reset rollback requires a non-bare worktree".into(),
        });
    };
    for path in post_paths {
        if initial_tree
            .lookup_entry_by_path(path.as_str())
            .map_err(EngineError::from_gix)?
            .is_some()
        {
            continue;
        }
        let file = workdir.join(&path);
        if let Ok(metadata) = std::fs::symlink_metadata(&file) {
            if metadata.file_type().is_file() || metadata.file_type().is_symlink() {
                std::fs::remove_file(file).map_err(EngineError::from_gix)?;
            } else {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "reset rollback cannot safely remove untracked directory '{path}'"
                    ),
                });
            }
        }
    }
    Ok(())
}

fn stash_apply_with_id_locked(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
    restore_index: bool,
) -> Result<(), EngineError> {
    let untracked = untracked_paths(repo, stash_id)?;
    apply_stash_with_merge(repo, stash_id)?;
    restore_stashed_untracked(repo, stash_id, &untracked)?;
    restore_untracked_index_state(repo, &untracked)?;
    if restore_index {
        restore_stash_index(repo, stash_id, stash_saved_base_tree(repo, stash_id)?)?;
    }
    Ok(())
}

fn restore_head_ref_locked(
    repo: &mut gix::Repository,
    initial: gix::hash::ObjectId,
    expected: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    use gix::refs::transaction::{Change, PreviousValue, RefEdit};
    use gix::refs::Target;

    let previous_reflog = repo.refs.write_reflog;
    repo.refs.write_reflog = gix::refs::store::WriteReflog::Disable;
    let result = (|| -> Result<(), EngineError> {
        match repo.head_name().map_err(EngineError::from_gix)? {
            Some(name) => {
                let _ = repo
                    .edit_reference(RefEdit {
                        change: Change::Update {
                            log: Default::default(),
                            expected: PreviousValue::MustExistAndMatch(Target::Object(expected)),
                            new: Target::Object(initial),
                        },
                        name,
                        deref: false,
                    })
                    .map_err(EngineError::from_gix)?;
            }
            None => {
                let head_name: gix::refs::FullName =
                    "HEAD".try_into().map_err(EngineError::from_gix)?;
                repo.edit_reference(RefEdit {
                    change: Change::Update {
                        log: Default::default(),
                        expected: PreviousValue::MustExistAndMatch(Target::Object(expected)),
                        new: Target::Object(initial),
                    },
                    name: head_name,
                    deref: true,
                })
                .map_err(EngineError::from_gix)?;
            }
        }
        Ok(())
    })();
    repo.refs.write_reflog = previous_reflog;
    result
}

/// 执行 reset 面板的具体语义。调用方已持有仓库锁。
fn reset_locked(
    repo: &gix::Repository,
    commit_id: &str,
    mode: ResetMode,
    allow_overwrite: bool,
) -> Result<(), EngineError> {
    let target = repo
        .rev_parse_single(BStr::new(commit_id.as_bytes()))
        .map_err(EngineError::from_gix)?
        .detach();
    let target_commit = repo.find_commit(target).map_err(EngineError::from_gix)?;
    let target_tree = target_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let current_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();

    match mode {
        ResetMode::Soft => move_head_to(repo, target),
        ResetMode::Mixed => {
            move_head_to(repo, target)?;
            reset_index_to_tree(repo, target_tree)
        }
        ResetMode::Hard => {
            if !allow_overwrite {
                crate::merge::guard_uncommitted_overwrite(repo, current_tree, target_tree)?;
            }
            restore_head(repo, target)
        }
        ResetMode::Keep => {
            // `--keep` refuses only when a local change overlaps a path changed
            // by the reset target. Unrelated local edits stay on disk.
            crate::merge::guard_uncommitted_overwrite(repo, current_tree, target_tree)?;
            move_head_to(repo, target)?;
            if let Some(workdir) = repo.workdir() {
                crate::merge::materialize_tree(repo, current_tree, target_tree, workdir)?;
            }
            reset_index_to_tree(repo, target_tree)
        }
    }
}

/// 把 HEAD 移到目标提交（symbolic 或 detached）。
fn move_head_to(repo: &gix::Repository, target: gix::hash::ObjectId) -> Result<(), EngineError> {
    use gix::refs::transaction::{Change, PreviousValue, RefEdit};
    use gix::refs::Target;
    match repo.head_name().map_err(EngineError::from_gix)? {
        Some(name) => {
            repo.reference(name, target, PreviousValue::Any, "rebase: start")
                .map_err(EngineError::from_gix)?;
        }
        None => {
            let head_name: gix::refs::FullName =
                "HEAD".try_into().map_err(EngineError::from_gix)?;
            repo.edit_reference(RefEdit {
                change: Change::Update {
                    log: Default::default(),
                    expected: PreviousValue::Any,
                    new: Target::Object(target),
                },
                name: head_name,
                deref: true,
            })
            .map_err(EngineError::from_gix)?;
        }
    }
    Ok(())
}

/// 创建一个本地 stash。该 helper 不在 FFI 导出 impl 中，避免把内部的
/// `include_untracked` 开关暴露给 Swift；调用方只选择普通 stash、Keep
/// index 或 Pull 专用 stash。
fn save_stash(
    inner: &RepositoryMutex<gix::Repository>,
    message: Option<String>,
    include_untracked: bool,
    include_ignored: bool,
    keep_index: bool,
) -> Result<String, EngineError> {
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;

    let mut repo = inner.lock().expect("repo mutex poisoned");
    let head_commit = repo.head_commit().map_err(EngineError::from_gix)?;
    let head_id = head_commit.id().detach();
    let head_tree = head_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let branch = repo
        .head_name()
        .map_err(EngineError::from_gix)?
        .map(|n| shorten_ref_name(n.as_bstr()))
        .unwrap_or_else(|| "detached".into());
    let summary = head_commit
        .message()
        .map(|m| m.title.trim_end().to_str_lossy().into_owned())
        .unwrap_or_default();
    drop(head_commit);
    let workdir = repo
        .workdir()
        .ok_or_else(|| EngineError::GitOperation {
            message: "bare repository has no worktree".into(),
        })?
        .to_path_buf();

    let index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    let index_tree = crate::index::build_tree(&repo, &index)?;
    let worktree_tree =
        build_worktree_tree(&repo, &index, &workdir, include_untracked, include_ignored)?;

    let sc_msg = message.unwrap_or_else(|| format!("WIP on {branch}: {summary}"));
    let ic_msg = format!("index on {branch}: {summary}");
    // gix creates two internal commits for a stash. Unlike the system Git
    // client it requires both author and committer identities, even though
    // these commits are only local implementation details. Use the same
    // in-memory generic fallback as fetch reflogs, without changing the
    // user's Git configuration.
    repo.committer_or_set_generic_fallback()
        .map(|_| ())
        .map_err(EngineError::from_gix)?;
    if repo.author().is_none() {
        let mut config = gix::config::File::new(gix::config::file::Metadata::api());
        config
            .set_raw_value(
                gix::config::tree::gitoxide::Author::NAME_FALLBACK,
                "no name configured",
            )
            .expect("works - statically known");
        config
            .set_raw_value(
                gix::config::tree::gitoxide::Author::EMAIL_FALLBACK,
                "noEmailAvailable@example.com",
            )
            .expect("works - statically known");
        repo.config_snapshot_mut()
            .append(config)
            .map_err(EngineError::from_gix)?;
    }
    let ic = repo
        .new_commit(&ic_msg, index_tree, [head_id])
        .map_err(EngineError::from_gix)?
        .id;
    let sc = repo
        .new_commit(&sc_msg, worktree_tree, [head_id, ic])
        .map_err(EngineError::from_gix)?
        .id;

    let name: gix::refs::FullName = "refs/stash".try_into().map_err(EngineError::from_gix)?;
    repo.edit_reference(RefEdit {
        change: Change::Update {
            log: LogChange {
                mode: RefLog::AndReference,
                force_create_reflog: true,
                message: sc_msg.clone().into(),
            },
            expected: PreviousValue::Any,
            new: Target::Object(sc),
        },
        name,
        deref: false,
    })
    .map_err(EngineError::from_gix)?;

    // `--keep-index` leaves the staged snapshot in both the index and the
    // worktree. Unstaged changes are therefore removed by materializing the
    // complete stash worktree tree back to the saved index tree.
    let (materialize_from, materialize_to, index_tree_to_write) = if keep_index {
        (worktree_tree, index_tree, index_tree)
    } else {
        (worktree_tree, head_tree, head_tree)
    };
    materialize_tree(&repo, materialize_from, materialize_to, &workdir)?;
    let mut index2 = repo
        .index_from_tree(&index_tree_to_write)
        .map_err(EngineError::from_gix)?;
    index2.remove_tree();
    index2
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;
    Ok(sc.to_hex().to_string())
}

/// 用当前 HEAD 与 stash 工作树做三方合并。
///
/// stash 的索引父提交记录了保存时的 HEAD，gix 会沿提交图寻找共同基线：
/// 本地和远程分别改了不同位置时自动合并；同一位置冲突时写入冲突 stages
/// 和 marker，并保留 stash，交给上层进入冲突解决流程。
fn restore_untracked_index_state(
    repo: &gix::Repository,
    paths: &[String],
) -> Result<(), EngineError> {
    if paths.is_empty() {
        return Ok(());
    }
    let head_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let head_tree = repo.find_tree(head_tree).map_err(EngineError::from_gix)?;
    let mut index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    for path in paths {
        if head_tree
            .lookup_entry_by_path(path)
            .map_err(EngineError::from_gix)?
            .is_some()
        {
            continue;
        }
        let path_bstr = path.as_bytes().as_bstr();
        while let Some(i) =
            index.entry_index_by_path_and_stage(path_bstr, gix::index::entry::Stage::Unconflicted)
        {
            index.remove_entry_at_index(i);
        }
    }
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;
    Ok(())
}

/// 恢复系统 Git `stash push -u/-a` 生成的第三父树。Arbor 自己创建的
/// stash 已经把未跟踪文件写进工作树树，因此没有第三父，保持原路径。
fn restore_stashed_untracked(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
    paths: &[String],
) -> Result<(), EngineError> {
    if paths.is_empty() {
        return Ok(());
    }
    let stash = repo.find_commit(stash_id).map_err(EngineError::from_gix)?;
    if stash.parent_ids().count() < 3 {
        return Ok(());
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "stash restore requires a non-bare worktree".into(),
    })?;
    let source = format!("{}^3", stash_id.to_hex());
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["restore", "--source", &source, "--worktree", "--"])
        .args(paths)
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git restore stashed untracked files failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(())
}

/// 弹出指定 stash 对象。临时保存的操作必须按对象 id 取回，不能依赖
/// `stash@{0}`，否则并发 stash 会把用户的另一条现场错误地弹出。
pub(crate) fn stash_pop_with_id(
    repository: &Repository,
    stash_id: gix::hash::ObjectId,
    restore_index: bool,
) -> Result<(), EngineError> {
    let repo = repository.inner.lock().expect("repo mutex poisoned");
    stash_pop_with_id_locked(&repo, stash_id, restore_index)
}

fn stash_pop_with_id_locked(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
    restore_index: bool,
) -> Result<(), EngineError> {
    let chain = walk_stash_chain(&repo)?;
    let index =
        chain
            .iter()
            .position(|id| *id == stash_id)
            .ok_or_else(|| EngineError::GitOperation {
                message: "stash entry is no longer available".into(),
            })?;
    let next_top = if index == 0 {
        chain.get(1).copied()
    } else {
        chain.first().copied()
    };
    let untracked = untracked_paths(&repo, stash_id)?;
    apply_stash_with_merge(&repo, stash_id)?;
    restore_stashed_untracked(&repo, stash_id, &untracked)?;
    restore_untracked_index_state(&repo, &untracked)?;
    if restore_index {
        restore_stash_index(&repo, stash_id, stash_saved_base_tree(&repo, stash_id)?)?;
    }
    remove_stash_entry(&repo, stash_id, next_top)?;
    Ok(())
}

fn drop_stash_with_id_locked(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    let chain = walk_stash_chain(repo)?;
    let index =
        chain
            .iter()
            .position(|id| *id == stash_id)
            .ok_or_else(|| EngineError::GitOperation {
                message: "stash entry is no longer available".into(),
            })?;
    let next_top = if index == 0 {
        chain.get(1).copied()
    } else {
        chain.first().copied()
    };
    remove_stash_entry(repo, stash_id, next_top)
}

fn stash_saved_base_tree(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
) -> Result<gix::hash::ObjectId, EngineError> {
    let stash = repo.find_commit(stash_id).map_err(EngineError::from_gix)?;
    let index_parent = stash
        .parent_ids()
        .nth(1)
        .ok_or_else(|| EngineError::GitOperation {
            message: "stash commit has no index parent".into(),
        })?;
    let base = repo
        .find_commit(index_parent)
        .map_err(EngineError::from_gix)?
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "stash index commit has no HEAD parent".into(),
        })?
        .detach();
    repo.find_commit(base)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)
        .map(|tree| tree.detach())
}

fn restore_stash_index(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
    saved_base_tree: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    use gix::bstr::ByteSlice;

    let stash = repo.find_commit(stash_id).map_err(EngineError::from_gix)?;
    let index_parent = stash
        .parent_ids()
        .nth(1)
        .ok_or_else(|| EngineError::GitOperation {
            message: "stash commit has no index parent".into(),
        })?
        .detach();
    let index_tree = repo
        .find_commit(index_parent)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let current_head_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();

    // Restore only the staged delta (saved HEAD -> saved index) onto the new
    // HEAD. Resetting the whole index to the old snapshot would resurrect
    // paths changed by the history rewrite and would lose the new HEAD's
    // index state.
    let labels = gix::merge::blob::builtin_driver::text::Labels {
        ancestor: Some(BStr::new("saved HEAD")),
        current: Some(BStr::new("new HEAD")),
        other: Some(BStr::new("saved index")),
    };
    let options = repo.tree_merge_options().map_err(EngineError::from_gix)?;
    let mut outcome = repo
        .merge_trees(
            saved_base_tree,
            current_head_tree,
            index_tree,
            labels,
            options,
        )
        .map_err(EngineError::from_gix)?;
    let merged_index_tree = outcome
        .tree
        .write()
        .map_err(EngineError::from_gix)?
        .detach();
    if !outcome.conflicts.is_empty() {
        let conflict_entries = outcome
            .conflicts
            .iter()
            .map(|conflict| {
                let entries = conflict.entries();
                crate::merge::ConflictEntry {
                    path: conflict.ours.location().to_str_lossy().into_owned(),
                    entries: entries.map(|entry| entry.map(|e| (e.id, e.mode))),
                }
            })
            .collect::<Vec<_>>();
        let paths = crate::merge::materialize_merge_outcome(
            repo,
            current_head_tree,
            merged_index_tree,
            &conflict_entries,
        )?;
        return Err(EngineError::StashApplyConflict {
            paths,
            stash_id: Some(stash_id.to_hex().to_string()),
        });
    }
    reset_index_to_tree(repo, merged_index_tree)
}

fn apply_stash_with_merge(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    // A pull/rebase may advance HEAD while the temporary stash contains no
    // worktree change for a path (the stash worktree tree equals the saved
    // base tree). In that case there is nothing to merge back. Running the
    // generic merge against the stash commit can incorrectly materialize the
    // old stash tree into the index, producing a false MM status even though
    // HEAD and the worktree are identical.
    let stash = repo.find_commit(stash_id).map_err(EngineError::from_gix)?;
    let saved_base_tree = stash_saved_base_tree(repo, stash_id)?;
    let stash_worktree_tree = stash.tree_id().map_err(EngineError::from_gix)?.detach();
    if saved_base_tree == stash_worktree_tree {
        let current_head_tree = repo
            .head_commit()
            .map_err(EngineError::from_gix)?
            .tree_id()
            .map_err(EngineError::from_gix)?
            .detach();
        reset_index_to_tree(repo, current_head_tree)?;
        return Ok(());
    }

    let outcome =
        crate::merge::apply_merge_with_ancestor(repo, stash_id, "stash", Some(saved_base_tree))?;
    if outcome.conflicts.is_empty() {
        return Ok(());
    }
    Err(EngineError::StashApplyConflict {
        paths: outcome.conflicts,
        stash_id: Some(stash_id.to_hex().to_string()),
    })
}

/// 根据 remote-tracking refs 计算系统 Git fetch 前后的变化。
/// 系统 Git 负责 transport/credentials，gix 负责后续读取和领域模型。
fn remote_tracking_snapshot(
    repo: &gix::Repository,
    remote: &str,
) -> Result<HashMap<String, String>, EngineError> {
    Ok(crate::branch::list_remote_branches(repo)?
        .into_iter()
        .filter(|branch| branch.remote == remote)
        .map(|branch| (branch.name, branch.short_id))
        .collect())
}

/// 通过统一 Git process 执行 fetch/prune/unshallow，并刷新 gix 缓存。
/// broker 为 Some 时接入 askpass；为 None 时交给系统 Git 的 credential
/// helper/SSH 配置处理。返回的 refs 变化保持与 gix fetch 相同的 UI 契约。
fn run_fetch_with_system_git_locked(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    flags: &[&str],
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(FetchOutcome, String), EngineError> {
    run_fetch_with_tag_mode_locked(repo, remote, flags, FetchTagsMode::Default, broker, cancel)
}

fn run_fetch_with_tag_mode_locked(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    flags: &[&str],
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(FetchOutcome, String), EngineError> {
    run_fetch_with_refspecs_and_tag_mode_locked(repo, remote, flags, &[], tag_mode, broker, cancel)
}

fn run_fetch_with_refspecs_and_tag_mode_locked(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    flags: &[&str],
    refspecs: &[String],
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(FetchOutcome, String), EngineError> {
    let auth_mode = if broker.is_some() {
        RemoteAuthMode::Interactive
    } else {
        RemoteAuthMode::System
    };
    run_fetch_with_refspecs_and_tag_mode_locked_with_auth_mode(
        repo, remote, flags, refspecs, tag_mode, broker, cancel, auth_mode,
    )
}

fn run_fetch_with_refspecs_and_tag_mode_locked_with_auth_mode(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    flags: &[&str],
    refspecs: &[String],
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
    auth_mode: RemoteAuthMode,
) -> Result<(FetchOutcome, String), EngineError> {
    let name = match remote {
        Some(n) => n.trim().to_string(),
        None => crate::remote::default_remote_name(repo)?,
    };
    remote_name_ok(&name)?;
    let before = remote_tracking_snapshot(repo, &name)?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "fetch requires a non-bare worktree".into(),
    })?;
    let mut spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Fetch,
        "fetch",
    );
    spec = spec.arg("--progress");
    for flag in flags {
        spec = spec.arg(*flag);
    }
    if let Some(flag) = tag_mode.flag() {
        spec = spec.arg(flag);
    }
    let mut spec = spec.arg(&name);
    for refspec in refspecs {
        spec = spec.arg(refspec);
    }
    let spec = spec.working_dir(workdir);
    let outcome = run_remote_query_command_with_mode(&spec, broker, cancel, auth_mode)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    repo.reload().map_err(EngineError::from_gix)?;
    let updated = remote_tracking_snapshot(repo, &name)?
        .into_iter()
        .filter_map(|(ref_name, short_id)| {
            (before.get(&ref_name) != Some(&short_id)).then_some(ref_name)
        })
        .collect();
    Ok((FetchOutcome { updated }, name))
}

fn fetch_with_tag_mode_locked(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    tag_mode: FetchTagsMode,
    broker: &crate::auth::CredentialBroker,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<FetchOutcome, EngineError> {
    run_fetch_with_tag_mode_locked(repo, remote, &[], tag_mode, Some(broker), cancel)
        .map(|(outcome, _)| outcome)
}

fn fetch_with_optional_auth_and_tag_mode(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(FetchOutcome, String), EngineError> {
    fetch_with_optional_auth_and_flags_and_tag_mode(repo, remote, &[], tag_mode, broker, cancel)
}

fn fetch_with_optional_auth_and_flags_and_tag_mode(
    repo: &mut gix::Repository,
    remote: &Option<String>,
    flags: &[&str],
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(FetchOutcome, String), EngineError> {
    run_fetch_with_tag_mode_locked(repo, remote, flags, tag_mode, broker, cancel)
}

fn fetch_remote_branch_locked(
    repo: &mut gix::Repository,
    remote: &str,
    branch: &str,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<FetchOutcome, EngineError> {
    fetch_remote_branch_locked_with_tag_mode(
        repo,
        remote,
        branch,
        FetchTagsMode::Default,
        broker,
        cancel,
    )
}

fn fetch_remote_branch_locked_with_tag_mode(
    repo: &mut gix::Repository,
    remote: &str,
    branch: &str,
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<FetchOutcome, EngineError> {
    let remote = remote.trim();
    remote_name_ok(remote)?;
    let branch = branch.trim();
    let remote_prefix = format!("{remote}/");
    let branch = branch.strip_prefix(&remote_prefix).unwrap_or(branch);
    let branch = branch.strip_prefix("refs/heads/").unwrap_or(branch);
    if branch.is_empty() || branch.starts_with('-') || branch.contains(':') {
        return Err(EngineError::GitOperation {
            message: "invalid remote branch name".into(),
        });
    }
    let source_ref = format!("refs/heads/{branch}");
    let _: gix::refs::FullName = source_ref
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    // IntelliJ's branch-popup fetch pins both sides of the refspec.  A
    // source-only refspec would silently fall back to the remote's configured
    // fetch refspec, so a custom remote.<name>.fetch can make this action fail
    // to update the selected remote-tracking ref.
    let destination_ref = format!("refs/remotes/{remote}/{branch}");
    let _: gix::refs::FullName = destination_ref
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    let refspecs = vec![format!("{source_ref}:{destination_ref}")];
    run_fetch_with_refspecs_and_tag_mode_locked(
        repo,
        &Some(remote.to_string()),
        &[],
        &refspecs,
        tag_mode,
        broker,
        cancel,
    )
    .map(|(outcome, _)| outcome)
}

struct ConfiguredUpstream {
    remote: String,
    branch: String,
}

/// Resolve the actual upstream instead of assuming its branch name equals the
/// local branch name. This is the important distinction between
/// `feature -> origin/release` and the common `feature -> origin/feature` case.
fn configured_upstream(
    repo: &gix::Repository,
    local_branch: &str,
) -> Result<ConfiguredUpstream, EngineError> {
    let config_path = repo.git_dir().join("config");
    let config = gix::config::File::from_path_no_includes(config_path, gix::config::Source::Local)
        .map_err(EngineError::from_gix)?;
    let remote_key = format!("branch.{local_branch}.remote");
    let merge_key = format!("branch.{local_branch}.merge");
    let remote = config.string(&remote_key).map(|value| value.to_string());
    let merge = config.string(&merge_key).map(|value| value.to_string());
    let Some(remote) = remote else {
        return Err(EngineError::NoUpstream {
            branch: local_branch.to_string(),
        });
    };
    let Some(merge) = merge else {
        return Err(EngineError::NoUpstream {
            branch: local_branch.to_string(),
        });
    };
    let branch = merge
        .strip_prefix("refs/heads/")
        .unwrap_or(merge.as_str())
        .trim_start_matches('/')
        .to_string();
    if branch.is_empty() {
        return Err(EngineError::GitOperation {
            message: format!("pull: invalid upstream branch for '{local_branch}'"),
        });
    }
    Ok(ConfiguredUpstream { remote, branch })
}

/// Fetch and fast-forward one local branch without checking it out. The
/// optional broker/cancel pair is used by Branches -> Update Selected so a
/// non-current branch follows the same credential and cancellation contract
/// as the current-branch update path.
fn update_branch_locked(
    repo: &mut gix::Repository,
    branch: &str,
    tag_mode: FetchTagsMode,
    broker: Option<&crate::auth::CredentialBroker>,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(), EngineError> {
    use gix::refs::transaction::PreviousValue;
    use gix::refs::Target;

    let branch = branch.trim();
    if branch.is_empty() || branch.starts_with('-') {
        return Err(EngineError::GitOperation {
            message: "branch name must not be empty or start with '-'".into(),
        });
    }
    let current = repo
        .head_name()
        .map_err(EngineError::from_gix)?
        .map(|name| shorten_ref_name(name.as_bstr()));
    if current.as_deref() == Some(branch) {
        return Err(EngineError::GitOperation {
            message: format!(
                "branch '{branch}' is checked out; use the current-branch update path"
            ),
        });
    }

    let upstream = configured_upstream(repo, branch)?;
    if upstream.remote == "." {
        return Err(EngineError::GitOperation {
            message: "update: local repository upstream is not supported".into(),
        });
    }
    let remote_name = upstream.remote.clone();
    fetch_remote_branch_locked_with_tag_mode(
        repo,
        &remote_name,
        &upstream.branch,
        tag_mode,
        broker,
        cancel,
    )?;
    let tracking = format!("refs/remotes/{remote_name}/{}", upstream.branch);
    let tracking_id = repo
        .rev_parse_single(BStr::new(tracking.as_bytes()))
        .map_err(|_| EngineError::TrackingMissing {
            branch: branch.to_string(),
            upstream: format!("{remote_name}/{}", upstream.branch),
        })?
        .detach();
    let local_ref = format!("refs/heads/{branch}");
    let local_name: gix::refs::FullName = local_ref
        .as_str()
        .try_into()
        .map_err(EngineError::from_gix)?;
    let local_id = repo
        .find_reference(local_ref.as_str())
        .map_err(EngineError::from_gix)?
        .try_id()
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("branch '{branch}' has no object id"),
        })?
        .detach();
    if local_id == tracking_id {
        return Ok(());
    }
    let tracking_reachable = reachable_from(repo, tracking_id)?;
    if !tracking_reachable.contains(&local_id) {
        return Err(EngineError::GitOperation {
            message: format!(
                "branch '{branch}' has diverged from {remote_name}/{}; checkout it, then merge or rebase",
                upstream.branch
            ),
        });
    }
    repo.reference(
        local_name,
        tracking_id,
        PreviousValue::MustExistAndMatch(Target::Object(local_id)),
        "branch: update",
    )
    .map_err(EngineError::from_gix)?;
    Ok(())
}

/// The non-interactive all-pick rebase used by `pull --rebase`.
/// It deliberately shares the same persisted conflict state as the public
/// interactive rebase API, so the existing resolve/continue/abort UI works.
fn pull_rebase_locked(
    repo: &gix::Repository,
    onto_id: gix::hash::ObjectId,
    onto_label: &str,
) -> Result<RebaseOutcome, EngineError> {
    let original_head = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let original_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let range_base = repo
        .merge_base(original_head, onto_id)
        .map_err(EngineError::from_gix)?
        .detach();
    let mut range = Vec::new();
    let mut cursor = original_head;
    loop {
        if cursor == range_base {
            break;
        }
        let commit = repo.find_commit(cursor).map_err(EngineError::from_gix)?;
        let Some(first_parent) = commit.parent_ids().next() else {
            return Err(EngineError::GitOperation {
                message: "pull --rebase: local history has no merge-base on its first-parent line"
                    .into(),
            });
        };
        // Match `git pull --rebase`'s default linear rebase: merge commits are
        // not replayed as merge commits, but their first-parent descendants are.
        if commit.parent_ids().nth(1).is_none() {
            range.push(cursor);
        }
        cursor = first_parent.detach();
    }
    range.reverse();
    let pairs: Vec<(RebaseAction, gix::hash::ObjectId)> = range
        .into_iter()
        .map(|id| (RebaseAction::Pick, id))
        .collect();
    let onto_tree = repo
        .find_commit(onto_id)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();

    move_head_to(repo, onto_id)?;
    match apply_rebase_actions(repo, onto_id, onto_tree, &pairs, true, None) {
        Ok(ApplyOutcome::Done { head, tree }) => {
            finalize_rebase(repo, original_tree, head, tree)?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: false,
                pause_reason: None,
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::Paused {
            head,
            tree,
            message,
            remaining,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head,
                    onto: onto_id,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Edit,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Edit),
                conflicts: Vec::new(),
            })
        }
        Ok(ApplyOutcome::PausedConflict {
            head,
            tree,
            message,
            remaining,
            conflicts,
        }) => {
            save_rebase_state(
                repo,
                &RebaseState {
                    original_head,
                    onto: onto_id,
                    head,
                    tree,
                    message,
                    reason: RebasePauseReason::Conflict,
                    remaining,
                },
            )?;
            Ok(RebaseOutcome {
                head_id: head.to_hex().to_string(),
                paused: true,
                pause_reason: Some(RebasePauseReason::Conflict),
                conflicts,
            })
        }
        Err(error) => {
            restore_head(repo, original_head)?;
            Err(EngineError::GitOperation {
                message: format!("pull --rebase ({onto_label}): {error}"),
            })
        }
    }
}

const SSH_BASE_COMMAND_KEY: &str = "arbor.ssh.baseCommand";
const SSH_KNOWN_HOSTS_KEY: &str = "arbor.ssh.knownHostsFile";
const SSH_IDENTITY_FILE_KEY: &str = "arbor.ssh.identityFile";
const SSH_HOST_KEY_POLICY_KEY: &str = "arbor.ssh.hostKeyPolicy";
const SSH_AUTH_METHOD_KEY: &str = "arbor.ssh.authMethod";

impl SshHostKeyPolicy {
    fn config_value(self) -> &'static str {
        match self {
            Self::Strict => "strict",
            Self::AcceptNew => "accept-new",
            Self::Ask => "ask",
            Self::NoCheck => "no-check",
        }
    }
}

impl SshAuthMethod {
    fn config_value(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::PublicKey => "public-key",
            Self::Password => "password",
        }
    }
}

fn clear_structured_ssh_config(workdir: &Path) -> Result<(), EngineError> {
    for key in [
        SSH_BASE_COMMAND_KEY,
        SSH_KNOWN_HOSTS_KEY,
        SSH_IDENTITY_FILE_KEY,
        SSH_HOST_KEY_POLICY_KEY,
        SSH_AUTH_METHOD_KEY,
    ] {
        unset_git_config_value(workdir, key)?;
    }
    Ok(())
}

fn set_or_unset_config_value(workdir: &Path, key: &str, value: &str) -> Result<(), EngineError> {
    if value.is_empty() {
        unset_git_config_value(workdir, key)
    } else {
        set_git_config_value(workdir, key, value)
    }
}

fn validated_merge_tool_name(key: &str, value: &str) -> Result<String, EngineError> {
    let value = value.trim();
    if value.contains('\0') || value.contains('\n') || value.contains('\r') {
        return Err(EngineError::GitOperation {
            message: format!("{key} cannot contain NUL or newline characters"),
        });
    }
    Ok(value.to_string())
}

fn build_ssh_command(
    command: &str,
    known_hosts_file: &str,
    identity_file: &str,
    host_key_policy: SshHostKeyPolicy,
    auth_method: SshAuthMethod,
) -> String {
    let mut result = if command.trim().is_empty() {
        "ssh".to_string()
    } else {
        command.trim().to_string()
    };
    if !identity_file.is_empty() {
        result.push_str(" -i ");
        result.push_str(&shell_quote_for_display(&expand_home_path(identity_file)));
        result.push_str(" -o IdentitiesOnly=yes");
    }
    if !known_hosts_file.is_empty() {
        result.push_str(" -o ");
        result.push_str(&shell_quote_for_display(&format!(
            "UserKnownHostsFile={}",
            expand_home_path(known_hosts_file)
        )));
    }
    result.push_str(" -o StrictHostKeyChecking=");
    result.push_str(match host_key_policy {
        SshHostKeyPolicy::Strict => "yes",
        SshHostKeyPolicy::AcceptNew => "accept-new",
        SshHostKeyPolicy::Ask => "ask",
        SshHostKeyPolicy::NoCheck => "no",
    });
    match auth_method {
        SshAuthMethod::Auto => {}
        SshAuthMethod::PublicKey => {
            result.push_str(" -o PreferredAuthentications=publickey");
        }
        SshAuthMethod::Password => {
            result.push_str(" -o PreferredAuthentications=password,keyboard-interactive");
        }
    }
    result
}

fn expand_home_path(value: &str) -> String {
    let Some(home) = std::env::var_os("HOME") else {
        return value.to_string();
    };
    let home = PathBuf::from(home).to_string_lossy().into_owned();
    if value == "~" {
        home
    } else if let Some(rest) = value.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else {
        value.to_string()
    }
}

fn command_output_message(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if stderr.is_empty() {
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    } else {
        stderr
    }
}

fn git_process_output_message(output: &crate::gitprocess::GitProcessOutcome) -> String {
    if output.stderr.trim().is_empty() {
        output.stdout.trim().to_string()
    } else {
        output.stderr.trim().to_string()
    }
}

#[derive(Clone, Debug)]
struct IndexStageRecord {
    mode: String,
    object: String,
    stage: u8,
}

fn run_git_with_index(
    workdir: &Path,
    args: &[String],
    index_path: Option<&Path>,
) -> Result<std::process::Output, EngineError> {
    run_git_with_index_and_environment(workdir, args, index_path, &[])
}

fn run_git_with_index_and_environment(
    workdir: &Path,
    args: &[String],
    index_path: Option<&Path>,
    environment: &[(String, String)],
) -> Result<std::process::Output, EngineError> {
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args(args).current_dir(workdir);
    if let Some(index_path) = index_path {
        command.env("GIT_INDEX_FILE", index_path);
    }
    for (key, value) in environment {
        command.env(key, value);
    }
    command.output().map_err(EngineError::from_gix)
}

fn ensure_git_command_success(
    output: &std::process::Output,
    operation: &str,
) -> Result<(), EngineError> {
    if output.status.success() {
        return Ok(());
    }
    Err(EngineError::GitOperation {
        message: format!("{operation} failed: {}", command_output_message(output)),
    })
}

fn parse_index_stage_records(
    bytes: &[u8],
) -> Result<HashMap<String, Vec<IndexStageRecord>>, EngineError> {
    let mut records = HashMap::new();
    for record in bytes.split(|byte| *byte == 0) {
        if record.is_empty() {
            continue;
        }
        let separator = record
            .iter()
            .position(|byte| *byte == b'\t')
            .ok_or_else(|| EngineError::GitOperation {
                message: "git ls-files returned a malformed index record".into(),
            })?;
        let metadata = &record[..separator];
        let path = String::from_utf8(record[separator + 1..].to_vec()).map_err(|_| {
            EngineError::GitOperation {
                message: "selected commit encountered a non-UTF-8 index path".into(),
            }
        })?;
        let fields = metadata.split(|byte| *byte == b' ').collect::<Vec<_>>();
        if fields.len() != 3 {
            return Err(EngineError::GitOperation {
                message: "git ls-files returned a malformed index metadata record".into(),
            });
        }
        let mode =
            String::from_utf8(fields[0].to_vec()).map_err(|_| EngineError::GitOperation {
                message: "git ls-files returned an invalid index mode".into(),
            })?;
        let object =
            String::from_utf8(fields[1].to_vec()).map_err(|_| EngineError::GitOperation {
                message: "git ls-files returned an invalid index object".into(),
            })?;
        let stage = String::from_utf8(fields[2].to_vec())
            .ok()
            .and_then(|value| value.parse::<u8>().ok())
            .ok_or_else(|| EngineError::GitOperation {
                message: "git ls-files returned an invalid index stage".into(),
            })?;
        records
            .entry(path)
            .or_insert_with(Vec::new)
            .push(IndexStageRecord {
                mode,
                object,
                stage,
            });
    }
    Ok(records)
}

fn parse_nul_paths(bytes: &[u8]) -> Result<HashSet<String>, EngineError> {
    bytes
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .map(|record| {
            String::from_utf8(record.to_vec()).map_err(|_| EngineError::GitOperation {
                message: "selected commit encountered a non-UTF-8 index path".into(),
            })
        })
        .collect()
}

fn shell_quote_for_display(value: &str) -> String {
    if value
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "_./:@%+-".contains(character))
    {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

fn append_coauthor_trailers(message: String, co_authors: &[String]) -> String {
    let authors: Vec<String> = co_authors
        .iter()
        .map(|value| {
            value
                .trim()
                .trim_start_matches("Co-authored-by:")
                .trim()
                .to_string()
        })
        .filter(|value| !value.is_empty())
        .collect();
    if authors.is_empty() {
        return message;
    }
    let mut result = message.trim_end().to_string();
    result.push_str("\n\n");
    for author in authors {
        result.push_str("Co-authored-by: ");
        result.push_str(&author);
        result.push('\n');
    }
    result
}

pub(crate) fn git_config_effective_value(
    workdir: &Path,
    key: &str,
) -> Result<Option<String>, EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", "--get", key])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        if matches!(output.status.code(), Some(1) | Some(5)) {
            return Ok(None);
        }
        return Err(EngineError::GitOperation {
            message: format!("git config failed: {}", command_output_message(&output)),
        });
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok((!value.is_empty()).then_some(value))
}

fn set_git_config_value_scope(
    workdir: &Path,
    key: &str,
    value: &str,
    scope: &str,
) -> Result<(), EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", scope, key, value])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git config {scope} failed: {}",
                command_output_message(&output)
            ),
        });
    }
    Ok(())
}

fn git_config_values(workdir: &Path, key: &str) -> Result<Vec<String>, EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", "--local", "--get-all", key])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        if matches!(output.status.code(), Some(1) | Some(5)) {
            return Ok(Vec::new());
        }
        return Err(EngineError::GitOperation {
            message: format!("git config failed: {}", command_output_message(&output)),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect())
}

fn set_git_config_value(workdir: &Path, key: &str, value: &str) -> Result<(), EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", "--local", key, value])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!("git config failed: {}", command_output_message(&output)),
        });
    }
    Ok(())
}

fn add_git_config_value(workdir: &Path, key: &str, value: &str) -> Result<(), EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", "--local", "--add", key, value])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!("git config failed: {}", command_output_message(&output)),
        });
    }
    Ok(())
}

fn unset_git_config_value(workdir: &Path, key: &str) -> Result<(), EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", "--local", "--unset", key])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() && output.status.code() != Some(5) {
        return Err(EngineError::GitOperation {
            message: format!("git config failed: {}", command_output_message(&output)),
        });
    }
    Ok(())
}

fn unset_git_config_values(workdir: &Path, key: &str) -> Result<(), EngineError> {
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["config", "--local", "--unset-all", key])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() && output.status.code() != Some(5) {
        return Err(EngineError::GitOperation {
            message: format!("git config failed: {}", command_output_message(&output)),
        });
    }
    Ok(())
}

#[cfg(test)]
mod rebase_editor_tests {
    use super::write_rebase_editors;
    use std::process::Command;

    #[test]
    fn desired_order_moves_update_ref_rows_with_their_pick_block() {
        let directory = tempfile::tempdir().expect("temporary rebase editor directory");
        let sequence_editor = directory.path().join("sequence-editor.sh");
        let message_editor = directory.path().join("message-editor.sh");
        let action_map = directory.path().join("actions.tsv");
        let order_file = directory.path().join("order.tsv");
        let todo = directory.path().join("git-rebase-todo");

        write_rebase_editors(
            &sequence_editor,
            &message_editor,
            &action_map,
            directory.path(),
            Some(&order_file),
        )
        .expect("write rebase editor scripts");
        std::fs::write(&action_map, "").expect("write empty action map");
        std::fs::write(&order_file, "bbb222\naaa111\nccc333\n").expect("write desired order");
        std::fs::write(
            &todo,
            "pick aaa111 # A\npick bbb222 # B\nupdate-ref refs/heads/topic\n\nupdate-ref refs/heads/main\n\npick ccc333 # C\n# generated comment\n",
        )
        .expect("write native todo");

        let output = Command::new("sh")
            .arg(&sequence_editor)
            .arg(&todo)
            .output()
            .expect("run rebase sequence editor");
        assert!(
            output.status.success(),
            "sequence editor failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let rewritten = std::fs::read_to_string(&todo).expect("read rewritten todo");
        assert_eq!(
            rewritten,
            "pick bbb222 # B\npick aaa111 # A\nupdate-ref refs/heads/topic\n\nupdate-ref refs/heads/main\n\npick ccc333 # C\n# generated comment\n"
        );
    }
}

#[cfg(test)]
mod remote_auth_mode_tests {
    use super::disable_interactive_auth;
    use crate::gitprocess::{GitCommandCategory, GitCommandSpec};

    #[test]
    fn no_auth_mode_overrides_all_interactive_auth_channels() {
        let spec = GitCommandSpec::new(GitCommandCategory::Fetch, "ls-remote");
        let disabled = disable_interactive_auth(&spec);

        assert_eq!(disabled.global_args, vec!["-c", "credential.helper="]);
        assert_eq!(
            disabled.env,
            vec![
                ("GIT_ASKPASS".into(), "".into()),
                ("GIT_TERMINAL_PROMPT".into(), "0".into()),
                ("SSH_ASKPASS".into(), "".into()),
                ("SSH_ASKPASS_REQUIRE".into(), "never".into()),
            ]
        );
    }
}

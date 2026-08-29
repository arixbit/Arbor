//! ENG-001：统一 Git 进程执行层。
//!
//! 所有直接调用 system git 的代码逐步收敛到这里，获得统一能力：
//! - 结构化参数建模（`GitCommandSpec`），禁止各处拼接 shell 字符串；
//! - stdout/stderr 流式事件（回调逐块投递，而非进程结束后一次性返回）；
//! - 取消（`GitCancelToken` -> 杀整个进程组，git 派生的 ssh/askpass 一并清理）
//!   与超时；
//! - 结构化结果（exit code、耗时、`GitFailureKind` 失败分类），认证失败、
//!   网络失败、冲突、non-fast-forward、用户取消可区分；
//! - 凭证脱敏：URL 内嵌密码与显式 secret 不会进入 stdout/stderr/display。

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::{Duration, Instant};

use crate::error::EngineError;

/// 当前应用使用的 Git 可执行文件。IntelliJ 将它作为 application-level
/// setting；项目级 override 在工作目录匹配时覆盖这个 fallback。
static GIT_EXECUTABLE: OnceLock<RwLock<PathBuf>> = OnceLock::new();
static PROJECT_GIT_EXECUTABLES: OnceLock<RwLock<HashMap<PathBuf, ProjectGitExecutable>>> =
    OnceLock::new();
static PROJECT_GIT_EXECUTABLE_GENERATION: AtomicU64 = AtomicU64::new(1);
/// Ephemeral pinentry endpoint data inherited by Git/GPG child processes.
///
/// The value is intentionally kept outside `GitCommandSpec`: a signed commit
/// can create several nested Git/GPG processes, and all of them must inherit
/// the same short-lived `PINENTRY_USER_DATA` value. Callers clear it as soon
/// as the signed operation returns.
static PINENTRY_USER_DATA: OnceLock<RwLock<Option<String>>> = OnceLock::new();

thread_local! {
    static SCOPED_GIT_EXECUTABLES: RefCell<Vec<PathBuf>> = const { RefCell::new(Vec::new()) };
}

#[derive(Clone, Debug)]
struct ProjectGitExecutable {
    roots: Vec<PathBuf>,
    executable: PathBuf,
    generation: u64,
}

/// Temporary per-thread executable scope installed while a Repository lock is
/// held. This prevents two project windows that happen to share a Git root
/// from changing each other's direct system-Git calls.
pub(crate) struct GitExecutableScope {
    previous: Option<PathBuf>,
}

impl Drop for GitExecutableScope {
    fn drop(&mut self) {
        let previous = self.previous.take();
        SCOPED_GIT_EXECUTABLES.with(|scopes| {
            let mut scopes = scopes.borrow_mut();
            if scopes.is_empty() {
                if let Some(previous) = previous {
                    scopes.push(previous);
                }
            } else {
                scopes.pop();
                if let Some(previous) = previous {
                    scopes.push(previous);
                }
            }
        });
    }
}

pub(crate) fn begin_git_executable_scope(executable: PathBuf) -> GitExecutableScope {
    let previous = SCOPED_GIT_EXECUTABLES.with(|scopes| {
        let mut scopes = scopes.borrow_mut();
        let previous = scopes.last().cloned();
        scopes.push(executable);
        previous
    });
    GitExecutableScope { previous }
}

fn scoped_git_executable() -> Option<PathBuf> {
    SCOPED_GIT_EXECUTABLES.with(|scopes| scopes.borrow().last().cloned())
}

fn pinentry_user_data() -> &'static RwLock<Option<String>> {
    PINENTRY_USER_DATA.get_or_init(|| RwLock::new(None))
}

/// Set or clear the process-local pinentry endpoint inherited by Git.
///
/// This is application state rather than repository configuration. The value
/// must be an opaque, short-lived token understood by the Swift pinentry
/// service; it is never written to Git config or operation logs.
#[uniffi::export]
pub fn set_pinentry_user_data(value: Option<String>) {
    *pinentry_user_data()
        .write()
        .expect("pinentry user data lock poisoned") = value;
}

#[derive(Clone, Debug)]
struct ActiveGitProgress {
    generation: u64,
    state: GitProgressState,
    parent: Option<Box<ActiveGitProgress>>,
}

static ACTIVE_GIT_PROGRESS: OnceLock<RwLock<Option<ActiveGitProgress>>> = OnceLock::new();
static NEXT_PROGRESS_GENERATION: AtomicU64 = AtomicU64::new(1);
static ACTIVE_ROOT_PROGRESS: OnceLock<RwLock<Option<RootProgressContext>>> = OnceLock::new();

#[derive(Clone, Debug)]
struct RootProgressContext {
    root_path: String,
    root_name: String,
    completed_roots: u32,
    total_roots: u32,
}

fn active_git_progress() -> &'static RwLock<Option<ActiveGitProgress>> {
    ACTIVE_GIT_PROGRESS.get_or_init(|| RwLock::new(None))
}

fn active_root_progress() -> &'static RwLock<Option<RootProgressContext>> {
    ACTIVE_ROOT_PROGRESS.get_or_init(|| RwLock::new(None))
}

fn current_root_progress() -> Option<RootProgressContext> {
    active_root_progress()
        .read()
        .expect("root progress lock poisoned")
        .clone()
}

/// 当前统一 Git 进程的传输进度。
///
/// Git 把传输进度写到 stderr，并用 `\r` 原地刷新；引擎将其规范化成可供
/// SwiftUI 轮询的快照。这个快照只描述当前活跃命令，命令结束后立即清除。
#[derive(uniffi::Record, Clone, Debug)]
pub struct GitProgressState {
    pub category: String,
    pub phase: String,
    pub percentage: Option<u32>,
    pub detail: String,
    pub root_path: String,
    pub root_name: String,
    pub completed_roots: u32,
    pub total_roots: u32,
    pub root_state: String,
}

#[uniffi::export]
pub fn git_progress_state() -> Option<GitProgressState> {
    active_git_progress()
        .read()
        .expect("git progress lock poisoned")
        .as_ref()
        .map(|active| active.state.clone())
}

fn begin_git_progress(spec: &GitCommandSpec) -> u64 {
    begin_operation_progress(
        spec.category.as_str().to_string(),
        "Starting".to_string(),
        spec.display(),
    )
}

fn update_git_progress(generation: u64, phase: String, percentage: u32, detail: String) {
    update_operation_progress(generation, phase, Some(percentage), detail);
}

fn end_git_progress(generation: u64) {
    end_operation_progress(generation);
}

/// Begin a progress snapshot for a non-Git-process engine operation. The
/// Swift status bar already polls this same immutable snapshot, so Shelf
/// apply can expose real file-loop progress without inventing a second FFI
/// callback or changing the atomic merge API.
pub(crate) fn begin_operation_progress(category: String, phase: String, detail: String) -> u64 {
    let generation = NEXT_PROGRESS_GENERATION.fetch_add(1, Ordering::Relaxed);
    let root = current_root_progress();
    let state = GitProgressState {
        category,
        phase,
        percentage: None,
        detail,
        root_path: root
            .as_ref()
            .map(|value| value.root_path.clone())
            .unwrap_or_default(),
        root_name: root
            .as_ref()
            .map(|value| value.root_name.clone())
            .unwrap_or_default(),
        completed_roots: root.as_ref().map_or(0, |value| value.completed_roots),
        total_roots: root.as_ref().map_or(0, |value| value.total_roots),
        root_state: String::new(),
    };
    let mut active = active_git_progress()
        .write()
        .expect("git progress lock poisoned");
    let parent = active.take().map(Box::new);
    *active = Some(ActiveGitProgress {
        generation,
        state,
        parent,
    });
    generation
}

/// Start one root of a sequential multi-root operation. Nested system-Git
/// transport progress inherits this root identity while retaining its own
/// byte-level percentage.
pub(crate) fn begin_root_operation_progress(
    root_index: usize,
    total_roots: usize,
    root_path: String,
    root_name: String,
) -> u64 {
    let context = RootProgressContext {
        root_path,
        root_name: root_name.clone(),
        completed_roots: root_index as u32,
        total_roots: total_roots as u32,
    };
    *active_root_progress()
        .write()
        .expect("root progress lock poisoned") = Some(context);
    begin_operation_progress(
        "multi-root".to_string(),
        format!("Root {}/{}", root_index.saturating_add(1), total_roots),
        format!("{root_name} — running"),
    )
}

/// Publish a root terminal state without losing its root metadata.
pub(crate) fn update_root_operation_progress(
    generation: u64,
    completed_roots: usize,
    root_state: String,
) {
    let mut active = active_git_progress()
        .write()
        .expect("git progress lock poisoned");
    let Some(active) = active.as_mut() else {
        return;
    };
    if active.generation != generation {
        return;
    }
    let total_roots = active.state.total_roots as usize;
    let completed_roots = completed_roots.min(total_roots);
    active.state.completed_roots = completed_roots as u32;
    active.state.root_state = root_state.clone();
    active.state.percentage =
        (total_roots > 0).then(|| ((completed_roots.saturating_mul(100)) / total_roots) as u32);
    active.state.phase = if total_roots > 0 {
        format!("Root {completed_roots}/{total_roots}")
    } else {
        "Root".to_string()
    };
    active.state.detail = if active.state.root_name.is_empty() {
        root_state
    } else {
        format!("{} — {root_state}", active.state.root_name)
    };
}

/// Finish one root progress generation and clear the inherited root context.
pub(crate) fn end_root_operation_progress(generation: u64) {
    end_operation_progress(generation);
    *active_root_progress()
        .write()
        .expect("root progress lock poisoned") = None;
}

pub(crate) fn update_operation_progress(
    generation: u64,
    phase: String,
    percentage: Option<u32>,
    detail: String,
) {
    let mut active = active_git_progress()
        .write()
        .expect("git progress lock poisoned");
    let Some(active) = active.as_mut() else {
        return;
    };
    if active.generation != generation {
        return;
    }
    active.state.phase = phase;
    active.state.percentage = percentage;
    active.state.detail = detail;
}

/// Update the currently active operation only when it belongs to the caller's
/// category. This is used by lower-level tree materialization helpers that do
/// not otherwise need to carry a progress handle through their signatures.
pub(crate) fn update_active_operation_progress(
    category: &str,
    phase: String,
    percentage: Option<u32>,
    detail: String,
) {
    let mut active = active_git_progress()
        .write()
        .expect("git progress lock poisoned");
    let Some(active) = active.as_mut() else {
        return;
    };
    if active.state.category != category {
        return;
    }
    active.state.phase = phase;
    active.state.percentage = percentage;
    active.state.detail = detail;
}

pub(crate) fn end_operation_progress(generation: u64) {
    let mut active = active_git_progress()
        .write()
        .expect("git progress lock poisoned");
    if active
        .as_ref()
        .is_some_and(|current| current.generation == generation)
    {
        *active = active
            .take()
            .and_then(|current| current.parent.map(|parent| *parent));
    }
}

fn git_executable_store() -> &'static RwLock<PathBuf> {
    GIT_EXECUTABLE.get_or_init(|| RwLock::new(PathBuf::from("git")))
}

fn project_git_executable_store() -> &'static RwLock<HashMap<PathBuf, ProjectGitExecutable>> {
    PROJECT_GIT_EXECUTABLES.get_or_init(|| RwLock::new(HashMap::new()))
}

fn normalize_working_path(path: &std::path::Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    std::fs::canonicalize(&absolute).unwrap_or(absolute)
}

fn path_depth(path: &std::path::Path) -> usize {
    path.components().count()
}

fn app_git_executable() -> PathBuf {
    git_executable_store()
        .read()
        .expect("git executable lock poisoned")
        .clone()
}

pub(crate) fn project_git_executable_for_working_dir(
    working_dir: Option<&std::path::Path>,
) -> Option<PathBuf> {
    let working_dir = normalize_working_path(working_dir?);
    let projects = project_git_executable_store()
        .read()
        .expect("project git executable lock poisoned");
    projects
        .values()
        .flat_map(|project| {
            project.roots.iter().filter_map(|root| {
                if working_dir.starts_with(root) {
                    Some((path_depth(root), project.generation, &project.executable))
                } else {
                    None
                }
            })
        })
        .max_by_key(|(depth, generation, _)| (*depth, *generation))
        .map(|(_, _, executable)| executable.clone())
}

pub(crate) fn git_executable_for_working_dir(working_dir: Option<&std::path::Path>) -> PathBuf {
    if let Some(executable) = scoped_git_executable() {
        return executable;
    }
    project_git_executable_for_working_dir(working_dir).unwrap_or_else(app_git_executable)
}

/// 创建一个使用项目/root 作用域 Git executable 的 argv 命令。
pub(crate) fn git_command_for_working_dir(
    working_dir: impl AsRef<std::path::Path>,
) -> std::process::Command {
    std::process::Command::new(git_executable_for_working_dir(Some(working_dir.as_ref())))
}

/// 创建一个使用当前配置 Git 可执行文件的 argv 命令。
/// 统一入口避免各模块悄悄绕过 Git executable 设置。
pub(crate) fn git_command() -> std::process::Command {
    let path = scoped_git_executable().unwrap_or_else(app_git_executable);
    std::process::Command::new(path)
}

pub(crate) fn validate_git_executable(path: &str) -> Result<String, EngineError> {
    let candidate = path.trim();
    let executable = if candidate.is_empty() {
        "git"
    } else {
        candidate
    };
    let output = std::process::Command::new(executable)
        .arg("--version")
        .output()
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot start Git executable '{executable}': {error}"),
        })?;
    let version = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() || !version.to_ascii_lowercase().contains("git version") {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(EngineError::GitOperation {
            message: if detail.is_empty() {
                format!("'{executable}' did not report a valid Git version")
            } else {
                format!("'{executable}' is not a valid Git executable: {detail}")
            },
        });
    }
    Ok(executable.to_string())
}

/// 当前生效的 Git executable；默认返回 PATH 中的 `git`。
#[uniffi::export]
pub fn git_executable() -> String {
    git_executable_store()
        .read()
        .expect("git executable lock poisoned")
        .to_string_lossy()
        .into_owned()
}

/// 验证并设置当前进程的 Git executable。传入空字符串恢复 PATH 默认值。
#[uniffi::export]
pub fn set_git_executable(path: String) -> Result<String, EngineError> {
    let executable = validate_git_executable(&path)?;
    *git_executable_store()
        .write()
        .expect("git executable lock poisoned") = PathBuf::from(&executable);
    Ok(executable)
}

/// 为一个项目注册 Git executable override 及其当前已发现的 roots。
///
/// `working_dir` 解析时使用最长 root 匹配；同一 root 被多个项目注册时，
/// 最近一次注册的项目生效。Repository/操作完成后仍应在调用方保持自己的
/// project scope，避免把应用级 fallback 当成项目配置。
#[uniffi::export]
pub fn set_project_git_executable(
    project_path: String,
    root_paths: Vec<String>,
    path: String,
) -> Result<String, EngineError> {
    let executable = validate_git_executable(&path)?;
    let project = normalize_working_path(std::path::Path::new(&project_path));
    let mut roots = root_paths
        .iter()
        .map(|root| normalize_working_path(std::path::Path::new(root)))
        .collect::<Vec<_>>();
    if roots.is_empty() {
        roots.push(project.clone());
    }
    roots.push(project.clone());
    roots.sort();
    roots.dedup();
    let generation = PROJECT_GIT_EXECUTABLE_GENERATION.fetch_add(1, Ordering::Relaxed);
    project_git_executable_store()
        .write()
        .expect("project git executable lock poisoned")
        .insert(
            project,
            ProjectGitExecutable {
                roots,
                executable: PathBuf::from(&executable),
                generation,
            },
        );
    Ok(executable)
}

/// 清除一个项目的 Git executable override；之后该项目使用应用级默认值。
#[uniffi::export]
pub fn clear_project_git_executable(project_path: String) {
    let project = normalize_working_path(std::path::Path::new(&project_path));
    project_git_executable_store()
        .write()
        .expect("project git executable lock poisoned")
        .remove(&project);
}

/// 返回项目 override 的 executable；没有 override 时返回 None。
#[uniffi::export]
pub fn project_git_executable(project_path: String) -> Option<String> {
    let project = normalize_working_path(std::path::Path::new(&project_path));
    project_git_executable_store()
        .read()
        .expect("project git executable lock poisoned")
        .get(&project)
        .map(|value| value.executable.to_string_lossy().into_owned())
}

/// 验证一个候选 Git executable，但不改变当前生效配置。
#[uniffi::export]
pub fn test_git_executable(path: String) -> Result<String, EngineError> {
    let executable = validate_git_executable(&path)?;
    let output = std::process::Command::new(&executable)
        .arg("--version")
        .output()
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot start Git executable '{executable}': {error}"),
        })?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// 返回当前 Git executable 的版本文本，用于 Settings 的 Test 按钮。
#[uniffi::export]
pub fn git_executable_version() -> Result<String, EngineError> {
    let output =
        git_command()
            .arg("--version")
            .output()
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot start Git executable: {error}"),
            })?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git --version failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// 命令类别：用于日志、指标和失败统计（禁止记录参数中的凭证）。
/// 后续命令迁移会消费全部分类，当前未被构造的变体属预期 API 面。
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitCommandCategory {
    Clone,
    Fetch,
    Push,
    Pull,
    Merge,
    Rebase,
    CherryPick,
    Revert,
    Stash,
    Config,
    Status,
    Log,
    Branch,
    Tag,
    Submodule,
    Worktree,
    Hook,
    Other,
}

impl GitCommandCategory {
    /// 供日志/指标使用；当前仅测试消费，保留为 API 面。
    #[allow(dead_code)]
    pub fn as_str(self) -> &'static str {
        match self {
            GitCommandCategory::Clone => "clone",
            GitCommandCategory::Fetch => "fetch",
            GitCommandCategory::Push => "push",
            GitCommandCategory::Pull => "pull",
            GitCommandCategory::Merge => "merge",
            GitCommandCategory::Rebase => "rebase",
            GitCommandCategory::CherryPick => "cherry-pick",
            GitCommandCategory::Revert => "revert",
            GitCommandCategory::Stash => "stash",
            GitCommandCategory::Config => "config",
            GitCommandCategory::Status => "status",
            GitCommandCategory::Log => "log",
            GitCommandCategory::Branch => "branch",
            GitCommandCategory::Tag => "tag",
            GitCommandCategory::Submodule => "submodule",
            GitCommandCategory::Worktree => "worktree",
            GitCommandCategory::Hook => "hook",
            GitCommandCategory::Other => "other",
        }
    }
}

/// 结构化失败分类。远程操作的错误必须能区分认证失败、网络失败、冲突、
/// non-fast-forward 与用户取消（ENG-001 验收要求）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitFailureKind {
    /// 用户取消（或取消令牌触发）。
    Cancelled,
    /// 超时被杀。
    Timeout,
    /// 用户名/密码/token/SSH key 认证失败。
    Authentication,
    /// SSH 远端 host key 与 known_hosts 中的记录不一致，连接被阻止。
    HostKeyChanged,
    /// 网络不可达、DNS、连接中断。
    Network,
    /// merge/rebase/cherry-pick/revert 产生冲突。
    Conflict,
    /// 存在未解决的 unmerged index 条目。
    UnmergedPaths,
    /// 远程会覆盖本地未跟踪文件。
    UntrackedWouldBeOverwritten,
    /// 远程/检出会覆盖本地未提交修改。
    LocalChangesWouldBeOverwritten,
    /// push 被拒绝：非 fast-forward（需要先 fetch/merge）。
    NonFastForward,
    /// 远程仓库不存在或无权限访问的 404 类错误。
    RepositoryNotFound,
    /// pre-commit / commit-msg / pre-push 等 hook 拒绝。
    HookRejected,
    /// `.git/index.lock` 等锁文件冲突。
    LockFailure,
    /// 其他失败。
    Other,
}

/// 流式事件：进程运行期间逐块投递 stdout/stderr。
/// git 的进度（remote: xx%、Resolving deltas…）走 stderr，含 \r 分隔。
#[derive(Clone, Debug)]
pub enum GitStreamEvent {
    // chunk 由消费方回调读取;当前无外部消费者,保留为事件 API 面。
    #[allow(dead_code)]
    Stdout { chunk: String },
    #[allow(dead_code)]
    Stderr { chunk: String },
}

/// 取消令牌：跨线程共享；触发后杀掉整个进程组。
/// 通过 uniffi 以 `GitCancelHandle` 暴露给 Swift。
#[derive(Clone, Default)]
pub struct GitCancelToken {
    cancelled: Arc<AtomicBool>,
}

impl GitCancelToken {
    /// Swift 侧经 uniffi 持有句柄并触发取消；当前仅测试消费。
    #[allow(dead_code)]
    pub fn new() -> Self {
        Self::default()
    }

    /// 触发取消：进程组会被杀掉。
    #[allow(dead_code)]
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

/// FFI-safe cancellation handle for long-running Git operations.
/// The handle is intentionally separate from the internal token so Swift can
/// request cancellation without seeing process-execution implementation types.
#[derive(uniffi::Object)]
pub struct GitCancelHandle {
    token: GitCancelToken,
}

impl GitCancelHandle {
    pub(crate) fn token(&self) -> &GitCancelToken {
        &self.token
    }
}

#[uniffi::export]
impl GitCancelHandle {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            token: GitCancelToken::new(),
        })
    }

    /// Kill the current Git process group as soon as the operation loop polls.
    pub fn cancel(&self) {
        self.token.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.token.is_cancelled()
    }
}

/// 一条 git 命令的结构化描述。所有系统 git 调用用它建模，
/// `display()` 输出脱敏后的展示串（日志/Git Console 安全）。
#[derive(Clone, Debug)]
pub struct GitCommandSpec {
    /// 日志/指标类别;当前无消费方,保留为 API 面。
    #[allow(dead_code)]
    pub category: GitCommandCategory,
    /// 位于子命令之前的全局选项（如 `-c key=value`），git 要求其在
    /// 子命令之前（`git -c x=1 ls-remote`），display 也按此顺序。
    pub global_args: Vec<String>,
    pub subcommand: String,
    pub args: Vec<String>,
    pub working_dir: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    pub timeout: Option<Duration>,
    /// Optional binary stdout sink. Git filters can return arbitrary bytes;
    /// keeping those bytes in a file avoids lossy UTF-8 conversion while the
    /// normal structured outcome still carries text diagnostics.
    pub stdout_file: Option<PathBuf>,
    /// 额外需要从输出/日志中抹除的字符串（token、passphrase 等）。
    pub redactions: Vec<String>,
}

impl GitCommandSpec {
    pub fn new(category: GitCommandCategory, subcommand: &str) -> Self {
        GitCommandSpec {
            category,
            global_args: Vec::new(),
            subcommand: subcommand.to_string(),
            args: Vec::new(),
            working_dir: None,
            env: Vec::new(),
            timeout: None,
            stdout_file: None,
            redactions: Vec::new(),
        }
    }

    pub fn arg(mut self, arg: impl Into<String>) -> Self {
        self.args.push(arg.into());
        self
    }

    /// 追加全局选项（在子命令之前，如 `-c credential.helper=`）。
    pub fn global_arg(mut self, arg: impl Into<String>) -> Self {
        self.global_args.push(arg.into());
        self
    }

    pub fn args(mut self, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    /// 可选参数：`Some(v)` 时追加 `[flag, v]`，`None` 时跳过。
    /// 后续命令迁移消费；当前仅测试覆盖。
    #[allow(dead_code)]
    pub fn opt_arg(mut self, flag: &str, value: Option<&str>) -> Self {
        if let Some(value) = value {
            self.args.push(flag.to_string());
            self.args.push(value.to_string());
        }
        self
    }

    /// 布尔 flag：`true` 时追加。
    pub fn flag_if(self, flag: &str, on: bool) -> Self {
        if on {
            self.arg(flag)
        } else {
            self
        }
    }

    pub fn working_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.working_dir = Some(dir.into());
        self
    }

    pub fn env(mut self, key: &str, value: impl Into<String>) -> Self {
        self.env.push((key.to_string(), value.into()));
        self
    }

    /// 超时配置；后续迁移消费，当前测试覆盖。
    #[allow(dead_code)]
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }

    /// Redirect stdout to an explicit file while retaining timeout and
    /// process-group cancellation semantics from the shared runner.
    pub fn stdout_file(mut self, path: impl Into<PathBuf>) -> Self {
        self.stdout_file = Some(path.into());
        self
    }

    /// 注册脱敏 secret；后续迁移消费。
    #[allow(dead_code)]
    pub fn redact(mut self, secret: impl Into<String>) -> Self {
        let secret = secret.into();
        if !secret.is_empty() {
            self.redactions.push(secret);
        }
        self
    }

    /// 以 `--` 结束参数（防路径被解析为选项）。调用方自行决定是否需要。
    pub fn separator(self) -> Self {
        self.arg("--")
    }

    /// 添加远程 URL 参数，并把 URL 内嵌密码注册为脱敏 secret
    /// （`https://user:token@host` 场景，错误信息/日志不泄漏 token）。
    pub fn url_arg(mut self, url: &str) -> Self {
        if let Some(secret) = url_password(url) {
            self.redactions.push(secret);
        }
        self.args.push(url.to_string());
        self
    }

    /// 脱敏后的展示串，例如 `git push origin main`。
    pub fn display(&self) -> String {
        let mut text = String::from("git");
        for arg in &self.global_args {
            text.push(' ');
            text.push_str(&redact(arg, &self.redactions));
        }
        text.push(' ');
        text.push_str(&self.subcommand);
        for arg in &self.args {
            text.push(' ');
            text.push_str(&redact(arg, &self.redactions));
        }
        text
    }
}

/// 将 Git 的传输进度行转换成统一快照。
///
/// 传输阶段通常形如 `Receiving objects: 67% (2/3)`，SSH/HTTP remote 还会
/// 在前面加 `remote:`。解析只接受 0..=100 的百分比，其他 stderr 文本仍
/// 保留在 GitProcessOutcome 中，不会被误显示成进度。
fn parse_git_progress_line(line: &str) -> Option<(String, u32)> {
    let detail = line.trim();
    let detail = detail.strip_prefix("remote:").unwrap_or(detail).trim();
    if let Some(progress) = detail.strip_prefix("Rebasing (") {
        let progress = progress.strip_suffix(')')?;
        let (current, total) = progress.split_once('/')?;
        let current = current.parse::<u32>().ok()?;
        let total = total.parse::<u32>().ok()?;
        if total > 0 && current <= total {
            return Some(("Rebasing".to_string(), current.saturating_mul(100) / total));
        }
    }
    let percent_index = detail.find('%')?;
    let digits_end = percent_index;
    let digits_start = detail[..digits_end]
        .char_indices()
        .rev()
        .take_while(|(_, character)| character.is_ascii_digit())
        .last()
        .map(|(index, _)| index)
        .unwrap_or(digits_end);
    if digits_start == digits_end {
        return None;
    }
    let percentage = detail[digits_start..digits_end].parse::<u32>().ok()?;
    if percentage > 100 {
        return None;
    }
    let phase = detail[..digits_start]
        .trim()
        .trim_end_matches(':')
        .trim()
        .to_string();
    if phase.is_empty() {
        return None;
    }
    Some((phase, percentage))
}

struct GitProgressParser {
    generation: u64,
    pending: String,
    last: Option<(String, u32)>,
}

impl GitProgressParser {
    fn new(generation: u64) -> Self {
        Self {
            generation,
            pending: String::new(),
            last: None,
        }
    }

    fn feed(&mut self, chunk: &str) {
        self.pending.push_str(chunk);
        let mut line_start = 0;
        let mut completed_lines = Vec::new();
        for (index, character) in self.pending.char_indices() {
            if character == '\r' || character == '\n' {
                completed_lines.push(self.pending[line_start..index].to_string());
                line_start = index + character.len_utf8();
            }
        }
        if line_start > 0 {
            self.pending = self.pending[line_start..].to_string();
        }
        for line in completed_lines {
            self.update(line);
        }
    }

    fn flush(&mut self) {
        if !self.pending.is_empty() {
            let line = std::mem::take(&mut self.pending);
            self.update(line);
        }
    }

    fn update(&mut self, line: String) {
        let Some((phase, percentage)) = parse_git_progress_line(&line) else {
            return;
        };
        self.last = Some((phase.clone(), percentage));
        update_git_progress(self.generation, phase, percentage, line.trim().to_string());
    }
}

/// 进程结果：结构化 exit code + 输出 + 失败分类。
#[derive(uniffi::Record, Clone, Debug)]
pub struct GitProcessOutcome {
    pub exit_code: i32,
    pub stdout: String,
    /// 原始 stdout 字节。没有发生脱敏时与 Git 管道逐字节一致；UI 文本仍使用
    /// `stdout`，这样非 UTF-8 输出不会在导出前被 replacement character 破坏。
    pub stdout_bytes: Vec<u8>,
    pub stderr: String,
    #[allow(dead_code)] // 指标/日志字段,后续消费
    pub duration_ms: u64,
    pub cancelled: bool,
    pub timed_out: bool,
    pub failure: Option<GitFailureKind>,
}

impl GitProcessOutcome {
    pub fn success(&self) -> bool {
        self.exit_code == 0 && !self.cancelled && !self.timed_out
    }

    /// 转为引擎错误；message 携带 stderr（已脱敏）。
    /// 转为引擎错误；message 携带 stderr（已脱敏）。
    /// 用户取消映射为独立的 `EngineError::Cancelled`，UI 无需猜错误文本。
    pub fn into_error(self, spec: &GitCommandSpec) -> EngineError {
        if matches!(self.failure, Some(GitFailureKind::Cancelled)) || self.cancelled {
            return EngineError::Cancelled;
        }
        let detail = if self.stderr.trim().is_empty() {
            self.stdout.trim().to_string()
        } else {
            self.stderr.trim().to_string()
        };
        match self.failure {
            Some(GitFailureKind::UntrackedWouldBeOverwritten) => {
                EngineError::UntrackedWouldBeOverwritten {
                    paths: overwritten_paths(&detail),
                }
            }
            Some(GitFailureKind::LocalChangesWouldBeOverwritten) => {
                EngineError::LocalChangesWouldBeOverwritten {
                    paths: overwritten_paths(&detail),
                }
            }
            Some(GitFailureKind::Authentication) => EngineError::GitOperation {
                message: format!("{}: authentication failed: {detail}", spec.display()),
            },
            Some(GitFailureKind::HostKeyChanged) => EngineError::GitOperation {
                message: format!("{}: SSH host key changed: {detail}", spec.display()),
            },
            Some(GitFailureKind::Network) => EngineError::GitOperation {
                message: format!("{}: network error: {detail}", spec.display()),
            },
            _ => EngineError::GitOperation {
                message: format!("{} failed: {detail}", spec.display()),
            },
        }
    }
}

/// Extract paths from Git's overwrite-protection diagnostic. Git prints the
/// paths after a heading and terminates the list before the remediation text.
/// Keep this deliberately conservative: an empty list is still useful as a
/// structured category, while guessed prose must never become a file path.
fn overwritten_paths(detail: &str) -> Vec<String> {
    let mut collecting = false;
    let mut paths = Vec::new();
    for raw_line in detail.lines() {
        let line = raw_line.trim();
        let lower = line.to_ascii_lowercase();
        if !collecting
            && (lower.contains("following files would be overwritten")
                || lower.contains("following untracked working tree files would be overwritten"))
        {
            collecting = true;
            continue;
        }
        if !collecting {
            continue;
        }
        if line.is_empty()
            || lower.starts_with("please ")
            || lower.starts_with("aborting")
            || lower.starts_with("error:")
            || lower.starts_with("fatal:")
        {
            break;
        }
        let path = line.trim_matches('"');
        if !path.is_empty() {
            paths.push(path.to_string());
        }
    }
    paths
}

/// 检测当前配置的 system Git 版本（`git --version`）。
/// git 版本决定可用参数（如 `--force-with-lease` 细节、rebase backend）。
#[allow(dead_code)]
pub fn git_version() -> Result<String, EngineError> {
    git_executable_version()
}

/// 运行一条 git 命令：流式投递事件，支持取消与超时。
///
/// - `cancel`：触发后向整个进程组发 SIGKILL（unix）并返回 `Cancelled`；
///   不留残留 git/ssh 子进程。
/// - `on_event`：stdout/stderr 逐块回调；同时完整累积在 outcome 里。
pub fn run(
    spec: &GitCommandSpec,
    cancel: Option<&GitCancelToken>,
    mut on_event: impl FnMut(GitStreamEvent),
) -> Result<GitProcessOutcome, EngineError> {
    let started = Instant::now();
    let mut command = match spec.working_dir.as_deref() {
        Some(working_dir) => git_command_for_working_dir(working_dir),
        None => git_command(),
    };
    command.args(&spec.global_args);
    command.arg(&spec.subcommand);
    command.args(&spec.args);
    if let Some(dir) = &spec.working_dir {
        command.current_dir(dir);
    }
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    // An explicit command-level value wins. This preserves callers that need
    // to suppress the application pinentry session for a particular Git
    // invocation while still covering hooks and GPG children by default.
    if !spec.env.iter().any(|(key, _)| key == "PINENTRY_USER_DATA") {
        if let Some(value) = pinentry_user_data()
            .read()
            .expect("pinentry user data lock poisoned")
            .as_ref()
        {
            command.env("PINENTRY_USER_DATA", value);
        }
    }
    set_process_group(&mut command);
    command.stdin(std::process::Stdio::null());
    if let Some(path) = &spec.stdout_file {
        let file = std::fs::File::create(path).map_err(|error| EngineError::GitOperation {
            message: format!(
                "failed to create stdout sink for {}: {error}",
                spec.display()
            ),
        })?;
        command.stdout(std::process::Stdio::from(file));
    } else {
        command.stdout(std::process::Stdio::piped());
    }
    command.stderr(std::process::Stdio::piped());

    let progress_generation = begin_git_progress(spec);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            end_git_progress(progress_generation);
            return Err(EngineError::GitOperation {
                message: format!("failed to spawn {}: {e}", spec.display()),
            });
        }
    };
    let pid = child.id();

    let stdout_handle = child.stdout.take();
    let stderr_handle = child.stderr.take();

    // 读线程：分块读取并发事件。缓冲区按块读取，进度行的 \r 由消费方解释。
    let (stdout_tx, stdout_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let (stderr_tx, stderr_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let stdout_reader = stdout_handle.map(|mut pipe| {
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match pipe.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if stdout_tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                }
            }
        })
    });
    let stderr_reader = stderr_handle.map(|mut pipe| {
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match pipe.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if stderr_tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                }
            }
        })
    });

    let deadline = spec.timeout.map(|t| started + t);
    let mut cancelled = false;
    let mut timed_out = false;
    // 累积缓冲必须在循环外声明：循环内排空的数据同样属于最终结果。
    let mut stdout_all = String::new();
    let mut stdout_bytes = Vec::new();
    let mut stderr_all = String::new();
    let mut progress_parser = GitProgressParser::new(progress_generation);
    let status = loop {
        // 先排空输出，保证取消/超时判断时事件已尽量投递。
        drain_channels(
            &stdout_rx,
            &stderr_rx,
            &mut on_event,
            &spec.redactions,
            &mut stdout_all,
            &mut stdout_bytes,
            &mut stderr_all,
            &mut progress_parser,
        );
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(e) => {
                kill_process_group(pid);
                let _ = child.wait();
                end_git_progress(progress_generation);
                return Err(EngineError::GitOperation {
                    message: format!("{}: wait failed: {e}", spec.display()),
                });
            }
        }
        if let Some(token) = cancel {
            if token.is_cancelled() {
                cancelled = true;
                kill_process_group(pid);
                break match child.wait() {
                    Ok(status) => status,
                    Err(e) => {
                        end_git_progress(progress_generation);
                        return Err(EngineError::GitOperation {
                            message: format!("{}: wait after cancel failed: {e}", spec.display()),
                        });
                    }
                };
            }
        }
        if let Some(deadline) = deadline {
            if Instant::now() >= deadline {
                timed_out = true;
                kill_process_group(pid);
                break match child.wait() {
                    Ok(status) => status,
                    Err(e) => {
                        end_git_progress(progress_generation);
                        return Err(EngineError::GitOperation {
                            message: format!("{}: wait after timeout failed: {e}", spec.display()),
                        });
                    }
                };
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    };

    // 子进程已退出：继续排空到 EOF，然后 join 读线程。
    // （sender 由读线程持有，线程退出时自动释放，channel 随之断开。）
    drain_channels(
        &stdout_rx,
        &stderr_rx,
        &mut on_event,
        &spec.redactions,
        &mut stdout_all,
        &mut stdout_bytes,
        &mut stderr_all,
        &mut progress_parser,
    );
    // 正常退出路径下，若孙进程（hook/alias 派生）仍持有管道写端，
    // 读线程可能不退出：join 只等有限时间，避免卡死。
    if let Some(handle) = stdout_reader {
        join_with_grace(handle);
    }
    if let Some(handle) = stderr_reader {
        join_with_grace(handle);
    }
    // join 后再补一次（读线程可能在我们 EOF 判断后仍写入了最后一帧）。
    drain_channels(
        &stdout_rx,
        &stderr_rx,
        &mut on_event,
        &spec.redactions,
        &mut stdout_all,
        &mut stdout_bytes,
        &mut stderr_all,
        &mut progress_parser,
    );
    progress_parser.flush();
    end_git_progress(progress_generation);

    let exit_code = status.code().unwrap_or(-1);
    let failure = if cancelled {
        Some(GitFailureKind::Cancelled)
    } else if timed_out {
        Some(GitFailureKind::Timeout)
    } else if exit_code == 0 {
        None
    } else {
        classify_failure(&stdout_all, &stderr_all)
    };

    Ok(GitProcessOutcome {
        exit_code,
        stdout: stdout_all,
        stdout_bytes,
        stderr: stderr_all,
        duration_ms: started.elapsed().as_millis() as u64,
        cancelled,
        timed_out,
        failure,
    })
}

/// 阻塞式便捷入口：不订阅事件、不取消。
pub fn run_to_completion(spec: &GitCommandSpec) -> Result<GitProcessOutcome, EngineError> {
    run(spec, None, |_| {})
}

/// 限时 join：超时后放弃等待（读线程会在管道真正关闭后自行退出）。
/// 防止孙进程持有管道写端导致 join 永久阻塞。
fn join_with_grace(handle: std::thread::JoinHandle<()>) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !handle.is_finished() {
        if Instant::now() >= deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = handle.join();
}

fn drain_channels(
    stdout_rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    stderr_rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    on_event: &mut impl FnMut(GitStreamEvent),
    redactions: &[String],
    stdout_all: &mut String,
    stdout_bytes: &mut Vec<u8>,
    stderr_all: &mut String,
    progress_parser: &mut GitProgressParser,
) {
    loop {
        let mut progressed = false;
        while let Ok(chunk) = stdout_rx.try_recv() {
            progressed = true;
            let text = String::from_utf8_lossy(&chunk).into_owned();
            let redacted = redact(&text, redactions);
            on_event(GitStreamEvent::Stdout {
                chunk: redacted.clone(),
            });
            stdout_all.push_str(&redacted);
            if redacted == text {
                stdout_bytes.extend_from_slice(&chunk);
            } else {
                // 脱敏后的文本才是可安全暴露给 FFI 的表示，避免原始 secret
                // 通过新增的字节字段绕过现有日志脱敏边界。
                stdout_bytes.extend_from_slice(redacted.as_bytes());
            }
        }
        while let Ok(chunk) = stderr_rx.try_recv() {
            progressed = true;
            let text = String::from_utf8_lossy(&chunk).into_owned();
            let redacted = redact(&text, redactions);
            on_event(GitStreamEvent::Stderr {
                chunk: redacted.clone(),
            });
            stderr_all.push_str(&redacted);
            progress_parser.feed(&redacted);
        }
        if !progressed {
            break;
        }
    }
}

/// 把 stderr/stdout 文本分类为失败类别。参照 git4idea 的错误解析：
/// 先匹配最特定的短语，再落到通用类别。
pub fn classify_failure(stdout: &str, stderr: &str) -> Option<GitFailureKind> {
    let hay = format!("{stdout}\n{stderr}").to_ascii_lowercase();
    let has = |needle: &str| hay.contains(needle);

    // 冲突/未合并要在认证之前判断：网络错误不会带这些词。
    if has("automatic merge failed")
        || has("merge conflict")
        || has("conflicts during")
        || has("could not apply")
        || has("error: could not apply")
    {
        return Some(GitFailureKind::Conflict);
    }
    if has("unmerged paths") || has("you have unmerged paths") || has("needs merge") {
        return Some(GitFailureKind::UnmergedPaths);
    }
    if has("untracked working tree files would be overwritten")
        || has("the following untracked working tree files would be overwritten")
    {
        return Some(GitFailureKind::UntrackedWouldBeOverwritten);
    }
    if has("your local changes to the following files would be overwritten")
        || has("cannot pull with rebase: you have unstaged changes")
        || has("cannot rebase: you have unstaged changes")
        || has("cannot rebase: you have unstaged")
        || has("please commit your changes or stash them")
    {
        return Some(GitFailureKind::LocalChangesWouldBeOverwritten);
    }
    // 必须先于通用 authentication 判断：changed host key 是安全阻断，
    // 不能让 UI 把它误导成“重新输入密码”。
    if has("remote host identification has changed")
        || has("offending key in")
        || has("possible dns spoofing detected")
        || (has("host key for") && has("has changed"))
    {
        return Some(GitFailureKind::HostKeyChanged);
    }
    // 认证（HTTPS 与 SSH）。
    if has("authentication failed")
        || has("could not read username")
        || has("terminal prompts disabled")
        || has("invalid credentials")
        || has("invalid username or password")
        || has("403 forbidden")
        || has("requested url returned error: 403")
        || has("permission denied (publickey")
        || has("permission denied (password")
        || has("host key verification failed")
        || has("permission denied (gssapi-keyex")
    {
        return Some(GitFailureKind::Authentication);
    }
    // 网络。
    if has("could not resolve host")
        || has("connection timed out")
        || has("connection refused")
        || has("connection reset")
        || has("network is unreachable")
        || has("ssl")
        || has("failed to connect")
        || has("connection was closed")
        || has("early eof")
        || has("rpc failed")
    {
        return Some(GitFailureKind::Network);
    }
    if has("non-fast-forward")
        || has("(fetch first)")
        || has("tip of your current branch is behind")
        || has("updates were rejected because the tip of your current branch is behind")
        // force-with-lease 拒绝(stale info)
        || has("stale info")
    {
        return Some(GitFailureKind::NonFastForward);
    }
    if has("repository not found")
        || has("does not appear to be a repository")
        || has("does not appear to be a git repository")
        || has("not a git repository")
        || has("not found") && has("repository")
    {
        return Some(GitFailureKind::RepositoryNotFound);
    }
    if has("pre-commit") || has("commit-msg") || has("pre-push") || has("hook declined") {
        return Some(GitFailureKind::HookRejected);
    }
    if has("index.lock") || has("another git process seems to be running") {
        return Some(GitFailureKind::LockFailure);
    }
    Some(GitFailureKind::Other)
}

/// 脱敏：先替换 URL 内嵌凭证（https://user:pass@host），再替换显式 secret。
pub fn redact(text: &str, secrets: &[String]) -> String {
    let mut output = redact_url_credentials(text);
    for secret in secrets {
        if !secret.is_empty() {
            output = output.replace(secret, "***");
        }
    }
    output
}

/// 把 `scheme://user:password@` 中的 password 替换为 `***`。
/// 不引入 regex 依赖：手工扫描 `://` 后的第一个 `@` 之前的 `:` 段。
fn redact_url_credentials(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // 找 "://" 起点
        if bytes[i] == b':' && i + 2 < bytes.len() && bytes[i + 1] == b'/' && bytes[i + 2] == b'/' {
            let scheme_start = i;
            let after = i + 3;
            // 找 userinfo 范围：到下一个 '/'、空白或 '@'
            let mut j = after;
            let mut at = None;
            let mut colon = None;
            while j < bytes.len() {
                let b = bytes[j];
                if b == b'@' {
                    at = Some(j);
                    break;
                }
                if b == b'/' || b == b' ' || b == b'\n' || b == b'\r' || b == b'\t' {
                    break;
                }
                if b == b':' && colon.is_none() {
                    colon = Some(j);
                }
                j += 1;
            }
            // scheme://user:pass@ -> scheme://user:***@
            if let (Some(c), Some(a)) = (colon, at) {
                if a > c + 1 {
                    output.push_str(&text[scheme_start..=c]);
                    output.push_str("***");
                    output.push_str(&text[a..=a]);
                    i = a + 1;
                    continue;
                }
            }
        }
        let ch = text[i..].chars().next().unwrap();
        output.push(ch);
        i += ch.len_utf8();
    }
    output
}

/// 提取 `scheme://user:password@` 中的 password（用于注册脱敏）。
fn url_password(url: &str) -> Option<String> {
    let bytes = url.as_bytes();
    let scheme_at = url.find("://")?;
    let userinfo_start = scheme_at + 3;
    let mut j = userinfo_start;
    let mut colon = None;
    while j < bytes.len() {
        let b = bytes[j];
        if b == b'@' {
            let colon = colon?;
            if j > colon + 1 {
                return Some(url[colon + 1..j].to_string());
            }
            return None;
        }
        if b == b'/' || b == b' ' || b == b'\n' || b == b'\r' || b == b'\t' {
            return None;
        }
        if b == b':' && colon.is_none() {
            colon = Some(j);
        }
        j += 1;
    }
    None
}

#[cfg(unix)]
fn set_process_group(command: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    // 独立进程组：取消时能杀掉 git 派生的 ssh/askpass 全部子进程。
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
}

#[cfg(not(unix))]
fn set_process_group(_command: &mut std::process::Command) {}

#[cfg(unix)]
fn kill_process_group(pid: u32) {
    // setsid 后 pid == pgid；负 pid 表示整个进程组。
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_process_group(pid: u32) {
    let _ = std::process::Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static PROGRESS_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn spec_display_and_redaction() {
        let spec = GitCommandSpec::new(GitCommandCategory::Push, "push")
            .arg("origin")
            .arg("main");
        assert_eq!(spec.display(), "git push origin main");
        assert_eq!(spec.category.as_str(), "push");
    }

    #[test]
    fn flag_and_opt_args() {
        let spec = GitCommandSpec::new(GitCommandCategory::Fetch, "fetch")
            .flag_if("--prune", true)
            .opt_arg("--depth", Some("1"));
        assert_eq!(spec.args, vec!["--prune", "--depth", "1"]);
        let spec = spec.flag_if("--all", false).opt_arg("--depth", None);
        assert_eq!(spec.args, vec!["--prune", "--depth", "1"]);
    }

    #[test]
    fn multi_root_progress_exposes_root_identity_and_completion() {
        let _guard = PROGRESS_TEST_LOCK.lock().expect("progress test lock");
        let generation = begin_root_operation_progress(1, 3, "/tmp/child".into(), "child".into());
        let state = git_progress_state().expect("root progress should be active");
        assert_eq!(state.category, "multi-root");
        assert_eq!(state.phase, "Root 2/3");
        assert_eq!(state.root_path, "/tmp/child");
        assert_eq!(state.root_name, "child");
        assert_eq!(state.completed_roots, 1);
        assert_eq!(state.total_roots, 3);
        assert_eq!(state.root_state, "");
        assert_eq!(state.percentage, None);

        update_root_operation_progress(generation, 2, "completed".into());
        let state = git_progress_state().expect("root completion should remain visible");
        assert_eq!(state.phase, "Root 2/3");
        assert_eq!(state.completed_roots, 2);
        assert_eq!(state.percentage, Some(66));
        assert_eq!(state.root_state, "completed");
        assert_eq!(state.detail, "child — completed");

        end_root_operation_progress(generation);
        assert!(git_progress_state().is_none());
    }

    #[test]
    fn nested_operation_progress_restores_multi_root_context() {
        let _guard = PROGRESS_TEST_LOCK.lock().expect("progress test lock");
        let root_generation =
            begin_root_operation_progress(0, 2, "/tmp/root".into(), "root".into());
        let child_generation =
            begin_operation_progress("rebase".into(), "Running Git".into(), "git rebase".into());
        let child = git_progress_state().expect("nested progress should be active");
        assert_eq!(child.category, "rebase");
        assert_eq!(child.root_path, "/tmp/root");
        assert_eq!(child.total_roots, 2);

        end_operation_progress(child_generation);
        let restored = git_progress_state().expect("parent root progress should be restored");
        assert_eq!(restored.category, "multi-root");
        assert_eq!(restored.root_name, "root");
        assert_eq!(restored.completed_roots, 0);

        update_root_operation_progress(root_generation, 1, "completed".into());
        assert_eq!(
            git_progress_state()
                .expect("restored root progress should accept updates")
                .percentage,
            Some(50)
        );
        end_root_operation_progress(root_generation);
        assert!(git_progress_state().is_none());
    }

    #[test]
    fn project_git_executable_uses_longest_root_and_can_be_cleared() {
        let temp = tempfile::tempdir().expect("temporary scope roots");
        let project = temp.path().join("project");
        let nested = project.join("nested");
        std::fs::create_dir_all(&nested).expect("scope roots");

        let outer_wrapper = temp.path().join("git-outer");
        let inner_wrapper = temp.path().join("git-inner");
        for wrapper in [&outer_wrapper, &inner_wrapper] {
            std::fs::write(wrapper, "#!/bin/sh\nexec git \"$@\"\n").expect("wrapper script");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mut permissions = std::fs::metadata(wrapper)
                    .expect("wrapper metadata")
                    .permissions();
                permissions.set_mode(0o700);
                std::fs::set_permissions(wrapper, permissions).expect("wrapper executable");
            }
        }

        let outer_project = temp.path().join("outer-project");
        let inner_project = temp.path().join("inner-project");
        set_project_git_executable(
            outer_project.to_string_lossy().into_owned(),
            vec![project.to_string_lossy().into_owned()],
            outer_wrapper.to_string_lossy().into_owned(),
        )
        .expect("outer project executable");
        set_project_git_executable(
            inner_project.to_string_lossy().into_owned(),
            vec![nested.to_string_lossy().into_owned()],
            inner_wrapper.to_string_lossy().into_owned(),
        )
        .expect("inner project executable");

        assert_eq!(
            git_command_for_working_dir(&project).get_program(),
            outer_wrapper.as_os_str()
        );
        assert_eq!(
            git_command_for_working_dir(&nested).get_program(),
            inner_wrapper.as_os_str()
        );
        assert_eq!(
            project_git_executable(outer_project.to_string_lossy().into_owned()),
            Some(outer_wrapper.to_string_lossy().into_owned())
        );

        clear_project_git_executable(inner_project.to_string_lossy().into_owned());
        assert_eq!(
            git_command_for_working_dir(&nested).get_program(),
            outer_wrapper.as_os_str()
        );
        clear_project_git_executable(outer_project.to_string_lossy().into_owned());
        assert!(project_git_executable(outer_project.to_string_lossy().into_owned()).is_none());
    }

    #[test]
    fn redacts_url_password() {
        assert_eq!(
            redact_url_credentials("https://user:hunter2@example.com/repo.git"),
            "https://user:***@example.com/repo.git"
        );
        assert_eq!(
            redact_url_credentials("https://example.com/repo.git"),
            "https://example.com/repo.git"
        );
    }

    #[test]
    fn redacts_explicit_secrets() {
        let spec = GitCommandSpec::new(GitCommandCategory::Push, "push")
            .arg("https://example.com/x.git")
            .redact("ghp_topsecret");
        let text = "token ghp_topsecret at https://u:p@h/x";
        assert_eq!(
            redact(text, &spec.redactions),
            "token *** at https://u:***@h/x"
        );
    }

    #[test]
    fn classifies_auth_failures() {
        assert_eq!(
            classify_failure(
                "",
                "fatal: Authentication failed for 'https://example.com/x.git'"
            ),
            Some(GitFailureKind::Authentication)
        );
        assert_eq!(
            classify_failure("", "fatal: could not read Username for 'https://example.com': terminal prompts disabled"),
            Some(GitFailureKind::Authentication)
        );
        assert_eq!(
            classify_failure("", "git@example.com: Permission denied (publickey)."),
            Some(GitFailureKind::Authentication)
        );
        assert_eq!(
            classify_failure(
                "",
                "fatal: unable to access 'https://example.com': 403 Forbidden"
            ),
            Some(GitFailureKind::Authentication)
        );
    }

    #[test]
    fn classifies_changed_ssh_host_key_before_authentication() {
        assert_eq!(
            classify_failure(
                "",
                "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nOffending ED25519 key in /Users/x/.ssh/known_hosts:12"
            ),
            Some(GitFailureKind::HostKeyChanged)
        );
    }

    #[test]
    fn classifies_network_and_nonff() {
        assert_eq!(
            classify_failure(
                "",
                "fatal: unable to access 'https://x/': Could not resolve host: x"
            ),
            Some(GitFailureKind::Network)
        );
        assert_eq!(
            classify_failure("", "error: failed to push some refs (non-fast-forward)"),
            Some(GitFailureKind::NonFastForward)
        );
    }

    #[test]
    fn classifies_conflict_and_dirty() {
        assert_eq!(
            classify_failure("", "Auto-merging a.txt\nCONFLICT (content): Merge conflict in a.txt\nAutomatic merge failed; fix conflicts and then commit the result."),
            Some(GitFailureKind::Conflict)
        );
        assert_eq!(
            classify_failure(
                "",
                "error: Your local changes to the following files would be overwritten by merge"
            ),
            Some(GitFailureKind::LocalChangesWouldBeOverwritten)
        );
        assert_eq!(
            classify_failure(
                "",
                "error: The following untracked working tree files would be overwritten by merge"
            ),
            Some(GitFailureKind::UntrackedWouldBeOverwritten)
        );
    }

    #[test]
    fn parses_overwrite_paths_without_including_remediation_text() {
        let detail = "error: Your local changes to the following files would be overwritten by merge:\n\ttracked.txt\n\t\"quoted name.txt\"\nPlease commit your changes or stash them before you merge.\nAborting";
        assert_eq!(
            overwritten_paths(detail),
            vec!["tracked.txt", "quoted name.txt"]
        );
    }

    #[test]
    fn classifies_hooks_and_locks() {
        assert_eq!(
            classify_failure("", "pre-commit: hook declined"),
            Some(GitFailureKind::HookRejected)
        );
        assert_eq!(
            classify_failure("", "fatal: Unable to create '/x/.git/index.lock': File exists. Another git process seems to be running"),
            Some(GitFailureKind::LockFailure)
        );
    }

    #[test]
    fn parses_git_transport_progress_lines() {
        assert_eq!(
            parse_git_progress_line("Receiving objects: 67% (2/3)"),
            Some(("Receiving objects".to_string(), 67))
        );
        assert_eq!(
            parse_git_progress_line("remote: Resolving deltas: 100% (4/4), done."),
            Some(("Resolving deltas".to_string(), 100))
        );
        assert_eq!(parse_git_progress_line("Everything up-to-date"), None);
        assert_eq!(parse_git_progress_line("Writing objects: 101%"), None);
    }

    #[test]
    fn parses_native_rebase_progress_lines() {
        assert_eq!(
            parse_git_progress_line("Rebasing (2/5)"),
            Some(("Rebasing".to_string(), 40))
        );
        assert_eq!(
            parse_git_progress_line("Rebasing (0/5)"),
            Some(("Rebasing".to_string(), 0))
        );
        assert_eq!(parse_git_progress_line("Rebasing (6/5)"), None);
    }

    #[test]
    fn progress_parser_handles_carriage_return_updates_and_split_chunks() {
        let mut parser = GitProgressParser::new(0);
        parser.feed("Receiving objects: 6");
        parser.feed("7% (2/3)\rResolving deltas: 100% (4/4)\r");

        assert_eq!(parser.last, Some(("Resolving deltas".to_string(), 100)));
    }

    #[test]
    fn run_reports_success_and_streams() {
        let spec = GitCommandSpec::new(GitCommandCategory::Other, "--version");
        let mut events = 0;
        let outcome = run(&spec, None, |_| events += 1).expect("git --version");
        assert!(outcome.success());
        assert!(outcome.failure.is_none());
        assert!(outcome.stdout.contains("git version"));
        assert!(events > 0);
    }

    #[test]
    fn run_classifies_failure_of_missing_path() {
        // working_dir 必须存在（否则 spawn 直接 ENOENT），但不是 git 仓库。
        let dir = tempfile::tempdir().expect("tempdir");
        let spec =
            GitCommandSpec::new(GitCommandCategory::Status, "status").working_dir(dir.path());
        let outcome = run_to_completion(&spec).expect("spawn");
        assert!(!outcome.success());
        assert_eq!(outcome.failure, Some(GitFailureKind::RepositoryNotFound));
    }

    /// 构造一个会派生子进程并阻塞 30s 的 git 命令（repo 本地 shell alias），
    /// 子进程把自身 pid 写入 hang.pid 后 exec sleep。
    /// 用于验证取消时整个进程组（git -> sh -> sleep）都被清理。
    fn hanging_repo_spec(dir: &std::path::Path) -> GitCommandSpec {
        std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(dir)
            .output()
            .expect("git init");
        // 必须先 init：否则 alias 写进全局配置且 git hang 在非仓库直接失败。
        std::process::Command::new("git")
            .args([
                "config",
                "alias.hang",
                "!echo $$ >hang.pid && exec sleep 30",
            ])
            .current_dir(dir)
            .output()
            .expect("git config alias");
        GitCommandSpec::new(GitCommandCategory::Other, "hang").working_dir(dir)
    }

    fn process_alive(pid: i32) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[test]
    fn cancel_kills_whole_process_group() {
        let dir = tempfile::tempdir().expect("tempdir");
        let spec = hanging_repo_spec(dir.path());
        let token = GitCancelToken::new();
        let cancel_timer = {
            let token = token.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(300));
                token.cancel();
            })
        };
        let outcome = run(&spec, Some(&token), |_| {}).expect("spawn hanging git");
        cancel_timer.join().unwrap();
        assert!(outcome.cancelled);
        assert_ne!(outcome.exit_code, 0);
        assert_eq!(outcome.failure, Some(GitFailureKind::Cancelled));
        // hang.pid 记录的是 exec sleep 后的 pid：进程组被杀后必须已不存在。
        let pid_text = std::fs::read_to_string(dir.path().join("hang.pid")).expect("hang.pid");
        let pid: i32 = pid_text.trim().parse().expect("pid number");
        let mut gone = false;
        for _ in 0..50 {
            if !process_alive(pid) {
                gone = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(gone, "residual child process {pid} survived cancellation");
    }

    #[test]
    fn timeout_kills_whole_process_group() {
        let dir = tempfile::tempdir().expect("tempdir");
        let spec = hanging_repo_spec(dir.path()).timeout(Duration::from_millis(300));
        let outcome = run_to_completion(&spec).expect("spawn hanging git");
        assert!(outcome.timed_out);
        assert!(!outcome.success());
        assert_eq!(outcome.failure, Some(GitFailureKind::Timeout));
        assert!(
            outcome.duration_ms < 5000,
            "timeout took {}ms",
            outcome.duration_ms
        );
        let pid_text = std::fs::read_to_string(dir.path().join("hang.pid")).expect("hang.pid");
        let pid: i32 = pid_text.trim().parse().expect("pid number");
        let mut gone = false;
        for _ in 0..50 {
            if !process_alive(pid) {
                gone = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(gone, "residual child process {pid} survived timeout");
    }

    #[test]
    fn into_error_maps_cancelled_to_engine_cancelled() {
        let spec = GitCommandSpec::new(GitCommandCategory::Fetch, "fetch").arg("origin");
        let outcome = GitProcessOutcome {
            exit_code: 128,
            stdout: String::new(),
            stdout_bytes: Vec::new(),
            stderr: "fatal: could not read Username".to_string(),
            duration_ms: 5,
            cancelled: true,
            timed_out: false,
            failure: Some(GitFailureKind::Cancelled),
        };
        let error = outcome.clone().into_error(&spec);
        assert!(matches!(error, crate::error::EngineError::Cancelled));
        // 取消标志也会单独触发 Cancelled 映射
        let outcome2 = GitProcessOutcome {
            exit_code: 128,
            stdout: String::new(),
            stdout_bytes: Vec::new(),
            stderr: "something".to_string(),
            duration_ms: 5,
            cancelled: true,
            timed_out: false,
            failure: Some(GitFailureKind::Other),
        };
        assert!(matches!(
            outcome2.into_error(&spec),
            crate::error::EngineError::Cancelled
        ));
    }

    #[test]
    fn git_version_detected() {
        let version = git_version().expect("git version");
        assert!(version.starts_with("git version"), "unexpected: {version}");
    }
}

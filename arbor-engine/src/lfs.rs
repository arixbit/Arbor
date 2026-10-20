//! LFS-001：Git LFS 全链路集成。
//!
//! Arbor 不重新实现 LFS 协议，而是驱动用户安装的 `git-lfs`（与 IntelliJ
//! 一致），把它的行为收敛成结构化结果：
//!
//! - 能力探测：`git lfs version`；未安装时返回 `installed = false` 而不是让
//!   UI 从一段英文 stderr 里猜；
//! - track/untrack：改写 `.gitattributes` 的入口，与 `git lfs track` 完全一致；
//! - 状态标记：`filter=lfs` 属性判定 + 工作区文件是否仍是 pointer（未
//!   smudge），用于在文件树/差异视图中标注 LFS 文件；
//! - 传输：fetch / pull / push / prune / checkout，接入统一 `GitCancelHandle`
//!   取消、统一 `GitCommandSpec` 参数建模与错误分类；
//! - hooks：`git lfs install --local` 安装 post-checkout/post-commit/
//!   post-merge/pre-push，并暴露当前安装状态供设置页展示。
//!
//! 所有命令都走 `gitprocess`，因此继承同一套可执行文件设置、脱敏日志、
//! 失败分类（认证/网络/取消）与进程组清理。

use std::path::{Path, PathBuf};

use crate::attributes::{self, AttributeValue};
use crate::error::EngineError;
use crate::gitprocess::{self, GitCancelToken, GitCommandCategory, GitCommandSpec};
use crate::repo::Repository;

/// LFS pointer 文件的魔数第一行。工作区文件以它开头说明内容还没被
/// smudge（例如 clone 时跳过下载、或对象不在本地缓存）。
const POINTER_MAGIC: &str = "version https://git-lfs.github.com/spec/v1";

/// LFS hook 名（`git lfs install` 安装的四个）。
const LFS_HOOKS: [&str; 4] = ["post-checkout", "post-commit", "post-merge", "pre-push"];

/// `git lfs` 是否可用。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LfsCapability {
    pub installed: bool,
    /// 形如 `3.7.1`；未安装时为 None。
    pub version: Option<String>,
    /// 未安装或探测失败时的原始首行，供设置页展示原因。
    pub detail: Option<String>,
}

/// 一条被 LFS 跟踪的匹配模式，来自 `git lfs track` 的 listing。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LfsTrackedPattern {
    /// 形如 `*.bin`，或 `assets` 目录下任意深度（`assets/` 后接路径）。
    pub pattern: String,
    /// 定义该规则的属性文件（`.gitattributes`、`dir/.gitattributes` 等）。
    pub source: String,
}

/// 一个已提交或已暂存的 LFS 文件。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LfsFileEntry {
    pub path: String,
    pub oid: String,
    /// 工作区是否已有真实内容（false 表示仍是 pointer 或未检出）。
    pub content_present: bool,
}

/// 单个路径的 LFS 状态，用于文件树/变更列表标注。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LfsPathState {
    pub path: String,
    /// `.gitattributes` 中 `filter=lfs` 是否命中。
    pub tracked: bool,
    /// 工作区文件内容仍是 LFS pointer（未 smudge）。
    pub pointer: bool,
}

/// `git lfs install --local` 安装的 hook 状态。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LfsHookState {
    pub post_checkout: bool,
    pub post_commit: bool,
    pub post_merge: bool,
    pub pre_push: bool,
}

/// 一次 LFS 命令的文本结果（stdout + 已脱敏 stderr）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LfsCommandResult {
    pub output: String,
    /// 本次命令为了让 checkout 生效，额外执行了 `git lfs install --local`。
    pub installed_filters: bool,
}

fn lfs_spec(workdir: &Path, args: &[String]) -> GitCommandSpec {
    GitCommandSpec::new(GitCommandCategory::Lfs, "lfs")
        .args(args.iter().cloned())
        .working_dir(workdir)
}

fn run_lfs(
    workdir: &Path,
    args: &[String],
    cancel: Option<&GitCancelToken>,
) -> Result<gitprocess::GitProcessOutcome, EngineError> {
    let spec = lfs_spec(workdir, args);
    gitprocess::run(&spec, cancel, |_| {})
}

fn lfs_failure(
    workdir: &Path,
    args: &[String],
    outcome: gitprocess::GitProcessOutcome,
) -> EngineError {
    if outcome.cancelled {
        return EngineError::Cancelled;
    }
    let spec = lfs_spec(workdir, args);
    outcome.into_error(&spec)
}

fn first_line(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_owned)
}

/// `git-lfs/3.7.1 (GitHub; darwin arm64; go 1.25.3)` -> `3.7.1`
fn parse_version(stdout: &str) -> Option<String> {
    let line = first_line(stdout)?;
    let rest = line.strip_prefix("git-lfs/").unwrap_or(&line);
    let version = rest.split_whitespace().next()?.trim();
    if version.is_empty() {
        None
    } else {
        Some(version.to_owned())
    }
}

fn looks_like_missing_lfs(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    lower.contains("'lfs' is not a git command") || lower.contains("git: 'lfs' is not a git command")
}

/// 探测 `git lfs` 可用性。任何失败都折叠成 `installed = false`，让 UI 能给出
/// 「安装 git-lfs」的可操作提示，而不是渲染原始 stderr。
pub(crate) fn lfs_capability(workdir: &Path) -> LfsCapability {
    let args = vec!["version".to_string()];
    match run_lfs(workdir, &args, None) {
        Ok(outcome) if outcome.success() && !looks_like_missing_lfs(&outcome.stderr) => {
            LfsCapability {
                installed: true,
                version: parse_version(&outcome.stdout),
                detail: None,
            }
        }
        Ok(outcome) => LfsCapability {
            installed: false,
            version: None,
            detail: first_line(&outcome.stderr).or_else(|| first_line(&outcome.stdout)),
        },
        Err(error) => LfsCapability {
            installed: false,
            version: None,
            detail: Some(error.to_string()),
        },
    }
}

fn parse_tracked_patterns(stdout: &str) -> Vec<LfsTrackedPattern> {
    // Listing tracked patterns
    //     *.bin (.gitattributes)
    // Listing excluded patterns
    let mut in_tracked = false;
    let mut patterns = Vec::new();
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with("Listing ") {
            in_tracked = trimmed.contains("tracked");
            continue;
        }
        if !in_tracked {
            continue;
        }
        // `pattern (source)`；pattern 本身可能含空格，因此从右往左找括号
        let Some(open) = trimmed.rfind(" (") else {
            patterns.push(LfsTrackedPattern {
                pattern: trimmed.to_string(),
                source: String::new(),
            });
            continue;
        };
        let source = trimmed[open + 2..].trim_end_matches(')').to_string();
        let pattern = trimmed[..open].trim().to_string();
        if !pattern.is_empty() {
            patterns.push(LfsTrackedPattern { pattern, source });
        }
    }
    patterns
}

/// 当前仓库被 LFS 跟踪的模式（含排除规则之外的 listing）。
pub(crate) fn lfs_tracked_patterns(workdir: &Path) -> Result<Vec<LfsTrackedPattern>, EngineError> {
    let args = vec!["track".to_string()];
    let outcome = run_lfs(workdir, &args, None)?;
    if !outcome.success() {
        if looks_like_missing_lfs(&outcome.stderr) {
            return Ok(Vec::new());
        }
        return Err(lfs_failure(workdir, &args, outcome));
    }
    Ok(parse_tracked_patterns(&outcome.stdout))
}

fn parse_ls_files(stdout: &str) -> Vec<LfsFileEntry> {
    // --long: `<oid> <*|-> <path>`；path 可含空格，因此只切前两段。
    let mut entries = Vec::new();
    for line in stdout.lines() {
        let line = line.trim_end();
        if line.trim().is_empty() {
            continue;
        }
        let mut parts = line.splitn(3, ' ');
        let (Some(oid), Some(marker), Some(path)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        if oid.is_empty() || path.is_empty() {
            continue;
        }
        entries.push(LfsFileEntry {
            path: path.to_string(),
            oid: oid.to_string(),
            content_present: marker == "*",
        });
    }
    entries
}

/// 仓库中的 LFS 文件；`all_revisions` 对应 `git lfs ls-files --all`。
pub(crate) fn lfs_files(
    workdir: &Path,
    all_revisions: bool,
) -> Result<Vec<LfsFileEntry>, EngineError> {
    let mut args = vec!["ls-files".to_string(), "--long".to_string()];
    if all_revisions {
        args.push("--all".to_string());
    }
    let outcome = run_lfs(workdir, &args, None)?;
    if !outcome.success() {
        if looks_like_missing_lfs(&outcome.stderr) {
            return Ok(Vec::new());
        }
        return Err(lfs_failure(workdir, &args, outcome));
    }
    Ok(parse_ls_files(&outcome.stdout))
}

fn worktree_file_is_pointer(workdir: &Path, path: &str) -> bool {
    let full = workdir.join(path);
    let Ok(bytes) = std::fs::read(&full) else {
        return false;
    };
    // pointer 文件很小；只在头部检测，避免把大文件读进内存。
    let head = &bytes[..bytes.len().min(POINTER_MAGIC.len() + 8)];
    head.starts_with(POINTER_MAGIC.as_bytes())
}

/// 批量标注路径的 LFS 状态：是否被 `filter=lfs` 命中、工作区是否仍是 pointer。
pub(crate) fn lfs_path_states(
    workdir: &Path,
    paths: &[String],
) -> Result<Vec<LfsPathState>, EngineError> {
    if paths.is_empty() {
        return Ok(Vec::new());
    }
    let attributes = attributes::check_attributes(workdir, paths)?;
    Ok(attributes
        .into_iter()
        .map(|attribute| {
            let tracked = matches!(&attribute.filter, AttributeValue::Value { value } if value == "lfs");
            let pointer = tracked && worktree_file_is_pointer(workdir, &attribute.path);
            LfsPathState {
                path: attribute.path,
                tracked,
                pointer,
            }
        })
        .collect())
}

fn hook_installed(git_dir: &Path, name: &str) -> bool {
    let path = git_dir.join("hooks").join(name);
    let Ok(bytes) = std::fs::read(&path) else {
        return false;
    };
    String::from_utf8_lossy(&bytes).contains("git lfs")
}

pub(crate) fn lfs_hook_state(git_dir: &Path) -> LfsHookState {
    LfsHookState {
        post_checkout: hook_installed(git_dir, LFS_HOOKS[0]),
        post_commit: hook_installed(git_dir, LFS_HOOKS[1]),
        post_merge: hook_installed(git_dir, LFS_HOOKS[2]),
        pre_push: hook_installed(git_dir, LFS_HOOKS[3]),
    }
}

fn output_result(outcome: &gitprocess::GitProcessOutcome) -> LfsCommandResult {
    let mut output = outcome.stdout.trim().to_string();
    let stderr = outcome.stderr.trim();
    if !stderr.is_empty() {
        if !output.is_empty() {
            output.push('\n');
        }
        output.push_str(stderr);
    }
    LfsCommandResult {
        output,
        installed_filters: false,
    }
}

fn filter_config(workdir: &Path, key: &str) -> bool {
    let spec = GitCommandSpec::new(GitCommandCategory::Config, "config")
        .args(["--get".to_string(), key.to_string()])
        .working_dir(workdir);
    match gitprocess::run_to_completion(&spec) {
        Ok(outcome) => {
            outcome.success() && outcome.stdout.to_ascii_lowercase().contains("git-lfs")
        }
        Err(_) => false,
    }
}

/// pointer 是否会被 smudge，取决于仓库/全局是否配置了 LFS filter。
fn lfs_filters_installed(workdir: &Path) -> bool {
    filter_config(workdir, "filter.lfs.smudge")
}

fn run_lfs_action(
    workdir: &Path,
    args: Vec<String>,
    cancel: Option<&GitCancelToken>,
) -> Result<LfsCommandResult, EngineError> {
    let outcome = run_lfs(workdir, &args, cancel)?;
    if !outcome.success() {
        return Err(lfs_failure(workdir, &args, outcome));
    }
    Ok(output_result(&outcome))
}

/// 检出方向的 LFS 命令（pull / checkout）在没有 filter 配置时会被 git-lfs
/// 静默跳过（退出码 0，只打印 "Skipping object checkout"）。这里在运行前
/// 补一次仓库级 `git lfs install --local`，并在仍然跳过时把结果折叠成错误，
/// 避免 UI 报告「已下载」而工作区仍是 pointer。
fn run_lfs_checkout_action(
    workdir: &Path,
    args: Vec<String>,
    cancel: Option<&GitCancelToken>,
) -> Result<LfsCommandResult, EngineError> {
    let mut installed_filters = false;
    if !lfs_filters_installed(workdir) {
        let install_args = vec!["install".to_string(), "--local".to_string()];
        let outcome = run_lfs(workdir, &install_args, cancel)?;
        if !outcome.success() {
            return Err(lfs_failure(workdir, &install_args, outcome));
        }
        installed_filters = true;
    }
    let outcome = run_lfs(workdir, &args, cancel)?;
    if !outcome.success() {
        return Err(lfs_failure(workdir, &args, outcome));
    }
    if outcome.stdout.contains("Skipping object checkout")
        || outcome.stderr.contains("Skipping object checkout")
    {
        return Err(EngineError::GitOperation {
            message: "Git LFS is not installed for this repository; run LFS install first".into(),
        });
    }
    let mut result = output_result(&outcome);
    result.installed_filters = installed_filters;
    Ok(result)
}

fn workdir_of(repository: &Repository) -> Result<PathBuf, EngineError> {
    repository
        .workdir()
        .map(PathBuf::from)
        .ok_or_else(|| EngineError::GitOperation {
            message: "Git LFS requires a working tree (bare repository)".into(),
        })
}

fn git_dir_of(repository: &Repository) -> PathBuf {
    PathBuf::from(repository.git_dir())
}

#[uniffi::export]
impl Repository {
    /// `git lfs version` 探测。
    pub fn lfs_capability(&self) -> LfsCapability {
        match self.workdir() {
            Some(workdir) => lfs_capability(Path::new(&workdir)),
            None => LfsCapability {
                installed: false,
                version: None,
                detail: Some("bare repository has no working tree".into()),
            },
        }
    }

    /// 被 LFS 跟踪的模式列表。
    pub fn lfs_tracked_patterns(&self) -> Result<Vec<LfsTrackedPattern>, EngineError> {
        lfs_tracked_patterns(&workdir_of(self)?)
    }

    /// 仓库中的 LFS 文件；`all_revisions = true` 时覆盖所有引用。
    pub fn lfs_files(&self, all_revisions: bool) -> Result<Vec<LfsFileEntry>, EngineError> {
        lfs_files(&workdir_of(self)?, all_revisions)
    }

    /// 批量标注路径的 LFS 状态（不改动磁盘）。
    pub fn lfs_path_states(&self, paths: Vec<String>) -> Result<Vec<LfsPathState>, EngineError> {
        lfs_path_states(&workdir_of(self)?, &paths)
    }

    /// 当前 `git lfs install --local` 的 hook 安装情况。
    pub fn lfs_hook_state(&self) -> LfsHookState {
        lfs_hook_state(&git_dir_of(self))
    }

    /// 安装 LFS 的 filter 与 hooks（仓库内生效，等价 `git lfs install --local`）。
    pub fn lfs_install(&self) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        run_lfs_action(&workdir, vec!["install".into(), "--local".into()], None)
    }

    /// 卸载 LFS 的 filter 与 hooks（仓库内生效）。
    pub fn lfs_uninstall(&self) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        run_lfs_action(&workdir, vec!["uninstall".into(), "--local".into()], None)
    }

    /// 让 LFS 跟踪给定模式；`git lfs track` 会改写 `.gitattributes`。
    pub fn lfs_track(&self, patterns: Vec<String>) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        if patterns.is_empty() {
            return Ok(LfsCommandResult {
                output: String::new(),
                installed_filters: false,
            });
        }
        let mut args = vec!["track".to_string()];
        args.extend(patterns);
        run_lfs_action(&workdir, args, None)
    }

    /// 取消跟踪给定模式。
    pub fn lfs_untrack(&self, patterns: Vec<String>) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        if patterns.is_empty() {
            return Ok(LfsCommandResult {
                output: String::new(),
                installed_filters: false,
            });
        }
        let mut args = vec!["untrack".to_string()];
        args.extend(patterns);
        run_lfs_action(&workdir, args, None)
    }

    /// 下载当前 revision 需要的 LFS 对象（不更新工作区）。
    /// `paths` 非空时只下载这些路径（`--include`）。
    pub fn lfs_fetch(
        &self,
        remote: Option<String>,
        all_revisions: bool,
        paths: Vec<String>,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        let mut args = vec!["fetch".to_string()];
        if all_revisions {
            args.push("--all".to_string());
        }
        for path in paths.iter().filter(|path| !path.trim().is_empty()) {
            args.push(format!("--include={path}"));
        }
        if let Some(remote) = remote.filter(|value| !value.trim().is_empty()) {
            args.push(remote);
        }
        run_lfs_action(&workdir, args, Some(cancel.token()))
    }

    /// 下载并检出 LFS 对象（`git lfs pull`）。
    /// `paths` 非空时只处理这些路径（`--include`），用于「下载这个文件」。
    pub fn lfs_pull(
        &self,
        remote: Option<String>,
        paths: Vec<String>,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        let mut args = vec!["pull".to_string()];
        for path in paths.iter().filter(|path| !path.trim().is_empty()) {
            args.push(format!("--include={path}"));
        }
        if let Some(remote) = remote.filter(|value| !value.trim().is_empty()) {
            args.push(remote);
        }
        run_lfs_checkout_action(&workdir, args, Some(cancel.token()))
    }

    /// 上传对象到远端；`all_revisions` 对应 `git lfs push --all`。
    pub fn lfs_push(
        &self,
        remote: Option<String>,
        all_revisions: bool,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        let mut args = vec!["push".to_string()];
        if all_revisions {
            args.push("--all".to_string());
        }
        args.push(remote.filter(|value| !value.trim().is_empty()).unwrap_or_else(|| "origin".into()));
        run_lfs_action(&workdir, args, Some(cancel.token()))
    }

    /// 清理本地不再被引用的 LFS 对象（`git lfs prune --force`）。
    pub fn lfs_prune(
        &self,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        run_lfs_action(
            &workdir,
            vec!["prune".into(), "--force".into()],
            Some(cancel.token()),
        )
    }

    /// 把工作区中的 pointer 还原成真实内容（`git lfs checkout`）。
    pub fn lfs_checkout(
        &self,
        paths: Vec<String>,
        cancel: std::sync::Arc<crate::gitprocess::GitCancelHandle>,
    ) -> Result<LfsCommandResult, EngineError> {
        let workdir = workdir_of(self)?;
        let mut args = vec!["checkout".to_string()];
        if !paths.is_empty() {
            args.push("--".to_string());
            args.extend(paths);
        }
        run_lfs_checkout_action(&workdir, args, Some(cancel.token()))
    }
}

//! OPS-001：Git 操作状态与恢复状态机。
//!
//! 统一识别四类进行中操作，无论状态由谁创建：
//! - 系统 git（用户在终端执行 merge/rebase/cherry-pick/revert，或引擎的
//!   系统恢复命令）：`MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD` /
//!   `rebase-merge/` / `rebase-apply/`；
//! - Arbor 引擎自管状态：`arbor-merge-state` / `arbor-rebase-state`
//!   （gix 路径不写标准状态文件）。
//!
//! UI 的 Operation Recovery Bar 只订阅 `operation_state()`，据此展示
//! continue/skip/abort；恢复命令按 origin 分派到引擎实现或系统 git。

use std::path::Path;

use crate::error::EngineError;
use crate::gitprocess::{self, GitCommandCategory, GitCommandSpec};

/// 进行中的操作类别。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationKind {
    Merge,
    Rebase,
    CherryPick,
    Revert,
}

/// 状态由谁创建：系统 git 的标准状态文件，或 Arbor 的自管状态文件。
/// 决定恢复命令走系统 git 还是引擎实现。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationOrigin {
    /// `rebase-merge/`、`MERGE_HEAD` 等标准 git 状态。
    Git,
    /// `arbor-merge-state`、`arbor-rebase-state`。
    Engine,
}

/// rebase 后端（`rebase-merge/` = merge backend，`rebase-apply/` = apply backend）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RebaseBackend {
    Merge,
    Apply,
}

/// 检测到的进行中操作与恢复所需的细节。
#[derive(uniffi::Record, Clone, Debug)]
pub struct OperationState {
    pub kind: OperationKind,
    pub origin: OperationOrigin,
    /// 仅 rebase：后端。
    pub backend: Option<RebaseBackend>,
    /// 仅 rebase：是否 todo 驱动（rebase-merge/interactive 存在）。
    /// 注意现代 git 对非交互 rebase 也使用 merge backend 并写该文件，
    /// 此字段表示 todo 机制在用，不能单独区分用户是否传了 `-i`。
    pub interactive: bool,
    /// 未解决的 unmerged 路径（status 的 Conflicted 条目）。
    pub conflicted_files: Vec<String>,
    /// 仅 rebase：onto 提交（hex）。
    pub onto: Option<String>,
    /// 仅 rebase：原分支全名（refs/heads/…）。
    pub original_branch: Option<String>,
    /// 仅 rebase：进度（已处理 / 总步数）。
    pub steps_done: Option<u32>,
    pub steps_total: Option<u32>,
    /// 暂停提交的 message（rebase 当前步 / engine merge 的提交信息）。
    pub message: Option<String>,
}

/// 从仓库状态检测进行中的操作。优先级与 git wt-status 一致：
/// rebase > cherry-pick > revert > merge；engine 状态仅在无 git 状态时生效。
pub(crate) fn detect(repo: &gix::Repository) -> Result<Option<OperationState>, EngineError> {
    let git_dir = repo.git_dir();
    let conflicted = || -> Result<Vec<String>, EngineError> {
        Ok(crate::status::compute_status(repo)?
            .into_iter()
            .filter(|entry| {
                entry.staged == crate::status::ChangeKind::Conflicted
                    || entry.unstaged == crate::status::ChangeKind::Conflicted
            })
            .map(|entry| entry.path)
            .collect())
    };

    if git_dir.join("rebase-merge").is_dir() {
        let dir = git_dir.join("rebase-merge");
        return Ok(Some(OperationState {
            kind: OperationKind::Rebase,
            origin: OperationOrigin::Git,
            backend: Some(RebaseBackend::Merge),
            interactive: dir.join("interactive").exists(),
            conflicted_files: conflicted()?,
            onto: read_trimmed(&dir.join("onto")),
            original_branch: read_trimmed(&dir.join("head-name")),
            steps_done: read_trimmed(&dir.join("msgnum")).and_then(|s| s.parse().ok()),
            steps_total: read_trimmed(&dir.join("end")).and_then(|s| s.parse().ok()),
            message: read_trimmed(&dir.join("message")),
        }));
    }
    if git_dir.join("rebase-apply").is_dir() {
        let dir = git_dir.join("rebase-apply");
        return Ok(Some(OperationState {
            kind: OperationKind::Rebase,
            origin: OperationOrigin::Git,
            backend: Some(RebaseBackend::Apply),
            interactive: false,
            conflicted_files: conflicted()?,
            onto: read_trimmed(&dir.join("onto")),
            original_branch: read_trimmed(&dir.join("head-name")),
            steps_done: read_trimmed(&dir.join("next")).and_then(|s| s.parse().ok()),
            steps_total: read_trimmed(&dir.join("last")).and_then(|s| s.parse().ok()),
            message: read_trimmed(&dir.join("message")),
        }));
    }
    // rebase 进行中时 CHERRY_PICK_HEAD 可能同时存在（rebase 内部用 cherry-pick
    // 机制），必须让位给 rebase；只有在无 rebase 状态时才独立成 cherry-pick。
    if git_dir.join("CHERRY_PICK_HEAD").exists() {
        return Ok(Some(OperationState {
            kind: OperationKind::CherryPick,
            origin: OperationOrigin::Git,
            backend: None,
            interactive: false,
            conflicted_files: conflicted()?,
            onto: None,
            original_branch: None,
            steps_done: None,
            steps_total: None,
            message: None,
        }));
    }
    if git_dir.join("REVERT_HEAD").exists() {
        return Ok(Some(OperationState {
            kind: OperationKind::Revert,
            origin: OperationOrigin::Git,
            backend: None,
            interactive: false,
            conflicted_files: conflicted()?,
            onto: None,
            original_branch: None,
            steps_done: None,
            steps_total: None,
            message: None,
        }));
    }
    if git_dir.join("MERGE_HEAD").exists() {
        return Ok(Some(OperationState {
            kind: OperationKind::Merge,
            origin: OperationOrigin::Git,
            backend: None,
            interactive: false,
            conflicted_files: conflicted()?,
            onto: None,
            original_branch: None,
            steps_done: None,
            steps_total: None,
            message: None,
        }));
    }
    if crate::remote::load_rebase_state(repo)?.is_some() {
        return Ok(Some(OperationState {
            kind: OperationKind::Rebase,
            origin: OperationOrigin::Engine,
            backend: None,
            interactive: false,
            conflicted_files: conflicted()?,
            onto: None,
            original_branch: None,
            steps_done: None,
            steps_total: None,
            message: None,
        }));
    }
    if git_dir.join("arbor-merge-state").exists() {
        return Ok(Some(OperationState {
            kind: OperationKind::Merge,
            origin: OperationOrigin::Engine,
            backend: None,
            interactive: false,
            conflicted_files: conflicted()?,
            onto: None,
            original_branch: None,
            steps_done: None,
            steps_total: None,
            message: None,
        }));
    }
    Ok(None)
}

fn read_trimmed(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

/// 恢复动作：对 git-origin 状态执行对应的系统 git 子命令。
#[derive(Clone, Copy, Debug)]
pub(crate) enum RecoveryAction {
    Continue,
    Skip,
    Abort,
}

/// 运行系统 git 恢复命令（merge/rebase/cherry-pick/revert 的 continue/skip/abort）。
/// 编辑器固定为 `true`（接受已有 message），绝不阻塞在交互编辑器上。
/// 返回 (成功?, 合并后的输出)。
pub(crate) fn run_recovery(
    workdir: &Path,
    kind: OperationKind,
    action: RecoveryAction,
) -> Result<(bool, String), EngineError> {
    let subcommand = match kind {
        OperationKind::Merge => "merge",
        OperationKind::Rebase => "rebase",
        OperationKind::CherryPick => "cherry-pick",
        OperationKind::Revert => "revert",
    };
    let flag = match action {
        RecoveryAction::Continue => "--continue",
        RecoveryAction::Skip => "--skip",
        RecoveryAction::Abort => "--abort",
    };
    // merge 没有独立的 --continue 子命令（git >= 2.12 有 `git merge --continue`）；
    // 统一用 merge --continue，编辑器为 true 时等价于接受 MERGE_MSG。
    let category = match kind {
        OperationKind::Merge => GitCommandCategory::Merge,
        OperationKind::Rebase => GitCommandCategory::Rebase,
        OperationKind::CherryPick => GitCommandCategory::CherryPick,
        OperationKind::Revert => GitCommandCategory::Revert,
    };
    let spec = GitCommandSpec::new(category, subcommand)
        .arg(flag)
        .working_dir(workdir)
        .env("GIT_EDITOR", "true")
        .env("GIT_SEQUENCE_EDITOR", "true")
        .env("GIT_MERGE_AUTOEDIT", "no");
    let outcome = gitprocess::run_to_completion(&spec)?;
    let output = if outcome.stderr.trim().is_empty() {
        outcome.stdout.trim().to_string()
    } else {
        outcome.stderr.trim().to_string()
    };
    Ok((outcome.success(), output))
}

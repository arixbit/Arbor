//! FFI 错误类型。引擎语言中立（D7）：只产出结构化错误码 + message 字符串，
//! 所有用户可见文案在 Swift 层本地化。

/// 引擎所有操作的失败都收口到这里。无用户文案；Swift 侧按变体 + message 本地化。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushFailureKind {
    NonFastForward,
    NoUpstream,
    Authentication,
    Permission,
    /// `--force-with-lease` refused to overwrite a remote ref that moved.
    StaleInfo,
    Other,
}

#[derive(uniffi::Error, Debug)]
pub enum EngineError {
    /// 给定路径不在任何 git 仓库内。
    NotARepository { path: String },
    /// 当前分支未配置 upstream，pull 无法确定要同步的远程分支。
    NoUpstream { branch: String },
    /// upstream 已配置，但对应的 remote-tracking ref 不存在。
    TrackingMissing { branch: String, upstream: String },
    /// 远程更新会覆盖工作区中尚未加入 Git 的本地文件。
    UntrackedWouldBeOverwritten { paths: Vec<String> },
    /// Git 操作会覆盖工作区中已有的本地变更。
    LocalChangesWouldBeOverwritten { paths: Vec<String> },
    /// stash 恢复时发生冲突；stash 引用会被保留，等待用户解决。
    /// `stash_id` 让 UI 可以准确打开本次 preserving process 保存的现场，
    /// 不必猜测 stash 栈位置。
    StashApplyConflict {
        paths: Vec<String>,
        stash_id: Option<String>,
    },
    /// shelf 应用时发生冲突；shelf 引用会被保留，等待用户解决。
    ShelveApplyConflict { name: String, paths: Vec<String> },
    /// push 被远程拒绝；保留分类，UI 可以提供 merge/rebase/publish 引导，
    /// 不需要从一段 shell 错误文本中猜测下一步。
    PushRejected {
        kind: PushFailureKind,
        remote: String,
        branch: String,
        message: String,
    },
    /// 用户取消了操作（认证对话框取消、取消令牌触发）。
    /// UI 应显示「已取消」而不是 generic error（AUTH-001 / ENG-001 验收）。
    Cancelled,
    /// 其他 git/引擎错误；message 携带 gix 错误链。
    GitOperation { message: String },
}

/// Display 仅供 uniffi FFI 约束与日志用（开发者面向，非用户文案）。
impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::NotARepository { path } => {
                write!(f, "not a git repository: {path}")
            }
            EngineError::NoUpstream { branch } => {
                write!(f, "pull: branch '{branch}' has no upstream")
            }
            EngineError::TrackingMissing { branch, upstream } => {
                write!(
                    f,
                    "pull: tracking branch '{upstream}' for '{branch}' is missing"
                )
            }
            EngineError::UntrackedWouldBeOverwritten { paths } => {
                write!(
                    f,
                    "untracked files would be overwritten: {}",
                    paths.join(", ")
                )
            }
            EngineError::LocalChangesWouldBeOverwritten { paths } => {
                write!(
                    f,
                    "local changes would be overwritten: {}",
                    paths.join(", ")
                )
            }
            EngineError::StashApplyConflict { paths, .. } => {
                write!(f, "stash apply conflicts: {}", paths.join(", "))
            }
            EngineError::ShelveApplyConflict { name, paths } => {
                write!(f, "shelve '{name}' apply conflicts: {}", paths.join(", "))
            }
            EngineError::PushRejected {
                remote,
                branch,
                message,
                ..
            } => write!(f, "push rejected for {remote}/{branch}: {message}"),
            EngineError::Cancelled => write!(f, "cancelled"),
            EngineError::GitOperation { message } => write!(f, "{message}"),
        }
    }
}

impl EngineError {
    /// 把任意 gix 错误收口为 GitOperation，并保留完整错误链（A: B: C 形式）。
    pub(crate) fn from_gix<E: std::error::Error>(e: E) -> Self {
        let mut message = format!("{e}");
        let mut source = e.source();
        while let Some(s) = source {
            message.push_str(": ");
            message.push_str(&format!("{s}"));
            source = s.source();
        }
        EngineError::GitOperation { message }
    }
}

impl From<gix::discover::Error> for EngineError {
    fn from(e: gix::discover::Error) -> Self {
        use gix::discover::upwards::Error as U;
        // 特判「未找到仓库」，给出带 path 的独立错误，便于 UI 区别展示。
        let not_a_repo_path = match &e {
            gix::discover::Error::Discover(up) => match up {
                U::NoGitRepository { path }
                | U::NoGitRepositoryWithinCeiling { path, .. }
                | U::NoGitRepositoryWithinFs { path, .. } => Some(path.display().to_string()),
                _ => None,
            },
            _ => None,
        };
        match not_a_repo_path {
            Some(path) => EngineError::NotARepository { path },
            None => EngineError::from_gix(e),
        }
    }
}

impl From<gix::status::Error> for EngineError {
    fn from(e: gix::status::Error) -> Self {
        EngineError::from_gix(e)
    }
}

// `platform.into_iter()` 的构建期错误（与逐条 item 的 iter::Error 不同）。
impl From<gix::status::into_iter::Error> for EngineError {
    fn from(e: gix::status::into_iter::Error) -> Self {
        EngineError::from_gix(e)
    }
}

impl From<gix::status::iter::Error> for EngineError {
    fn from(e: gix::status::iter::Error) -> Self {
        EngineError::from_gix(e)
    }
}

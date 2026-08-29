//! 远程操作与交互式 rebase 辅助。
//!
//! fetch/push 的 transport 走统一 system Git process（本地 file remote 也复用同一条路径）；
//! gix 负责 refs 刷新以及后续 merge/rebase 领域模型；
//! rebase = merge_trees cherry-pick 循环（ancestor=被移植提交的父树）。

use gix::bstr::{BStr, ByteSlice};

use crate::error::EngineError;
use crate::merge::{materialize_tree, ConflictEntry};

/// 一条远程（REMOTE-001：URL/push URL/refspec 全量配置）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct RemoteInfo {
    pub name: String,
    pub url: String,
    /// pushurl（未单独配置时为空，push 用 url）。
    pub push_url: Option<String>,
    /// fetch refspec（形如 +refs/heads/…:refs/remotes/origin/…，星号通配）。
    pub fetch_refspec: Option<String>,
    /// push refspec（形如 HEAD:refs/heads/main）。
    pub push_refspec: Option<String>,
}

/// fetch 结果：更新的 remote-tracking refs（refs/remotes/<name>/<branch> 的短名）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct FetchOutcome {
    pub updated: Vec<String>,
}

/// Tags to include when fetching, matching IntelliJ's project Git setting.
#[derive(uniffi::Enum, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum FetchTagsMode {
    /// Use the repository's normal Git tag-following behavior.
    #[default]
    Default,
    /// Fetch and prune tags that no longer exist on the remote.
    PruneTags,
    /// Fetch all tags from the remote.
    AllTags,
    /// Do not fetch tags.
    NoTags,
}

impl FetchTagsMode {
    pub(crate) fn flag(self) -> Option<&'static str> {
        match self {
            Self::Default => None,
            Self::PruneTags => Some("--prune-tags"),
            Self::AllTags => Some("--tags"),
            Self::NoTags => Some("--no-tags"),
        }
    }
}

/// 提交后推送的结果；无远程或 detached HEAD 时只提交，pushed=false。
#[derive(uniffi::Record, Clone, Debug)]
pub struct CommitPushOutcome {
    pub commit_id: String,
    pub pushed: bool,
}

/// Tags to include in a branch push, matching IntelliJ's Git push options.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushTagMode {
    /// Push all local tags (`git push --tags`).
    All,
    /// Push annotated tags reachable from the pushed branch (`--follow-tags`).
    Follow,
}

/// 交互式 rebase 的一个动作（与范围提交一一对应，旧→新）。
#[derive(uniffi::Enum, Clone, Debug)]
pub enum RebaseAction {
    Pick,
    Drop,
    Reword {
        message: String,
    },
    Squash,
    /// Squash the commit into its kept predecessor and use this complete
    /// message for the resulting commit.  An empty custom message is never
    /// emitted by the UI; the plain `Squash` variant keeps the old default
    /// concatenation behavior for callers that do not edit the message.
    SquashWithMessage {
        message: String,
    },
    /// 将提交并入前一个提交，但保留前一个提交的信息（git autosquash 的 fixup! 语义）。
    Fixup,
    /// 应用到该提交后暂停（用户 amend，然后 rebase_continue）。
    Edit,
}

/// rebase 暂停原因，公开给 Swift 以便 UI 不通过错误字符串猜测状态。
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum RebasePauseReason {
    Edit,
    Conflict,
}

/// rebase 结果：新 HEAD id + 暂停信息。
#[derive(uniffi::Record, Clone, Debug)]
pub struct RebaseOutcome {
    pub head_id: String,
    pub paused: bool,
    pub pause_reason: Option<RebasePauseReason>,
    pub conflicts: Vec<String>,
}

/// rebase 暂停/续跑的状态（存 .git/arbor-rebase-state，跨进程存活）。
#[derive(Clone, Debug)]
pub(crate) struct RebaseState {
    pub original_head: gix::hash::ObjectId,
    pub onto: gix::hash::ObjectId,
    pub head: gix::hash::ObjectId,
    pub tree: gix::hash::ObjectId,
    /// 当前（edit）提交信息，amend 用
    pub message: String,
    /// 暂停原因；旧状态文件缺省为 Edit。
    pub reason: RebasePauseReason,
    /// 剩余 (action, commit_id)，旧→新
    pub remaining: Vec<(RebaseAction, gix::hash::ObjectId)>,
}

pub(crate) fn rebase_state_path(repo: &gix::Repository) -> std::path::PathBuf {
    repo.git_dir().join("arbor-rebase-state")
}

/// 序列化：单行转义 `\` 与 `\n`。
fn encode(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\n', "\\n")
}
fn decode(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('\\') => out.push('\\'),
                _ => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn action_tag(a: &RebaseAction) -> char {
    match a {
        RebaseAction::Pick => 'P',
        RebaseAction::Drop => 'D',
        RebaseAction::Reword { .. } => 'R',
        RebaseAction::Squash | RebaseAction::SquashWithMessage { .. } => 'S',
        RebaseAction::Fixup => 'F',
        RebaseAction::Edit => 'E',
    }
}

/// 保存 rebase 状态。
pub(crate) fn save_rebase_state(
    repo: &gix::Repository,
    state: &RebaseState,
) -> Result<(), EngineError> {
    let mut text = String::new();
    text.push_str(&format!("original_head={}\n", state.original_head));
    text.push_str(&format!("onto={}\n", state.onto));
    text.push_str(&format!("head={}\n", state.head));
    text.push_str(&format!("tree={}\n", state.tree));
    text.push_str(&format!(
        "reason={}\n",
        match state.reason {
            RebasePauseReason::Edit => "edit",
            RebasePauseReason::Conflict => "conflict",
        }
    ));
    text.push_str(&format!("message={}\n", encode(&state.message)));
    for (action, id) in &state.remaining {
        let tag = action_tag(action);
        let msg = match action {
            RebaseAction::Reword { message } | RebaseAction::SquashWithMessage { message } => {
                format!(" {}\n", encode(message))
            }
            _ => "\n".into(),
        };
        text.push_str(&format!("{tag} {id}{msg}"));
    }
    std::fs::write(rebase_state_path(repo), text).map_err(EngineError::from_gix)?;
    Ok(())
}

/// 读取 rebase 状态；无状态返回 None。
pub(crate) fn load_rebase_state(
    repo: &gix::Repository,
) -> Result<Option<RebaseState>, EngineError> {
    let path = rebase_state_path(repo);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(None);
    };
    let mut original_head = None;
    let mut onto = None;
    let mut head = None;
    let mut tree = None;
    let mut reason = RebasePauseReason::Edit;
    let mut message = String::new();
    let mut remaining = Vec::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "original_head" => original_head = gix::hash::ObjectId::from_hex(value.as_bytes()).ok(),
            "onto" => onto = gix::hash::ObjectId::from_hex(value.as_bytes()).ok(),
            "head" => head = gix::hash::ObjectId::from_hex(value.as_bytes()).ok(),
            "tree" => tree = gix::hash::ObjectId::from_hex(value.as_bytes()).ok(),
            "reason" => {
                reason = if value == "conflict" {
                    RebasePauseReason::Conflict
                } else {
                    RebasePauseReason::Edit
                }
            }
            "message" => message = decode(value),
            _ => {}
        }
    }
    for line in text.lines() {
        if line.starts_with('P')
            || line.starts_with('D')
            || line.starts_with('S')
            || line.starts_with('F')
            || line.starts_with('E')
            || line.starts_with('R')
        {
            let (tag, rest) = line.split_at(1);
            let rest = rest.trim_start();
            let (id_hex, msg_part) = match rest.split_once(' ') {
                Some((id, m)) => (id, Some(m)),
                None => (rest, None),
            };
            let Ok(id) = gix::hash::ObjectId::from_hex(id_hex.as_bytes()) else {
                continue;
            };
            let action = match tag {
                "P" => RebaseAction::Pick,
                "D" => RebaseAction::Drop,
                "S" => match msg_part {
                    Some(message) if !message.is_empty() => RebaseAction::SquashWithMessage {
                        message: decode(message),
                    },
                    _ => RebaseAction::Squash,
                },
                "F" => RebaseAction::Fixup,
                "E" => RebaseAction::Edit,
                "R" => RebaseAction::Reword {
                    message: decode(msg_part.unwrap_or("")),
                },
                _ => continue,
            };
            remaining.push((action, id));
        }
    }
    let (Some(original_head), Some(onto), Some(head), Some(tree)) =
        (original_head, onto, head, tree)
    else {
        return Ok(None);
    };
    Ok(Some(RebaseState {
        original_head,
        onto,
        head,
        tree,
        message,
        reason,
        remaining,
    }))
}

/// 清除 rebase 状态。
pub(crate) fn clear_rebase_state(repo: &gix::Repository) {
    let _ = std::fs::remove_file(rebase_state_path(repo));
}

/// 列出远程（名字 + fetch url）。
/// 直接从 .git/config 读取（gix 的 Repository 缓存 config，remote_add 写盘后
/// 同一句柄看不到新 remote；绕开缓存保证列表最新）。
pub(crate) fn list_remotes(repo: &gix::Repository) -> Result<Vec<RemoteInfo>, EngineError> {
    let config_path = repo.git_dir().join("config");
    let config = gix::config::File::from_path_no_includes(config_path, gix::config::Source::Local)
        .map_err(EngineError::from_gix)?;
    let mut out = Vec::new();
    for section in config.sections() {
        let header = section.header();
        if header.name() != "remote" {
            continue;
        }
        let Some(name) = header.subsection_name() else {
            continue;
        };
        let url = section
            .value("url")
            .map(|v| v.to_string())
            .unwrap_or_default();
        let push_url = section.value("pushurl").map(|v| v.to_string());
        let fetch_refspec = section.value("fetch").map(|v| v.to_string());
        let push_refspec = section.value("push").map(|v| v.to_string());
        out.push(RemoteInfo {
            name: name.to_string(),
            url,
            push_url,
            fetch_refspec,
            push_refspec,
        });
    }
    Ok(out)
}

/// 第一个远程名（默认远程），从 .git/config 读取。
pub(crate) fn default_remote_name(repo: &gix::Repository) -> Result<String, EngineError> {
    let config_path = repo.git_dir().join("config");
    let config = gix::config::File::from_path_no_includes(config_path, gix::config::Source::Local)
        .map_err(EngineError::from_gix)?;
    for section in config.sections() {
        let header = section.header();
        if header.name() == "remote" {
            if let Some(name) = header.subsection_name() {
                return Ok(name.to_string());
            }
        }
    }
    Err(EngineError::GitOperation {
        message: "no remote configured".into(),
    })
}

/// cherry-pick：merge_trees(ancestor=cherry 的父树, ours=当前树, theirs=cherry 树)。
/// 保持旧的 clean-only API，普通调用方仍把冲突当作错误。
pub(crate) fn cherry_pick_tree(
    repo: &gix::Repository,
    cherry: &gix::Commit<'_>,
    current_tree: gix::hash::ObjectId,
) -> Result<gix::hash::ObjectId, EngineError> {
    match cherry_pick_tree_with_conflict(repo, cherry, current_tree)? {
        CherryPickOutcome::Clean(tree) => Ok(tree),
        CherryPickOutcome::Conflict { .. } => Err(EngineError::GitOperation {
            message: "rebase: conflict while applying commit".into(),
        }),
    }
}

pub(crate) enum CherryPickOutcome {
    Clean(gix::hash::ObjectId),
    Conflict {
        merged_tree: gix::hash::ObjectId,
        conflicts: Vec<ConflictEntry>,
    },
}

/// 可暂停的 cherry-pick 变体：保留含 marker 的合并树和 stages 数据。
pub(crate) fn cherry_pick_tree_with_conflict(
    repo: &gix::Repository,
    cherry: &gix::Commit<'_>,
    current_tree: gix::hash::ObjectId,
) -> Result<CherryPickOutcome, EngineError> {
    use gix::merge::blob::builtin_driver::text::Labels;
    let parent_tree = {
        let mut parents = cherry.parent_ids();
        match parents.next() {
            Some(p) => repo
                .find_commit(p)
                .map_err(EngineError::from_gix)?
                .tree_id()
                .map_err(EngineError::from_gix)?
                .detach(),
            None => repo.empty_tree().id, // 根提交：ancestor = 空树
        }
    };
    let cherry_tree = cherry.tree_id().map_err(EngineError::from_gix)?.detach();
    let labels = Labels {
        ancestor: None,
        current: Some(BStr::new("HEAD")),
        other: Some(BStr::new("cherry-pick")),
    };
    let options = repo.tree_merge_options().map_err(EngineError::from_gix)?;
    let mut outcome = repo
        .merge_trees(parent_tree, current_tree, cherry_tree, labels, options)
        .map_err(EngineError::from_gix)?;
    // 冲突检测：任一冲突的合并 blob 含 marker（resolution == Conflict）。
    // 注意 `failed_on_first_unresolved_conflict` 不反映无 fail-on-conflict 模式下的冲突。
    let has_conflict = outcome.conflicts.iter().any(|c| {
        c.content_merge()
            .map(|cm| cm.resolution == gix::merge::blob::Resolution::Conflict)
            .unwrap_or(false)
    });
    if has_conflict {
        let conflicts = outcome
            .conflicts
            .iter()
            .filter(|conflict| {
                conflict
                    .content_merge()
                    .map(|cm| cm.resolution == gix::merge::blob::Resolution::Conflict)
                    .unwrap_or(false)
            })
            .map(|conflict| {
                let entries = conflict.entries();
                ConflictEntry {
                    path: conflict.ours.location().to_str_lossy().into_owned(),
                    entries: entries.map(|entry| entry.map(|e| (e.id, e.mode))),
                }
            })
            .collect();
        let merged_tree = outcome
            .tree
            .write()
            .map_err(EngineError::from_gix)?
            .detach();
        return Ok(CherryPickOutcome::Conflict {
            merged_tree,
            conflicts,
        });
    }
    let tree = outcome
        .tree
        .write()
        .map_err(EngineError::from_gix)?
        .detach();
    Ok(CherryPickOutcome::Clean(tree))
}

/// 恢复 HEAD 到指定提交（rebase 中止用）：ref 回移 + 工作区物化 + 索引重建。
pub(crate) fn restore_head(
    repo: &gix::Repository,
    original_head: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    // 当前 HEAD 树（materialize 的 old 侧）
    let current_tree = repo
        .head_commit()
        .ok()
        .and_then(|c| c.tree_id().ok())
        .map(|t| t.detach());
    restore_head_from_tree(repo, original_head, current_tree)
}

/// 用指定的旧工作区树恢复 HEAD；rebase conflict 暂停时 HEAD 仍指向上一个
/// 已提交树，但工作区实际来自含 marker 的临时合并树，因此必须由状态文件提供 old tree。
pub(crate) fn restore_head_from_tree(
    repo: &gix::Repository,
    original_head: gix::hash::ObjectId,
    current_tree: Option<gix::hash::ObjectId>,
) -> Result<(), EngineError> {
    use gix::refs::transaction::{Change, PreviousValue, RefEdit};
    use gix::refs::Target;
    let target_commit = repo
        .find_commit(original_head)
        .map_err(EngineError::from_gix)?;
    let target_tree = target_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();

    // 1. ref 回移
    match repo.head_name().map_err(EngineError::from_gix)? {
        Some(name) => {
            repo.reference(name, original_head, PreviousValue::Any, "rebase: abort")
                .map_err(EngineError::from_gix)?;
        }
        None => {
            let head_name: gix::refs::FullName =
                "HEAD".try_into().map_err(EngineError::from_gix)?;
            repo.edit_reference(RefEdit {
                change: Change::Update {
                    log: Default::default(),
                    expected: PreviousValue::Any,
                    new: Target::Object(original_head),
                },
                name: head_name,
                deref: true,
            })
            .map_err(EngineError::from_gix)?;
        }
    }

    // 2. 工作区物化（当前树 -> 目标树）
    if let Some(cur) = current_tree {
        if let Some(workdir) = repo.workdir() {
            materialize_tree(repo, cur, target_tree, workdir)?;
        }
    }
    // 3. 索引重建
    let mut index = repo
        .index_from_tree(&target_tree)
        .map_err(EngineError::from_gix)?;
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;
    Ok(())
}

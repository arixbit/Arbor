//! REBASE-001：interactive rebase 的显式 todo 模型。
//!
//! - `RebaseTodo`：onto + 有序 item 列表。顺序由用户拖拽/批量操作决定，
//!   是最终执行顺序的权威来源（不是「按数组固定的默认顺序」）；
//! - `build_todo`：从 HEAD 沿第一父链到 onto 生成默认 todo（全部 pick），
//!   autosquash 时 `fixup!`/`squash!` 提交自动吸附到目标提交后
//!   （预览 = 生成结果直接展示，用户可手工修正）；
//! - `validate_to_actions`：执行前校验 todo 与范围提交集合一一对应
//!   （不重复、不缺失、顺序任意），再转成引擎的 RebaseAction。

use gix::bstr::ByteSlice;

use crate::error::EngineError;
use crate::remote::RebaseAction;

/// todo 动作（git todo 全集）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RebaseTodoAction {
    Pick,
    Reword,
    Edit,
    Squash,
    Fixup,
    Drop,
}

/// todo 的一行。
#[derive(uniffi::Record, Clone, Debug)]
pub struct RebaseTodoItem {
    pub action: RebaseTodoAction,
    pub commit_id: String,
    /// 提交标题（显示用；reword 后仍显示原标题，用户可改 message）。
    pub summary: String,
    /// reword 的新信息；Squash 时也可填写最终合并提交信息；None = 保留默认信息。
    pub message: Option<String>,
    /// Merge-preserving todo 中的 merge 拓扑行。该行由 Git 的
    /// label/reset/merge 控制语义驱动，结构化编辑器只能保留它。
    pub is_merge_commit: bool,
    /// Merge-preserving todo 中，当前提交是否与上一行处于同一条
    /// 可连续重放的线性分支段。只有这种行可以安全使用 squash/fixup；
    /// 跨 label/reset/merge 控制边界的组合必须由执行器拒绝。
    pub can_squash_or_fixup: bool,
}

/// 显式 rebase todo。
#[derive(uniffi::Record, Clone, Debug)]
pub struct RebaseTodo {
    pub onto: String,
    pub items: Vec<RebaseTodoItem>,
}

/// 计算 rebase 范围：HEAD 沿第一父链到 onto（不含）的非 merge 提交，旧→新。
/// onto 不在第一父链时退到 merge-base（与 rebase_with_options 一致）。
pub(crate) fn rebase_range(
    repo: &gix::Repository,
    onto_id: gix::hash::ObjectId,
    original_head: gix::hash::ObjectId,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
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
    Ok(range)
}

/// 生成默认 todo（全部 pick）；`auto_squash` 时 fixup!/squash! 吸附。
pub(crate) fn build_todo(
    repo: &gix::Repository,
    onto_id: gix::hash::ObjectId,
    original_head: gix::hash::ObjectId,
    auto_squash: bool,
) -> Result<RebaseTodo, EngineError> {
    let range = rebase_range(repo, onto_id, original_head)?;
    build_todo_from_ids(repo, onto_id, range, auto_squash)
}

/// 以调用方提供的拓扑顺序生成 todo。
///
/// `--rebase-merges` 的原生 todo 还包含 label/reset/merge 控制行；Arbor
/// 用 merge commit 行代表这段受 Git 控制的拓扑，真正的 label/reset/merge
/// 指令仍由 Git 生成和执行。因此这里的顺序必须与原生 rebase 展开顺序
/// 一致，而不能退回 first-parent 线。
pub(crate) fn build_todo_from_ids(
    repo: &gix::Repository,
    onto_id: gix::hash::ObjectId,
    ids: Vec<gix::hash::ObjectId>,
    auto_squash: bool,
) -> Result<RebaseTodo, EngineError> {
    let items = build_todo_items(repo, ids, auto_squash)?;
    Ok(RebaseTodo {
        onto: onto_id.to_hex().to_string(),
        items,
    })
}

/// Build a todo for true `git rebase --root`; its upstream field is empty
/// because there is no excluded parent revision.
pub(crate) fn build_todo_from_ids_without_onto(
    repo: &gix::Repository,
    ids: Vec<gix::hash::ObjectId>,
    auto_squash: bool,
) -> Result<RebaseTodo, EngineError> {
    Ok(RebaseTodo {
        onto: String::new(),
        items: build_todo_items(repo, ids, auto_squash)?,
    })
}

fn build_todo_items(
    repo: &gix::Repository,
    ids: Vec<gix::hash::ObjectId>,
    auto_squash: bool,
) -> Result<Vec<RebaseTodoItem>, EngineError> {
    let mut pairs: Vec<(RebaseAction, gix::hash::ObjectId)> =
        ids.iter().map(|id| (RebaseAction::Pick, *id)).collect();
    if auto_squash {
        pairs = autosquash_pairs(repo, pairs)?;
    }
    let pair_ids: Vec<_> = pairs.iter().map(|(_, id)| *id).collect();
    let mut items = Vec::with_capacity(pairs.len());
    for (index, (action, id)) in pairs.into_iter().enumerate() {
        let summary = commit_title(repo, id)?;
        let is_merge_commit = repo
            .find_commit(id)
            .map_err(EngineError::from_gix)?
            .parent_ids()
            .nth(1)
            .is_some();
        let can_squash_or_fixup = if index == 0 || is_merge_commit {
            false
        } else {
            let previous_id = Some(pair_ids[index - 1]);
            let previous_is_merge = previous_id
                .and_then(|previous| repo.find_commit(previous).ok())
                .and_then(|commit| commit.parent_ids().nth(1))
                .is_some();
            let first_parent = repo
                .find_commit(id)
                .map_err(EngineError::from_gix)?
                .parent_ids()
                .next()
                .map(|parent| parent.detach());
            !previous_is_merge && first_parent == previous_id
        };
        items.push(RebaseTodoItem {
            action: match action {
                RebaseAction::Pick => RebaseTodoAction::Pick,
                RebaseAction::Drop => RebaseTodoAction::Drop,
                RebaseAction::Reword { .. } => RebaseTodoAction::Reword,
                RebaseAction::Squash | RebaseAction::SquashWithMessage { .. } => {
                    RebaseTodoAction::Squash
                }
                RebaseAction::Fixup => RebaseTodoAction::Fixup,
                RebaseAction::Edit => RebaseTodoAction::Edit,
            },
            commit_id: id.to_hex().to_string(),
            summary,
            message: None,
            is_merge_commit,
            can_squash_or_fixup,
        });
    }
    Ok(items)
}

/// 校验 todo 并转成 (action, commit_id) 序列。
/// 规则：item 集合与范围提交集合完全一致（长度相等即互不重复且无缺失），
/// **顺序以 todo 为准**（拖拽排序的最终权威）。reword 未提供新信息时用
/// 提交原信息。返回 pairs 的顺序 = todo 顺序，执行时直接按此重放。
pub(crate) fn validate_to_pairs(
    repo: &gix::Repository,
    onto_id: gix::hash::ObjectId,
    original_head: gix::hash::ObjectId,
    todo: &RebaseTodo,
) -> Result<Vec<(RebaseAction, gix::hash::ObjectId)>, EngineError> {
    let range = rebase_range(repo, onto_id, original_head)?;
    validate_to_pairs_from_ids(repo, &range, todo)
}

/// Validate a todo against a caller-provided commit order.  Root rebase has no
/// excluded `onto` commit, so it cannot use `rebase_range` without making up
/// a synthetic parent; the set/order validation itself is otherwise identical.
pub(crate) fn validate_to_pairs_from_ids(
    repo: &gix::Repository,
    range: &[gix::hash::ObjectId],
    todo: &RebaseTodo,
) -> Result<Vec<(RebaseAction, gix::hash::ObjectId)>, EngineError> {
    if todo.items.len() != range.len() {
        return Err(EngineError::GitOperation {
            message: format!(
                "rebase todo: {} items for {} commits in range",
                todo.items.len(),
                range.len()
            ),
        });
    }
    let mut seen = std::collections::HashSet::new();
    let mut pairs = Vec::with_capacity(todo.items.len());
    for item in &todo.items {
        let id = gix::hash::ObjectId::from_hex(item.commit_id.as_bytes()).map_err(|_| {
            EngineError::GitOperation {
                message: format!("rebase todo: invalid commit id {}", item.commit_id),
            }
        })?;
        if !seen.insert(id) {
            return Err(EngineError::GitOperation {
                message: format!("rebase todo: duplicate commit {}", item.commit_id),
            });
        }
        if !range.contains(&id) {
            return Err(EngineError::GitOperation {
                message: format!(
                    "rebase todo: commit {} is not in the rebase range",
                    item.commit_id
                ),
            });
        }
        if matches!(
            item.action,
            RebaseTodoAction::Squash | RebaseTodoAction::Fixup
        ) {
            let Some((_, previous_id)) = pairs.last() else {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "rebase todo: {} cannot be the first row",
                        match item.action {
                            RebaseTodoAction::Squash => "squash",
                            RebaseTodoAction::Fixup => "fixup",
                            _ => unreachable!(),
                        }
                    ),
                });
            };
            let previous_action = pairs.last().map(|(action, _)| action);
            let current_is_merge = repo
                .find_commit(id)
                .map_err(EngineError::from_gix)?
                .parent_ids()
                .nth(1)
                .is_some();
            let previous_is_merge = repo
                .find_commit(*previous_id)
                .map_err(EngineError::from_gix)?
                .parent_ids()
                .nth(1)
                .is_some();
            if matches!(previous_action, Some(RebaseAction::Drop))
                || current_is_merge
                || previous_is_merge
            {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "rebase todo: squash/fixup for {} has no valid kept predecessor",
                        item.commit_id
                    ),
                });
            }
        }
        let action = match item.action {
            RebaseTodoAction::Pick => RebaseAction::Pick,
            RebaseTodoAction::Drop => RebaseAction::Drop,
            RebaseTodoAction::Edit => RebaseAction::Edit,
            RebaseTodoAction::Squash => match item
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
            RebaseTodoAction::Fixup => RebaseAction::Fixup,
            RebaseTodoAction::Reword => {
                let message = match &item.message {
                    Some(message) => message.clone(),
                    None => commit_title(repo, id)?,
                };
                RebaseAction::Reword { message }
            }
        };
        pairs.push((action, id));
    }
    Ok(pairs)
}

/// autosquash 吸附：`squash! <subject>` / `fixup! <subject>` 提交移动到
/// 主题匹配的提交之后并改对应动作（git autosquash 语义）。
pub(crate) fn autosquash_pairs(
    repo: &gix::Repository,
    mut pairs: Vec<(RebaseAction, gix::hash::ObjectId)>,
) -> Result<Vec<(RebaseAction, gix::hash::ObjectId)>, EngineError> {
    let mut i = 0;
    while i < pairs.len() {
        let id = pairs[i].1;
        if repo
            .find_commit(id)
            .map_err(EngineError::from_gix)?
            .parent_ids()
            .nth(1)
            .is_some()
        {
            i += 1;
            continue;
        }
        let title = commit_title(repo, id)?;
        let (prefix, action) = if let Some(target) = title.strip_prefix("squash! ") {
            (target.trim(), RebaseAction::Squash)
        } else if let Some(target) = title.strip_prefix("fixup! ") {
            (target.trim(), RebaseAction::Fixup)
        } else {
            i += 1;
            continue;
        };

        let target_index = pairs[..i].iter().position(|(_, target_id)| {
            repo.find_commit(*target_id)
                .map(|commit| commit.parent_ids().nth(1).is_none())
                .unwrap_or(false)
                && commit_title(repo, *target_id)
                    .map(|target_title| target_title == prefix)
                    .unwrap_or(false)
        });
        let Some(target_index) = target_index else {
            i += 1;
            continue;
        };

        let (_, moved_id) = pairs.remove(i);
        let insert_at = target_index + 1;
        pairs.insert(insert_at, (action, moved_id));
        // 目标后插入的 autosquash commit 已经处理；继续扫描其后的原序列。
        // 注意：目标紧邻 fixup 之前时 insert_at + 1 == i（位置没变），
        // 此时必须推进 i，否则同一 fixup 会无限循环。
        i = if insert_at + 1 <= i {
            i + 1
        } else {
            insert_at + 1
        };
    }
    Ok(pairs)
}

/// 提交标题（第一行）。
pub(crate) fn commit_title(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
) -> Result<String, EngineError> {
    let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
    commit
        .message()
        .map(|m| m.title.trim_end().to_str_lossy().into_owned())
        .map_err(EngineError::from_gix)
}

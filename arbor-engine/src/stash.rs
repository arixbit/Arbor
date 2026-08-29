//! stash：保存 / 列表 / 弹出 / 丢弃（gix 无 stash API，手动组装）。
//!
//! 结构：index-提交（tree=索引树，父=保存时 HEAD）+ stash-提交（tree=工作区树，
//! 父=[保存时 HEAD, index-提交]），refs/stash 指向最新 stash；stash 栈由
//! refs/stash 的 reflog 管理，和系统 Git 保持一致。

use crate::error::EngineError;
use crate::index::mode_to_kind;

/// 一条 stash。
#[derive(uniffi::Record, Clone, Debug)]
pub struct StashInfo {
    pub id: String,
    pub short_id: String,
    pub message: String,
}

/// 按 refs/stash reflog 列出 stash（新→旧）。
///
/// Git stash commit 的第一父必须是保存现场时的 HEAD，不能拿上一个 stash
/// 充当第一父；否则三方合并会把整个旧 stash 树当成共同基线。stash 栈的
/// 顺序来自 refs/stash reflog，而不是 commit parent 链。
pub(crate) fn walk_stash_chain(
    repo: &gix::Repository,
) -> Result<Vec<gix::hash::ObjectId>, EngineError> {
    use std::collections::HashSet;

    let mut out = Vec::new();
    let Some(id) = repo
        .find_reference("refs/stash")
        .ok()
        .and_then(|r| r.try_id())
    else {
        return Ok(out);
    };
    let current = id.detach();
    let log_path = repo.git_dir().join("logs").join("refs").join("stash");
    let mut reflog_ids = Vec::new();
    if let Ok(text) = std::fs::read_to_string(log_path) {
        let lines: Vec<&str> = text.lines().collect();
        // A dropped stash can leave older reflog lines behind. Start at the
        // last entry that produced the current ref, so stale newer lines do
        // not resurrect a stash that is no longer in the stack.
        if let Some(start) = lines
            .iter()
            .rposition(|line| reflog_new_id(line).as_ref() == Some(&current))
        {
            reflog_ids.extend(
                lines[..=start]
                    .iter()
                    .rev()
                    .filter_map(|line| reflog_new_id(line)),
            );
        }
    }

    // Keep the current ref even if its reflog is missing or malformed.
    if reflog_ids.first().copied() != Some(current) {
        reflog_ids.insert(0, current);
    }

    let mut seen = HashSet::new();
    for cid in reflog_ids {
        if !seen.insert(cid) {
            continue;
        }
        let Ok(commit) = repo.find_commit(cid) else {
            continue;
        };
        if commit.parent_ids().count() >= 2 {
            out.push(cid);
        }
    }

    // Compatibility for repositories created by the old Arbor implementation
    // (which incorrectly chained stash commits through their first parent).
    if out.is_empty() {
        let mut cur = Some(current);
        while let Some(cid) = cur {
            let Ok(commit) = repo.find_commit(cid) else {
                break;
            };
            let parents: Vec<_> = commit.parent_ids().collect();
            if parents.len() < 2 {
                break;
            }
            out.push(cid);
            cur = parents.first().map(|p| p.detach());
        }
    }
    Ok(out)
}

fn reflog_new_id(line: &str) -> Option<gix::hash::ObjectId> {
    let mut fields = line.split_whitespace();
    let _old = fields.next()?;
    let new = fields.next()?;
    gix::hash::ObjectId::from_hex(new.as_bytes()).ok()
}

/// 从工作区文件构建树（stash 的工作区侧；索引路径对应的工作区文件缺失 = 删除）。
pub(crate) fn build_worktree_tree(
    repo: &gix::Repository,
    index: &gix::index::File,
    workdir: &std::path::Path,
    include_untracked: bool,
    include_ignored: bool,
) -> Result<gix::hash::ObjectId, EngineError> {
    use gix::bstr::ByteSlice;
    use std::collections::HashSet;
    use std::os::unix::fs::PermissionsExt;

    let mut editor = repo
        .edit_tree(repo.empty_tree().id)
        .map_err(EngineError::from_gix)?;
    let indexed_paths: HashSet<Vec<u8>> = index
        .entries()
        .iter()
        .map(|entry| entry.path(index).to_vec())
        .collect();
    for entry in index.entries() {
        let path = entry.path(index);
        let file_path = workdir.join(String::from_utf8_lossy(path).into_owned());
        if entry.mode.contains(gix::index::entry::Mode::COMMIT) {
            // A nested worktree is a separate repository boundary. Preserve
            // the parent gitlink in the stash tree instead of attempting to
            // read the directory as a blob (which would make stash/reset
            // materialization remove the nested worktree).
            editor
                .upsert(path, mode_to_kind(entry.mode), entry.id)
                .map_err(EngineError::from_gix)?;
            continue;
        }
        if let Ok(data) = std::fs::read(&file_path) {
            let blob = repo
                .write_blob(&data)
                .map_err(EngineError::from_gix)?
                .detach();
            editor
                .upsert(path, mode_to_kind(entry.mode), blob)
                .map_err(EngineError::from_gix)?;
        }
    }

    if include_untracked {
        let list_paths = |with_ignored: bool| -> Result<Vec<Vec<u8>>, EngineError> {
            let mut args = vec!["ls-files", "--others"];
            if with_ignored {
                args.push("--ignored");
            }
            args.extend(["--exclude-standard", "-z"]);
            let output = crate::gitprocess::git_command_for_working_dir(workdir)
                .args(args)
                .current_dir(workdir)
                .output()
                .map_err(|error| EngineError::GitOperation {
                    message: format!("failed to list untracked files for stash: {error}"),
                })?;
            if !output.status.success() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "git ls-files failed while saving untracked files: {}",
                        String::from_utf8_lossy(&output.stderr).trim()
                    ),
                });
            }
            Ok(output
                .stdout
                .split(|byte| *byte == 0)
                .filter(|path| !path.is_empty())
                .map(|path| path.to_vec())
                .collect())
        };
        let mut paths = list_paths(false)?;
        if include_ignored {
            paths.extend(list_paths(true)?);
        }
        paths.sort();
        paths.dedup();

        for path in paths {
            if indexed_paths.contains(path.as_slice()) {
                continue;
            }
            let path_text = String::from_utf8_lossy(&path);
            let file_path = workdir.join(path_text.as_ref());
            let meta = std::fs::symlink_metadata(&file_path).map_err(EngineError::from_gix)?;
            let (data, mode) = if meta.file_type().is_symlink() {
                let target = std::fs::read_link(&file_path).map_err(EngineError::from_gix)?;
                (
                    target.to_string_lossy().into_owned().into_bytes(),
                    gix::index::entry::Mode::SYMLINK,
                )
            } else if meta.is_file() {
                let mode = if meta.permissions().mode() & 0o111 != 0 {
                    gix::index::entry::Mode::FILE_EXECUTABLE
                } else {
                    gix::index::entry::Mode::FILE
                };
                (
                    std::fs::read(&file_path).map_err(EngineError::from_gix)?,
                    mode,
                )
            } else {
                continue;
            };
            let blob = repo
                .write_blob(&data)
                .map_err(EngineError::from_gix)?
                .detach();
            editor
                .upsert(path.as_bstr(), mode_to_kind(mode), blob)
                .map_err(EngineError::from_gix)?;
        }
    }
    Ok(editor.write().map_err(EngineError::from_gix)?.detach())
}

/// 找出 stash 中原本未被 HEAD 或 index 管理的路径。
/// 这些文件恢复后应该继续保持 untracked/ignored，而不是被 stash pop 意外暂存。
pub(crate) fn untracked_paths(
    repo: &gix::Repository,
    stash_id: gix::hash::ObjectId,
) -> Result<Vec<String>, EngineError> {
    use gix::bstr::ByteSlice;
    use gix::object::tree::diff::ChangeDetached;

    let stash = repo.find_commit(stash_id).map_err(EngineError::from_gix)?;
    let parents: Vec<_> = stash.parent_ids().collect();
    // System Git stores `stash push -u/-a` untracked files in a third parent,
    // while Arbor's native stash stores them directly in the worktree tree.
    // Keep the path discovery compatible with both layouts.
    if parents.len() >= 3 {
        let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
            message: "stash restore requires a non-bare worktree".into(),
        })?;
        let source = format!("{}^3", stash_id.to_hex());
        let output = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["ls-tree", "-r", "--name-only", "-z", &source])
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git ls-tree failed while reading stashed untracked files: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        let paths = output
            .stdout
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty())
            .map(|path| String::from_utf8_lossy(path).into_owned())
            .collect::<Vec<_>>();
        return Ok(paths);
    }
    let index_id = parents
        .get(1)
        .copied()
        .ok_or_else(|| EngineError::GitOperation {
            message: "stash commit has no index parent".into(),
        })?;
    let index_commit = repo.find_commit(index_id).map_err(EngineError::from_gix)?;
    let base_id = index_commit
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "stash index commit has no HEAD parent".into(),
        })?;
    let base_tree = repo
        .find_commit(base_id)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let index_tree = index_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let worktree_tree = stash.tree_id().map_err(EngineError::from_gix)?.detach();
    let base_tree = repo.find_tree(base_tree).map_err(EngineError::from_gix)?;
    let index_tree = repo.find_tree(index_tree).map_err(EngineError::from_gix)?;
    let worktree_tree = repo
        .find_tree(worktree_tree)
        .map_err(EngineError::from_gix)?;
    let changes = repo
        .diff_tree_to_tree(Some(&index_tree), Some(&worktree_tree), None)
        .map_err(EngineError::from_gix)?;

    let mut paths = Vec::new();
    for change in changes {
        if let ChangeDetached::Addition { location, .. } = change {
            let path = location.to_str_lossy();
            if base_tree
                .lookup_entry_by_path(path.as_ref())
                .map_err(EngineError::from_gix)?
                .is_none()
            {
                paths.push(path.into_owned());
            }
        }
    }
    paths.sort();
    paths.dedup();
    Ok(paths)
}

/// 删除 stash 栈中的一条记录，并把 refs/stash 移到新的栈顶（如果需要）。
///
/// `next_top` 等于当前栈顶时表示删除的是旧 stash，只需要重写 reflog；
/// `None` 表示栈已空。
pub(crate) fn remove_stash_entry(
    repo: &gix::Repository,
    removed_id: gix::hash::ObjectId,
    next_top: Option<gix::hash::ObjectId>,
) -> Result<(), EngineError> {
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    use gix::refs::Target;
    let name: gix::refs::FullName = "refs/stash".try_into().map_err(EngineError::from_gix)?;

    let current = repo
        .find_reference("refs/stash")
        .ok()
        .and_then(|r| r.try_id())
        .map(|id| id.detach());
    let needs_ref_update = current != next_top;
    if needs_ref_update {
        let edit = if let Some(next_top) = next_top {
            RefEdit {
                change: Change::Update {
                    log: LogChange {
                        mode: RefLog::AndReference,
                        force_create_reflog: true,
                        message: "drop stash".into(),
                    },
                    expected: PreviousValue::Any,
                    new: Target::Object(next_top),
                },
                name: name.clone(),
                deref: false,
            }
        } else {
            RefEdit {
                change: Change::Delete {
                    expected: PreviousValue::Any,
                    log: RefLog::AndReference,
                },
                name: name.clone(),
                deref: false,
            }
        };
        repo.edit_reference(edit).map_err(EngineError::from_gix)?;
    }

    cleanup_stash_reflog(repo, removed_id, next_top, needs_ref_update)
}

fn cleanup_stash_reflog(
    repo: &gix::Repository,
    removed_id: gix::hash::ObjectId,
    next_top: Option<gix::hash::ObjectId>,
    ref_was_updated: bool,
) -> Result<(), EngineError> {
    let log_path = repo.git_dir().join("logs").join("refs").join("stash");
    if next_top.is_none() {
        let _ = std::fs::remove_file(&log_path);
        return Ok(());
    }
    let Ok(text) = std::fs::read_to_string(&log_path) else {
        return Ok(());
    };
    let removed_hex = removed_id.to_hex().to_string();
    let next_hex = next_top.map(|id| id.to_hex().to_string());
    let mut lines = Vec::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let old = fields.next();
        let new = fields.next();
        let remove_original = new == Some(removed_hex.as_str());
        let remove_shift =
            ref_was_updated && old == Some(removed_hex.as_str()) && new == next_hex.as_deref();
        if !remove_original && !remove_shift {
            lines.push(line);
        }
    }
    let mut out = lines.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    std::fs::write(&log_path, out).map_err(EngineError::from_gix)
}

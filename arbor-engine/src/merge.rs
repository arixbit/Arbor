//! 三栏冲突合并：merge 结果、冲突块解析（marker -> 块）、逐块决策、树物化。
//!
//! 冲突数据流：merge_commits -> 冲突列表（含 stage 1/2/3 条目 + 合并 blob）
//! -> 索引写 stages（status 显示 Conflicted）+ 工作区写 marker 内容（materialize）
//! -> conflict_file 解析 marker 成块（含两侧行号，内容搜索定位）
//! -> resolve 按块决策替换 result 内容并写回索引/工作区。

use std::collections::HashSet;

use gix::bstr::{BStr, ByteSlice};

use crate::diff::blob_bytes;
use crate::error::EngineError;

/// merge/pull 结果：冲突文件路径列表与本次从上游带来的提交数。
#[derive(uniffi::Record, Clone, Debug)]
pub struct MergeOutcome {
    pub conflicts: Vec<String>,
    pub updated_commits: u32,
    pub upstream: String,
    pub branch: String,
    /// The operation has already moved HEAD or created its commit.
    pub completed: bool,
    /// The result is materialized and needs the explicit finish step.
    pub requires_finish: bool,
    /// The result is a squash merge: finishing it creates one parent commit.
    pub squashed: bool,
}

/// Merge strategy exposed by the merge dialog.
///
/// The default follows Git's normal fast-forward preference. `NoFastForward`
/// always keeps a merge commit when the histories can be merged, while
/// `Squash` materializes the combined tree and finishes as a single-parent
/// commit.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MergeMode {
    FastForward,
    FastForwardOnly,
    NoFastForward,
    Squash,
}

/// Options exposed by the IntelliJ-style merge dialog.
#[derive(uniffi::Record, Clone, Debug)]
pub struct MergeOptions {
    pub mode: MergeMode,
    pub commit_message: Option<String>,
    pub no_commit: bool,
    pub no_verify: bool,
    pub allow_unrelated_histories: bool,
}

/// Options for the IntelliJ-style Pull dialog. Pull reuses the merge state
/// machine for merge-mode pulls, while `rebase` selects the native rebase
/// path. The UI enforces the same mutually-exclusive option combinations as
/// GitPullOption; the engine still validates the combination defensively.
#[derive(uniffi::Record, Clone, Debug)]
pub struct PullOptions {
    pub rebase: bool,
    pub mode: MergeMode,
    pub no_commit: bool,
    pub no_verify: bool,
}

/// 一个需要写入索引 stages 1/2/3 的冲突路径。
///
/// 由 merge_trees/merge_commits 的 gix 冲突对象转换而来，避免把带仓库
/// 生命周期的 gix tree outcome 跨模块传递。
#[derive(Clone, Debug)]
pub(crate) struct ConflictEntry {
    pub path: String,
    pub entries: [Option<(gix::hash::ObjectId, gix::object::tree::EntryMode)>; 3],
}

/// 一个冲突块：两侧行号（1-based，内容搜索定位，找不到为 0）+ 两侧行内容 + result 行范围。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ConflictBlock {
    pub ours_start: u32,
    pub ours_count: u32,
    pub theirs_start: u32,
    pub theirs_count: u32,
    pub ours_lines: Vec<String>,
    pub theirs_lines: Vec<String>,
    /// result 中 marker 块的行范围（1-based 含 marker 行）
    pub result_start: u32,
    pub result_end: u32,
}

/// 一个冲突文件的三方内容 + 冲突块。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ConflictFile {
    pub path: String,
    pub base: String,
    pub ours: String,
    pub theirs: String,
    /// 当前工作区内容（未解决时含 marker）
    pub result: String,
    pub blocks: Vec<ConflictBlock>,
}

/// 冲突块的接受方向。
#[derive(uniffi::Enum, Clone, Copy, Debug)]
pub enum PickKind {
    Ours,
    Theirs,
}

/// 一个块决策：块下标 + 接受方向。
#[derive(uniffi::Record, Clone, Debug)]
pub struct BlockDecision {
    pub block_index: u32,
    pub pick: PickKind,
}

/// 把合并树的变化物化到工作区（写 blob 建父目录 / 删文件）。
/// old_tree = 当前工作区对应树，new_tree = 目标树。
pub(crate) fn materialize_tree(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
) -> Result<(), EngineError> {
    materialize_tree_inner(repo, old_tree_id, new_tree_id, workdir, None, &[])
}

/// Materialize a tree change while leaving nested gitlink worktrees in place.
/// The caller is responsible for rolling those nested repositories back as
/// separate roots; removing their directory here would destroy that boundary.
pub(crate) fn materialize_tree_ignoring_paths(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
    ignored_paths: &[String],
) -> Result<(), EngineError> {
    materialize_tree_inner(repo, old_tree_id, new_tree_id, workdir, None, ignored_paths)
}

/// Materialize only the selected file-level changes from one tree to another.
/// A rename matches either endpoint so selecting the visible destination still
/// moves the complete change rather than leaving half of it behind.
pub(crate) fn materialize_tree_paths(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
    paths: &[String],
) -> Result<(), EngineError> {
    materialize_tree_inner(repo, old_tree_id, new_tree_id, workdir, Some(paths), &[])
}

fn materialize_tree_inner(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
    selected_paths: Option<&[String]>,
    ignored_paths: &[String],
) -> Result<(), EngineError> {
    use gix::object::tree::diff::ChangeDetached;
    let old_tree = repo.find_tree(old_tree_id).map_err(EngineError::from_gix)?;
    let new_tree = repo.find_tree(new_tree_id).map_err(EngineError::from_gix)?;
    let changes = repo
        .diff_tree_to_tree(Some(&old_tree), Some(&new_tree), None)
        .map_err(EngineError::from_gix)?;
    let selected_change_count = changes
        .iter()
        .filter(|change| change_matches_paths(change, selected_paths))
        .count()
        .max(1);
    let gitlink_changes = changed_gitlink_paths(
        repo,
        old_tree_id,
        new_tree_id,
        &changes,
        selected_paths,
        ignored_paths,
    )?;
    preflight_gitlink_worktrees(workdir, &gitlink_changes)?;
    preflight_checkout_conversions(
        repo,
        new_tree_id,
        workdir,
        &changes,
        selected_paths,
        ignored_paths,
    )?;
    // First remove every old node. Tree diffs may emit a directory deletion
    // after the replacement file addition, so writing while iterating would
    // make the result depend on gix's change ordering.
    let mut materialized_changes = 0usize;
    for change in &changes {
        if !change_matches_paths(change, selected_paths)
            || change_matches_ignored_paths(change, ignored_paths)
        {
            continue;
        }
        match change {
            ChangeDetached::Addition { .. } => {}
            ChangeDetached::Modification { location, .. }
            | ChangeDetached::Deletion { location, .. } => {
                if gitlink_changes
                    .iter()
                    .any(|change| change.path == location.to_str_lossy())
                {
                    continue;
                }
                remove_worktree_path(&workdir.join(location_to_path(location.as_bstr())))?;
            }
            ChangeDetached::Rewrite {
                source_location,
                location,
                ..
            } => {
                remove_worktree_path(&workdir.join(location_to_path(source_location.as_bstr())))?;
                remove_worktree_path(&workdir.join(location_to_path(location.as_bstr())))?;
            }
        }
    }

    // Then write every new node. Attribute files must be installed before
    // their sibling files so checkout conversion observes the target tree's
    // rules when a branch changes `.gitattributes` and a tracked file in the
    // same operation.
    let mut write_order: Vec<usize> = (0..changes.len()).collect();
    write_order.sort_by_key(|index| {
        let path = change_target_path(&changes[*index]);
        let is_attributes = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == ".gitattributes");
        (if is_attributes { 0 } else { 1 }, path.components().count())
    });
    for index in write_order {
        let change = &changes[index];
        if !change_matches_paths(change, selected_paths)
            || change_matches_ignored_paths(change, ignored_paths)
        {
            continue;
        }
        match change {
            ChangeDetached::Addition {
                location,
                entry_mode,
                id,
                ..
            }
            | ChangeDetached::Modification {
                location,
                entry_mode,
                id,
                ..
            }
            | ChangeDetached::Rewrite {
                location,
                entry_mode,
                id,
                ..
            } => {
                if gitlink_changes
                    .iter()
                    .any(|change| change.path == location.to_str_lossy())
                {
                    continue;
                }
                let location: &BStr = location.as_bstr();
                let path = workdir.join(location_to_path(location));
                if entry_mode.is_tree() {
                    remove_worktree_path(&path)?;
                    materialize_tree_at(repo, *id, workdir, &location_to_path(location))?;
                } else if entry_mode.is_blob_or_symlink() {
                    remove_worktree_path_if_directory(&path)?;
                    let data = blob_bytes(repo, *id, "materialize tree")?;
                    write_worktree_entry(workdir, location, &data, index_mode(*entry_mode))?;
                } else if entry_mode.is_commit() {
                    remove_worktree_path(&path)?;
                } else {
                    return Err(EngineError::GitOperation {
                        message: format!(
                            "materialize tree: unsupported entry mode at {}",
                            location.to_str_lossy()
                        ),
                    });
                }
            }
            ChangeDetached::Deletion { .. } => {}
        }
        materialized_changes += 1;
        let detail = match change {
            ChangeDetached::Addition { location, .. }
            | ChangeDetached::Modification { location, .. }
            | ChangeDetached::Deletion { location, .. } => location.to_str_lossy().into_owned(),
            ChangeDetached::Rewrite {
                source_location,
                location,
                ..
            } => format!(
                "{} → {}",
                source_location.to_str_lossy(),
                location.to_str_lossy()
            ),
        };
        crate::gitprocess::update_active_operation_progress(
            "shelve",
            "Applying Shelf files".to_string(),
            Some(
                25 + (materialized_changes.saturating_mul(75) / selected_change_count).min(75)
                    as u32,
            ),
            detail,
        );
    }
    materialize_gitlink_changes(repo, new_tree_id, workdir, &gitlink_changes)?;
    Ok(())
}

#[derive(Clone, Debug)]
pub(crate) struct GitlinkChange {
    path: String,
    source_is_gitlink: bool,
    target_is_gitlink: bool,
    target_id: Option<gix::hash::ObjectId>,
}

fn changed_gitlink_paths(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
    changes: &[gix::object::tree::diff::ChangeDetached],
    selected_paths: Option<&[String]>,
    ignored_paths: &[String],
) -> Result<Vec<GitlinkChange>, EngineError> {
    let old_tree = repo.find_tree(old_tree_id).map_err(EngineError::from_gix)?;
    let new_tree = repo.find_tree(new_tree_id).map_err(EngineError::from_gix)?;
    let mut paths = HashSet::new();
    for change in changes {
        if !change_matches_paths(change, selected_paths)
            || change_matches_ignored_paths(change, ignored_paths)
        {
            continue;
        }
        match change {
            gix::object::tree::diff::ChangeDetached::Addition { location, .. }
            | gix::object::tree::diff::ChangeDetached::Modification { location, .. }
            | gix::object::tree::diff::ChangeDetached::Deletion { location, .. } => {
                paths.insert(location.to_str_lossy().into_owned());
            }
            gix::object::tree::diff::ChangeDetached::Rewrite {
                source_location,
                location,
                ..
            } => {
                paths.insert(source_location.to_str_lossy().into_owned());
                paths.insert(location.to_str_lossy().into_owned());
            }
        }
    }

    let mut result = paths
        .into_iter()
        .map(|path| {
            let source_entry = old_tree
                .lookup_entry(path.split('/'))
                .map_err(EngineError::from_gix)?;
            let target_entry = new_tree
                .lookup_entry(path.split('/'))
                .map_err(EngineError::from_gix)?;
            let source_is_gitlink = source_entry
                .as_ref()
                .is_some_and(|entry| entry.mode().is_commit());
            let target_is_gitlink = target_entry
                .as_ref()
                .is_some_and(|entry| entry.mode().is_commit());
            let target_id = target_entry
                .as_ref()
                .filter(|entry| entry.mode().is_commit())
                .map(|entry| entry.object_id());
            Ok(GitlinkChange {
                path,
                source_is_gitlink,
                target_is_gitlink,
                target_id,
            })
        })
        .collect::<Result<Vec<_>, EngineError>>()?;
    result.retain(|change| change.source_is_gitlink || change.target_is_gitlink);
    result.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(result)
}

pub(crate) fn gitlink_changes_for_tree_rewrite(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
) -> Result<Vec<GitlinkChange>, EngineError> {
    let old_tree = repo.find_tree(old_tree_id).map_err(EngineError::from_gix)?;
    let new_tree = repo.find_tree(new_tree_id).map_err(EngineError::from_gix)?;
    let changes = repo
        .diff_tree_to_tree(Some(&old_tree), Some(&new_tree), None)
        .map_err(EngineError::from_gix)?;
    changed_gitlink_paths(repo, old_tree_id, new_tree_id, &changes, None, &[])
}

pub(crate) fn preflight_gitlink_worktrees(
    workdir: &std::path::Path,
    changes: &[GitlinkChange],
) -> Result<(), EngineError> {
    for change in changes {
        let path = workdir.join(&change.path);
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "submodule path {} is not initialized; refusing gitlink materialization",
                        change.path
                    ),
                });
            }
            Err(error) => return Err(EngineError::from_gix(error)),
        };
        if !metadata.is_dir() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "submodule path {} is not an initialized worktree; refusing gitlink materialization",
                    change.path
                ),
            });
        }
        if !path.join(".git").exists() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "submodule path {} is not initialized; refusing gitlink materialization",
                    change.path
                ),
            });
        }

        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Submodule,
            "status",
        )
        .args(["--porcelain", "--untracked-files=all"])
        .working_dir(&path);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "submodule path {} is not initialized; refusing history rewrite: {}",
                    change.path,
                    outcome.into_error(&spec)
                ),
            });
        }
        if !outcome.stdout.trim().is_empty() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "submodule path {} has local changes; commit or save them before gitlink materialization",
                    change.path
                ),
            });
        }
        if change.target_is_gitlink {
            let target_id = change.target_id.ok_or_else(|| EngineError::GitOperation {
                message: format!("submodule path {} has no target gitlink id", change.path),
            })?;
            let target = format!("{}^{{commit}}", target_id.to_hex());
            let spec = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Submodule,
                "cat-file",
            )
            .args(["-e", target.as_str()])
            .working_dir(&path);
            let outcome = crate::gitprocess::run_to_completion(&spec)?;
            if !outcome.success() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "submodule path {} does not contain target commit {}; fetch it before gitlink materialization",
                        change.path, target_id
                    ),
                });
            }
        }
    }
    Ok(())
}

fn materialize_gitlink_changes(
    _repo: &gix::Repository,
    new_tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
    changes: &[GitlinkChange],
) -> Result<(), EngineError> {
    for change in changes {
        if change.target_is_gitlink {
            let tree = new_tree_id.to_hex().to_string();
            let spec = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Submodule,
                "checkout",
            )
            .args([
                "--force",
                "--recurse-submodules",
                tree.as_str(),
                "--",
                change.path.as_str(),
            ])
            .working_dir(workdir);
            let outcome = crate::gitprocess::run_to_completion(&spec)?;
            if !outcome.success() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "could not materialize submodule path {}: {}",
                        change.path,
                        outcome.into_error(&spec)
                    ),
                });
            }
        } else if change.source_is_gitlink {
            let spec = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Submodule,
                "rm",
            )
            .args(["--force", "--", change.path.as_str()])
            .working_dir(workdir);
            let outcome = crate::gitprocess::run_to_completion(&spec)?;
            if !outcome.success() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "could not remove submodule path {}: {}",
                        change.path,
                        outcome.into_error(&spec)
                    ),
                });
            }
        }
    }
    Ok(())
}

fn change_target_path(change: &gix::object::tree::diff::ChangeDetached) -> std::path::PathBuf {
    match change {
        gix::object::tree::diff::ChangeDetached::Addition { location, .. }
        | gix::object::tree::diff::ChangeDetached::Modification { location, .. }
        | gix::object::tree::diff::ChangeDetached::Deletion { location, .. }
        | gix::object::tree::diff::ChangeDetached::Rewrite { location, .. } => {
            location_to_path(location.as_bstr())
        }
    }
}

fn preflight_checkout_conversions(
    repo: &gix::Repository,
    target_tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
    changes: &[gix::object::tree::diff::ChangeDetached],
    selected_paths: Option<&[String]>,
    ignored_paths: &[String],
) -> Result<(), EngineError> {
    let mut paths = Vec::new();
    for change in changes {
        if !change_matches_paths(change, selected_paths)
            || change_matches_ignored_paths(change, ignored_paths)
        {
            continue;
        }
        let (location, entry_mode, id) = match change {
            gix::object::tree::diff::ChangeDetached::Addition {
                location,
                entry_mode,
                id,
                ..
            }
            | gix::object::tree::diff::ChangeDetached::Modification {
                location,
                entry_mode,
                id,
                ..
            }
            | gix::object::tree::diff::ChangeDetached::Rewrite {
                location,
                entry_mode,
                id,
                ..
            } => (location, *entry_mode, *id),
            gix::object::tree::diff::ChangeDetached::Deletion { .. } => continue,
        };
        let relative = location_to_path(location.as_bstr());
        if entry_mode.is_tree() {
            collect_tree_checkout_paths(repo, id, &relative, &mut paths)?;
        } else if entry_mode.is_blob_or_symlink()
            && !index_mode(entry_mode).contains(gix::index::entry::Mode::SYMLINK)
        {
            paths.push(relative.to_string_lossy().into_owned());
        }
    }
    paths.sort();
    paths.dedup();
    if paths.is_empty() {
        return Ok(());
    }

    use std::time::{SystemTime, UNIX_EPOCH};
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| EngineError::GitOperation {
            message: format!("checkout preflight clock failed: {error}"),
        })?
        .as_nanos();
    let index_path = repo.git_dir().join(format!(
        "arbor-checkout-index-{}-{nonce}",
        std::process::id()
    ));
    let result = (|| {
        let spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Config,
            "read-tree",
        )
        .arg(target_tree_id.to_hex().to_string())
        .env("GIT_INDEX_FILE", index_path.to_string_lossy())
        .working_dir(workdir);
        let outcome = crate::gitprocess::run_to_completion(&spec)?;
        if !outcome.success() {
            return Err(outcome.into_error(&spec));
        }
        let attrs =
            crate::attributes::check_attributes_with_index(workdir, &paths, Some(&index_path))?;
        crate::attributes::validate_checkout_attributes(workdir, &attrs)
    })();
    let _ = std::fs::remove_file(&index_path);
    result
}

fn collect_tree_checkout_paths(
    repo: &gix::Repository,
    tree_id: gix::hash::ObjectId,
    relative: &std::path::Path,
    paths: &mut Vec<String>,
) -> Result<(), EngineError> {
    let tree = repo.find_tree(tree_id).map_err(EngineError::from_gix)?;
    for entry in tree.iter() {
        let entry = entry.map_err(EngineError::from_gix)?;
        let child = relative.join(location_to_path(entry.inner.filename));
        if entry.inner.mode.is_tree() {
            collect_tree_checkout_paths(repo, entry.inner.oid.to_owned(), &child, paths)?;
        } else if entry.inner.mode.is_blob_or_symlink()
            && !index_mode(entry.inner.mode).contains(gix::index::entry::Mode::SYMLINK)
        {
            paths.push(child.to_string_lossy().into_owned());
        }
    }
    Ok(())
}

fn change_matches_paths(
    change: &gix::object::tree::diff::ChangeDetached,
    selected_paths: Option<&[String]>,
) -> bool {
    let Some(selected_paths) = selected_paths else {
        return true;
    };
    let matches = |location: &BStr| {
        let location = location.to_str_lossy();
        selected_paths
            .iter()
            .any(|path| path.as_str() == location.as_ref())
    };
    match change {
        gix::object::tree::diff::ChangeDetached::Addition { location, .. }
        | gix::object::tree::diff::ChangeDetached::Modification { location, .. }
        | gix::object::tree::diff::ChangeDetached::Deletion { location, .. } => {
            matches(location.as_bstr())
        }
        gix::object::tree::diff::ChangeDetached::Rewrite {
            source_location,
            location,
            ..
        } => matches(source_location.as_bstr()) || matches(location.as_bstr()),
    }
}

fn change_matches_ignored_paths(
    change: &gix::object::tree::diff::ChangeDetached,
    ignored_paths: &[String],
) -> bool {
    let overlaps = |location: &BStr| {
        let location = location.to_str_lossy();
        ignored_paths
            .iter()
            .any(|ignored| paths_overlap(location.as_ref(), ignored))
    };
    match change {
        gix::object::tree::diff::ChangeDetached::Addition { location, .. }
        | gix::object::tree::diff::ChangeDetached::Modification { location, .. }
        | gix::object::tree::diff::ChangeDetached::Deletion { location, .. } => {
            overlaps(location.as_bstr())
        }
        gix::object::tree::diff::ChangeDetached::Rewrite {
            source_location,
            location,
            ..
        } => overlaps(source_location.as_bstr()) || overlaps(location.as_bstr()),
    }
}

fn paths_overlap(left: &str, right: &str) -> bool {
    left == right
        || left
            .strip_prefix(right)
            .map(|suffix| suffix.starts_with('/'))
            .unwrap_or(false)
        || right
            .strip_prefix(left)
            .map(|suffix| suffix.starts_with('/'))
            .unwrap_or(false)
}

/// Materialize every leaf below a tree entry. Git does not store empty
/// directories, so creating the directory here also covers that edge case.
fn materialize_tree_at(
    repo: &gix::Repository,
    tree_id: gix::hash::ObjectId,
    workdir: &std::path::Path,
    relative: &std::path::Path,
) -> Result<(), EngineError> {
    let tree = repo.find_tree(tree_id).map_err(EngineError::from_gix)?;
    let directory = workdir.join(relative);
    std::fs::create_dir_all(&directory).map_err(EngineError::from_gix)?;
    // The first pass makes a directory's `.gitattributes` effective before
    // any sibling file is written. The second pass handles all other entries.
    for attributes_first in [true, false] {
        for entry in tree.iter() {
            let entry = entry.map_err(EngineError::from_gix)?;
            let is_attributes = entry.inner.filename.to_str_lossy() == ".gitattributes";
            if is_attributes != attributes_first {
                continue;
            }
            let child = relative.join(location_to_path(entry.inner.filename));
            if entry.inner.mode.is_tree() {
                materialize_tree_at(repo, entry.inner.oid.to_owned(), workdir, &child)?;
            } else if entry.inner.mode.is_blob_or_symlink() {
                let data = blob_bytes(repo, entry.inner.oid.to_owned(), "materialize tree")?;
                write_worktree_entry(
                    workdir,
                    child.as_os_str().as_encoded_bytes().as_bstr(),
                    &data,
                    index_mode(entry.inner.mode),
                )?;
            } else if entry.inner.mode.is_commit() {
                remove_worktree_path(&workdir.join(&child))?;
            } else {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "materialize tree: unsupported entry mode at {}",
                        child.display()
                    ),
                });
            }
        }
    }
    Ok(())
}

fn remove_worktree_path_if_directory(path: &std::path::Path) -> Result<(), EngineError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            std::fs::remove_dir_all(path).map_err(EngineError::from_gix)
        }
        Ok(metadata) if metadata.file_type().is_symlink() => {
            std::fs::remove_file(path).map_err(EngineError::from_gix)
        }
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(EngineError::from_gix(e)),
    }
}

fn remove_worktree_path(path: &std::path::Path) -> Result<(), EngineError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            std::fs::remove_dir_all(path).map_err(EngineError::from_gix)
        }
        Ok(_) => std::fs::remove_file(path).map_err(EngineError::from_gix),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(EngineError::from_gix(e)),
    }
}

/// 写工作区树条目（建父目录，并保留 Git 的 symlink / executable mode）。
pub(crate) fn write_worktree_entry(
    workdir: &std::path::Path,
    location: &BStr,
    data: &[u8],
    mode: gix::index::entry::Mode,
) -> Result<(), EngineError> {
    use gix::index::entry::Mode;

    let path = workdir.join(location_to_path(location));
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if mode.contains(Mode::SYMLINK) {
        remove_worktree_path(&path)?;
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            std::os::unix::fs::symlink(std::ffi::OsStr::from_bytes(data), &path)
                .map_err(EngineError::from_gix)?;
        }
        #[cfg(not(unix))]
        {
            return Err(EngineError::GitOperation {
                message: format!(
                    "materialize tree: symlinks are unsupported on this platform at {}",
                    location.to_str_lossy()
                ),
            });
        }
    } else {
        remove_worktree_path_if_directory(&path)?;
        let relative = location_to_path(location);
        let relative = relative.to_string_lossy();
        let checkout_data = crate::attributes::checkout_worktree_bytes(workdir, &relative, data)?;
        std::fs::write(&path, checkout_data).map_err(EngineError::from_gix)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let permissions =
                std::fs::Permissions::from_mode(if mode.contains(Mode::FILE_EXECUTABLE) {
                    0o755
                } else {
                    0o644
                });
            std::fs::set_permissions(&path, permissions).map_err(EngineError::from_gix)?;
        }
    }
    Ok(())
}

/// 将一个已经写入 ODB 的合并树物化为：索引（含冲突 stages）+ 工作区（含 marker）。
///
/// merge() 和 rebase 冲突暂停都走这里，保证两条路径的索引/工作区语义一致。
pub(crate) fn materialize_merge_outcome(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    merged_tree_id: gix::hash::ObjectId,
    conflicts: &[ConflictEntry],
) -> Result<Vec<String>, EngineError> {
    use gix::index::entry::{Flags, Stage, Stat};

    let mut index = repo
        .index_from_tree(&merged_tree_id)
        .map_err(EngineError::from_gix)?;
    for conflict in conflicts {
        let path = conflict.path.as_bytes().as_bstr();
        if let Some(i) = index.entry_index_by_path_and_stage(path, Stage::Unconflicted) {
            index.remove_entry_at_index(i);
        }
        for (stage, entry) in [
            (Stage::Base, &conflict.entries[0]),
            (Stage::Ours, &conflict.entries[1]),
            (Stage::Theirs, &conflict.entries[2]),
        ] {
            if let Some((id, mode)) = entry {
                index.dangerously_push_entry(
                    Stat::default(),
                    *id,
                    Flags::from_bits_truncate((stage as u32) << 12),
                    index_mode(*mode),
                    path,
                );
            }
        }
        index.sort_entries();
    }
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;

    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    materialize_tree(repo, old_tree_id, merged_tree_id, workdir)?;
    Ok(conflicts
        .iter()
        .map(|conflict| conflict.path.clone())
        .collect())
}

/// BStr 路径 -> Path（v1 假设 UTF-8，非 UTF-8 lossy）。
fn location_to_path(location: &BStr) -> std::path::PathBuf {
    std::path::PathBuf::from(String::from_utf8_lossy(location).into_owned())
}

/// 从工作区内容解析冲突 marker 成块；ours/theirs 用于定位块在两侧文件中的起始行。
pub(crate) fn parse_marker_blocks(result: &str, ours: &str, theirs: &str) -> Vec<ConflictBlock> {
    let lines: Vec<&str> = result.lines().collect();
    let mut blocks = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        if lines[i].starts_with("<<<<<<<") {
            let start = i;
            i += 1;
            let mut ours_lines = Vec::new();
            while i < lines.len() && lines[i].trim_end() != "=======" {
                ours_lines.push(lines[i].to_string());
                i += 1;
            }
            if i >= lines.len() {
                break; // 格式异常，停止解析
            }
            i += 1; // 跳过 =======
            let mut theirs_lines = Vec::new();
            while i < lines.len() && !lines[i].starts_with(">>>>>>>") {
                theirs_lines.push(lines[i].to_string());
                i += 1;
            }
            if i >= lines.len() {
                break;
            }
            let end = i; // >>>>>>> 行
            i += 1;
            let ours_start = locate_lines_in(ours, &ours_lines);
            let theirs_start = locate_lines_in(theirs, &theirs_lines);
            blocks.push(ConflictBlock {
                ours_start,
                ours_count: ours_lines.len() as u32,
                theirs_start,
                theirs_count: theirs_lines.len() as u32,
                ours_lines,
                theirs_lines,
                result_start: (start + 1) as u32,
                result_end: (end + 1) as u32,
            });
        } else {
            i += 1;
        }
    }
    blocks
}

/// 在完整内容中定位行序列，返回 1-based 起始行（找不到为 0）。
pub(crate) fn locate_lines_in(content: &str, lines: &[String]) -> u32 {
    let haystack: Vec<&str> = content.lines().collect();
    if lines.is_empty() || lines.len() > haystack.len() {
        return 0;
    }
    'outer: for s in 0..=(haystack.len() - lines.len()) {
        for (k, l) in lines.iter().enumerate() {
            if haystack[s + k] != l {
                continue 'outer;
            }
        }
        return (s + 1) as u32;
    }
    0
}

/// 移除索引中某路径的全部冲突阶段（1/2/3）。
pub(crate) fn remove_conflict_stages(index: &mut gix::index::File, path: &BStr) {
    use gix::index::entry::Stage;
    for stage in [Stage::Base, Stage::Ours, Stage::Theirs] {
        while let Some(i) = index.entry_index_by_path_and_stage(path, stage) {
            index.remove_entry_at_index(i);
        }
    }
}

/// 把解决后的内容落盘：写工作区文件 + 清索引冲突阶段（1/2/3）+ upsert stage 0
/// （写 blob + stat + mode）。`resolve`（按块选边）与 `resolve_edited`（自由编辑）共用。
pub(crate) fn write_resolved(
    repo: &gix::Repository,
    path: &str,
    content: &str,
) -> Result<(), EngineError> {
    write_resolved_bytes(repo, path, content.as_bytes())
}

/// bytes 版本（CONFLICT-001 accept 的二进制安全路径）。
pub(crate) fn write_resolved_bytes(
    repo: &gix::Repository,
    path: &str,
    content: &[u8],
) -> Result<(), EngineError> {
    use gix::index::entry::Mode;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    let file_path = workdir.join(path);
    if let Some(parent) = file_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let checkout_content = crate::attributes::checkout_worktree_bytes(workdir, path, content)?;
    std::fs::write(&file_path, checkout_content).map_err(EngineError::from_gix)?;

    let path_bstr = path.as_bytes().as_bstr();
    let mut index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    remove_conflict_stages(&mut index, path_bstr);
    let meta =
        gix::index::fs::Metadata::from_path_no_follow(&file_path).map_err(EngineError::from_gix)?;
    let stat = gix::index::entry::Stat::from_fs(&meta).map_err(EngineError::from_gix)?;
    let mode = if meta.is_executable() {
        Mode::FILE_EXECUTABLE
    } else {
        Mode::FILE
    };
    let clean_content = crate::attributes::clean_worktree_bytes(workdir, path, content)?;
    upsert_index_entry(repo, &mut index, path_bstr, &clean_content, mode, stat)?;
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;
    Ok(())
}

/// 写 blob + upsert 索引 stage 0 条目（存在则更新 id/stat/mode，不存在则 push+sort）。
/// stage / unstage / resolve / resolve_edited / stage_lines / unstage_lines 共用。
/// 调用方负责 `index.remove_tree()` + `index.write(...)`。
pub(crate) fn upsert_index_entry(
    repo: &gix::Repository,
    index: &mut gix::index::File,
    path: &BStr,
    content: &[u8],
    mode: gix::index::entry::Mode,
    stat: gix::index::entry::Stat,
) -> Result<gix::hash::ObjectId, EngineError> {
    use gix::index::entry::{Flags, Stage};
    let blob_id = repo
        .write_blob(content)
        .map_err(EngineError::from_gix)?
        .detach();
    match index.entry_index_by_path_and_stage(path, Stage::Unconflicted) {
        Some(i) => {
            let e = &mut index.entries_mut()[i];
            e.id = blob_id;
            e.stat = stat;
            e.mode = mode;
        }
        None => {
            index.dangerously_push_entry(stat, blob_id, Flags::empty(), mode, path);
            index.sort_entries();
        }
    }
    Ok(blob_id)
}

/// tree EntryMode -> 索引 entry::Mode。
pub(crate) fn index_mode(mode: gix::object::tree::EntryMode) -> gix::index::entry::Mode {
    gix::index::entry::Mode::from_bits_truncate(mode.value() as u32)
}

/// 执行三方合并；`ancestor_tree` 仅用于 `--allow-unrelated-histories`，
/// 此时以空树作为共同祖先模拟 Git 的 unrelated histories 合并。
pub(crate) fn apply_merge_with_ancestor(
    repo: &gix::Repository,
    theirs_id: gix::hash::ObjectId,
    theirs_label: &str,
    ancestor_tree: Option<gix::hash::ObjectId>,
) -> Result<MergeOutcome, EngineError> {
    apply_merge_with_ancestor_ignoring_paths(repo, theirs_id, theirs_label, ancestor_tree, &[])
}

pub(crate) fn apply_merge_with_ancestor_ignoring_paths(
    repo: &gix::Repository,
    theirs_id: gix::hash::ObjectId,
    theirs_label: &str,
    ancestor_tree: Option<gix::hash::ObjectId>,
    ignored_paths: &[String],
) -> Result<MergeOutcome, EngineError> {
    use gix::merge::blob::Resolution;
    let head_commit = repo.head_commit().map_err(EngineError::from_gix)?;
    let ours_id = head_commit.id().detach();
    let ours_tree = head_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    // 未提交变更保护：合并会覆盖未提交变更时拒绝（D47 限制消除）
    let theirs_commit = repo.find_commit(theirs_id).map_err(EngineError::from_gix)?;
    let theirs_tree = theirs_commit
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    guard_uncommitted_overwrite_ignoring_paths(repo, ours_tree, theirs_tree, ignored_paths)?;
    let mut tree_outcome = if let Some(ancestor_tree) = ancestor_tree {
        let labels = gix::merge::blob::builtin_driver::text::Labels {
            ancestor: None,
            current: Some(BStr::new("HEAD")),
            other: Some(BStr::new(theirs_label)),
        };
        let options = repo.tree_merge_options().map_err(EngineError::from_gix)?;
        repo.merge_trees(ancestor_tree, ours_tree, theirs_tree, labels, options)
            .map_err(EngineError::from_gix)?
    } else {
        let labels = gix::merge::blob::builtin_driver::text::Labels {
            ancestor: None,
            current: Some(BStr::new("HEAD")),
            other: Some(BStr::new(theirs_label)),
        };
        let options: gix::merge::commit::Options = repo
            .tree_merge_options()
            .map_err(EngineError::from_gix)?
            .into();
        let outcome = repo
            .merge_commits(ours_id, theirs_id, labels, options)
            .map_err(EngineError::from_gix)?;
        outcome.tree_merge
    };
    let merged_tree = tree_outcome
        .tree
        .write()
        .map_err(EngineError::from_gix)?
        .detach();

    // 冲突路径 = 含 marker 的内容冲突
    let is_content_conflict = |c: &gix::merge::tree::Conflict| -> bool {
        c.content_merge()
            .map(|cm| cm.resolution == Resolution::Conflict)
            .unwrap_or(false)
    };
    let conflict_entries: Vec<ConflictEntry> = tree_outcome
        .conflicts
        .iter()
        .filter(|conflict| is_content_conflict(conflict))
        .map(|conflict| {
            let entries = conflict.entries();
            ConflictEntry {
                path: conflict.ours.location().to_str_lossy().into_owned(),
                entries: entries.map(|entry| entry.map(|e| (e.id, e.mode))),
            }
        })
        .collect();
    let conflicts = materialize_merge_outcome(repo, ours_tree, merged_tree, &conflict_entries)?;

    Ok(MergeOutcome {
        conflicts,
        updated_commits: 0,
        upstream: String::new(),
        branch: String::new(),
        completed: false,
        requires_finish: true,
        squashed: false,
    })
}

/// 未提交变更保护：old_tree -> new_tree 会被改写/删除的路径中，
/// 若有任何未提交变更（暂存或未暂存），拒绝操作（保守策略，比 git 更严）。
pub(crate) fn guard_uncommitted_overwrite(
    repo: &gix::Repository,
    old_tree: gix::hash::ObjectId,
    new_tree: gix::hash::ObjectId,
) -> Result<(), EngineError> {
    guard_uncommitted_overwrite_ignoring_paths(repo, old_tree, new_tree, &[])
}

pub(crate) fn guard_uncommitted_overwrite_ignoring_paths(
    repo: &gix::Repository,
    old_tree: gix::hash::ObjectId,
    new_tree: gix::hash::ObjectId,
    ignored_paths: &[String],
) -> Result<(), EngineError> {
    use gix::object::tree::diff::ChangeDetached;
    use std::collections::HashSet;
    // 受影响路径（会被新树写入或删除）
    let old = repo.find_tree(old_tree).map_err(EngineError::from_gix)?;
    let new = repo.find_tree(new_tree).map_err(EngineError::from_gix)?;
    let changes = repo
        .diff_tree_to_tree(Some(&old), Some(&new), None)
        .map_err(EngineError::from_gix)?;
    let affected: HashSet<String> = changes
        .iter()
        .map(|c| match c {
            ChangeDetached::Addition { location, .. }
            | ChangeDetached::Modification { location, .. }
            | ChangeDetached::Rewrite { location, .. }
            | ChangeDetached::Deletion { location, .. } => location.to_string(),
        })
        .collect();
    if affected.is_empty() {
        return Ok(());
    }
    let path_overlaps = |left: &str, right: &str| {
        left == right
            || left
                .strip_prefix(right)
                .map(|suffix| suffix.starts_with('/'))
                .unwrap_or(false)
            || right
                .strip_prefix(left)
                .map(|suffix| suffix.starts_with('/'))
                .unwrap_or(false)
    };
    // 未提交路径
    let changed = crate::status::compute_status(repo)?
        .into_iter()
        .filter(|entry| {
            !ignored_paths
                .iter()
                .any(|ignored| path_overlaps(&entry.path, ignored))
        })
        .filter(|e| {
            e.staged != crate::status::ChangeKind::Unchanged
                || (e.unstaged != crate::status::ChangeKind::Unchanged
                    && e.unstaged != crate::status::ChangeKind::Ignored)
        })
        .collect::<Vec<_>>();
    let mut blocked_untracked: Vec<String> = changed
        .iter()
        .filter(|entry| {
            entry.staged == crate::status::ChangeKind::Unchanged
                && entry.unstaged == crate::status::ChangeKind::Untracked
                && affected
                    .iter()
                    .any(|affected_path| path_overlaps(affected_path, &entry.path))
        })
        .map(|entry| entry.path.clone())
        .collect();
    blocked_untracked.sort();
    blocked_untracked.dedup();
    if !blocked_untracked.is_empty() {
        blocked_untracked.truncate(5);
        return Err(EngineError::UntrackedWouldBeOverwritten {
            paths: blocked_untracked,
        });
    }

    let mut blocked: Vec<String> = changed
        .iter()
        .filter(|entry| {
            entry.staged != crate::status::ChangeKind::Unchanged
                || (entry.unstaged != crate::status::ChangeKind::Unchanged
                    && entry.unstaged != crate::status::ChangeKind::Ignored)
        })
        .filter(|entry| {
            affected
                .iter()
                .any(|affected_path| path_overlaps(affected_path, &entry.path))
        })
        .map(|entry| entry.path.clone())
        .collect();
    blocked.sort();
    blocked.dedup();
    blocked.truncate(5);
    if !blocked.is_empty() {
        return Err(EngineError::LocalChangesWouldBeOverwritten { paths: blocked });
    }
    Ok(())
}

//! shelve：JetBrains 本地补丁抽象（模块 H ⚠️ 决策点：复刻，价值高）。
//!
//! 与 stash 不同（stash 保存全部并走 refs/stash 链），shelve 保存**指定路径**的
//! 变更为命名补丁：补丁提交的树 = HEAD 树 + 指定路径的工作区内容（其他路径保持 HEAD），
//! 存于 `refs/shelved/<name>`，列表存 `.git/arbor-shelves`（跨进程存活）。

use gix::bstr::{BStr, ByteSlice};

use crate::diff::blob_bytes;
use crate::error::EngineError;
use crate::merge::{index_mode, materialize_tree_paths, write_worktree_entry, ConflictEntry};

const RESTORE_SNAPSHOT_FILE: &str = "arbor-shelve-restore";
const RESTORE_SNAPSHOT_TMP_FILE: &str = "arbor-shelve-restore.tmp";
const RESTORE_SNAPSHOT_MAGIC: &str = "ARBOUR_SHELVE_RESTORE_V1";
const TEMPORARY_INDEX_SNAPSHOT_FILE: &str = "arbor-shelve-index-restore";
const TEMPORARY_INDEX_SNAPSHOT_TMP_FILE: &str = "arbor-shelve-index-restore.tmp";
const TEMPORARY_INDEX_SNAPSHOT_MAGIC: &str = "ARBOUR_SHELVE_INDEX_RESTORE_V1";
const SHELF_PATCH_DIR: &str = "arbor-shelf-patches";
const DELETED_SHELF_PATCH_DIR: &str = "arbor-shelf-patches-deleted";
const SHELF_LOCATION_FILE: &str = "arbor-shelf-location";

struct ShelveApplyProgress {
    generation: u64,
}

impl ShelveApplyProgress {
    fn new(name: &str) -> Self {
        Self {
            generation: crate::gitprocess::begin_operation_progress(
                "shelve".to_string(),
                "Preparing Shelf".to_string(),
                name.to_string(),
            ),
        }
    }
}

impl Drop for ShelveApplyProgress {
    fn drop(&mut self) {
        crate::gitprocess::end_operation_progress(self.generation);
    }
}

fn shelf_progress_percentage(completed: usize, total: usize) -> u32 {
    if total == 0 {
        100
    } else {
        ((completed.saturating_mul(100) / total).min(100)) as u32
    }
}

/// 一个 shelf 补丁。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ShelveInfo {
    pub name: String,
    pub id: String,
    pub short_id: String,
    /// Paths changed by this shelved changelist, in the same order as the
    /// tree diff. The UI uses this to preserve IntelliJ's two-level
    /// ShelvedChangeList -> ShelvedChange presentation instead of flattening
    /// every shelf into one opaque row.
    pub paths: Vec<String>,
    /// User-facing shelf description. The current dialog keeps this equal to
    /// the shelf name, but it is persisted separately so future rename and
    /// changelist flows do not have to rewrite the patch object.
    pub description: String,
    /// Last lifecycle update as Unix seconds. IntelliJ uses this date for
    /// shelf ordering and Recently Deleted expiry.
    pub timestamp: i64,
    /// Whether this entry came from the Recently Deleted collection.
    pub is_deleted: bool,
    /// Whether IntelliJ considers this changelist already unshelved. Recycled
    /// entries remain recoverable but are hidden from the default Shelf view.
    pub is_recycled: bool,
    /// Whether a deferred delete must be finalized during repository reopen.
    pub is_pending_delete: bool,
}

/// One member selected in the Shelf apply dialog.
///
/// `hunk_index = None` means the whole file member. This is required for
/// binary, rename-only, and mode-only changes, which do not have text hunks.
/// Text changes use zero-based hunk indexes from the corresponding `diff
/// --git` chunk.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq, Hash)]
pub struct ShelvePatchSelection {
    pub path: String,
    pub hunk_index: Option<u32>,
}

/// A resolved text hunk decision kept with a paused Shelf/Apply Patch restore.
/// Only decisions that cannot be reconstructed from the current result text
/// (`applied`, `automatically_applied`, and `ignored`) are persisted.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq, Hash)]
pub struct ShelveRestoreHunkResolution {
    pub path: String,
    pub hunk_index: u32,
    pub resolution: String,
}

/// A pending shelf restore is deliberately persisted under `.git`. A shelf
/// conflict has no native Git operation state, so an in-memory Swift flag is
/// not enough to make Cancel or app restart safe.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ShelveRestoreInfo {
    pub name: String,
    pub is_pop: bool,
    pub remove_applied: bool,
    pub paths: Vec<String>,
    /// Optional target Changes Browser changelist for a drag-and-drop
    /// unshelve. Persisting this keeps the target stable across app restart
    /// while the conflict resolver is open.
    pub target_change_list: Option<String>,
    /// The effective patch input for a paused raw Shelf or direct Apply Patch
    /// conflict. This is persisted so the resolver can restore its patch-side
    /// preview after an application restart.
    pub patch: Option<String>,
    pub is_direct_patch: bool,
    /// Members that completed before a conflict paused the restore.
    pub applied_paths: Vec<String>,
    /// Members that failed without creating a conflict and remain unattempted
    /// by the resolver.
    pub failed_paths: Vec<String>,
    /// Members whose conflicts are currently being resolved.
    pub conflict_paths: Vec<String>,
    pub resolved_hunks: Vec<ShelveRestoreHunkResolution>,
}

fn patch_apply_result(
    all_paths: std::collections::BTreeSet<String>,
    applied_paths: std::collections::BTreeSet<String>,
    failed_paths: std::collections::BTreeSet<String>,
    already_applied_paths: std::collections::BTreeSet<String>,
    partial_paths: std::collections::BTreeSet<String>,
) -> crate::repo::PatchApplyResult {
    let mut member_statuses = Vec::new();
    for path in all_paths {
        let status = if failed_paths.contains(&path) {
            crate::repo::PatchApplyStatus::Failure
        } else if partial_paths.contains(&path) {
            crate::repo::PatchApplyStatus::Partial
        } else if already_applied_paths.contains(&path) {
            crate::repo::PatchApplyStatus::AlreadyApplied
        } else if applied_paths.contains(&path) {
            crate::repo::PatchApplyStatus::Success
        } else {
            crate::repo::PatchApplyStatus::Skip
        };
        member_statuses.push(crate::repo::PatchApplyMemberResult { path, status });
    }
    let overall_status = aggregate_patch_apply_status(
        &member_statuses
            .iter()
            .map(|member| member.status)
            .collect::<Vec<_>>(),
    );
    crate::repo::PatchApplyResult {
        applied_paths: applied_paths.into_iter().collect(),
        failed_paths: failed_paths.into_iter().collect(),
        overall_status,
        member_statuses,
    }
}

fn aborted_patch_apply_result(
    paths: std::collections::BTreeSet<String>,
) -> crate::repo::PatchApplyResult {
    let member_statuses = paths
        .iter()
        .cloned()
        .map(|path| crate::repo::PatchApplyMemberResult {
            path,
            status: crate::repo::PatchApplyStatus::Abort,
        })
        .collect::<Vec<_>>();
    crate::repo::PatchApplyResult {
        failed_paths: paths.iter().cloned().collect(),
        applied_paths: Vec::new(),
        overall_status: crate::repo::PatchApplyStatus::Abort,
        member_statuses,
    }
}

fn aggregate_patch_apply_status(
    statuses: &[crate::repo::PatchApplyStatus],
) -> crate::repo::PatchApplyStatus {
    use crate::repo::PatchApplyStatus;

    let mut aggregate = None;
    for status in statuses {
        aggregate = Some(match (aggregate, *status) {
            (None, next) => next,
            (Some(PatchApplyStatus::Success), PatchApplyStatus::AlreadyApplied)
            | (Some(PatchApplyStatus::AlreadyApplied), PatchApplyStatus::Success) => {
                PatchApplyStatus::Partial
            }
            (Some(current), next) => {
                if patch_apply_status_rank(next) > patch_apply_status_rank(current) {
                    next
                } else {
                    current
                }
            }
        });
    }
    aggregate.unwrap_or(PatchApplyStatus::Skip)
}

fn patch_apply_status_rank(status: crate::repo::PatchApplyStatus) -> u8 {
    match status {
        crate::repo::PatchApplyStatus::Skip => 0,
        crate::repo::PatchApplyStatus::Success => 1,
        crate::repo::PatchApplyStatus::AlreadyApplied => 2,
        crate::repo::PatchApplyStatus::Partial => 3,
        crate::repo::PatchApplyStatus::Failure => 4,
        crate::repo::PatchApplyStatus::Abort => 5,
    }
}

#[derive(Clone, Debug)]
pub(crate) struct IndexSnapshotEntry {
    path: String,
    id: gix::hash::ObjectId,
    mode: u32,
    flags: u32,
}

#[derive(Clone, Debug)]
struct ShelveRestoreSnapshot {
    name: String,
    is_pop: bool,
    remove_applied: bool,
    paths: Vec<String>,
    target_change_list: Option<String>,
    patch: Option<String>,
    is_direct_patch: bool,
    differentiated_apply: bool,
    applied_paths: Vec<String>,
    failed_paths: Vec<String>,
    conflict_paths: Vec<String>,
    patch_base_path: Option<String>,
    patch_path_strip: u32,
    resolved_hunks: Vec<ShelveRestoreHunkResolution>,
    worktree_tree: gix::hash::ObjectId,
    index_entries: Vec<IndexSnapshotEntry>,
}

#[derive(Clone, Debug)]
struct TemporaryIndexSnapshot {
    name: String,
    paths: Vec<String>,
    index_entries: Vec<IndexSnapshotEntry>,
}

pub(crate) fn shelves_file(repo: &gix::Repository) -> std::path::PathBuf {
    shelf_storage_root(repo).join("arbor-shelves")
}

pub(crate) fn deleted_shelves_file(repo: &gix::Repository) -> std::path::PathBuf {
    shelf_storage_root(repo).join("arbor-shelves-deleted")
}

pub(crate) fn shelf_metadata_file(repo: &gix::Repository) -> std::path::PathBuf {
    shelf_storage_root(repo).join("arbor-shelves-meta")
}

fn shelf_patch_dir(repo: &gix::Repository, is_deleted: bool) -> std::path::PathBuf {
    shelf_storage_root(repo).join(if is_deleted {
        DELETED_SHELF_PATCH_DIR
    } else {
        SHELF_PATCH_DIR
    })
}

/// The location marker remains in `.git` so changing a Shelf directory never
/// changes Git refs or operation recovery state. An invalid marker fails back
/// to the legacy in-repository directory; the public setter validates and
/// writes only absolute, canonical paths.
fn shelf_storage_root(repo: &gix::Repository) -> std::path::PathBuf {
    let legacy = repo.git_dir().to_path_buf();
    let marker = legacy.join(SHELF_LOCATION_FILE);
    let Ok(raw) = std::fs::read_to_string(marker) else {
        return legacy;
    };
    let candidate = std::path::PathBuf::from(raw.trim());
    if candidate.is_absolute() {
        candidate
    } else {
        legacy
    }
}

pub(crate) fn shelf_location(repo: &gix::Repository) -> std::path::PathBuf {
    shelf_storage_root(repo)
}

fn copy_shelf_artifact(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> Result<(), EngineError> {
    if !source.exists() {
        return Ok(());
    }
    if source.is_dir() {
        std::fs::create_dir_all(destination).map_err(EngineError::from_gix)?;
        for entry in std::fs::read_dir(source).map_err(EngineError::from_gix)? {
            let entry = entry.map_err(EngineError::from_gix)?;
            copy_shelf_artifact(&entry.path(), &destination.join(entry.file_name()))?;
        }
    } else {
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(EngineError::from_gix)?;
        }
        std::fs::copy(source, destination).map_err(EngineError::from_gix)?;
    }
    Ok(())
}

fn verify_shelf_artifact(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> Result<(), EngineError> {
    let source_metadata = std::fs::symlink_metadata(source).map_err(EngineError::from_gix)?;
    let destination_metadata =
        std::fs::symlink_metadata(destination).map_err(EngineError::from_gix)?;
    if source_metadata.file_type().is_dir() != destination_metadata.file_type().is_dir() {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: migrated artifact type mismatch for {}",
                source.display()
            ),
        });
    }
    if source_metadata.file_type().is_dir() {
        let source_entries = std::fs::read_dir(source)
            .map_err(EngineError::from_gix)?
            .map(|entry| {
                entry
                    .map(|entry| entry.file_name())
                    .map_err(EngineError::from_gix)
            })
            .collect::<Result<std::collections::HashSet<_>, _>>()?;
        let destination_entries = std::fs::read_dir(destination)
            .map_err(EngineError::from_gix)?
            .map(|entry| {
                entry
                    .map(|entry| entry.file_name())
                    .map_err(EngineError::from_gix)
            })
            .collect::<Result<std::collections::HashSet<_>, _>>()?;
        if source_entries != destination_entries {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: migrated artifact entries differ for {}",
                    source.display()
                ),
            });
        }
        for name in source_entries {
            verify_shelf_artifact(&source.join(&name), &destination.join(&name))?;
        }
    } else if std::fs::read(source).map_err(EngineError::from_gix)?
        != std::fs::read(destination).map_err(EngineError::from_gix)?
    {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: migrated artifact contents differ for {}",
                source.display()
            ),
        });
    }
    Ok(())
}

/// Change the on-disk Shelf directory. The copy is assembled in a temporary
/// sibling and the location marker is written last; a failed copy therefore
/// leaves the old Shelf fully usable and can be retried safely.
pub(crate) fn set_shelf_location(
    repo: &gix::Repository,
    requested: &std::path::Path,
    migrate_existing: bool,
) -> Result<std::path::PathBuf, EngineError> {
    if !requested.is_absolute() {
        return Err(EngineError::GitOperation {
            message: "shelve: location must be an absolute path".into(),
        });
    }
    let legacy = repo.git_dir().to_path_buf();
    let current = shelf_storage_root(repo);
    let target = if requested.exists() {
        requested.canonicalize().map_err(EngineError::from_gix)?
    } else {
        requested.to_path_buf()
    };
    if target == current {
        return Ok(target);
    }
    let artifacts = [
        "arbor-shelves",
        "arbor-shelves-deleted",
        "arbor-shelves-meta",
        SHELF_PATCH_DIR,
        DELETED_SHELF_PATCH_DIR,
    ];
    let has_artifacts = artifacts.iter().any(|name| current.join(name).exists());
    if !migrate_existing {
        if has_artifacts {
            return Err(EngineError::GitOperation {
                message: "shelve: existing Shelves require migration before changing location"
                    .into(),
            });
        }
        std::fs::create_dir_all(&target).map_err(EngineError::from_gix)?;
    } else {
        if has_artifacts {
            if target.exists() {
                let mut entries = std::fs::read_dir(&target).map_err(EngineError::from_gix)?;
                if entries.next().is_some() {
                    return Err(EngineError::GitOperation {
                        message: "shelve: migration target must be empty".into(),
                    });
                }
                std::fs::remove_dir(&target).map_err(EngineError::from_gix)?;
            } else if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(EngineError::from_gix)?;
            }
            let tmp = target.with_extension(format!("arbor-shelf-migrate-{}", std::process::id()));
            if tmp.exists() {
                std::fs::remove_dir_all(&tmp).map_err(EngineError::from_gix)?;
            }
            std::fs::create_dir_all(&tmp).map_err(EngineError::from_gix)?;
            for name in artifacts {
                copy_shelf_artifact(&current.join(name), &tmp.join(name))?;
                if current.join(name).exists() {
                    verify_shelf_artifact(&current.join(name), &tmp.join(name))?;
                }
            }
            std::fs::rename(&tmp, &target).map_err(EngineError::from_gix)?;
        } else {
            std::fs::create_dir_all(&target).map_err(EngineError::from_gix)?;
        }
    }
    let marker = legacy.join(SHELF_LOCATION_FILE);
    let tmp_marker = marker.with_extension("tmp");
    std::fs::write(&tmp_marker, format!("{}\n", target.display()))
        .map_err(EngineError::from_gix)?;
    if let Err(error) = std::fs::rename(&tmp_marker, &marker) {
        let _ = std::fs::remove_file(&tmp_marker);
        return Err(EngineError::from_gix(error));
    }
    Ok(target)
}

pub(crate) fn shelf_patch_file(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
) -> std::path::PathBuf {
    shelf_patch_dir(repo, is_deleted).join(format!("{}.patch", sanitize_ref_name(name)))
}

pub(crate) fn read_shelf_patch(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
) -> Result<Option<Vec<u8>>, EngineError> {
    match std::fs::read(shelf_patch_file(repo, name, is_deleted)) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(EngineError::from_gix(error)),
    }
}

/// Persist an imported patch without interpreting it against the current
/// worktree. The temp+rename sequence is important: a crash cannot leave a
/// partial patch that still looks like a valid shelf payload.
pub(crate) fn write_shelf_patch(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
    patch: &[u8],
    replace: bool,
) -> Result<(), EngineError> {
    let path = shelf_patch_file(repo, name, is_deleted);
    if !replace && path.exists() {
        return Err(EngineError::GitOperation {
            message: format!("shelve: patch file already exists for {name}"),
        });
    }
    std::fs::create_dir_all(shelf_patch_dir(repo, is_deleted)).map_err(EngineError::from_gix)?;
    let tmp = path.with_extension("patch.tmp");
    std::fs::write(&tmp, patch).map_err(EngineError::from_gix)?;
    if let Err(error) = std::fs::rename(&tmp, &path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(EngineError::from_gix(error));
    }
    Ok(())
}

pub(crate) fn remove_shelf_patch(
    repo: &gix::Repository,
    name: &str,
    is_deleted: bool,
) -> Result<Option<Vec<u8>>, EngineError> {
    let path = shelf_patch_file(repo, name, is_deleted);
    let Some(bytes) = read_shelf_patch(repo, name, is_deleted)? else {
        return Ok(None);
    };
    std::fs::remove_file(path).map_err(EngineError::from_gix)?;
    Ok(Some(bytes))
}

pub(crate) fn move_shelf_patch(
    repo: &gix::Repository,
    name: &str,
    from_deleted: bool,
    to_deleted: bool,
) -> Result<bool, EngineError> {
    if from_deleted == to_deleted {
        return Ok(read_shelf_patch(repo, name, from_deleted)?.is_some());
    }
    let source = shelf_patch_file(repo, name, from_deleted);
    if !source.exists() {
        return Ok(false);
    }
    let destination = shelf_patch_file(repo, name, to_deleted);
    if destination.exists() {
        return Err(EngineError::GitOperation {
            message: format!("shelve: destination patch file already exists for {name}"),
        });
    }
    std::fs::create_dir_all(shelf_patch_dir(repo, to_deleted)).map_err(EngineError::from_gix)?;
    std::fs::rename(source, destination).map_err(EngineError::from_gix)?;
    Ok(true)
}

pub(crate) fn rename_shelf_patch(
    repo: &gix::Repository,
    old_name: &str,
    new_name: &str,
    is_deleted: bool,
) -> Result<bool, EngineError> {
    let source = shelf_patch_file(repo, old_name, is_deleted);
    if !source.exists() {
        return Ok(false);
    }
    let destination = shelf_patch_file(repo, new_name, is_deleted);
    if destination.exists() {
        return Err(EngineError::GitOperation {
            message: format!("shelve: destination patch file already exists for {new_name}"),
        });
    }
    std::fs::create_dir_all(shelf_patch_dir(repo, is_deleted)).map_err(EngineError::from_gix)?;
    std::fs::rename(source, destination).map_err(EngineError::from_gix)?;
    Ok(true)
}

#[derive(Clone, Debug)]
pub(crate) struct ParsedPatchChange {
    pub path: String,
    pub endpoints: Vec<String>,
    /// Original endpoint spellings, including `a/`/`b/` when present. The
    /// normalized endpoints above are used for shelf member identity, while
    /// these paths are needed to calculate the actual target of `git apply
    /// -pN` when N is smaller than Git's conventional prefix depth.
    pub raw_endpoints: Vec<String>,
    pub chunk: String,
}

/// A patch member whose payload is intentionally kept as bytes. Git's
/// textual headers and paths are UTF-8 in the supported filesystem model,
/// but a patch payload can still contain arbitrary bytes. Member listing and
/// deletion must not require decoding that payload just to find its chunk.
#[derive(Clone, Debug)]
struct ParsedPatchByteChange {
    path: String,
    endpoints: Vec<String>,
    start: usize,
    end: usize,
}

fn patch_byte_lines(patch: &[u8]) -> Vec<(usize, usize)> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (index, byte) in patch.iter().enumerate() {
        if *byte == b'\n' {
            lines.push((start, index + 1));
            start = index + 1;
        }
    }
    if start < patch.len() {
        lines.push((start, patch.len()));
    }
    lines
}

fn patch_byte_line_without_eol(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn patch_byte_line_utf8<'a>(line: &'a [u8], message: &str) -> Result<&'a str, EngineError> {
    std::str::from_utf8(patch_byte_line_without_eol(line)).map_err(|_| EngineError::GitOperation {
        message: message.into(),
    })
}

/// Locate patch member boundaries without decoding member payloads. This is
/// used only by operations that preserve raw patch bytes; normal apply and
/// preview paths continue to use the richer UTF-8 parser above.
fn parse_patch_change_byte_spans(patch: &[u8]) -> Result<Vec<ParsedPatchByteChange>, EngineError> {
    let lines = patch_byte_lines(patch);
    let diff_starts = lines
        .iter()
        .enumerate()
        .filter_map(|(index, (start, end))| {
            patch_byte_line_without_eol(&patch[*start..*end])
                .starts_with(b"diff --git ")
                .then_some(index)
        })
        .collect::<Vec<_>>();

    let parse_diff = |line_index: usize, end: usize| {
        let (start, line_end) = lines[line_index];
        let header = patch_byte_line_utf8(
            &patch[start..line_end],
            "shelve: patch header is not valid UTF-8",
        )?;
        let (old_header, new_header) =
            patch_header_tokens(header.strip_prefix("diff --git ").ok_or_else(|| {
                EngineError::GitOperation {
                    message: "shelve: malformed git diff header".into(),
                }
            })?)?;
        let old = normalize_patch_path(&old_header)?;
        let new = normalize_patch_path(&new_header)?;
        let mut endpoints = Vec::new();
        for path in [old.clone(), new.clone()].into_iter().flatten() {
            if !endpoints.contains(&path) {
                endpoints.push(path);
            }
        }
        for (line_start, line_end) in lines[line_index + 1..end].iter().copied() {
            let line = patch_byte_line_without_eol(&patch[line_start..line_end]);
            let Some(value) = [
                b"rename from ".as_slice(),
                b"rename to ".as_slice(),
                b"copy from ".as_slice(),
                b"copy to ".as_slice(),
                b"--- ".as_slice(),
                b"+++ ".as_slice(),
            ]
            .iter()
            .find_map(|prefix| line.strip_prefix(*prefix)) else {
                continue;
            };
            let Ok(value) = std::str::from_utf8(value) else {
                continue;
            };
            if let Some(path) = patch_line_path(value)? {
                if !endpoints.contains(&path) {
                    endpoints.push(path);
                }
            }
        }
        let path = new
            .or(old)
            .or_else(|| endpoints.first().cloned())
            .ok_or_else(|| EngineError::GitOperation {
                message: "shelve: patch change has no file path".into(),
            })?;
        Ok(ParsedPatchByteChange {
            path,
            endpoints,
            start,
            end: lines[end - 1].1,
        })
    };

    if !diff_starts.is_empty() {
        return diff_starts
            .iter()
            .enumerate()
            .map(|(index, line_index)| {
                parse_diff(
                    *line_index,
                    diff_starts.get(index + 1).copied().unwrap_or(lines.len()),
                )
            })
            .collect();
    }

    let unified_starts = lines
        .windows(2)
        .enumerate()
        .filter_map(|(index, window)| {
            let first = patch_byte_line_without_eol(&patch[window[0].0..window[0].1]);
            let second = patch_byte_line_without_eol(&patch[window[1].0..window[1].1]);
            (first.starts_with(b"--- ") && second.starts_with(b"+++ ")).then_some(index)
        })
        .collect::<Vec<_>>();
    let mut changes = Vec::new();
    for (index, line_index) in unified_starts.iter().enumerate() {
        let end = unified_starts
            .get(index + 1)
            .copied()
            .unwrap_or(lines.len());
        let old = patch_byte_line_utf8(
            &patch[lines[*line_index].0..lines[*line_index].1],
            "shelve: unified patch header is not valid UTF-8",
        )?
        .strip_prefix("--- ")
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: malformed unified patch header".into(),
        })?
        .trim();
        let new = patch_byte_line_utf8(
            &patch[lines[*line_index + 1].0..lines[*line_index + 1].1],
            "shelve: unified patch header is not valid UTF-8",
        )?
        .strip_prefix("+++ ")
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: malformed unified patch header".into(),
        })?
        .trim();
        let old = patch_line_path(old)?;
        let new = patch_line_path(new)?;
        let mut endpoints = Vec::new();
        for path in [old.clone(), new.clone()].into_iter().flatten() {
            if !endpoints.contains(&path) {
                endpoints.push(path);
            }
        }
        let path = new.or_else(|| endpoints.first().cloned()).ok_or_else(|| {
            EngineError::GitOperation {
                message: "shelve: unified patch change has no file path".into(),
            }
        })?;
        changes.push(ParsedPatchByteChange {
            path,
            endpoints,
            start: lines[*line_index].0,
            end: lines[end - 1].1,
        });
    }
    if changes.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: patch contains no file changes".into(),
        });
    }
    Ok(changes)
}

pub(crate) fn patch_paths_bytes(patch: &[u8]) -> Result<Vec<String>, EngineError> {
    if let Ok(patch) = std::str::from_utf8(patch) {
        return patch_paths(patch);
    }
    let mut paths = Vec::new();
    for path in parse_patch_change_byte_spans(patch)?
        .into_iter()
        .map(|change| change.path)
    {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    Ok(paths)
}

pub(crate) fn remove_patch_chunks_bytes(
    patch: &[u8],
    paths: &[String],
) -> Result<Option<Vec<u8>>, EngineError> {
    if paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: select at least one deleted shelf member".into(),
        });
    }
    let selected = paths
        .iter()
        .map(|path| {
            crate::repo::worktree_relative_path(path)?;
            Ok(path.clone())
        })
        .collect::<Result<std::collections::HashSet<_>, EngineError>>()?;
    let changes = parse_patch_change_byte_spans(patch)?;
    let mut matched = std::collections::HashSet::new();
    let mut result = Vec::new();
    for change in changes {
        let remove = change.endpoints.iter().any(|path| selected.contains(path));
        if remove {
            matched.extend(
                change
                    .endpoints
                    .iter()
                    .filter(|path| selected.contains(*path))
                    .cloned(),
            );
        } else {
            result.extend_from_slice(&patch[change.start..change.end]);
        }
    }
    for path in &selected {
        if !matched.contains(path) {
            return Err(EngineError::GitOperation {
                message: format!("shelve: selected path is not in the imported patch: {path}"),
            });
        }
    }
    Ok((!result.iter().all(u8::is_ascii_whitespace)).then_some(result))
}

fn patch_hunk_blocks(change: &ParsedPatchChange) -> (String, Vec<String>) {
    let lines: Vec<&str> = change.chunk.split_inclusive('\n').collect();
    let starts = lines
        .iter()
        .enumerate()
        .filter_map(|(index, line)| line.trim_end().starts_with("@@").then_some(index))
        .collect::<Vec<_>>();
    let Some(first) = starts.first().copied() else {
        return (change.chunk.clone(), Vec::new());
    };
    let prefix = lines[..first].concat();
    let blocks = starts
        .iter()
        .enumerate()
        .map(|(index, start)| {
            let end = starts.get(index + 1).copied().unwrap_or(lines.len());
            lines[*start..end].concat()
        })
        .collect();
    (prefix, blocks)
}

fn patch_change_has_standalone_metadata(prefix: &str) -> bool {
    prefix.lines().any(|line| {
        [
            "old mode ",
            "new mode ",
            "new file mode ",
            "deleted file mode ",
            "similarity index ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to ",
        ]
        .iter()
        .any(|prefix| line.starts_with(prefix))
    })
}

fn render_patch_change_selection(
    change: &ParsedPatchChange,
    selected_hunks: Option<&std::collections::HashSet<u32>>,
    keep_selected: bool,
) -> Option<String> {
    let Some(selected_hunks) = selected_hunks else {
        return keep_selected.then(|| change.chunk.clone());
    };
    let (prefix, blocks) = patch_hunk_blocks(change);
    if blocks.is_empty() {
        return None;
    }
    let mut result = prefix;
    let mut kept_block = false;
    for (index, block) in blocks.into_iter().enumerate() {
        let selected = selected_hunks.contains(&(index as u32));
        if selected == keep_selected {
            result.push_str(&block);
            kept_block = true;
        }
    }
    if kept_block {
        Some(result)
    } else if !keep_selected && patch_change_has_standalone_metadata(&result) {
        Some(result)
    } else {
        None
    }
}

fn selected_patch_changes(
    patch: &str,
    selections: &[ShelvePatchSelection],
    keep_selected: bool,
) -> Result<String, EngineError> {
    if selections.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: select at least one change".into(),
        });
    }
    let mut normalized_selections = Vec::with_capacity(selections.len());
    let mut seen = std::collections::HashSet::new();
    for selection in selections {
        crate::repo::worktree_relative_path(&selection.path)?;
        if !seen.insert((selection.path.clone(), selection.hunk_index)) {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: selected member appears more than once: {}",
                    selection.path
                ),
            });
        }
        normalized_selections.push(selection.clone());
    }

    let changes = parse_patch_changes(patch)?;
    let mut matched_paths = std::collections::HashSet::new();
    let mut result = String::new();
    for change in &changes {
        let matching = normalized_selections
            .iter()
            .filter(|selection| change.endpoints.contains(&selection.path))
            .collect::<Vec<_>>();
        if matching.is_empty() {
            if !keep_selected {
                result.push_str(&change.chunk);
            }
            continue;
        }
        for selection in &matching {
            matched_paths.insert(selection.path.clone());
        }
        let whole_file = matching
            .iter()
            .any(|selection| selection.hunk_index.is_none());
        let rendered = if whole_file {
            if keep_selected {
                Some(change.chunk.clone())
            } else {
                None
            }
        } else {
            let hunk_indexes = matching
                .iter()
                .filter_map(|selection| selection.hunk_index)
                .collect::<std::collections::HashSet<_>>();
            let (_, blocks) = patch_hunk_blocks(change);
            if blocks.is_empty() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "shelve: {} has no selectable text hunks; select the file instead",
                        change.path
                    ),
                });
            }
            if let Some(index) = hunk_indexes
                .iter()
                .find(|index| **index as usize >= blocks.len())
            {
                return Err(EngineError::GitOperation {
                    message: format!("shelve: hunk {} is not present in {}", index, change.path),
                });
            }
            render_patch_change_selection(change, Some(&hunk_indexes), keep_selected)
        };
        if let Some(rendered) = rendered {
            result.push_str(&rendered);
        }
    }
    for selection in &normalized_selections {
        if !matched_paths.contains(&selection.path) {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: selected path is not in the patch: {}",
                    selection.path
                ),
            });
        }
    }
    if result.trim().is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: no patch changes remain".into(),
        });
    }
    Ok(result)
}

pub(crate) fn select_patch_selections(
    patch: &str,
    selections: &[ShelvePatchSelection],
) -> Result<String, EngineError> {
    selected_patch_changes(patch, selections, true)
}

pub(crate) fn remove_patch_selections(
    patch: &str,
    selections: &[ShelvePatchSelection],
) -> Result<Option<String>, EngineError> {
    let changes = parse_patch_changes(patch)?;
    let selected = selected_patch_changes(patch, selections, true)?;
    let selected_changes = parse_patch_changes(&selected)?;
    let selected_endpoints = selected_changes
        .iter()
        .flat_map(|change| change.endpoints.iter().cloned())
        .collect::<std::collections::HashSet<_>>();
    let mut result = String::new();
    for change in changes {
        if !change
            .endpoints
            .iter()
            .any(|path| selected_endpoints.contains(path))
        {
            result.push_str(&change.chunk);
            continue;
        }
        let matching = selections
            .iter()
            .filter(|selection| change.endpoints.contains(&selection.path))
            .collect::<Vec<_>>();
        if matching
            .iter()
            .any(|selection| selection.hunk_index.is_none())
        {
            continue;
        }
        let hunk_indexes = matching
            .iter()
            .filter_map(|selection| selection.hunk_index)
            .collect::<std::collections::HashSet<_>>();
        if let Some(rendered) = render_patch_change_selection(&change, Some(&hunk_indexes), false) {
            result.push_str(&rendered);
        }
    }
    Ok((!result.trim().is_empty()).then_some(result))
}

fn decode_git_path(token: &str) -> Result<String, EngineError> {
    let token = token.trim();
    if !token.starts_with('"') {
        return Ok(token.to_string());
    }
    let bytes = token.as_bytes();
    if bytes.len() < 2 || bytes[bytes.len() - 1] != b'"' {
        return Err(EngineError::GitOperation {
            message: "shelve: malformed quoted patch path".into(),
        });
    }
    let mut out = Vec::new();
    let mut index = 1;
    while index + 1 < bytes.len() {
        let byte = bytes[index];
        if byte == b'"' {
            if index != bytes.len() - 1 {
                return Err(EngineError::GitOperation {
                    message: "shelve: malformed quoted patch path".into(),
                });
            }
            break;
        }
        if byte != b'\\' {
            out.push(byte);
            index += 1;
            continue;
        }
        index += 1;
        let Some(&escaped) = bytes.get(index) else {
            return Err(EngineError::GitOperation {
                message: "shelve: malformed quoted patch path escape".into(),
            });
        };
        match escaped {
            b'a' => out.push(7),
            b'b' => out.push(8),
            b't' => out.push(b'\t'),
            b'n' => out.push(b'\n'),
            b'v' => out.push(11),
            b'f' => out.push(12),
            b'r' => out.push(b'\r'),
            b'\\' | b'"' => out.push(escaped),
            b'0'..=b'7' => {
                let mut value = (escaped - b'0') as u8;
                for _ in 0..2 {
                    index += 1;
                    let Some(next @ b'0'..=b'7') = bytes.get(index).copied() else {
                        break;
                    };
                    value = value * 8 + next - b'0';
                }
                out.push(value);
            }
            _ => out.push(escaped),
        }
        index += 1;
    }
    String::from_utf8(out).map_err(|_| EngineError::GitOperation {
        message: "shelve: patch path is not valid UTF-8".into(),
    })
}

fn patch_header_tokens(value: &str) -> Result<(String, String), EngineError> {
    let value = value.trim();
    let parse = |value: &str| -> Result<(String, String), EngineError> {
        if value.starts_with('"') {
            let bytes = value.as_bytes();
            let mut escaped = false;
            for index in 1..bytes.len() {
                if escaped {
                    escaped = false;
                } else if bytes[index] == b'\\' {
                    escaped = true;
                } else if bytes[index] == b'"' {
                    let token = decode_git_path(&value[..=index])?;
                    return Ok((token, value[index + 1..].trim_start().to_string()));
                }
            }
            return Err(EngineError::GitOperation {
                message: "shelve: malformed git diff path header".into(),
            });
        }
        let split = value.find(char::is_whitespace).unwrap_or(value.len());
        Ok((
            value[..split].to_string(),
            value[split..].trim_start().to_string(),
        ))
    };
    if let Some(boundary) = value.rfind(" b/") {
        let first = value[..boundary].trim().to_string();
        let second = value[boundary + 1..].trim().to_string();
        if !first.is_empty() && !second.is_empty() {
            return Ok((first, second));
        }
    }
    let (first, rest) = parse(value)?;
    let (second, _) = parse(&rest)?;
    Ok((first, second))
}

fn normalize_patch_path(value: &str) -> Result<Option<String>, EngineError> {
    let value = value.trim();
    if value == "/dev/null" {
        return Ok(None);
    }
    let value = value
        .strip_prefix("a/")
        .or_else(|| value.strip_prefix("b/"))
        .unwrap_or(value);
    crate::repo::worktree_relative_path(value)?;
    Ok(Some(value.to_string()))
}

fn raw_patch_path(value: &str) -> Result<Option<String>, EngineError> {
    let value = value.trim();
    if value == "/dev/null" {
        return Ok(None);
    }
    normalize_patch_path(value)?;
    Ok(Some(value.to_string()))
}

fn patch_line_token(value: &str) -> Result<String, EngineError> {
    let value = value.trim_start();
    if value.starts_with('"') {
        let bytes = value.as_bytes();
        let mut escaped = false;
        let mut end = None;
        for index in 1..bytes.len() {
            if escaped {
                escaped = false;
            } else if bytes[index] == b'\\' {
                escaped = true;
            } else if bytes[index] == b'"' {
                end = Some(index + 1);
                break;
            }
        }
        let Some(end) = end else {
            return Err(EngineError::GitOperation {
                message: "shelve: malformed patch path".into(),
            });
        };
        decode_git_path(&value[..end])
    } else {
        Ok(value
            .split_once('\t')
            .map(|(path, _)| path)
            .unwrap_or(value)
            .trim()
            .to_string())
    }
}

fn patch_line_path(value: &str) -> Result<Option<String>, EngineError> {
    let token = patch_line_token(value)?;
    normalize_patch_path(&token)
}

fn raw_patch_line_path(value: &str) -> Result<Option<String>, EngineError> {
    let token = patch_line_token(value)?;
    raw_patch_path(&token)
}

/// Parse Git's `diff --git` chunks without applying them. This is deliberately
/// independent from the current HEAD: imported shelves must remain inspectable
/// even when their original base objects are no longer present.
pub(crate) fn parse_patch_changes(patch: &str) -> Result<Vec<ParsedPatchChange>, EngineError> {
    let lines: Vec<&str> = patch.split_inclusive('\n').collect();
    let starts: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter_map(|(index, line)| line.trim_end().strip_prefix("diff --git ").map(|_| index))
        .collect();
    let mut changes = Vec::new();
    for (chunk_index, line_index) in starts.iter().enumerate() {
        let end = starts.get(chunk_index + 1).copied().unwrap_or(lines.len());
        let header = lines[*line_index].trim_end();
        let (old_header, new_header) =
            patch_header_tokens(header.strip_prefix("diff --git ").ok_or_else(|| {
                EngineError::GitOperation {
                    message: "shelve: malformed git diff header".into(),
                }
            })?)?;
        let old = normalize_patch_path(&old_header)?;
        let new = normalize_patch_path(&new_header)?;
        let mut endpoints = Vec::new();
        let mut raw_endpoints = Vec::new();
        for raw_path in [&old_header, &new_header] {
            if let Some(path) = raw_patch_path(raw_path)? {
                if !raw_endpoints.contains(&path) {
                    raw_endpoints.push(path);
                }
            }
        }
        if let Some(path) = old.clone() {
            endpoints.push(path);
        }
        if let Some(path) = new.clone() {
            if !endpoints.contains(&path) {
                endpoints.push(path);
            }
        }
        for line in &lines[*line_index + 1..end] {
            let line = line.trim_end();
            for prefix in ["rename from ", "rename to ", "--- ", "+++ "] {
                if let Some(value) = line.strip_prefix(prefix) {
                    if let Some(path) = patch_line_path(value)? {
                        if !endpoints.contains(&path) {
                            endpoints.push(path);
                        }
                    }
                    if raw_endpoints.is_empty() {
                        if let Some(path) = raw_patch_line_path(value)? {
                            if !raw_endpoints.contains(&path) {
                                raw_endpoints.push(path);
                            }
                        }
                    }
                }
            }
        }
        let Some(path) = new.or(old).or_else(|| endpoints.first().cloned()) else {
            return Err(EngineError::GitOperation {
                message: "shelve: patch change has no file path".into(),
            });
        };
        changes.push(ParsedPatchChange {
            path,
            endpoints,
            raw_endpoints,
            chunk: lines[*line_index..end].concat(),
        });
    }
    if changes.is_empty() {
        // Plain unified patches do not have diff --git boundaries. Match the
        // paired ---/+++ headers instead so a multi-file patch keeps separate
        // members for selection, path mapping, and remainder persistence.
        let starts = lines
            .iter()
            .enumerate()
            .filter_map(|(index, line)| {
                (line.trim_end().starts_with("--- ")
                    && lines
                        .get(index + 1)
                        .is_some_and(|next| next.trim_end().starts_with("+++ ")))
                .then_some(index)
            })
            .collect::<Vec<_>>();
        for (chunk_index, line_index) in starts.iter().enumerate() {
            let end = starts.get(chunk_index + 1).copied().unwrap_or(lines.len());
            let old_value = lines[*line_index]
                .trim_end()
                .strip_prefix("--- ")
                .ok_or_else(|| EngineError::GitOperation {
                    message: "shelve: malformed unified patch header".into(),
                })?;
            let new_value = lines[*line_index + 1]
                .trim_end()
                .strip_prefix("+++ ")
                .ok_or_else(|| EngineError::GitOperation {
                    message: "shelve: malformed unified patch header".into(),
                })?;
            let old = patch_line_path(old_value)?;
            let new = patch_line_path(new_value)?;
            let mut endpoints = Vec::new();
            let mut raw_endpoints = Vec::new();
            if let Some(path) = old {
                endpoints.push(path);
            }
            if let Some(path) = new.clone() {
                if !endpoints.contains(&path) {
                    endpoints.push(path);
                }
            }
            for value in [old_value, new_value] {
                if let Some(path) = raw_patch_line_path(value)? {
                    if !raw_endpoints.contains(&path) {
                        raw_endpoints.push(path);
                    }
                }
            }
            let Some(path) = new.or_else(|| endpoints.first().cloned()) else {
                return Err(EngineError::GitOperation {
                    message: "shelve: unified patch change has no file path".into(),
                });
            };
            changes.push(ParsedPatchChange {
                path,
                endpoints,
                raw_endpoints,
                chunk: lines[*line_index..end].concat(),
            });
        }
    }
    if changes.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: patch contains no file changes".into(),
        });
    }
    Ok(changes)
}

/// Return the stable source members of a patch in patch order. A rename is a
/// single member even though its parsed change has both old and new endpoints.
pub(crate) fn patch_member_paths(patch: &str) -> Result<Vec<String>, EngineError> {
    let changes = parse_patch_changes(patch)?;
    let mut paths = Vec::new();
    for change in changes {
        for path in change.endpoints {
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    Ok(paths)
}

pub(crate) fn patch_paths(patch: &str) -> Result<Vec<String>, EngineError> {
    let mut paths = Vec::new();
    for change in parse_patch_changes(patch)? {
        if !paths.contains(&change.path) {
            paths.push(change.path);
        }
    }
    Ok(paths)
}

pub(crate) fn patch_endpoint_paths(patch: &str) -> Result<Vec<String>, EngineError> {
    let mut paths = Vec::new();
    for change in parse_patch_changes(patch)? {
        for path in change.endpoints {
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    Ok(paths)
}

fn selected_patch_chunks(patch: &str, paths: &[String], keep: bool) -> Result<String, EngineError> {
    if paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: select at least one change".into(),
        });
    }
    let selected: std::collections::HashSet<String> = paths
        .iter()
        .map(|path| {
            crate::repo::worktree_relative_path(path)?;
            Ok(path.clone())
        })
        .collect::<Result<_, EngineError>>()?;
    let changes = parse_patch_changes(patch)?;
    let mut matched = std::collections::HashSet::new();
    let mut result = String::new();
    for change in changes {
        let selected_change = change.endpoints.iter().any(|path| selected.contains(path));
        if selected_change {
            matched.extend(
                change
                    .endpoints
                    .iter()
                    .filter(|path| selected.contains(*path))
                    .cloned(),
            );
        }
        if selected_change == keep {
            result.push_str(&change.chunk);
        }
    }
    for path in &selected {
        if !matched.contains(path) {
            return Err(EngineError::GitOperation {
                message: format!("shelve: selected path is not in the imported patch: {path}"),
            });
        }
    }
    if result.trim().is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: no patch changes remain".into(),
        });
    }
    Ok(result)
}

pub(crate) fn select_patch_chunks(patch: &str, paths: &[String]) -> Result<String, EngineError> {
    selected_patch_chunks(patch, paths, true)
}

pub(crate) fn remove_patch_chunks(
    patch: &str,
    paths: &[String],
) -> Result<Option<String>, EngineError> {
    let changes = parse_patch_changes(patch)?;
    let selected: std::collections::HashSet<String> = paths
        .iter()
        .map(|path| {
            crate::repo::worktree_relative_path(path)?;
            Ok(path.clone())
        })
        .collect::<Result<_, EngineError>>()?;
    let mut matched = std::collections::HashSet::new();
    let mut result = String::new();
    for change in changes {
        let remove = change.endpoints.iter().any(|path| selected.contains(path));
        if remove {
            matched.extend(
                change
                    .endpoints
                    .iter()
                    .filter(|path| selected.contains(*path))
                    .cloned(),
            );
        } else {
            result.push_str(&change.chunk);
        }
    }
    for path in &selected {
        if !matched.contains(path) {
            return Err(EngineError::GitOperation {
                message: format!("shelve: selected path is not in the imported patch: {path}"),
            });
        }
    }
    Ok((!result.trim().is_empty()).then_some(result))
}

#[derive(Clone, Debug)]
pub(crate) struct ShelfMetadata {
    pub name: String,
    pub id: gix::hash::ObjectId,
    pub timestamp: i64,
    pub description: String,
    pub recycled: bool,
    pub to_delete: bool,
    pub deleted: bool,
}

fn restore_snapshot_file(repo: &gix::Repository) -> std::path::PathBuf {
    repo.git_dir().join(RESTORE_SNAPSHOT_FILE)
}

fn restore_snapshot_tmp_file(repo: &gix::Repository) -> std::path::PathBuf {
    repo.git_dir().join(RESTORE_SNAPSHOT_TMP_FILE)
}

fn temporary_index_snapshot_file(repo: &gix::Repository) -> std::path::PathBuf {
    repo.git_dir().join(TEMPORARY_INDEX_SNAPSHOT_FILE)
}

fn temporary_index_snapshot_tmp_file(repo: &gix::Repository) -> std::path::PathBuf {
    repo.git_dir().join(TEMPORARY_INDEX_SNAPSHOT_TMP_FILE)
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        result.push(HEX[(byte >> 4) as usize] as char);
        result.push(HEX[(byte & 0x0f) as usize] as char);
    }
    result
}

fn hex_decode(value: &str) -> Result<Vec<u8>, EngineError> {
    let bytes = value.as_bytes();
    if bytes.len() % 2 != 0 {
        return Err(EngineError::GitOperation {
            message: "shelve restore snapshot has invalid hex data".into(),
        });
    }
    let mut result = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let high = (pair[0] as char).to_digit(16);
        let low = (pair[1] as char).to_digit(16);
        let (Some(high), Some(low)) = (high, low) else {
            return Err(EngineError::GitOperation {
                message: "shelve restore snapshot has invalid hex data".into(),
            });
        };
        result.push(((high << 4) | low) as u8);
    }
    Ok(result)
}

fn snapshot_path_to_string(bytes: &[u8]) -> Result<String, EngineError> {
    String::from_utf8(bytes.to_vec()).map_err(|_| EngineError::GitOperation {
        message: "shelve restore snapshot contains a non-UTF-8 path".into(),
    })
}

pub(crate) fn capture_index_entries_for_paths(
    repo: &gix::Repository,
    paths: &[String],
) -> Result<Vec<IndexSnapshotEntry>, EngineError> {
    let selected: std::collections::HashSet<&str> = paths.iter().map(String::as_str).collect();
    let index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    Ok(index
        .entries()
        .iter()
        .filter_map(|entry| {
            let path = entry.path(&index).to_str_lossy().into_owned();
            selected
                .contains(path.as_str())
                .then_some(IndexSnapshotEntry {
                    path,
                    id: entry.id,
                    mode: entry.mode.bits(),
                    flags: entry.flags.bits(),
                })
        })
        .collect())
}

pub(crate) fn write_temporary_index_snapshot(
    repo: &gix::Repository,
    name: &str,
    paths: &[String],
    index_entries: &[IndexSnapshotEntry],
) -> Result<(), EngineError> {
    let mut text = String::new();
    text.push_str(TEMPORARY_INDEX_SNAPSHOT_MAGIC);
    text.push('\n');
    text.push_str("name=");
    text.push_str(&hex_encode(name.as_bytes()));
    text.push('\n');
    for path in paths {
        text.push_str("path=");
        text.push_str(&hex_encode(path.as_bytes()));
        text.push('\n');
    }
    for entry in index_entries {
        text.push_str("index=");
        text.push_str(&entry.mode.to_string());
        text.push(' ');
        text.push_str(&entry.flags.to_string());
        text.push(' ');
        text.push_str(&entry.id.to_hex().to_string());
        text.push(' ');
        text.push_str(&hex_encode(entry.path.as_bytes()));
        text.push('\n');
    }
    let tmp = temporary_index_snapshot_tmp_file(repo);
    std::fs::write(&tmp, text).map_err(EngineError::from_gix)?;
    std::fs::rename(&tmp, temporary_index_snapshot_file(repo)).map_err(EngineError::from_gix)?;
    Ok(())
}

fn load_temporary_index_snapshot(
    repo: &gix::Repository,
) -> Result<Option<TemporaryIndexSnapshot>, EngineError> {
    let path = temporary_index_snapshot_file(repo);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(EngineError::from_gix(error)),
    };
    let mut lines = text.lines();
    if lines.next() != Some(TEMPORARY_INDEX_SNAPSHOT_MAGIC) {
        return Err(EngineError::GitOperation {
            message: "temporary shelf index snapshot has an unknown format".into(),
        });
    }
    let mut name = None;
    let mut paths = Vec::new();
    let mut index_entries = Vec::new();
    for line in lines {
        if let Some(value) = line.strip_prefix("name=") {
            name = Some(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("path=") {
            paths.push(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("index=") {
            let fields = value.split_once(' ').and_then(|(mode, rest)| {
                rest.split_once(' ')
                    .map(|(flags, rest)| (mode, flags, rest))
            });
            let Some((mode, flags, rest)) = fields else {
                return Err(EngineError::GitOperation {
                    message: "temporary shelf index snapshot has invalid index entry".into(),
                });
            };
            let Some((id, path)) = rest.split_once(' ') else {
                return Err(EngineError::GitOperation {
                    message: "temporary shelf index snapshot has invalid index entry".into(),
                });
            };
            index_entries.push(IndexSnapshotEntry {
                path: snapshot_path_to_string(&hex_decode(path)?)?,
                id: gix::hash::ObjectId::from_hex(id.as_bytes()).map_err(EngineError::from_gix)?,
                mode: mode.parse().map_err(|_| EngineError::GitOperation {
                    message: "temporary shelf index snapshot has invalid mode".into(),
                })?,
                flags: flags.parse().map_err(|_| EngineError::GitOperation {
                    message: "temporary shelf index snapshot has invalid flags".into(),
                })?,
            });
        } else if !line.trim().is_empty() {
            return Err(EngineError::GitOperation {
                message: "temporary shelf index snapshot has an unknown record".into(),
            });
        }
    }
    let Some(name) = name else {
        return Err(EngineError::GitOperation {
            message: "temporary shelf index snapshot is incomplete".into(),
        });
    };
    Ok(Some(TemporaryIndexSnapshot {
        name,
        paths,
        index_entries,
    }))
}

pub(crate) fn has_temporary_index_snapshot(repo: &gix::Repository) -> Result<bool, EngineError> {
    Ok(load_temporary_index_snapshot(repo)?.is_some())
}

pub(crate) fn clear_temporary_index_snapshot(repo: &gix::Repository) -> Result<(), EngineError> {
    for path in [
        temporary_index_snapshot_file(repo),
        temporary_index_snapshot_tmp_file(repo),
    ] {
        match std::fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(EngineError::from_gix(error)),
        }
    }
    Ok(())
}

pub(crate) fn restore_temporary_index_snapshot(
    repo: &gix::Repository,
    name: &str,
) -> Result<bool, EngineError> {
    let Some(snapshot) = load_temporary_index_snapshot(repo)? else {
        return Ok(false);
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "temporary shelf index snapshot belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
    clear_temporary_index_snapshot(repo)?;
    Ok(true)
}

fn write_restore_snapshot(
    repo: &gix::Repository,
    snapshot: &ShelveRestoreSnapshot,
) -> Result<(), EngineError> {
    let mut text = String::new();
    text.push_str(RESTORE_SNAPSHOT_MAGIC);
    text.push('\n');
    text.push_str("name=");
    text.push_str(&hex_encode(snapshot.name.as_bytes()));
    text.push('\n');
    text.push_str("pop=");
    text.push_str(if snapshot.is_pop { "1" } else { "0" });
    text.push('\n');
    text.push_str("remove_applied=");
    text.push_str(if snapshot.remove_applied { "1" } else { "0" });
    text.push('\n');
    if let Some(target_change_list) = &snapshot.target_change_list {
        text.push_str("target_change_list=");
        text.push_str(&hex_encode(target_change_list.as_bytes()));
        text.push('\n');
    }
    if let Some(patch) = &snapshot.patch {
        text.push_str("patch=");
        text.push_str(&hex_encode(patch.as_bytes()));
        text.push('\n');
    }
    if snapshot.is_direct_patch {
        text.push_str("direct_patch=1\n");
    }
    if snapshot.differentiated_apply {
        text.push_str("differentiated=1\n");
    }
    if let Some(base_path) = &snapshot.patch_base_path {
        text.push_str("patch_base=");
        text.push_str(&hex_encode(base_path.as_bytes()));
        text.push('\n');
    }
    text.push_str("patch_strip=");
    text.push_str(&snapshot.patch_path_strip.to_string());
    text.push('\n');
    for path in &snapshot.applied_paths {
        text.push_str("applied=");
        text.push_str(&hex_encode(path.as_bytes()));
        text.push('\n');
    }
    for path in &snapshot.failed_paths {
        text.push_str("failed=");
        text.push_str(&hex_encode(path.as_bytes()));
        text.push('\n');
    }
    for path in &snapshot.conflict_paths {
        text.push_str("conflict=");
        text.push_str(&hex_encode(path.as_bytes()));
        text.push('\n');
    }
    for hunk in &snapshot.resolved_hunks {
        text.push_str("hunk=");
        text.push_str(&hex_encode(hunk.path.as_bytes()));
        text.push(' ');
        text.push_str(&hunk.hunk_index.to_string());
        text.push(' ');
        text.push_str(&hex_encode(hunk.resolution.as_bytes()));
        text.push('\n');
    }
    text.push_str("tree=");
    text.push_str(&snapshot.worktree_tree.to_hex().to_string());
    text.push('\n');
    for path in &snapshot.paths {
        text.push_str("path=");
        text.push_str(&hex_encode(path.as_bytes()));
        text.push('\n');
    }
    for entry in &snapshot.index_entries {
        text.push_str("index=");
        text.push_str(&entry.mode.to_string());
        text.push(' ');
        text.push_str(&entry.flags.to_string());
        text.push(' ');
        text.push_str(&entry.id.to_hex().to_string());
        text.push(' ');
        text.push_str(&hex_encode(entry.path.as_bytes()));
        text.push('\n');
    }
    let tmp = restore_snapshot_tmp_file(repo);
    std::fs::write(&tmp, text).map_err(EngineError::from_gix)?;
    std::fs::rename(&tmp, restore_snapshot_file(repo)).map_err(EngineError::from_gix)?;
    Ok(())
}

fn validate_restore_hunk_resolution(resolution: &str) -> Result<(), EngineError> {
    match resolution {
        "applied" | "automatically_applied" | "ignored" => Ok(()),
        _ => Err(EngineError::GitOperation {
            message: format!("shelve restore snapshot has invalid hunk resolution: {resolution}"),
        }),
    }
}

fn load_restore_snapshot(
    repo: &gix::Repository,
) -> Result<Option<ShelveRestoreSnapshot>, EngineError> {
    let path = restore_snapshot_file(repo);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(EngineError::from_gix(error)),
    };
    let mut lines = text.lines();
    if lines.next() != Some(RESTORE_SNAPSHOT_MAGIC) {
        return Err(EngineError::GitOperation {
            message: "shelve restore snapshot has an unknown format".into(),
        });
    }
    let mut name = None;
    let mut is_pop = None;
    let mut remove_applied = false;
    let mut target_change_list = None;
    let mut patch = None;
    let mut is_direct_patch = false;
    let mut differentiated_apply = false;
    let mut applied_paths = Vec::new();
    let mut failed_paths = Vec::new();
    let mut conflict_paths = Vec::new();
    let mut patch_base_path = None;
    let mut patch_path_strip = 1;
    let mut resolved_hunks = Vec::new();
    let mut worktree_tree = None;
    let mut paths = Vec::new();
    let mut index_entries = Vec::new();
    for line in lines {
        if let Some(value) = line.strip_prefix("name=") {
            name = Some(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("pop=") {
            is_pop = Some(match value {
                "0" => false,
                "1" => true,
                _ => {
                    return Err(EngineError::GitOperation {
                        message: "shelve restore snapshot has invalid pop flag".into(),
                    })
                }
            });
        } else if let Some(value) = line.strip_prefix("remove_applied=") {
            remove_applied = match value {
                "0" => false,
                "1" => true,
                _ => {
                    return Err(EngineError::GitOperation {
                        message: "shelve restore snapshot has invalid remove-applied flag".into(),
                    })
                }
            };
        } else if let Some(value) = line.strip_prefix("target_change_list=") {
            target_change_list = Some(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("patch=") {
            patch = Some(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("direct_patch=") {
            is_direct_patch = match value {
                "0" => false,
                "1" => true,
                _ => {
                    return Err(EngineError::GitOperation {
                        message: "shelve restore snapshot has invalid direct-patch flag".into(),
                    })
                }
            };
        } else if let Some(value) = line.strip_prefix("differentiated=") {
            differentiated_apply = match value {
                "0" => false,
                "1" => true,
                _ => {
                    return Err(EngineError::GitOperation {
                        message: "shelve restore snapshot has invalid differentiated flag".into(),
                    })
                }
            };
        } else if let Some(value) = line.strip_prefix("patch_base=") {
            patch_base_path = Some(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("patch_strip=") {
            patch_path_strip = value.parse().map_err(|_| EngineError::GitOperation {
                message: "shelve restore snapshot has invalid patch strip".into(),
            })?;
        } else if let Some(value) = line.strip_prefix("applied=") {
            applied_paths.push(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("failed=") {
            failed_paths.push(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("conflict=") {
            conflict_paths.push(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("hunk=") {
            let mut fields = value.split(' ');
            let Some(path) = fields.next() else {
                return Err(EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid hunk record".into(),
                });
            };
            let Some(index) = fields.next() else {
                return Err(EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid hunk record".into(),
                });
            };
            let Some(resolution) = fields.next() else {
                return Err(EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid hunk record".into(),
                });
            };
            if fields.next().is_some() {
                return Err(EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid hunk record".into(),
                });
            }
            let path = snapshot_path_to_string(&hex_decode(path)?)?;
            let resolution = snapshot_path_to_string(&hex_decode(resolution)?)?;
            validate_restore_hunk_resolution(&resolution)?;
            resolved_hunks.push(ShelveRestoreHunkResolution {
                path,
                hunk_index: index.parse().map_err(|_| EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid hunk index".into(),
                })?,
                resolution,
            });
        } else if let Some(value) = line.strip_prefix("tree=") {
            worktree_tree = Some(
                gix::hash::ObjectId::from_hex(value.as_bytes()).map_err(EngineError::from_gix)?,
            );
        } else if let Some(value) = line.strip_prefix("path=") {
            paths.push(snapshot_path_to_string(&hex_decode(value)?)?);
        } else if let Some(value) = line.strip_prefix("index=") {
            let fields = value.split_once(' ').and_then(|(mode, rest)| {
                rest.split_once(' ')
                    .map(|(flags, rest)| (mode, flags, rest))
            });
            let Some((mode, flags, rest)) = fields else {
                return Err(EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid index entry".into(),
                });
            };
            let Some((id, path)) = rest.split_once(' ') else {
                return Err(EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid index entry".into(),
                });
            };
            index_entries.push(IndexSnapshotEntry {
                path: snapshot_path_to_string(&hex_decode(path)?)?,
                id: gix::hash::ObjectId::from_hex(id.as_bytes()).map_err(EngineError::from_gix)?,
                mode: mode.parse().map_err(|_| EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid mode".into(),
                })?,
                flags: flags.parse().map_err(|_| EngineError::GitOperation {
                    message: "shelve restore snapshot has invalid flags".into(),
                })?,
            });
        } else if !line.trim().is_empty() {
            return Err(EngineError::GitOperation {
                message: "shelve restore snapshot has an unknown record".into(),
            });
        }
    }
    let (Some(name), Some(is_pop), Some(worktree_tree)) = (name, is_pop, worktree_tree) else {
        return Err(EngineError::GitOperation {
            message: "shelve restore snapshot is incomplete".into(),
        });
    };
    if let Some(hunk) = resolved_hunks
        .iter()
        .find(|hunk| !paths.iter().any(|path| path == &hunk.path))
    {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve restore snapshot hunk path is not pending: {}",
                hunk.path
            ),
        });
    }
    Ok(Some(ShelveRestoreSnapshot {
        name,
        is_pop,
        remove_applied,
        paths,
        target_change_list,
        patch,
        is_direct_patch,
        differentiated_apply,
        applied_paths,
        failed_paths,
        conflict_paths,
        patch_base_path,
        patch_path_strip,
        resolved_hunks,
        worktree_tree,
        index_entries,
    }))
}

pub(crate) fn clear_restore_snapshot(repo: &gix::Repository) -> Result<(), EngineError> {
    for path in [restore_snapshot_file(repo), restore_snapshot_tmp_file(repo)] {
        match std::fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(EngineError::from_gix(error)),
        }
    }
    Ok(())
}

/// Persist the target local Changelist after an unshelve enters conflict.
/// Applying a shelf remains independent from UI state; this only updates the
/// already-written restore snapshot.
pub(crate) fn set_restore_target(
    repo: &gix::Repository,
    name: &str,
    target_change_list: &str,
) -> Result<(), EngineError> {
    let Some(mut snapshot) = load_restore_snapshot(repo)? else {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no pending restore for {name}"),
        });
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    let target_change_list = target_change_list.trim();
    if target_change_list.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: target Changelist must not be empty".into(),
        });
    }
    snapshot.target_change_list = Some(target_change_list.to_string());
    write_restore_snapshot(repo, &snapshot)
}

/// Persist one resolved hunk decision for a paused restore. The operation is
/// deliberately path/index keyed so multiple conflict files can update the
/// same restore snapshot independently.
pub(crate) fn set_restore_hunk_resolution(
    repo: &gix::Repository,
    name: &str,
    path: &str,
    hunk_index: u32,
    resolution: &str,
) -> Result<(), EngineError> {
    validate_restore_hunk_resolution(resolution)?;
    let Some(mut snapshot) = load_restore_snapshot(repo)? else {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no pending restore for {name}"),
        });
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    if !snapshot.paths.iter().any(|candidate| candidate == path) {
        return Err(EngineError::GitOperation {
            message: format!("shelve: restore path is not pending: {path}"),
        });
    }
    if let Some(existing) = snapshot
        .resolved_hunks
        .iter_mut()
        .find(|item| item.path == path && item.hunk_index == hunk_index)
    {
        existing.resolution = resolution.to_string();
    } else {
        snapshot.resolved_hunks.push(ShelveRestoreHunkResolution {
            path: path.to_string(),
            hunk_index,
            resolution: resolution.to_string(),
        });
    }
    write_restore_snapshot(repo, &snapshot)
}

/// Clear the persisted hunk decisions for one file after Reset or a fresh
/// conflict reload. Decisions for other files in the same restore remain.
pub(crate) fn clear_restore_hunk_resolutions(
    repo: &gix::Repository,
    name: &str,
    path: &str,
) -> Result<(), EngineError> {
    let Some(mut snapshot) = load_restore_snapshot(repo)? else {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no pending restore for {name}"),
        });
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    snapshot.resolved_hunks.retain(|item| item.path != path);
    write_restore_snapshot(repo, &snapshot)
}

pub(crate) fn restore_info(
    repo: &gix::Repository,
) -> Result<Option<ShelveRestoreInfo>, EngineError> {
    Ok(
        load_restore_snapshot(repo)?.map(|snapshot| ShelveRestoreInfo {
            name: snapshot.name,
            is_pop: snapshot.is_pop,
            remove_applied: snapshot.remove_applied,
            paths: snapshot.paths,
            target_change_list: snapshot.target_change_list,
            patch: snapshot.patch,
            is_direct_patch: snapshot.is_direct_patch,
            applied_paths: snapshot.applied_paths,
            failed_paths: snapshot.failed_paths,
            conflict_paths: snapshot.conflict_paths,
            resolved_hunks: snapshot.resolved_hunks,
        }),
    )
}

/// ref 名消毒：空白/`~^:?*[\`/斜杠/控制字符 -> `-`。
/// Return source-patch members that remain successful after a differentiated
/// raw Shelf restore pauses for conflict resolution. Ordinary failed members
/// are persisted separately and stay in the Shelf remainder.
pub(crate) fn differentiated_restore_source_paths(
    repo: &gix::Repository,
    name: &str,
) -> Result<Option<Vec<String>>, EngineError> {
    let Some(snapshot) = load_restore_snapshot(repo)? else {
        return Ok(None);
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    if !snapshot.differentiated_apply {
        return Ok(None);
    }
    let patch = snapshot
        .patch
        .as_deref()
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: differentiated restore snapshot has no patch".into(),
        })?;
    let mut applied_targets = snapshot.applied_paths.clone();
    // The member that paused the differentiated apply is not recorded as
    // applied until the user resolves it. Members after that point were never
    // attempted and must remain in the Shelf remainder.
    applied_targets.extend(snapshot.conflict_paths.iter().cloned());
    applied_targets.sort();
    applied_targets.dedup();
    source_paths_for_applied_target_paths(
        patch,
        None,
        &applied_targets,
        snapshot.patch_base_path.as_deref(),
        snapshot.patch_path_strip,
    )
    .map(Some)
}

pub(crate) fn sanitize_ref_name(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_whitespace() || c.is_control() || "~^:?*[\\/".contains(c) {
                '-'
            } else {
                c
            }
        })
        .collect()
}

/// 读 shelf 列表（新→旧）。
pub(crate) fn load_shelves(
    repo: &gix::Repository,
) -> Result<Vec<(String, gix::hash::ObjectId)>, EngineError> {
    load_shelves_from(&shelves_file(repo))
}

pub(crate) fn load_deleted_shelves(
    repo: &gix::Repository,
) -> Result<Vec<(String, gix::hash::ObjectId)>, EngineError> {
    load_shelves_from(&deleted_shelves_file(repo))
}

fn load_shelves_from(
    path: &std::path::Path,
) -> Result<Vec<(String, gix::hash::ObjectId)>, EngineError> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for line in text.lines() {
        // New entries use a tab so shelf names may contain spaces. The
        // fallback keeps the original space-delimited format readable.
        let Some((name, id_hex)) = line.split_once('\t').or_else(|| line.rsplit_once(' ')) else {
            continue;
        };
        if let Ok(id) = gix::hash::ObjectId::from_hex(id_hex.as_bytes()) {
            out.push((name.to_string(), id));
        }
    }
    Ok(out)
}

pub(crate) fn save_shelves(
    repo: &gix::Repository,
    list: &[(String, gix::hash::ObjectId)],
) -> Result<(), EngineError> {
    save_shelves_to(&shelves_file(repo), list)
}

pub(crate) fn save_deleted_shelves(
    repo: &gix::Repository,
    list: &[(String, gix::hash::ObjectId)],
) -> Result<(), EngineError> {
    save_shelves_to(&deleted_shelves_file(repo), list)
}

fn save_shelves_to(
    path: &std::path::Path,
    list: &[(String, gix::hash::ObjectId)],
) -> Result<(), EngineError> {
    let mut text = String::new();
    for (name, id) in list {
        text.push_str(&format!("{}\t{}\n", name, id.to_hex()));
    }
    std::fs::write(path, text).map_err(EngineError::from_gix)?;
    Ok(())
}

/// Read optional Shelf metadata without making the legacy list files
/// unreadable. The metadata file is deliberately separate: existing users can
/// upgrade without a format migration, and a damaged metadata record falls
/// back to the patch commit timestamp and name.
pub(crate) fn load_shelf_metadata(
    repo: &gix::Repository,
) -> Result<Vec<ShelfMetadata>, EngineError> {
    let path = shelf_metadata_file(repo);
    let Ok(text) = std::fs::read_to_string(path) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for line in text.lines() {
        let mut fields = line.split('\t');
        let (Some(name_hex), Some(id_hex), Some(timestamp), Some(description_hex)) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let recycled = fields.next().is_some_and(|value| value == "1");
        let to_delete = fields.next().is_some_and(|value| value == "1");
        let deleted = fields.next().is_some_and(|value| value == "1");
        if fields.next().is_some() {
            continue;
        }
        let Ok(name_bytes) = hex_decode(name_hex) else {
            continue;
        };
        let Ok(name) = String::from_utf8(name_bytes) else {
            continue;
        };
        let Ok(description_bytes) = hex_decode(description_hex) else {
            continue;
        };
        let Ok(description) = String::from_utf8(description_bytes) else {
            continue;
        };
        let Ok(id) = gix::hash::ObjectId::from_hex(id_hex.as_bytes()) else {
            continue;
        };
        let Ok(timestamp) = timestamp.parse::<i64>() else {
            continue;
        };
        out.push(ShelfMetadata {
            name,
            id,
            timestamp,
            description,
            recycled,
            to_delete,
            deleted,
        });
    }
    Ok(out)
}

pub(crate) fn save_shelf_metadata(
    repo: &gix::Repository,
    metadata: &[ShelfMetadata],
) -> Result<(), EngineError> {
    let mut text = String::new();
    for item in metadata {
        text.push_str(&hex_encode(item.name.as_bytes()));
        text.push('\t');
        text.push_str(&item.id.to_hex().to_string());
        text.push('\t');
        text.push_str(&item.timestamp.to_string());
        text.push('\t');
        text.push_str(&hex_encode(item.description.as_bytes()));
        text.push('\t');
        text.push(if item.recycled { '1' } else { '0' });
        text.push('\t');
        text.push(if item.to_delete { '1' } else { '0' });
        text.push('\t');
        text.push(if item.deleted { '1' } else { '0' });
        text.push('\n');
    }
    let path = shelf_metadata_file(repo);
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text).map_err(EngineError::from_gix)?;
    std::fs::rename(tmp, path).map_err(EngineError::from_gix)?;
    Ok(())
}

pub(crate) fn upsert_shelf_metadata(
    repo: &gix::Repository,
    name: &str,
    id: gix::hash::ObjectId,
    timestamp: i64,
    description: &str,
) -> Result<(), EngineError> {
    let mut metadata = load_shelf_metadata(repo)?;
    metadata.retain(|item| item.name != name);
    metadata.insert(
        0,
        ShelfMetadata {
            name: name.to_string(),
            id,
            timestamp,
            description: description.to_string(),
            recycled: false,
            to_delete: false,
            deleted: false,
        },
    );
    save_shelf_metadata(repo, &metadata)
}

pub(crate) fn set_shelf_metadata_state(
    repo: &gix::Repository,
    name: &str,
    recycled: bool,
    to_delete: bool,
    deleted: bool,
) -> Result<(), EngineError> {
    let mut metadata = load_shelf_metadata(repo)?;
    if let Some(item) = metadata.iter_mut().find(|item| item.name == name) {
        item.recycled = recycled;
        item.to_delete = to_delete;
        item.deleted = deleted;
        save_shelf_metadata(repo, &metadata)?;
    }
    Ok(())
}

pub(crate) fn remove_shelf_metadata(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    let mut metadata = load_shelf_metadata(repo)?;
    let original_len = metadata.len();
    metadata.retain(|item| item.name != name);
    if metadata.len() != original_len {
        save_shelf_metadata(repo, &metadata)?;
    }
    Ok(())
}

pub(crate) fn rename_shelf_metadata(
    repo: &gix::Repository,
    old_name: &str,
    new_name: &str,
    id: gix::hash::ObjectId,
    fallback_timestamp: i64,
    fallback_description: &str,
) -> Result<(), EngineError> {
    let mut metadata = load_shelf_metadata(repo)?;
    if let Some(item) = metadata.iter_mut().find(|item| item.name == old_name) {
        item.name = new_name.to_string();
        item.id = id;
        item.description = fallback_description.to_string();
    } else {
        metadata.insert(
            0,
            ShelfMetadata {
                name: new_name.to_string(),
                id,
                timestamp: fallback_timestamp,
                description: fallback_description.to_string(),
                recycled: false,
                to_delete: false,
                deleted: false,
            },
        );
    }
    save_shelf_metadata(repo, &metadata)
}

fn read_worktree_entry(
    file_path: &std::path::Path,
) -> Result<Option<(Vec<u8>, gix::index::entry::Mode)>, EngineError> {
    use gix::index::entry::Mode;
    use std::os::unix::fs::PermissionsExt;

    let metadata = match std::fs::symlink_metadata(file_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(EngineError::from_gix(error)),
    };
    if metadata.file_type().is_symlink() {
        let target = std::fs::read_link(file_path).map_err(EngineError::from_gix)?;
        return Ok(Some((
            target.to_string_lossy().into_owned().into_bytes(),
            Mode::SYMLINK,
        )));
    }
    if !metadata.is_file() {
        return Ok(None);
    }
    let data = std::fs::read(file_path).map_err(EngineError::from_gix)?;
    let mode = if metadata.permissions().mode() & 0o111 != 0 {
        Mode::FILE_EXECUTABLE
    } else {
        Mode::FILE
    };
    Ok(Some((data, mode)))
}

/// 构建补丁树：HEAD 树 + 指定路径的工作区内容（工作区缺失 = 从树中移除）。
pub(crate) fn build_patch_tree(
    repo: &gix::Repository,
    paths: &[String],
) -> Result<gix::hash::ObjectId, EngineError> {
    for path in paths {
        crate::repo::worktree_relative_path(path)?;
    }
    let head_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    let mut editor = repo.edit_tree(head_tree).map_err(EngineError::from_gix)?;
    for path in paths {
        let path_bstr = path.as_bytes().as_bstr();
        let file_path = workdir.join(path);
        if let Some((data, mode)) = read_worktree_entry(&file_path)? {
            let blob = repo
                .write_blob(&data)
                .map_err(EngineError::from_gix)?
                .detach();
            let kind = crate::index::mode_to_kind(mode);
            editor
                .upsert(path_bstr, kind, blob)
                .map_err(EngineError::from_gix)?;
        } else {
            // 工作区已删除：从补丁树移除（补丁 = 删除）
            editor.remove(path_bstr).map_err(EngineError::from_gix)?;
        }
    }
    Ok(editor.write().map_err(EngineError::from_gix)?.detach())
}

/// 把某路径重置回 HEAD（工作区写 HEAD 内容/删除 + 索引条目回 HEAD）。
/// 供 shelve 保存后清空工作区用。
pub(crate) fn reset_path_to_head(repo: &gix::Repository, path: &str) -> Result<(), EngineError> {
    use gix::index::entry::{Flags, Stage, Stat};
    crate::repo::worktree_relative_path(path)?;
    let head_tree = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let head_entry = repo
        .find_tree(head_tree)
        .map_err(EngineError::from_gix)?
        .lookup_entry_by_path(path)
        .map_err(EngineError::from_gix)?;
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    let file_path = workdir.join(path);
    let path_bstr = path.as_bytes().as_bstr();
    let mut index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();

    match head_entry {
        Some(entry) if entry.mode().is_blob_or_symlink() => {
            let blob_id = entry.object_id();
            let mode = index_mode(entry.mode());
            // 写 HEAD 内容到工作区 + 索引条目回 HEAD
            let data = blob_bytes(repo, blob_id, "reset path to HEAD")?;
            if let Some(parent) = file_path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            write_worktree_entry(workdir, path_bstr, &data, mode)?;
            let meta = gix::index::fs::Metadata::from_path_no_follow(&file_path)
                .map_err(EngineError::from_gix)?;
            let stat = Stat::from_fs(&meta).map_err(EngineError::from_gix)?;
            match index.entry_index_by_path_and_stage(path_bstr, Stage::Unconflicted) {
                Some(i) => {
                    let e = &mut index.entries_mut()[i];
                    e.id = blob_id;
                    e.stat = stat;
                    e.mode = mode;
                }
                None => {
                    index.dangerously_push_entry(stat, blob_id, Flags::empty(), mode, path_bstr);
                    index.sort_entries();
                }
            }
        }
        Some(_) => {
            return Err(EngineError::GitOperation {
                message: format!("shelve: HEAD path is not a file: {path}"),
            });
        }
        None => {
            // HEAD 无此路径（新增文件）：删工作区文件 + 删索引条目
            let _ = std::fs::remove_file(&file_path);
            while let Some(i) = index.entry_index_by_path_and_stage(path_bstr, Stage::Unconflicted)
            {
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

pub(crate) fn apply_shelve_with_options(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
) -> Result<Vec<String>, EngineError> {
    apply_shelve_with_options_from_collection(repo, patch_id, name, is_pop, remove_applied, false)
}

/// Apply a patch that lives in Recently Deleted. The patch and ref remain in
/// that collection unless the caller explicitly removes applied members.
pub(crate) fn apply_deleted_shelve_with_options(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
) -> Result<Vec<String>, EngineError> {
    apply_shelve_with_options_from_collection(repo, patch_id, name, is_pop, remove_applied, true)
}

fn apply_shelve_with_options_from_collection(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
    is_deleted: bool,
) -> Result<Vec<String>, EngineError> {
    if let Some(bytes) = read_shelf_patch(repo, name, is_deleted)? {
        let patch = String::from_utf8(bytes).map_err(|_| EngineError::GitOperation {
            message: format!("shelve: imported patch for {name} is not UTF-8"),
        })?;
        return apply_raw_shelve(
            repo,
            &patch,
            name,
            is_pop,
            remove_applied,
            None,
            None,
            None,
            false,
        );
    }
    let patch = repo.find_commit(patch_id).map_err(EngineError::from_gix)?;
    let parent_id = patch
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: patch has no parent".into(),
        })?
        .detach();
    let parent = repo.find_commit(parent_id).map_err(EngineError::from_gix)?;
    let parent_tree = parent.tree_id().map_err(EngineError::from_gix)?.detach();
    let patch_tree = patch.tree_id().map_err(EngineError::from_gix)?.detach();
    let visible_paths = crate::tree::diff_trees(repo, parent_tree, patch_tree)?
        .into_iter()
        .map(|change| change.path)
        .collect::<Vec<_>>();
    if visible_paths.is_empty() {
        return Ok(Vec::new());
    }
    let expanded = selected_shelf_paths(repo, parent_tree, patch_tree, &visible_paths)?;
    apply_shelve_three_way(
        repo,
        parent_tree,
        patch_tree,
        &expanded,
        name,
        is_pop,
        remove_applied,
    )
}

pub(crate) fn apply_shelve_paths_with_options(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    paths: &[String],
    name: &str,
    remove_applied: bool,
) -> Result<Vec<String>, EngineError> {
    apply_shelve_paths_with_options_from_collection(
        repo,
        patch_id,
        paths,
        name,
        remove_applied,
        false,
        None,
        None,
    )
}

/// Apply selected members from an imported patch relative to a mapped base
/// directory. Revision-backed shelves deliberately reject a non-empty base
/// mapping instead of silently applying it at the repository root.
pub(crate) fn apply_shelve_paths_with_options_and_base(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    paths: &[String],
    name: &str,
    remove_applied: bool,
    base_path: &str,
    path_strip: u32,
) -> Result<Vec<String>, EngineError> {
    apply_shelve_paths_with_options_from_collection(
        repo,
        patch_id,
        paths,
        name,
        remove_applied,
        false,
        Some(base_path),
        Some(path_strip),
    )
}

/// Apply selected members from a Recently Deleted shelf while keeping the
/// deleted-list lifecycle unless the caller explicitly removes applied files.
pub(crate) fn apply_deleted_shelve_paths_with_options(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    paths: &[String],
    name: &str,
    remove_applied: bool,
) -> Result<Vec<String>, EngineError> {
    apply_shelve_paths_with_options_from_collection(
        repo,
        patch_id,
        paths,
        name,
        remove_applied,
        true,
        None,
        None,
    )
}

/// Apply selected members from an imported Recently Deleted patch relative
/// to a mapped base directory.
pub(crate) fn apply_deleted_shelve_paths_with_options_and_base(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    paths: &[String],
    name: &str,
    remove_applied: bool,
    base_path: &str,
    path_strip: u32,
) -> Result<Vec<String>, EngineError> {
    apply_shelve_paths_with_options_from_collection(
        repo,
        patch_id,
        paths,
        name,
        remove_applied,
        true,
        Some(base_path),
        Some(path_strip),
    )
}

fn apply_shelve_paths_with_options_from_collection(
    repo: &gix::Repository,
    patch_id: gix::hash::ObjectId,
    paths: &[String],
    name: &str,
    remove_applied: bool,
    is_deleted: bool,
    base_path: Option<&str>,
    path_strip: Option<u32>,
) -> Result<Vec<String>, EngineError> {
    let path_strip_value = path_strip.unwrap_or(1);
    if paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: select at least one change to unshelve".into(),
        });
    }
    if let Some(bytes) = read_shelf_patch(repo, name, is_deleted)? {
        let patch = String::from_utf8(bytes).map_err(|_| EngineError::GitOperation {
            message: format!("shelve: imported patch for {name} is not UTF-8"),
        })?;
        return apply_raw_shelve(
            repo,
            &patch,
            name,
            false,
            remove_applied,
            Some(paths),
            base_path,
            Some(path_strip_value),
            false,
        );
    }
    if base_path
        .map(str::trim)
        .is_some_and(|path| !path.is_empty())
        || path_strip_value != 1
    {
        return Err(EngineError::GitOperation {
            message: "shelve: base directory mapping is only available for imported patches".into(),
        });
    }
    let patch = repo.find_commit(patch_id).map_err(EngineError::from_gix)?;
    let parent_id = patch
        .parent_ids()
        .next()
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: patch has no parent".into(),
        })?
        .detach();
    let parent_tree = repo
        .find_commit(parent_id)
        .map_err(EngineError::from_gix)?
        .tree_id()
        .map_err(EngineError::from_gix)?
        .detach();
    let patch_tree = patch.tree_id().map_err(EngineError::from_gix)?.detach();
    let expanded = selected_shelf_paths(repo, parent_tree, patch_tree, paths)?;
    apply_shelve_three_way(
        repo,
        parent_tree,
        patch_tree,
        &expanded,
        name,
        false,
        remove_applied,
    )
}

/// Validate visible shelf members and expand a selected rename to both tree
/// endpoints. Keeping this in the engine gives unshelve and member-level Drop
/// identical path semantics, including traversal and duplicate rejection.
pub(crate) fn selected_shelf_paths(
    repo: &gix::Repository,
    parent_tree: gix::hash::ObjectId,
    patch_tree: gix::hash::ObjectId,
    paths: &[String],
) -> Result<Vec<String>, EngineError> {
    if paths.is_empty() {
        return Err(EngineError::GitOperation {
            message: "shelve: select at least one change".into(),
        });
    }
    let changes = crate::tree::diff_trees(repo, parent_tree, patch_tree)?;
    let mut selected = std::collections::HashSet::new();
    let mut expanded = Vec::new();
    for path in paths {
        crate::repo::worktree_relative_path(path)?;
        if !selected.insert(path.clone()) {
            return Err(EngineError::GitOperation {
                message: format!("shelve: selected path appears more than once: {path}"),
            });
        }
        let Some(change) = changes.iter().find(|change| {
            change.path == *path || change.old_path.as_deref() == Some(path.as_str())
        }) else {
            return Err(EngineError::GitOperation {
                message: format!("shelve: selected path is not in the shelf: {path}"),
            });
        };
        expanded.push(change.path.clone());
        if let Some(old_path) = &change.old_path {
            expanded.push(old_path.clone());
        }
    }
    expanded.sort();
    expanded.dedup();
    Ok(expanded)
}

/// Build a tree that starts at the shelf parent and overlays the current
/// worktree for only the paths being applied. This lets the normal tree merge
/// machinery preserve staged/unstaged local content without treating the
/// entire repository as part of an unshelve operation.
fn worktree_overlay_tree(
    repo: &gix::Repository,
    parent_tree: gix::hash::ObjectId,
    paths: &[String],
    workdir: &std::path::Path,
) -> Result<gix::hash::ObjectId, EngineError> {
    let mut editor = repo.edit_tree(parent_tree).map_err(EngineError::from_gix)?;
    let total = paths.len().max(1);
    for (index, path) in paths.iter().enumerate() {
        crate::repo::worktree_relative_path(path)?;
        let file_path = workdir.join(path);
        if let Some((data, mode)) = read_worktree_entry(&file_path)? {
            let blob = repo
                .write_blob(&data)
                .map_err(EngineError::from_gix)?
                .detach();
            let kind = crate::index::mode_to_kind(mode);
            editor
                .upsert(path.as_bytes().as_bstr(), kind, blob)
                .map_err(EngineError::from_gix)?;
        } else {
            editor
                .remove(path.as_bytes().as_bstr())
                .map_err(EngineError::from_gix)?;
        }
        crate::gitprocess::update_active_operation_progress(
            "shelve",
            "Preparing local changes".to_string(),
            Some(shelf_progress_percentage(index + 1, total) / 4),
            path.clone(),
        );
    }
    editor
        .write()
        .map(|tree| tree.detach())
        .map_err(EngineError::from_gix)
}

fn capture_restore_snapshot(
    repo: &gix::Repository,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
    paths: &[String],
) -> Result<ShelveRestoreSnapshot, EngineError> {
    if load_restore_snapshot(repo)?.is_some() {
        return Err(EngineError::GitOperation {
            message: "shelve: another restore is waiting for completion or rollback".into(),
        });
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve restore requires a non-bare worktree".into(),
    })?;
    let worktree_tree = worktree_overlay_tree(repo, repo.empty_tree().id, paths, workdir)?;
    let selected: std::collections::HashSet<&str> = paths.iter().map(String::as_str).collect();
    let index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    let index_entries = index
        .entries()
        .iter()
        .filter_map(|entry| {
            let path = entry.path(&index).to_str_lossy().into_owned();
            selected
                .contains(path.as_str())
                .then_some(IndexSnapshotEntry {
                    path,
                    id: entry.id,
                    mode: entry.mode.bits(),
                    flags: entry.flags.bits(),
                })
        })
        .collect();
    Ok(ShelveRestoreSnapshot {
        name: name.to_string(),
        is_pop,
        remove_applied,
        paths: paths.to_vec(),
        target_change_list: None,
        patch: None,
        is_direct_patch: false,
        differentiated_apply: false,
        applied_paths: Vec::new(),
        failed_paths: Vec::new(),
        conflict_paths: Vec::new(),
        patch_base_path: None,
        patch_path_strip: 1,
        resolved_hunks: Vec::new(),
        worktree_tree,
        index_entries,
    })
}

fn remove_index_path_entries(index: &mut gix::index::File, path: &str) {
    let path = path.as_bytes().as_bstr();
    let indexes = index
        .entries()
        .iter()
        .enumerate()
        .filter_map(|(position, entry)| (entry.path(index) == path).then_some(position))
        .collect::<Vec<_>>();
    for position in indexes.into_iter().rev() {
        index.remove_entry_at_index(position);
    }
}

fn restore_index_snapshot(
    repo: &gix::Repository,
    paths: &[String],
    entries: &[IndexSnapshotEntry],
) -> Result<(), EngineError> {
    use gix::index::entry::{Flags, Mode, Stat};

    let mut index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    for path in paths {
        remove_index_path_entries(&mut index, path);
    }
    for entry in entries {
        index.dangerously_push_entry(
            Stat::default(),
            entry.id,
            Flags::from_bits_retain(entry.flags),
            Mode::from_bits_retain(entry.mode),
            entry.path.as_bytes().as_bstr(),
        );
    }
    index.sort_entries();
    index.remove_tree();
    index
        .write(gix::index::write::Options::default())
        .map_err(EngineError::from_gix)?;
    Ok(())
}

/// Restore only one failed direct-patch member from the operation snapshot.
/// The full snapshot remains on disk until every member has been attempted or
/// a real conflict pauses the operation.
fn restore_patch_paths(
    repo: &gix::Repository,
    snapshot: &ShelveRestoreSnapshot,
    paths: &[String],
) -> Result<(), EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve restore requires a non-bare worktree".into(),
    })?;
    let current_tree = worktree_overlay_tree(repo, repo.empty_tree().id, paths, workdir)?;
    materialize_tree_paths(repo, current_tree, snapshot.worktree_tree, workdir, paths)?;
    let selected: std::collections::HashSet<&str> = paths.iter().map(String::as_str).collect();
    let index_entries = snapshot
        .index_entries
        .iter()
        .filter(|entry| selected.contains(entry.path.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    restore_index_snapshot(repo, paths, &index_entries)
}

fn conflict_paths(repo: &gix::Repository) -> Result<Vec<String>, EngineError> {
    Ok(crate::status::compute_status(repo)?
        .into_iter()
        .filter(|entry| {
            entry.staged == crate::status::ChangeKind::Conflicted
                || entry.unstaged == crate::status::ChangeKind::Conflicted
        })
        .map(|entry| entry.path)
        .collect())
}

fn raw_apply_output(
    repo: &gix::Repository,
    patch: &str,
    three_way: bool,
    directory: Option<&str>,
    path_strip: u32,
) -> Result<crate::gitprocess::GitProcessOutcome, EngineError> {
    raw_apply_output_with_cancel(repo, patch, three_way, directory, path_strip, None)
}

fn raw_apply_output_with_cancel(
    repo: &gix::Repository,
    patch: &str,
    three_way: bool,
    directory: Option<&str>,
    path_strip: u32,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<crate::gitprocess::GitProcessOutcome, EngineError> {
    use std::io::Write;

    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve restore requires a non-bare worktree".into(),
    })?;
    let mut patch_file = tempfile::NamedTempFile::new().map_err(EngineError::from_gix)?;
    patch_file
        .write_all(patch.as_bytes())
        .map_err(EngineError::from_gix)?;
    let mut spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Other,
        "apply",
    )
    .args(["--binary", "--whitespace=nowarn"])
    .flag_if("--3way", three_way)
    .arg(format!("-p{path_strip}"));
    if let Some(directory) = directory {
        spec = spec.arg(format!("--directory={directory}"));
    }
    spec = spec
        .arg(patch_file.path().to_string_lossy().into_owned())
        .working_dir(workdir.to_path_buf());
    crate::gitprocess::run(&spec, cancel, |_| {})
}

/// `git apply --3way` requires the index to match the current worktree. A
/// direct Apply Patch operation is intentionally allowed to run over local
/// unstaged edits, so temporarily stage only the affected paths; the restore
/// snapshot puts the original index back after a clean apply or completion.
fn stage_direct_patch_paths(
    repo: &gix::Repository,
    paths: &[String],
    indexed_paths: &[String],
) -> Result<(), EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve restore requires a non-bare worktree".into(),
    })?;
    let stage_paths = paths
        .iter()
        .filter(|path| {
            workdir.join(path).symlink_metadata().is_ok()
                || indexed_paths.iter().any(|indexed| indexed == *path)
        })
        .collect::<Vec<_>>();
    if stage_paths.is_empty() {
        return Ok(());
    }
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command
        .args(["add", "--all", "--"])
        .args(stage_paths)
        .current_dir(workdir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let output = command.output().map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: could not prepare direct patch paths: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(())
}

fn raw_apply_check_output(
    repo: &gix::Repository,
    patch: &str,
    reverse: bool,
    directory: Option<&str>,
    path_strip: u32,
) -> Result<std::process::Output, EngineError> {
    use std::io::Write;
    use std::process::Stdio;

    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve restore requires a non-bare worktree".into(),
    })?;
    let mut command = crate::gitprocess::git_command_for_working_dir(workdir);
    command.args(["apply", "--check", "--whitespace=nowarn"]);
    if reverse {
        command.arg("--reverse");
    }
    command.arg(format!("-p{path_strip}"));
    if let Some(directory) = directory {
        command.arg(format!("--directory={directory}"));
    }
    let mut child = command
        .current_dir(workdir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(EngineError::from_gix)?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| EngineError::GitOperation {
            message: "shelve: could not open patch check input".into(),
        })?;
    stdin
        .write_all(patch.as_bytes())
        .map_err(EngineError::from_gix)?;
    drop(stdin);
    child.wait_with_output().map_err(EngineError::from_gix)
}

fn patch_change_has_unsupported_fragment_metadata(prefix: &str) -> bool {
    prefix.lines().any(|line| {
        [
            "GIT binary patch",
            "Binary files ",
            "old mode ",
            "new mode ",
            "new file mode ",
            "deleted file mode ",
            "similarity index ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to ",
        ]
        .iter()
        .any(|prefix| line.starts_with(prefix))
    })
}

fn patch_hunk_has_text_change(block: &str) -> bool {
    block.lines().any(|line| {
        line.as_bytes()
            .first()
            .is_some_and(|prefix| *prefix == b'+' || *prefix == b'-')
    })
}

struct FilteredPatch {
    patch: String,
    already_applied_paths: std::collections::BTreeSet<String>,
    partial_paths: std::collections::BTreeSet<String>,
}

/// Remove only text hunks that Git itself confirms are already applied in the
/// current worktree. Checking each hunk in both directions is more precise
/// than comparing whole files and preserves normal Git conflict handling for
/// anything ambiguous. Binary, rename, and mode-only changes stay untouched.
fn filter_already_applied_hunks_with_status(
    repo: &gix::Repository,
    patch: &str,
    directory: Option<&str>,
    path_strip: u32,
) -> Result<FilteredPatch, EngineError> {
    let changes = parse_patch_changes(patch)?;
    let mut filtered = String::new();
    let mut already_applied_paths = std::collections::BTreeSet::new();
    let mut partial_paths = std::collections::BTreeSet::new();
    for change in changes {
        let (prefix, blocks) = patch_hunk_blocks(&change);
        if blocks.is_empty() || patch_change_has_unsupported_fragment_metadata(&prefix) {
            filtered.push_str(&change.chunk);
            continue;
        }

        let mut kept_blocks = String::new();
        let mut has_already_applied_hunk = false;
        let mut has_remaining_hunk = false;
        for block in blocks {
            if !patch_hunk_has_text_change(&block) {
                kept_blocks.push_str(&block);
                has_remaining_hunk = true;
                continue;
            }
            let fragment = format!("{prefix}{block}");
            let forward = raw_apply_check_output(repo, &fragment, false, directory, path_strip)?;
            if forward.status.success() {
                kept_blocks.push_str(&block);
                has_remaining_hunk = true;
                continue;
            }
            let reverse = raw_apply_check_output(repo, &fragment, true, directory, path_strip)?;
            if !reverse.status.success() {
                kept_blocks.push_str(&block);
                has_remaining_hunk = true;
            } else {
                has_already_applied_hunk = true;
            }
        }
        if has_already_applied_hunk {
            let mapped_paths = map_patch_paths(&[&change], directory, path_strip)?;
            if has_remaining_hunk {
                partial_paths.extend(mapped_paths);
            } else {
                already_applied_paths.extend(mapped_paths);
            }
        }
        if !kept_blocks.is_empty() {
            filtered.push_str(&prefix);
            filtered.push_str(&kept_blocks);
        }
    }
    Ok(FilteredPatch {
        patch: filtered,
        already_applied_paths,
        partial_paths,
    })
}

fn filter_already_applied_hunks(
    repo: &gix::Repository,
    patch: &str,
    directory: Option<&str>,
    path_strip: u32,
) -> Result<String, EngineError> {
    Ok(filter_already_applied_hunks_with_status(repo, patch, directory, path_strip)?.patch)
}

fn raw_process_output(output: &crate::gitprocess::GitProcessOutcome) -> String {
    if output.stderr.trim().is_empty() {
        output.stdout.trim().to_string()
    } else {
        output.stderr.trim().to_string()
    }
}

fn normalize_patch_base_path(base_path: Option<&str>) -> Result<Option<String>, EngineError> {
    let Some(base_path) = base_path.map(str::trim).filter(|path| !path.is_empty()) else {
        return Ok(None);
    };
    let relative = crate::repo::worktree_relative_path(base_path)?;
    if relative.as_os_str().is_empty() {
        return Ok(None);
    }
    let normalized = relative.to_str().ok_or_else(|| EngineError::GitOperation {
        message: "shelve: patch base directory is not valid UTF-8".into(),
    })?;
    Ok(Some(normalized.to_string()))
}

fn map_patch_paths(
    changes: &[&ParsedPatchChange],
    base_path: Option<&str>,
    path_strip: u32,
) -> Result<Vec<String>, EngineError> {
    let mut mapped = std::collections::BTreeSet::new();
    for change in changes {
        let raw_endpoints = if change.raw_endpoints.is_empty() {
            change.endpoints.clone()
        } else {
            change.raw_endpoints.clone()
        };
        for path in &raw_endpoints {
            let components = path.split('/').collect::<Vec<_>>();
            if components.len() <= path_strip as usize {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "shelve: path strip {path_strip} removes the complete path {path}"
                    ),
                });
            }
            let stripped = components[path_strip as usize..].join("/");
            let mapped_path = base_path
                .filter(|base| !base.is_empty())
                .map(|base| format!("{base}/{stripped}"))
                .unwrap_or(stripped);
            mapped.insert(mapped_path);
        }
    }
    Ok(mapped.into_iter().collect())
}

/// Translate the target paths that were actually applied back to the source
/// patch coordinates used by Shelf lifecycle operations. Imported Shelves may
/// apply below a mapped base directory and with a non-default `-pN`, while
/// remainder/recycled patch bookkeeping must continue to address the original
/// patch members.
pub(crate) fn source_paths_for_applied_target_paths(
    patch: &str,
    requested_paths: Option<&[String]>,
    applied_target_paths: &[String],
    base_path: Option<&str>,
    path_strip: u32,
) -> Result<Vec<String>, EngineError> {
    let applied = applied_target_paths
        .iter()
        .cloned()
        .collect::<std::collections::HashSet<_>>();
    if applied.is_empty() {
        return Ok(Vec::new());
    }
    let requested = requested_paths.map(|paths| {
        paths
            .iter()
            .cloned()
            .collect::<std::collections::HashSet<_>>()
    });
    let base_path = normalize_patch_base_path(base_path)?;
    let changes = parse_patch_changes(patch)?;
    let mut source_paths = std::collections::BTreeSet::new();
    for change in &changes {
        if requested
            .as_ref()
            .is_some_and(|paths| !change.endpoints.iter().any(|path| paths.contains(path)))
        {
            continue;
        }
        let mapped = map_patch_paths(&[change], base_path.as_deref(), path_strip)?;
        if mapped.iter().any(|path| applied.contains(path)) {
            source_paths.extend(change.endpoints.iter().cloned());
        }
    }
    Ok(source_paths.into_iter().collect())
}

/// Keep only the selected text-hunk records whose containing file member was
/// actually applied. A failed file block must remain in the original Shelf
/// remainder even when another selected file succeeded.
pub(crate) fn applied_patch_selections_for_target_paths(
    patch: &str,
    selections: &[ShelvePatchSelection],
    applied_target_paths: &[String],
    base_path: Option<&str>,
    path_strip: u32,
) -> Result<Vec<ShelvePatchSelection>, EngineError> {
    let applied = applied_target_paths
        .iter()
        .cloned()
        .collect::<std::collections::HashSet<_>>();
    let base_path = normalize_patch_base_path(base_path)?;
    let changes = parse_patch_changes(patch)?;
    let mut result = Vec::new();
    for selection in selections {
        let Some(change) = changes
            .iter()
            .find(|change| change.endpoints.contains(&selection.path))
        else {
            return Err(EngineError::GitOperation {
                message: format!(
                    "shelve: selected path is not in the patch: {}",
                    selection.path
                ),
            });
        };
        let mapped = map_patch_paths(&[change], base_path.as_deref(), path_strip)?;
        if mapped.iter().any(|path| applied.contains(path)) {
            result.push(selection.clone());
        }
    }
    Ok(result)
}

/// Apply an imported patch only when it is actually unshelved. The first
/// attempt uses Git's three-way machinery; a plain apply fallback handles
/// external patches that omit blob ids but still apply cleanly by context.
pub(crate) fn apply_raw_shelve(
    repo: &gix::Repository,
    patch: &str,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
    selected_paths: Option<&[String]>,
    base_path: Option<&str>,
    path_strip: Option<u32>,
    is_direct_patch: bool,
) -> Result<Vec<String>, EngineError> {
    let base_path = normalize_patch_base_path(base_path)?;
    let path_strip = path_strip.unwrap_or(1);
    let changes = parse_patch_changes(patch)?;
    let selected_changes = if let Some(paths) = selected_paths {
        let selected: std::collections::HashSet<String> = paths.iter().cloned().collect();
        changes
            .iter()
            .filter(|change| change.endpoints.iter().any(|path| selected.contains(path)))
            .collect::<Vec<_>>()
    } else {
        changes.iter().collect::<Vec<_>>()
    };
    if selected_changes.is_empty() {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no selected changes in {name}"),
        });
    }
    let mapped_paths = map_patch_paths(&selected_changes, base_path.as_deref(), path_strip)?;
    let input = if let Some(selected) = selected_paths {
        select_patch_chunks(patch, selected)?
    } else {
        patch.to_string()
    };
    if !is_direct_patch {
        let result = apply_raw_shelve_differentiated_input(
            repo,
            &input,
            name,
            mapped_paths,
            base_path.as_deref(),
            path_strip,
            is_pop,
            remove_applied,
            false,
            None,
        )?;
        return Ok(result.applied_paths);
    }
    let input = filter_already_applied_hunks(repo, &input, base_path.as_deref(), path_strip)?;
    if input.trim().is_empty() {
        return Ok(mapped_paths);
    }
    let before_conflicts = conflict_paths(repo)?;
    apply_raw_shelve_patch(
        repo,
        &input,
        name,
        is_pop,
        remove_applied,
        &mapped_paths,
        before_conflicts,
        base_path.as_deref(),
        path_strip,
        is_direct_patch,
    )?;
    Ok(mapped_paths)
}

/// Apply an explicitly selected subset of a raw shelf patch. Native shelves
/// use the same path so hunk selection retains Git's `--3way` behavior and
/// imported shelves do not need a second patch implementation.
pub(crate) fn apply_raw_shelve_selections(
    repo: &gix::Repository,
    patch: &str,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
    selections: &[ShelvePatchSelection],
    base_path: Option<&str>,
    path_strip: Option<u32>,
    is_direct_patch: bool,
) -> Result<Vec<String>, EngineError> {
    let base_path = normalize_patch_base_path(base_path)?;
    let path_strip = path_strip.unwrap_or(1);
    let input = select_patch_selections(patch, selections)?;
    let input_changes = parse_patch_changes(&input)?;
    let input_change_refs = input_changes.iter().collect::<Vec<_>>();
    let mapped_paths = map_patch_paths(&input_change_refs, base_path.as_deref(), path_strip)?;
    if !is_direct_patch {
        let result = apply_raw_shelve_differentiated_input(
            repo,
            &input,
            name,
            mapped_paths,
            base_path.as_deref(),
            path_strip,
            is_pop,
            remove_applied,
            false,
            None,
        )?;
        return Ok(result.applied_paths);
    }
    let input = filter_already_applied_hunks(repo, &input, base_path.as_deref(), path_strip)?;
    if input.trim().is_empty() {
        return Ok(mapped_paths);
    }
    let before_conflicts = conflict_paths(repo)?;
    apply_raw_shelve_patch(
        repo,
        &input,
        name,
        is_pop,
        remove_applied,
        &mapped_paths,
        before_conflicts,
        base_path.as_deref(),
        path_strip,
        is_direct_patch,
    )?;
    Ok(mapped_paths)
}

/// Apply an imported patch with IntelliJ's differentiated per-file semantics.
/// Direct Apply and imported Shelf apply share this engine path; the caller
/// selects whether the restore snapshot belongs to a direct patch or a Shelf
/// lifecycle.
pub(crate) fn apply_raw_shelve_differentiated(
    repo: &gix::Repository,
    patch: &str,
    name: &str,
    selected_paths: &[String],
    base_path: Option<&str>,
    path_strip: Option<u32>,
    is_pop: bool,
    remove_applied: bool,
    is_direct_patch: bool,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<crate::repo::PatchApplyResult, EngineError> {
    let changes = parse_patch_changes(patch)?;
    let selected: std::collections::HashSet<String> = selected_paths.iter().cloned().collect();
    let selected_changes = changes
        .iter()
        .filter(|change| change.endpoints.iter().any(|path| selected.contains(path)))
        .collect::<Vec<_>>();
    if selected_changes.is_empty() {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no selected changes in {name}"),
        });
    }
    let path_strip = path_strip.unwrap_or(1);
    let mapped_paths = map_patch_paths(&selected_changes, base_path, path_strip)?;
    let input = select_patch_chunks(patch, selected_paths)?;
    apply_raw_shelve_differentiated_input(
        repo,
        &input,
        name,
        mapped_paths,
        base_path,
        path_strip,
        is_pop,
        remove_applied,
        is_direct_patch,
        cancel,
    )
}

/// Apply selected file/hunk members of a direct imported patch with
/// differentiated per-file results.
pub(crate) fn apply_raw_shelve_selections_differentiated(
    repo: &gix::Repository,
    patch: &str,
    name: &str,
    selections: &[ShelvePatchSelection],
    base_path: Option<&str>,
    path_strip: Option<u32>,
    is_pop: bool,
    remove_applied: bool,
    is_direct_patch: bool,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<crate::repo::PatchApplyResult, EngineError> {
    let input = select_patch_selections(patch, selections)?;
    let input_changes = parse_patch_changes(&input)?;
    let input_change_refs = input_changes.iter().collect::<Vec<_>>();
    let mapped_paths = map_patch_paths(&input_change_refs, base_path, path_strip.unwrap_or(1))?;
    apply_raw_shelve_differentiated_input(
        repo,
        &input,
        name,
        mapped_paths,
        base_path,
        path_strip.unwrap_or(1),
        is_pop,
        remove_applied,
        is_direct_patch,
        cancel,
    )
}

fn apply_raw_shelve_differentiated_input(
    repo: &gix::Repository,
    input: &str,
    name: &str,
    all_mapped_paths: Vec<String>,
    base_path: Option<&str>,
    path_strip: u32,
    is_pop: bool,
    remove_applied: bool,
    is_direct_patch: bool,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<crate::repo::PatchApplyResult, EngineError> {
    let _progress = ShelveApplyProgress::new(name);
    let applied_phase = if is_direct_patch {
        "Patch applied"
    } else {
        "Shelf applied"
    };
    crate::gitprocess::update_active_operation_progress(
        "shelve",
        "Checking patch files".to_string(),
        Some(0),
        name.to_string(),
    );
    let base_path = normalize_patch_base_path(base_path)?;
    let filtered =
        filter_already_applied_hunks_with_status(repo, input, base_path.as_deref(), path_strip)?;
    let filtered_input = filtered.patch;
    if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
        return Ok(aborted_patch_apply_result(
            all_mapped_paths.iter().cloned().collect(),
        ));
    }
    if filtered_input.trim().is_empty() {
        crate::gitprocess::update_active_operation_progress(
            "shelve",
            applied_phase.to_string(),
            Some(100),
            name.to_string(),
        );
        return Ok(patch_apply_result(
            all_mapped_paths.iter().cloned().collect(),
            all_mapped_paths.into_iter().collect(),
            std::collections::BTreeSet::new(),
            filtered.already_applied_paths,
            filtered.partial_paths,
        ));
    }
    let changes = parse_patch_changes(&filtered_input)?;
    let change_refs = changes.iter().collect::<Vec<_>>();
    let attempted_paths = map_patch_paths(&change_refs, base_path.as_deref(), path_strip)?;
    let before_conflicts = conflict_paths(repo)?;
    let (applied_attempts, failed_attempts) = match apply_raw_shelve_patch_differentiated(
        repo,
        &filtered_input,
        name,
        &attempted_paths,
        before_conflicts,
        base_path.as_deref(),
        path_strip,
        is_pop,
        remove_applied,
        is_direct_patch,
        cancel,
    ) {
        Err(EngineError::Cancelled) => {
            return Ok(aborted_patch_apply_result(
                all_mapped_paths.iter().cloned().collect(),
            ));
        }
        Err(error) => return Err(error),
        Ok(result) => result,
    };
    let attempted = attempted_paths
        .iter()
        .cloned()
        .collect::<std::collections::BTreeSet<_>>();
    let all_paths = all_mapped_paths
        .iter()
        .cloned()
        .chain(attempted_paths.iter().cloned())
        .collect::<std::collections::BTreeSet<_>>();
    let mut applied = all_mapped_paths
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();
    for path in attempted {
        applied.remove(&path);
    }
    applied.extend(applied_attempts);
    let failed = failed_attempts
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();
    Ok(patch_apply_result(
        all_paths,
        applied,
        failed,
        filtered.already_applied_paths,
        filtered.partial_paths,
    ))
}

fn apply_raw_shelve_patch_differentiated(
    repo: &gix::Repository,
    input: &str,
    name: &str,
    attempted_paths: &[String],
    before_conflicts: Vec<String>,
    directory: Option<&str>,
    path_strip: u32,
    is_pop: bool,
    remove_applied: bool,
    is_direct_patch: bool,
    cancel: Option<&crate::gitprocess::GitCancelToken>,
) -> Result<(Vec<String>, Vec<String>), EngineError> {
    let mut snapshot =
        capture_restore_snapshot(repo, name, is_pop, remove_applied, attempted_paths)?;
    snapshot.differentiated_apply = true;
    snapshot.patch = Some(input.to_string());
    snapshot.patch_base_path = directory.map(str::to_string);
    snapshot.patch_path_strip = path_strip;
    if is_direct_patch {
        snapshot.is_direct_patch = true;
    }
    write_restore_snapshot(repo, &snapshot)?;
    let indexed_paths = snapshot
        .index_entries
        .iter()
        .map(|entry| entry.path.clone())
        .collect::<Vec<_>>();
    if let Err(error) = stage_direct_patch_paths(repo, attempted_paths, &indexed_paths) {
        let _ = abort_restore(repo, name);
        return Err(error);
    }

    let changes = parse_patch_changes(input)?;
    let total = changes.len().max(1);
    let mut applied = std::collections::BTreeSet::new();
    let mut failed = std::collections::BTreeSet::new();
    let apply_phase = if is_direct_patch {
        "Applying Patch files"
    } else {
        "Applying Shelf files"
    };
    let applied_phase = if is_direct_patch {
        "Patch applied"
    } else {
        "Shelf applied"
    };
    let conflict_phase = if is_direct_patch {
        "Patch conflicts ready"
    } else {
        "Shelf conflicts ready"
    };
    crate::gitprocess::update_active_operation_progress(
        "shelve",
        apply_phase.to_string(),
        Some(0),
        name.to_string(),
    );

    for (index, change) in changes.iter().enumerate() {
        if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
            abort_restore(repo, name)?;
            return Err(EngineError::Cancelled);
        }
        let change_paths = map_patch_paths(&[change], directory, path_strip)?;
        let three_way_output = match raw_apply_output_with_cancel(
            repo,
            &change.chunk,
            true,
            directory,
            path_strip,
            cancel,
        ) {
            Ok(output) => output,
            Err(error) => {
                let _ = abort_restore(repo, name);
                return Err(error);
            }
        };
        if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
            abort_restore(repo, name)?;
            return Err(EngineError::Cancelled);
        }
        if three_way_output.success() {
            applied.extend(change_paths.iter().cloned());
            snapshot.applied_paths.extend(change_paths.iter().cloned());
            snapshot.applied_paths.sort();
            snapshot.applied_paths.dedup();
            write_restore_snapshot(repo, &snapshot)?;
            crate::gitprocess::update_active_operation_progress(
                "shelve",
                apply_phase.to_string(),
                Some(shelf_progress_percentage(index + 1, total)),
                change.path.clone(),
            );
            continue;
        }
        let after_three_way_conflicts = conflict_paths(repo)?;
        let new_conflicts = after_three_way_conflicts
            .iter()
            .filter(|path| !before_conflicts.contains(path))
            .cloned()
            .collect::<Vec<_>>();
        if !new_conflicts.is_empty() {
            snapshot.conflict_paths = new_conflicts.clone();
            write_restore_snapshot(repo, &snapshot)?;
            crate::gitprocess::update_active_operation_progress(
                "shelve",
                conflict_phase.to_string(),
                Some(100),
                new_conflicts
                    .first()
                    .cloned()
                    .unwrap_or_else(|| name.to_string()),
            );
            return Err(EngineError::ShelveApplyConflict {
                name: name.to_string(),
                paths: new_conflicts,
            });
        }
        if let Err(error) = restore_patch_paths(repo, &snapshot, &change_paths) {
            let _ = abort_restore(repo, name);
            return Err(error);
        }

        let plain_output = match raw_apply_output_with_cancel(
            repo,
            &change.chunk,
            false,
            directory,
            path_strip,
            cancel,
        ) {
            Ok(output) => output,
            Err(error) => {
                let _ = abort_restore(repo, name);
                return Err(error);
            }
        };
        if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
            abort_restore(repo, name)?;
            return Err(EngineError::Cancelled);
        }
        if plain_output.success() {
            applied.extend(change_paths.iter().cloned());
            snapshot.applied_paths.extend(change_paths.iter().cloned());
            snapshot.applied_paths.sort();
            snapshot.applied_paths.dedup();
        } else {
            let after_plain_conflicts = conflict_paths(repo)?;
            let new_conflicts = after_plain_conflicts
                .iter()
                .filter(|path| !before_conflicts.contains(path))
                .cloned()
                .collect::<Vec<_>>();
            if !new_conflicts.is_empty() {
                snapshot.conflict_paths = new_conflicts.clone();
                write_restore_snapshot(repo, &snapshot)?;
                crate::gitprocess::update_active_operation_progress(
                    "shelve",
                    conflict_phase.to_string(),
                    Some(100),
                    new_conflicts
                        .first()
                        .cloned()
                        .unwrap_or_else(|| name.to_string()),
                );
                return Err(EngineError::ShelveApplyConflict {
                    name: name.to_string(),
                    paths: new_conflicts,
                });
            }
            if let Err(error) = restore_patch_paths(repo, &snapshot, &change_paths) {
                let _ = abort_restore(repo, name);
                return Err(error);
            }
            failed.extend(change_paths.iter().cloned());
            snapshot.failed_paths.extend(change_paths.iter().cloned());
            snapshot.failed_paths.sort();
            snapshot.failed_paths.dedup();
        }
        write_restore_snapshot(repo, &snapshot)?;
        crate::gitprocess::update_active_operation_progress(
            "shelve",
            apply_phase.to_string(),
            Some(shelf_progress_percentage(index + 1, total)),
            change.path.clone(),
        );
    }

    if cancel.is_some_and(crate::gitprocess::GitCancelToken::is_cancelled) {
        abort_restore(repo, name)?;
        return Err(EngineError::Cancelled);
    }

    restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
    clear_restore_snapshot(repo)?;
    crate::gitprocess::update_active_operation_progress(
        "shelve",
        applied_phase.to_string(),
        Some(100),
        name.to_string(),
    );
    Ok((applied.into_iter().collect(), failed.into_iter().collect()))
}

fn apply_raw_shelve_patch(
    repo: &gix::Repository,
    input: &str,
    name: &str,
    is_pop: bool,
    remove_applied: bool,
    paths: &[String],
    before_conflicts: Vec<String>,
    directory: Option<&str>,
    path_strip: u32,
    is_direct_patch: bool,
) -> Result<Vec<String>, EngineError> {
    let mut snapshot = capture_restore_snapshot(repo, name, is_pop, remove_applied, &paths)?;
    if is_direct_patch {
        snapshot.patch = Some(input.to_string());
        snapshot.is_direct_patch = true;
    }
    write_restore_snapshot(repo, &snapshot)?;
    if is_direct_patch {
        let indexed_paths = snapshot
            .index_entries
            .iter()
            .map(|entry| entry.path.clone())
            .collect::<Vec<_>>();
        if let Err(error) = stage_direct_patch_paths(repo, paths, &indexed_paths) {
            let _ = abort_restore(repo, name);
            return Err(error);
        }
    }

    let three_way_output = raw_apply_output(repo, &input, true, directory, path_strip)?;
    if three_way_output.success() {
        restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
        clear_restore_snapshot(repo)?;
        return Ok(paths.to_vec());
    }
    let after_three_way_conflicts = conflict_paths(repo)?;
    let new_conflicts = after_three_way_conflicts
        .iter()
        .filter(|path| !before_conflicts.contains(path))
        .cloned()
        .collect::<Vec<_>>();
    if !new_conflicts.is_empty() {
        return Err(EngineError::ShelveApplyConflict {
            name: name.to_string(),
            paths: new_conflicts,
        });
    }
    abort_restore(repo, name)?;

    // Retry from the exact pre-apply state. A patch without `index` blob
    // metadata cannot use Git's three-way fallback, but can still be a valid
    // clean context patch.
    let mut snapshot = capture_restore_snapshot(repo, name, is_pop, remove_applied, &paths)?;
    if is_direct_patch {
        snapshot.patch = Some(input.to_string());
        snapshot.is_direct_patch = true;
    }
    write_restore_snapshot(repo, &snapshot)?;
    if is_direct_patch {
        let indexed_paths = snapshot
            .index_entries
            .iter()
            .map(|entry| entry.path.clone())
            .collect::<Vec<_>>();
        if let Err(error) = stage_direct_patch_paths(repo, paths, &indexed_paths) {
            let _ = abort_restore(repo, name);
            return Err(error);
        }
    }
    let plain_output = raw_apply_output(repo, &input, false, directory, path_strip)?;
    if plain_output.success() {
        restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
        clear_restore_snapshot(repo)?;
        return Ok(paths.to_vec());
    }
    let after_plain_conflicts = conflict_paths(repo)?;
    let new_conflicts = after_plain_conflicts
        .iter()
        .filter(|path| !before_conflicts.contains(path))
        .cloned()
        .collect::<Vec<_>>();
    if !new_conflicts.is_empty() {
        return Err(EngineError::ShelveApplyConflict {
            name: name.to_string(),
            paths: new_conflicts,
        });
    }
    abort_restore(repo, name)?;
    Err(EngineError::GitOperation {
        message: format!(
            "shelve: imported patch could not be applied: {}",
            raw_process_output(&plain_output)
        ),
    })
}

pub(crate) fn abort_restore(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    let Some(snapshot) = load_restore_snapshot(repo)? else {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no pending restore for {name}"),
        });
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "shelve rollback requires a non-bare worktree".into(),
    })?;
    let current_tree = worktree_overlay_tree(repo, repo.empty_tree().id, &snapshot.paths, workdir)?;
    materialize_tree_paths(
        repo,
        current_tree,
        snapshot.worktree_tree,
        workdir,
        &snapshot.paths,
    )?;

    restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
    clear_restore_snapshot(repo)?;
    Ok(())
}

/// Finish a raw imported-patch restore after conflicts were resolved. Unlike
/// a Shelf restore there is no changelist/ref to finalize; the original index
/// boundary is restored and the apply snapshot is then removed.
pub(crate) fn complete_raw_restore(repo: &gix::Repository, name: &str) -> Result<(), EngineError> {
    let Some(snapshot) = load_restore_snapshot(repo)? else {
        return Err(EngineError::GitOperation {
            message: format!("shelve: no pending restore for {name}"),
        });
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    let conflicts = conflict_paths(repo)?;
    if !conflicts.is_empty() {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: unresolved conflicts remain: {}",
                conflicts.join(", ")
            ),
        });
    }
    restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
    clear_restore_snapshot(repo)?;
    Ok(())
}

/// Restore the pre-apply index boundary after a differentiated Shelf conflict
/// is resolved. The raw patch executor stages affected worktree files only to
/// make Git's three-way conflict detection reliable; the user's original
/// staged/unstaged split must survive completion.
pub(crate) fn restore_differentiated_index_snapshot(
    repo: &gix::Repository,
    name: &str,
) -> Result<bool, EngineError> {
    let Some(snapshot) = load_restore_snapshot(repo)? else {
        return Ok(false);
    };
    if snapshot.name != name {
        return Err(EngineError::GitOperation {
            message: format!(
                "shelve: pending restore belongs to '{}', not '{name}'",
                snapshot.name
            ),
        });
    }
    if !snapshot.differentiated_apply {
        return Ok(false);
    }
    restore_index_snapshot(repo, &snapshot.paths, &snapshot.index_entries)?;
    Ok(true)
}

/// Apply a shelf as a three-way merge: shelf parent is the base, the current
/// worktree is ours, and the shelf tree is theirs. Clean changes stay
/// unstaged, while conflicts get normal index stages and marker content so the
/// existing Merge Revisions workbench can resolve them. The shelf itself is
/// never removed here; shelve pop only removes it after a successful apply.
fn apply_shelve_three_way(
    repo: &gix::Repository,
    parent_tree: gix::hash::ObjectId,
    patch_tree: gix::hash::ObjectId,
    paths: &[String],
    name: &str,
    is_pop: bool,
    remove_applied: bool,
) -> Result<Vec<String>, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    let _progress = ShelveApplyProgress::new(name);
    let ours_tree = worktree_overlay_tree(repo, parent_tree, paths, workdir)?;
    let snapshot = capture_restore_snapshot(repo, name, is_pop, remove_applied, paths)?;
    let labels = gix::merge::blob::builtin_driver::text::Labels {
        ancestor: Some(BStr::new("shelf parent")),
        current: Some(BStr::new("local changes")),
        other: Some(BStr::new("shelf")),
    };
    let options = repo.tree_merge_options().map_err(EngineError::from_gix)?;
    let mut outcome = repo
        .merge_trees(parent_tree, ours_tree, patch_tree, labels, options)
        .map_err(EngineError::from_gix)?;
    let merged_tree = outcome
        .tree
        .write()
        .map_err(EngineError::from_gix)?
        .detach();
    let conflicts = outcome
        .conflicts
        .iter()
        .filter(|conflict| {
            conflict
                .content_merge()
                .map(|merge| merge.resolution == gix::merge::blob::Resolution::Conflict)
                .unwrap_or(true)
        })
        .map(|conflict| {
            let entries = conflict.entries();
            ConflictEntry {
                path: conflict.ours.location().to_str_lossy().into_owned(),
                entries: entries.map(|entry| entry.map(|e| (e.id, e.mode))),
            }
        })
        .collect::<Vec<_>>();

    if !conflicts.is_empty() {
        use gix::index::entry::{Flags, Stage, Stat};

        let mut index = repo
            .index_or_load_from_head_or_empty()
            .map_err(EngineError::from_gix)?
            .into_owned();
        for conflict in &conflicts {
            let path = conflict.path.as_bytes().as_bstr();
            crate::merge::remove_conflict_stages(&mut index, path);
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
                        crate::merge::index_mode(*mode),
                        path,
                    );
                }
            }
        }
        index.sort_entries();
        index.remove_tree();
        index
            .write(gix::index::write::Options::default())
            .map_err(EngineError::from_gix)?;
    }

    // Persist the pre-apply worktree and index before touching disk. This is
    // what makes a conflict cancelable and recoverable after an app restart.
    write_restore_snapshot(repo, &snapshot)?;
    crate::gitprocess::update_active_operation_progress(
        "shelve",
        "Applying Shelf files".to_string(),
        Some(25),
        name.to_string(),
    );
    if let Err(error) = materialize_tree_paths(repo, ours_tree, merged_tree, workdir, paths) {
        return Err(error);
    }
    if conflicts.is_empty() {
        crate::gitprocess::update_active_operation_progress(
            "shelve",
            "Shelf applied".to_string(),
            Some(100),
            name.to_string(),
        );
        clear_restore_snapshot(repo)?;
        Ok(paths.to_vec())
    } else {
        crate::gitprocess::update_active_operation_progress(
            "shelve",
            "Shelf conflicts ready".to_string(),
            Some(100),
            conflicts
                .first()
                .map(|conflict| conflict.path.clone())
                .unwrap_or_else(|| name.to_string()),
        );
        Err(EngineError::ShelveApplyConflict {
            name: name.to_string(),
            paths: conflicts
                .into_iter()
                .map(|conflict| conflict.path)
                .collect(),
        })
    }
}

#[cfg(test)]
mod patch_selection_tests {
    use super::{
        aggregate_patch_apply_status, remove_patch_selections, select_patch_selections,
        ShelvePatchSelection,
    };
    use crate::PatchApplyStatus;

    const TWO_HUNK_PATCH: &str = concat!(
        "diff --git a/file.txt b/file.txt\n",
        "index 1111111..2222222 100644\n",
        "--- a/file.txt\n",
        "+++ b/file.txt\n",
        "@@ -1,2 +1,2 @@\n",
        " before\n",
        "-old one\n",
        "+new one\n",
        "@@ -10,2 +10,2 @@\n",
        " context\n",
        "-old two\n",
        "+new two\n",
    );

    #[test]
    fn selects_one_hunk_and_keeps_the_other_in_the_shelf() {
        let selection = ShelvePatchSelection {
            path: "file.txt".into(),
            hunk_index: Some(1),
        };
        let selected = select_patch_selections(TWO_HUNK_PATCH, &[selection.clone()]).unwrap();
        assert!(!selected.contains("new one"));
        assert!(selected.contains("new two"));

        let remaining = remove_patch_selections(TWO_HUNK_PATCH, &[selection])
            .unwrap()
            .unwrap();
        assert!(remaining.contains("new one"));
        assert!(!remaining.contains("new two"));
    }

    #[test]
    fn whole_file_selection_is_valid_for_binary_patch_without_hunks() {
        let patch = concat!(
            "diff --git a/image.bin b/image.bin\n",
            "index 1111111..2222222 100644\n",
            "GIT binary patch\n",
            "literal 3\n",
            "abc\n",
        );
        let whole = ShelvePatchSelection {
            path: "image.bin".into(),
            hunk_index: None,
        };
        assert_eq!(select_patch_selections(patch, &[whole]).unwrap(), patch);
    }

    #[test]
    fn binary_patch_rejects_hunk_selection() {
        let patch = concat!(
            "diff --git a/image.bin b/image.bin\n",
            "GIT binary patch\n",
            "literal 3\n",
            "abc\n",
        );
        let hunk = ShelvePatchSelection {
            path: "image.bin".into(),
            hunk_index: Some(0),
        };
        let error = select_patch_selections(patch, &[hunk]).unwrap_err();
        assert!(error.to_string().contains("no selectable text hunks"));
    }

    #[test]
    fn patch_apply_status_aggregation_matches_intellij_order() {
        assert_eq!(
            aggregate_patch_apply_status(&[PatchApplyStatus::Skip]),
            PatchApplyStatus::Skip
        );
        assert_eq!(
            aggregate_patch_apply_status(&[PatchApplyStatus::Success, PatchApplyStatus::Skip]),
            PatchApplyStatus::Success
        );
        assert_eq!(
            aggregate_patch_apply_status(&[
                PatchApplyStatus::Success,
                PatchApplyStatus::AlreadyApplied,
            ]),
            PatchApplyStatus::Partial
        );
        assert_eq!(
            aggregate_patch_apply_status(&[
                PatchApplyStatus::AlreadyApplied,
                PatchApplyStatus::Failure,
            ]),
            PatchApplyStatus::Failure
        );
    }
}

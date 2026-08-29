//! CONFLICT-001：统一冲突工作台。
//!
//! 从 merge / rebase / cherry-pick / revert 进入同一工作台：
//! - `ConflictWorkspace`：进行中的操作类别（opstate::detect）+ 未解决冲突
//!   文件列表（三方内容 + 冲突块 + 二进制降级标记）；
//! - 文件级操作：accept ours / theirs / both（写工作区 + 清 stages + 索引
//!   stage 0，二进制安全）、mark resolved（resolve_edited 语义）、
//!   reset（从 index stages 重新物化 marker，恢复冲突现场）；
//! - 解决一个文件后 `conflict_workspace()` 的列表即不含它；全部解决后
//!   UI 展示对应操作的 continue（OPS-001 恢复命令）。

use gix::bstr::{BStr, ByteSlice};
use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use crate::error::EngineError;
use crate::merge::ConflictFile;
use crate::opstate::OperationKind;

const RESOLVED_LEDGER: &str = "arbor-resolved-conflicts";
const RESOLVED_LEDGER_TMP: &str = "arbor-resolved-conflicts.tmp";

#[derive(Clone, Debug)]
struct ResolvedLedgerEntry {
    path: String,
    /// The exact stage 1/2/3 index records captured before resolution.
    /// Keeping these records makes RevertResolved independent of the
    /// operation backend and of how many rebase actions remain.
    index_entries: Vec<String>,
}

/// 文件级接受方向（IntelliJ Accept Yours/Theirs/Both）。
#[derive(uniffi::Enum, Clone, Copy, Debug)]
pub enum FilePick {
    Ours,
    Theirs,
    Both,
}

/// 冲突工作台中的一个文件（含二进制降级标记）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ConflictWorkspaceFile {
    pub path: String,
    /// 任一侧 stage 是二进制：blocks 恒为空，UI 走手动编辑或外部工具策略。
    pub binary: bool,
    pub file: ConflictFile,
}

/// 统一冲突工作台。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ConflictWorkspace {
    /// 进行中的操作；None 表示冲突现场独立存在（状态文件缺失等）。
    pub operation: Option<OperationKind>,
    /// 当前未解决冲突文件（解决一个即移除）。
    pub files: Vec<ConflictWorkspaceFile>,
    /// 当前操作中已经解决、但尚未 continue/abort 的文件。
    /// 这些路径用于复刻 IntelliJ 的 Revert Resolved action。
    pub resolved_files: Vec<String>,
}

/// 构建统一冲突工作台：从 status 的 Conflicted 条目 + index stages。
pub(crate) fn build_workspace(repo: &gix::Repository) -> Result<ConflictWorkspace, EngineError> {
    let operation = crate::opstate::detect(repo)?.map(|state| state.kind);
    let status = crate::status::compute_status(repo)?;
    let conflicted_paths: HashSet<String> = status
        .iter()
        .filter(|entry| {
            entry.staged == crate::status::ChangeKind::Conflicted
                || entry.unstaged == crate::status::ChangeKind::Conflicted
        })
        .map(|entry| entry.path.clone())
        .collect();
    let mut files = Vec::new();
    for entry in status {
        let conflicted = entry.staged == crate::status::ChangeKind::Conflicted
            || entry.unstaged == crate::status::ChangeKind::Conflicted;
        if !conflicted {
            continue;
        }
        let (binary, file) = read_conflict_file(repo, &entry.path)?;
        files.push(ConflictWorkspaceFile {
            path: entry.path,
            binary,
            file,
        });
    }
    let mut resolved_files = if operation.is_some() {
        load_resolved_paths(repo)?
    } else {
        clear_resolved_ledger(repo);
        Vec::new()
    };
    resolved_files.retain(|path| !conflicted_paths.contains(path));
    resolved_files.sort();
    Ok(ConflictWorkspace {
        operation,
        files,
        resolved_files,
    })
}

/// Record that a path has moved from an unmerged index entry to a resolved
/// stage-0 entry during the current Git operation. IntelliJ keeps this in its
/// conflict manager; Arbor stores the small ledger under `.git` so a refresh
/// or reopening the conflict workbench does not lose the action target.
pub(crate) fn mark_resolved(
    repo: &gix::Repository,
    path: &str,
    index_entries: Vec<String>,
) -> Result<(), EngineError> {
    let Some(signature) = operation_signature(repo) else {
        return Ok(());
    };
    let mut entries = load_resolved_entries_for_signature(repo, &signature)?;
    if !entries.iter().any(|existing| existing.path == path) {
        entries.push(ResolvedLedgerEntry {
            path: path.to_string(),
            index_entries,
        });
        write_resolved_entries(repo, &signature, &entries)?;
    }
    Ok(())
}

pub(crate) fn remove_resolved(repo: &gix::Repository, path: &str) -> Result<(), EngineError> {
    let Some(signature) = operation_signature(repo) else {
        return Ok(());
    };
    let mut entries = load_resolved_entries_for_signature(repo, &signature)?;
    let original_len = entries.len();
    entries.retain(|existing| existing.path != path);
    if entries.len() != original_len {
        if entries.is_empty() {
            clear_resolved_ledger(repo);
        } else {
            write_resolved_entries(repo, &signature, &entries)?;
        }
    }
    Ok(())
}

/// Clear the current operation's resolved-file ledger after continue/abort.
/// This is intentionally crate-visible so all recovery entry points share the
/// same lifecycle boundary.
pub(crate) fn clear_resolved_ledger(repo: &gix::Repository) {
    let _ = std::fs::remove_file(repo.git_dir().join(RESOLVED_LEDGER));
    let _ = std::fs::remove_file(repo.git_dir().join(RESOLVED_LEDGER_TMP));
}

/// Recreate a resolved file's conflict state using Git's native `checkout -m`
/// behavior, matching IntelliJ GitMergeUtil.revertMergedFiles.
pub(crate) fn revert_resolved(repo: &gix::Repository, path: &str) -> Result<(), EngineError> {
    let relative = crate::repo::worktree_relative_path(path)?;
    let relative = relative.to_string_lossy().into_owned();
    let entries = load_resolved_entries(repo)?;
    let Some(entry) = entries.iter().find(|entry| entry.path == relative) else {
        return Err(EngineError::GitOperation {
            message: format!("revert resolved: path is not a resolved conflict: {relative}"),
        });
    };
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "revert resolved requires a non-bare worktree".into(),
    })?;
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Merge,
        "checkout",
    )
    .args(["-m".to_string(), "--".to_string(), relative.clone()])
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    if !has_unmerged_path(repo, &relative)? {
        if !entry.index_entries.is_empty() {
            restore_index_entries(repo, workdir, &relative, &entry.index_entries)?;
            let restore_markers = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Merge,
                "checkout",
            )
            .args(["-m".to_string(), "--".to_string(), relative.clone()])
            .working_dir(workdir);
            let marker_outcome = crate::gitprocess::run_to_completion(&restore_markers)?;
            if !marker_outcome.success() {
                return Err(marker_outcome.into_error(&restore_markers));
            }
        } else if let Some((base, ours, theirs)) = conflict_tree_spec(repo, workdir)? {
            restore_unmerged_path(repo, workdir, &base, &ours, &theirs, &relative)?;
            let restore_markers = crate::gitprocess::GitCommandSpec::new(
                crate::gitprocess::GitCommandCategory::Merge,
                "checkout",
            )
            .args(["-m".to_string(), "--".to_string(), relative.clone()])
            .working_dir(workdir);
            let marker_outcome = crate::gitprocess::run_to_completion(&restore_markers)?;
            if !marker_outcome.success() {
                return Err(marker_outcome.into_error(&restore_markers));
            }
        }
    }
    let is_conflicted = has_unmerged_path(repo, &relative)?;
    if !is_conflicted {
        let status_spec = crate::gitprocess::GitCommandSpec::new(
            crate::gitprocess::GitCommandCategory::Status,
            "status",
        )
        .args(["--porcelain=v1".to_string()])
        .working_dir(workdir);
        let status = crate::gitprocess::run_to_completion(&status_spec)
            .map(|result| format!("{}{}", result.stdout, result.stderr))
            .unwrap_or_else(|error| error.to_string());
        return Err(EngineError::GitOperation {
            message: format!(
                "revert resolved: Git did not recreate an unmerged entry for {relative}; status: {}",
                status.trim()
            ),
        });
    }
    remove_resolved(repo, &relative)
}

/// Reconstruct only one path's stage 1/2/3 entries without replacing the
/// user's other resolved paths. `git read-tree -m` has no pathspec form, so it
/// is run against a temporary index and the selected entries are copied back
/// with `git update-index --index-info`.
fn restore_unmerged_path(
    repo: &gix::Repository,
    workdir: &Path,
    base: &str,
    ours: &str,
    theirs: &str,
    path: &str,
) -> Result<(), EngineError> {
    if path.contains('\n') || path.contains('\0') {
        return Err(EngineError::GitOperation {
            message: "revert resolved does not support newline-containing paths".into(),
        });
    }
    let temporary_index = repo.git_dir().join(format!(
        "arbor-revert-resolved-index-{}.tmp",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&temporary_index);
    let result = (|| -> Result<Vec<String>, EngineError> {
        let mut read_tree = crate::gitprocess::git_command_for_working_dir(workdir);
        let output = read_tree
            .args(["read-tree", "-m", base, ours, theirs])
            .env("GIT_INDEX_FILE", &temporary_index)
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git read-tree failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        let mut list = crate::gitprocess::git_command_for_working_dir(workdir);
        let output = list
            .args(["ls-files", "--stage", "-z", "--", path])
            .env("GIT_INDEX_FILE", &temporary_index)
            .current_dir(workdir)
            .output()
            .map_err(EngineError::from_gix)?;
        if !output.status.success() {
            return Err(EngineError::GitOperation {
                message: format!(
                    "git ls-files failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            });
        }
        let entries = output
            .stdout
            .split(|byte| *byte == 0)
            .filter_map(|record| {
                let record = String::from_utf8_lossy(record);
                let (metadata, entry_path) = record.split_once('\t')?;
                (entry_path == path).then(|| format!("{metadata}\t{entry_path}"))
            })
            .collect::<Vec<_>>();
        if entries.is_empty() {
            return Err(EngineError::GitOperation {
                message: format!("git read-tree produced no index entries for {path}"),
            });
        }
        Ok(entries)
    })();
    let _ = std::fs::remove_file(&temporary_index);
    let entries = result?;

    restore_index_entries(repo, workdir, path, &entries)
}

fn restore_index_entries(
    _repo: &gix::Repository,
    workdir: &Path,
    path: &str,
    entries: &[String],
) -> Result<(), EngineError> {
    let mut remove = crate::gitprocess::git_command_for_working_dir(workdir);
    let output = remove
        .args(["update-index", "--force-remove", "--", path])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git update-index remove failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }

    let mut update = crate::gitprocess::git_command_for_working_dir(workdir);
    let mut child = update
        .args(["update-index", "--index-info"])
        .current_dir(workdir)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(EngineError::from_gix)?;
    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| EngineError::GitOperation {
                message: "git update-index did not open stdin".into(),
            })?;
        let input = entries.join("\n") + "\n";
        stdin
            .write_all(input.as_bytes())
            .map_err(EngineError::from_gix)?;
    }
    let output = child.wait_with_output().map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git update-index --index-info failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(())
}

fn has_unmerged_path(repo: &gix::Repository, path: &str) -> Result<bool, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "status requires a non-bare worktree".into(),
    })?;
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Status,
        "status",
    )
    .args([
        "--porcelain=v1".to_string(),
        "--".to_string(),
        path.to_string(),
    ])
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    Ok(outcome.stdout.lines().any(|line| {
        let bytes = line.as_bytes();
        bytes.len() >= 2
            && (bytes[0] == b'U'
                || bytes[1] == b'U'
                || bytes.starts_with(b"AA")
                || bytes.starts_with(b"DD"))
    }))
}

fn conflict_tree_spec(
    repo: &gix::Repository,
    workdir: &Path,
) -> Result<Option<(String, String, String)>, EngineError> {
    let git_dir = repo.git_dir();
    let ours = git_rev(workdir, &["rev-parse", "HEAD"])?;
    if let Some(theirs) = read_trimmed(&git_dir.join("MERGE_HEAD")) {
        let base = git_rev(workdir, &["merge-base", "HEAD", &theirs])?;
        return Ok(Some((base, ours, theirs)));
    }
    for marker in ["CHERRY_PICK_HEAD", "REBASE_HEAD", "REVERT_HEAD"] {
        if let Some(theirs) = read_trimmed(&git_dir.join(marker)) {
            let parent = format!("{theirs}^");
            let base = git_rev(workdir, &["rev-parse", &parent])?;
            if marker == "REVERT_HEAD" {
                return Ok(Some((theirs, ours, base)));
            } else {
                return Ok(Some((base, ours, theirs)));
            }
        }
    }
    if let Ok(state) = std::fs::read_to_string(git_dir.join("arbor-merge-state")) {
        let value = |key: &str| {
            state
                .lines()
                .find_map(|line| line.strip_prefix(key).map(str::trim))
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        if let (Some(ours), Some(theirs)) = (value("ours="), value("theirs=")) {
            let base = git_rev(workdir, &["merge-base", &ours, &theirs])?;
            return Ok(Some((base, ours, theirs)));
        }
    }
    if let Ok(state) = std::fs::read_to_string(git_dir.join("arbor-rebase-state")) {
        let head = state.lines().find_map(|line| {
            line.strip_prefix("head=")
                .map(str::trim)
                .filter(|value| !value.is_empty())
        });
        let cherry = state.lines().find_map(|line| {
            let mut fields = line.split_whitespace();
            let tag = fields.next()?;
            let id = fields.next()?;
            matches!(tag, "P" | "R" | "S" | "F" | "E").then_some(id)
        });
        if let (Some(head), Some(cherry)) = (head, cherry) {
            let parent = format!("{cherry}^");
            let base = git_rev(workdir, &["rev-parse", &parent])?;
            return Ok(Some((base, head.to_string(), cherry.to_string())));
        }
    }
    Ok(None)
}

fn git_rev(workdir: &Path, args: &[&str]) -> Result<String, EngineError> {
    let spec = crate::gitprocess::GitCommandSpec::new(
        crate::gitprocess::GitCommandCategory::Merge,
        args[0],
    )
    .args(args[1..].iter().map(|arg| (*arg).to_string()))
    .working_dir(workdir);
    let outcome = crate::gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    let value = outcome.stdout.trim();
    if value.is_empty() {
        return Err(EngineError::GitOperation {
            message: format!("git {} returned an empty revision", args.join(" ")),
        });
    }
    Ok(value.to_string())
}

fn read_trimmed(path: &std::path::Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// Capture the exact unmerged index records before a file is resolved. This
/// preserves mode, object id, and stage without trying to infer the current
/// operation's three trees later.
pub(crate) fn capture_index_entries(
    repo: &gix::Repository,
    path: &str,
) -> Result<Vec<String>, EngineError> {
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "capture conflict stages requires a non-bare worktree".into(),
    })?;
    let output = crate::gitprocess::git_command_for_working_dir(workdir)
        .args(["ls-files", "--stage", "-z", "--", path])
        .current_dir(workdir)
        .output()
        .map_err(EngineError::from_gix)?;
    if !output.status.success() {
        return Err(EngineError::GitOperation {
            message: format!(
                "git ls-files failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        });
    }
    Ok(output
        .stdout
        .split(|byte| *byte == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            let (metadata, entry_path) = record.split_once('\t')?;
            let stage = metadata.split_whitespace().nth(2)?;
            (entry_path == path && stage != "0").then(|| record.into_owned())
        })
        .collect())
}

/// 文件级接受一侧或双方：写工作区 + 清冲突 stages + upsert stage 0。
/// 二进制安全（raw bytes）。
pub(crate) fn accept(
    repo: &gix::Repository,
    path: &str,
    pick: FilePick,
) -> Result<(), EngineError> {
    use gix::index::entry::Stage;
    let index_entries = capture_index_entries(repo, path)?;
    let index = repo.index().map_err(EngineError::from_gix)?;
    let path_bstr = path.as_bytes().as_bstr();
    let ours = stage_bytes(repo, &index, path_bstr, Stage::Ours);
    let theirs = stage_bytes(repo, &index, path_bstr, Stage::Theirs);
    let content: Vec<u8> = match pick {
        FilePick::Ours => ours,
        FilePick::Theirs => theirs,
        // Both：两段都保留（ours 在上，中间换行分隔）；任一侧缺失取另一侧。
        FilePick::Both => {
            let mut merged = Vec::new();
            let mut any = false;
            for side in [&ours, &theirs] {
                if !side.is_empty() {
                    if any {
                        merged.push(b'\n');
                    }
                    merged.extend_from_slice(side);
                    any = true;
                }
            }
            merged
        }
    };
    crate::merge::write_resolved_bytes(repo, path, &content)?;
    mark_resolved(repo, path, index_entries)
}

/// 重新物化冲突现场：从 index stages 重新生成 marker 内容写回工作区，
/// **不碰索引 stages**（reset 语义：放弃当前编辑，回到未解决状态）。
pub(crate) fn reset(repo: &gix::Repository, path: &str) -> Result<(), EngineError> {
    use gix::index::entry::Stage;
    let index = repo.index().map_err(EngineError::from_gix)?;
    let path_bstr = path.as_bytes().as_bstr();
    let ours = stage_bytes(repo, &index, path_bstr, Stage::Ours);
    let theirs = stage_bytes(repo, &index, path_bstr, Stage::Theirs);
    if has_binary_attribute(repo, path)
        || crate::diff::is_binary(&ours)
        || crate::diff::is_binary(&theirs)
    {
        return Err(EngineError::GitOperation {
            message: format!("reset: {path} 是二进制文件，无法生成 marker；请用 Accept 或手动编辑"),
        });
    }
    let content = render_marker(
        &String::from_utf8_lossy(&ours),
        &String::from_utf8_lossy(&theirs),
    );
    let workdir = repo.workdir().ok_or_else(|| EngineError::GitOperation {
        message: "bare repository has no worktree".into(),
    })?;
    let file_path = workdir.join(path);
    if let Some(parent) = file_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let checkout_content =
        crate::attributes::checkout_worktree_bytes(workdir, path, content.as_bytes())?;
    std::fs::write(&file_path, checkout_content).map_err(EngineError::from_gix)?;
    remove_resolved(repo, path)
}

fn ledger_path(repo: &gix::Repository) -> PathBuf {
    repo.git_dir().join(RESOLVED_LEDGER)
}

fn load_resolved_paths(repo: &gix::Repository) -> Result<Vec<String>, EngineError> {
    let Some(signature) = operation_signature(repo) else {
        return Ok(Vec::new());
    };
    Ok(load_resolved_entries_for_signature(repo, &signature)?
        .into_iter()
        .map(|entry| entry.path)
        .collect())
}

fn load_resolved_entries(repo: &gix::Repository) -> Result<Vec<ResolvedLedgerEntry>, EngineError> {
    let Some(signature) = operation_signature(repo) else {
        return Ok(Vec::new());
    };
    load_resolved_entries_for_signature(repo, &signature)
}

fn load_resolved_entries_for_signature(
    repo: &gix::Repository,
    expected_signature: &str,
) -> Result<Vec<ResolvedLedgerEntry>, EngineError> {
    let text = match std::fs::read_to_string(ledger_path(repo)) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(EngineError::from_gix(error)),
    };
    let mut signature = None;
    let mut entries: Vec<ResolvedLedgerEntry> = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("signature=") {
            signature = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("path=") {
            if let Some(path) = decode_path(value) {
                entries.push(ResolvedLedgerEntry {
                    path,
                    index_entries: Vec::new(),
                });
            }
        } else if let Some(value) = line.strip_prefix("entry=") {
            if let (Some(entry), Some(current)) = (decode_path(value), entries.last_mut()) {
                current.index_entries.push(entry);
            }
        }
    }
    if signature.as_deref() != Some(expected_signature) {
        return Ok(Vec::new());
    }
    entries.sort_by(|left, right| left.path.cmp(&right.path));
    entries.dedup_by(|left, right| left.path == right.path);
    Ok(entries)
}

fn write_resolved_entries(
    repo: &gix::Repository,
    signature: &str,
    entries: &[ResolvedLedgerEntry],
) -> Result<(), EngineError> {
    let mut text = format!("signature={signature}\n");
    for entry in entries {
        text.push_str("path=");
        text.push_str(&encode_path(&entry.path));
        text.push('\n');
        for index_entry in &entry.index_entries {
            text.push_str("entry=");
            text.push_str(&encode_path(index_entry));
            text.push('\n');
        }
    }
    let ledger = ledger_path(repo);
    let temporary = repo.git_dir().join(RESOLVED_LEDGER_TMP);
    std::fs::write(&temporary, text).map_err(EngineError::from_gix)?;
    std::fs::rename(&temporary, ledger).map_err(EngineError::from_gix)
}

fn encode_path(path: &str) -> String {
    path.as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn decode_path(value: &str) -> Option<String> {
    if value.len() % 2 != 0 {
        return None;
    }
    let bytes = (0..value.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&value[index..index + 2], 16).ok())
        .collect::<Option<Vec<_>>>()?;
    String::from_utf8(bytes).ok()
}

fn operation_signature(repo: &gix::Repository) -> Option<String> {
    let git_dir = repo.git_dir();
    for (kind, marker) in [
        ("rebase-merge", git_dir.join("rebase-merge")),
        ("rebase-apply", git_dir.join("rebase-apply")),
    ] {
        if marker.is_dir() {
            let names = [
                "head-name",
                "onto",
                "orig-head",
                "msgnum",
                "end",
                "next",
                "last",
                "message",
                "git-rebase-todo",
                "done",
            ];
            let paths = names
                .iter()
                .map(|name| marker.join(name))
                .collect::<Vec<_>>();
            return Some(hash_state(kind, &paths));
        }
    }
    for (kind, marker) in [
        ("cherry-pick", git_dir.join("CHERRY_PICK_HEAD")),
        ("revert", git_dir.join("REVERT_HEAD")),
        ("merge", git_dir.join("MERGE_HEAD")),
        ("arbor-rebase", git_dir.join("arbor-rebase-state")),
        ("arbor-merge", git_dir.join("arbor-merge-state")),
    ] {
        if marker.is_file() {
            return Some(hash_state(kind, &[marker]));
        }
    }
    None
}

fn hash_state(kind: &str, paths: &[PathBuf]) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    kind.hash(&mut hasher);
    for path in paths {
        path.to_string_lossy().hash(&mut hasher);
        std::fs::read(path).unwrap_or_default().hash(&mut hasher);
    }
    format!("{kind}:{:016x}", hasher.finish())
}

/// 读取一个冲突文件的三方内容 + 冲突块 + 二进制标记。
pub(crate) fn read_conflict_file(
    repo: &gix::Repository,
    path: &str,
) -> Result<(bool, ConflictFile), EngineError> {
    use gix::index::entry::Stage;
    let index = repo.index().map_err(EngineError::from_gix)?;
    let path_bstr = path.as_bytes().as_bstr();
    let base_bytes = stage_bytes(repo, &index, path_bstr, Stage::Base);
    let ours_bytes = stage_bytes(repo, &index, path_bstr, Stage::Ours);
    let theirs_bytes = stage_bytes(repo, &index, path_bstr, Stage::Theirs);
    let base = String::from_utf8_lossy(&base_bytes).into_owned();
    let ours = String::from_utf8_lossy(&ours_bytes).into_owned();
    let theirs = String::from_utf8_lossy(&theirs_bytes).into_owned();
    let binary = has_binary_attribute(repo, path)
        || [&base_bytes, &ours_bytes, &theirs_bytes]
            .iter()
            .any(|bytes| crate::diff::is_binary(bytes));
    let result = String::from_utf8_lossy(&crate::diff::worktree_bytes(repo, path)).into_owned();
    let blocks = if binary {
        Vec::new()
    } else {
        crate::merge::parse_marker_blocks(&result, &ours, &theirs)
    };
    Ok((
        binary,
        ConflictFile {
            path: path.to_string(),
            base,
            ours,
            theirs,
            result,
            blocks,
        },
    ))
}

fn stage_bytes(
    repo: &gix::Repository,
    index: &gix::index::File,
    path: &BStr,
    stage: gix::index::entry::Stage,
) -> Vec<u8> {
    index
        .entry_by_path_and_stage(path, stage)
        .and_then(|entry| crate::diff::blob_bytes(repo, entry.id, "read conflict stage").ok())
        .unwrap_or_default()
}

fn has_binary_attribute(repo: &gix::Repository, path: &str) -> bool {
    repo.workdir()
        .and_then(|workdir| {
            crate::attributes::check_attributes(workdir, &[path.to_string()])
                .ok()
                .and_then(|attrs| attrs.first().cloned())
        })
        .map(|attrs| attrs.binary == crate::attributes::AttributeValue::Set)
        .unwrap_or(false)
}

/// 从两侧内容生成 git 风格 marker（与 gix merge 物化格式兼容，
/// parse_marker_blocks 只依赖 marker 行前缀，label 不影响解析）。
pub(crate) fn render_marker(ours: &str, theirs: &str) -> String {
    let mut out = String::new();
    out.push_str("<<<<<<< HEAD\n");
    out.push_str(ours);
    if !ours.is_empty() && !ours.ends_with('\n') {
        out.push('\n');
    }
    out.push_str("=======\n");
    out.push_str(theirs);
    if !theirs.is_empty() && !theirs.ends_with('\n') {
        out.push('\n');
    }
    out.push_str(">>>>>>> theirs\n");
    out
}

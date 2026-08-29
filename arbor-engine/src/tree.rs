//! 提交树之间的结构化变化。

/// 树条目的变化种类。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
}

/// 两个 revision 的树差异条目。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct TreeChange {
    /// 新路径；删除时为原路径。重命名时为目标路径。
    pub path: String,
    /// 重命名来源路径；非重命名变更为空。
    pub old_path: Option<String>,
    /// 重命名前后的 blob 内容完全相同；仅对重命名变更有意义。
    pub is_pure_move: bool,
    pub kind: TreeChangeKind,
    pub old_mode: u32,
    pub new_mode: u32,
}

/// 两个 tree id 的结构化变化（HEAD-001 commit_diff/tree_changes 共用）。
pub(crate) fn diff_trees(
    repo: &gix::Repository,
    old_tree_id: gix::hash::ObjectId,
    new_tree_id: gix::hash::ObjectId,
) -> Result<Vec<TreeChange>, crate::error::EngineError> {
    use gix::object::tree::diff::ChangeDetached;
    let old_tree = repo
        .find_tree(old_tree_id)
        .map_err(crate::error::EngineError::from_gix)?;
    let new_tree = repo
        .find_tree(new_tree_id)
        .map_err(crate::error::EngineError::from_gix)?;
    let changes = repo
        .diff_tree_to_tree(Some(&old_tree), Some(&new_tree), None)
        .map_err(crate::error::EngineError::from_gix)?;
    let mut out = Vec::with_capacity(changes.len());
    for change in &changes {
        let item = match change {
            ChangeDetached::Addition {
                location,
                entry_mode,
                ..
            } => TreeChange {
                path: location.to_string(),
                old_path: None,
                is_pure_move: false,
                kind: TreeChangeKind::Added,
                old_mode: 0,
                new_mode: entry_mode.value() as u32,
            },
            ChangeDetached::Modification {
                location,
                previous_entry_mode,
                entry_mode,
                ..
            } => TreeChange {
                path: location.to_string(),
                old_path: None,
                is_pure_move: false,
                kind: TreeChangeKind::Modified,
                old_mode: previous_entry_mode.value() as u32,
                new_mode: entry_mode.value() as u32,
            },
            ChangeDetached::Deletion {
                location,
                entry_mode,
                ..
            } => TreeChange {
                path: location.to_string(),
                old_path: None,
                is_pure_move: false,
                kind: TreeChangeKind::Deleted,
                old_mode: entry_mode.value() as u32,
                new_mode: 0,
            },
            ChangeDetached::Rewrite {
                source_location,
                source_entry_mode,
                source_id,
                location,
                entry_mode,
                id,
                ..
            } => {
                let old_path = source_location.to_string();
                TreeChange {
                    path: location.to_string(),
                    old_path: (!old_path.is_empty()).then_some(old_path),
                    is_pure_move: source_id == id,
                    kind: TreeChangeKind::Renamed,
                    old_mode: source_entry_mode.value() as u32,
                    new_mode: entry_mode.value() as u32,
                }
            }
        };
        out.push(item);
    }
    Ok(out)
}

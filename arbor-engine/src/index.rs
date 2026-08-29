//! Git index helpers shared by commit and stash operations.

use crate::error::EngineError;

/// Index entry mode -> tree entry kind.
pub(crate) fn mode_to_kind(mode: gix::index::entry::Mode) -> gix::object::tree::EntryKind {
    use gix::index::entry::Mode;
    use gix::object::tree::EntryKind;
    if mode.contains(Mode::SYMLINK) {
        if mode.contains(Mode::DIR) {
            EntryKind::Commit
        } else {
            EntryKind::Link
        }
    } else if mode.contains(Mode::FILE_EXECUTABLE) {
        EntryKind::BlobExecutable
    } else if mode.contains(Mode::COMMIT) {
        EntryKind::Commit
    } else {
        EntryKind::Blob
    }
}

/// Build a tree from an already loaded index.
pub(crate) fn build_tree(
    repo: &gix::Repository,
    index: &gix::index::File,
) -> Result<gix::hash::ObjectId, EngineError> {
    let mut editor = repo
        .edit_tree(repo.empty_tree().id)
        .map_err(EngineError::from_gix)?;
    for entry in index.entries() {
        editor
            .upsert(entry.path(index), mode_to_kind(entry.mode), entry.id)
            .map_err(EngineError::from_gix)?;
    }
    editor
        .write()
        .map(|id| id.detach())
        .map_err(EngineError::from_gix)
}

/// Build a tree from the repository's current index.
pub(crate) fn index_tree(repo: &gix::Repository) -> Result<gix::hash::ObjectId, EngineError> {
    let index = repo
        .index_or_load_from_head_or_empty()
        .map_err(EngineError::from_gix)?
        .into_owned();
    build_tree(repo, &index)
}

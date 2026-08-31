//! 本地 Changelist 元数据。
//!
//! Changelist 是 IntelliJ Changes Browser 的工作区分组，不改变 Git 的
//! index/worktree。只持久化路径归属和列表顺序，Git 状态仍由 status() 负责。

use std::collections::HashSet;
use std::path::Path;

use crate::error::EngineError;

pub(crate) const DEFAULT_CHANGE_LIST_NAME: &str = "Default";
const CHANGE_LISTS_FILE: &str = "arbor-changelists";
const CHANGE_LISTS_MAGIC_V1: &str = "ARBOR_CHANGELISTS_V1";
const CHANGE_LISTS_MAGIC_V2: &str = "ARBOR_CHANGELISTS_V2";

/// 一个本地 Changelist。paths 只包含当前仍存在于 Git Changes Browser 的
/// 变更；空列表仍会保留，便于用户先创建列表再拖入文件。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ChangeListInfo {
    pub name: String,
    pub paths: Vec<String>,
    pub is_default: bool,
    pub is_active: bool,
}

/// Changelist metadata that is not part of the Changes Browser path
/// projection. Keeping this separate preserves the existing lightweight
/// `ChangeListInfo` ABI while exposing IntelliJ-style description/context
/// settings to the settings and create dialogs.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ChangeListMetadata {
    pub name: String,
    pub description: Option<String>,
    pub is_active: bool,
    pub track_context: bool,
    pub task_identity: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StoredChangeList {
    pub name: String,
    pub is_default: bool,
    pub description: Option<String>,
    pub track_context: bool,
    pub task_identity: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ChangeLists {
    pub lists: Vec<StoredChangeList>,
    pub active: String,
    /// Vec 顺序同时是各列表的成员顺序；未出现的路径隐式属于默认列表。
    pub assignments: Vec<(String, String)>,
    /// Snapshot observation state used to assign only paths that first appear
    /// after the initial load to the active list.
    pub observed: bool,
    pub seen_paths: Vec<String>,
}

pub(crate) fn change_lists_file(repo: &gix::Repository) -> std::path::PathBuf {
    repo.git_dir().join(CHANGE_LISTS_FILE)
}

fn encode_hex(value: &str) -> String {
    value
        .as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn decode_hex(value: &str) -> Result<String, EngineError> {
    if value.len() % 2 != 0 {
        return Err(EngineError::GitOperation {
            message: "changelist: malformed metadata encoding".into(),
        });
    }
    let mut bytes = Vec::with_capacity(value.len() / 2);
    let raw = value.as_bytes();
    for index in (0..raw.len()).step_by(2) {
        let high = (raw[index] as char).to_digit(16);
        let low = (raw[index + 1] as char).to_digit(16);
        match (high, low) {
            (Some(high), Some(low)) => bytes.push(((high << 4) | low) as u8),
            _ => {
                return Err(EngineError::GitOperation {
                    message: "changelist: malformed metadata encoding".into(),
                })
            }
        }
    }
    String::from_utf8(bytes).map_err(|_| EngineError::GitOperation {
        message: "changelist: metadata is not valid UTF-8".into(),
    })
}

pub(crate) fn validate_change_list_name(name: &str) -> Result<(), EngineError> {
    if name.trim().is_empty() {
        return Err(EngineError::GitOperation {
            message: "changelist: name is required".into(),
        });
    }
    if name
        .chars()
        .any(|character| matches!(character, '\t' | '\r' | '\n'))
    {
        return Err(EngineError::GitOperation {
            message: "changelist: name must not contain tabs or line breaks".into(),
        });
    }
    Ok(())
}

pub(crate) fn validate_change_path(path: &str) -> Result<(), EngineError> {
    let candidate = Path::new(path);
    if path.is_empty() || candidate.is_absolute() {
        return Err(EngineError::GitOperation {
            message: format!("changelist: invalid path '{path}'"),
        });
    }
    if candidate
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(EngineError::GitOperation {
            message: format!("changelist: path escapes worktree '{path}'"),
        });
    }
    Ok(())
}

pub(crate) fn empty_change_lists() -> ChangeLists {
    ChangeLists {
        lists: vec![StoredChangeList {
            name: DEFAULT_CHANGE_LIST_NAME.into(),
            is_default: true,
            description: None,
            track_context: false,
            task_identity: None,
        }],
        active: DEFAULT_CHANGE_LIST_NAME.into(),
        assignments: Vec::new(),
        observed: false,
        seen_paths: Vec::new(),
    }
}

pub(crate) fn load_change_lists(repo: &gix::Repository) -> Result<ChangeLists, EngineError> {
    let path = change_lists_file(repo);
    let contents = match std::fs::read_to_string(&path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(empty_change_lists())
        }
        Err(error) => return Err(EngineError::from_gix(error)),
    };

    let mut lines = contents.lines();
    let version = match lines.next() {
        Some(CHANGE_LISTS_MAGIC_V1) => 1,
        Some(CHANGE_LISTS_MAGIC_V2) => 2,
        _ => {
            return Err(EngineError::GitOperation {
                message: "changelist: unsupported metadata format".into(),
            })
        }
    };
    let mut observed = false;
    let mut seen_paths = Vec::new();
    let mut seen_observed_paths = HashSet::new();

    if version != 1 && version != 2 {
        return Err(EngineError::GitOperation {
            message: "changelist: unsupported metadata format".into(),
        });
    }

    let mut lists = Vec::new();
    let mut active = None;
    let mut assignments = Vec::new();
    let mut seen_names = HashSet::new();
    let mut seen_assignment_paths = HashSet::new();

    for line in lines {
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split('\t');
        match fields.next() {
            Some("L") => {
                let encoded_name = fields.next().ok_or_else(|| metadata_error())?;
                let default_marker = fields.next().ok_or_else(|| metadata_error())?;
                let name = decode_hex(encoded_name)?;
                validate_change_list_name(&name)?;
                if !seen_names.insert(name.clone()) {
                    return Err(EngineError::GitOperation {
                        message: format!("changelist: duplicate list '{name}'"),
                    });
                }
                let is_default = default_marker == "1";
                if default_marker != "0" && !is_default {
                    return Err(metadata_error());
                }
                let (description, track_context, task_identity) = if version >= 2 {
                    let encoded_description = fields.next().ok_or_else(|| metadata_error())?;
                    let track_marker = fields.next().ok_or_else(|| metadata_error())?;
                    let encoded_task = fields.next().ok_or_else(|| metadata_error())?;
                    if fields.next().is_some() || (track_marker != "0" && track_marker != "1") {
                        return Err(metadata_error());
                    }
                    let description = decode_hex(encoded_description)?;
                    let task_identity = decode_hex(encoded_task)?;
                    (
                        (!description.is_empty()).then_some(description),
                        track_marker == "1",
                        (!task_identity.is_empty()).then_some(task_identity),
                    )
                } else {
                    if fields.next().is_some() {
                        return Err(metadata_error());
                    }
                    (None, false, None)
                };
                lists.push(StoredChangeList {
                    name,
                    is_default,
                    description,
                    track_context,
                    task_identity,
                });
            }
            Some("A") => {
                if active.is_some() {
                    return Err(metadata_error());
                }
                let encoded_name = fields.next().ok_or_else(|| metadata_error())?;
                if fields.next().is_some() {
                    return Err(metadata_error());
                }
                let name = decode_hex(encoded_name)?;
                validate_change_list_name(&name)?;
                active = Some(name);
            }
            Some("P") => {
                let encoded_path = fields.next().ok_or_else(|| metadata_error())?;
                let encoded_name = fields.next().ok_or_else(|| metadata_error())?;
                if fields.next().is_some() {
                    return Err(metadata_error());
                }
                let path = decode_hex(encoded_path)?;
                let name = decode_hex(encoded_name)?;
                validate_change_path(&path)?;
                validate_change_list_name(&name)?;
                if !seen_assignment_paths.insert(path.clone()) {
                    return Err(EngineError::GitOperation {
                        message: format!("changelist: duplicate path '{path}'"),
                    });
                }
                assignments.push((path, name));
            }
            Some("O") if version >= 2 => {
                let marker = fields.next().ok_or_else(|| metadata_error())?;
                if fields.next().is_some() || (marker != "0" && marker != "1") {
                    return Err(metadata_error());
                }
                observed = marker == "1";
            }
            Some("S") if version >= 2 => {
                let encoded_path = fields.next().ok_or_else(|| metadata_error())?;
                if fields.next().is_some() {
                    return Err(metadata_error());
                }
                let path = decode_hex(encoded_path)?;
                validate_change_path(&path)?;
                if !seen_observed_paths.insert(path.clone()) {
                    return Err(EngineError::GitOperation {
                        message: format!("changelist: duplicate observed path '{path}'"),
                    });
                }
                seen_paths.push(path);
            }
            _ => return Err(metadata_error()),
        }
    }

    if lists.is_empty() {
        return Err(EngineError::GitOperation {
            message: "changelist: metadata has no lists".into(),
        });
    }
    let default_count = lists.iter().filter(|list| list.is_default).count();
    if default_count != 1 {
        return Err(EngineError::GitOperation {
            message: "changelist: metadata must contain exactly one default list".into(),
        });
    }
    let default_name = lists
        .iter()
        .find(|list| list.is_default)
        .map(|list| list.name.clone())
        .expect("default count checked");
    let active = active.unwrap_or_else(|| default_name.clone());
    if !lists.iter().any(|list| list.name == active) {
        return Err(EngineError::GitOperation {
            message: format!("changelist: active list '{active}' does not exist"),
        });
    }
    if assignments
        .iter()
        .any(|(_, name)| !lists.iter().any(|list| list.name == *name))
    {
        return Err(EngineError::GitOperation {
            message: "changelist: invalid path assignment".into(),
        });
    }

    Ok(ChangeLists {
        lists,
        active,
        assignments,
        observed,
        seen_paths,
    })
}

fn metadata_error() -> EngineError {
    EngineError::GitOperation {
        message: "changelist: malformed metadata".into(),
    }
}

pub(crate) fn save_change_lists(
    repo: &gix::Repository,
    state: &ChangeLists,
) -> Result<(), EngineError> {
    let default_count = state.lists.iter().filter(|list| list.is_default).count();
    if default_count != 1 || !state.lists.iter().any(|list| list.name == state.active) {
        return Err(EngineError::GitOperation {
            message: "changelist: invalid list state".into(),
        });
    }
    let names: HashSet<&str> = state.lists.iter().map(|list| list.name.as_str()).collect();
    let mut seen_paths = HashSet::new();
    for list in &state.lists {
        validate_change_list_name(&list.name)?;
    }
    for (path, name) in &state.assignments {
        validate_change_path(path)?;
        if !names.contains(name.as_str()) || !seen_paths.insert(path) {
            return Err(EngineError::GitOperation {
                message: format!("changelist: invalid assignment for '{path}'"),
            });
        }
    }
    let mut seen_observed_paths = HashSet::new();
    for path in &state.seen_paths {
        validate_change_path(path)?;
        if !seen_observed_paths.insert(path) {
            return Err(EngineError::GitOperation {
                message: format!("changelist: duplicate observed path '{path}'"),
            });
        }
    }

    let mut output = String::from(CHANGE_LISTS_MAGIC_V2);
    output.push('\n');
    for list in &state.lists {
        output.push_str("L\t");
        output.push_str(&encode_hex(&list.name));
        output.push('\t');
        output.push(if list.is_default { '1' } else { '0' });
        output.push('\t');
        output.push_str(&encode_hex(list.description.as_deref().unwrap_or_default()));
        output.push('\t');
        output.push(if list.track_context { '1' } else { '0' });
        output.push('\t');
        output.push_str(&encode_hex(
            list.task_identity.as_deref().unwrap_or_default(),
        ));
        output.push('\n');
    }
    output.push_str("A\t");
    output.push_str(&encode_hex(&state.active));
    output.push('\n');
    output.push_str("O\t");
    output.push(if state.observed { '1' } else { '0' });
    output.push('\n');
    for path in &state.seen_paths {
        output.push_str("S\t");
        output.push_str(&encode_hex(path));
        output.push('\n');
    }
    for (path, name) in &state.assignments {
        output.push_str("P\t");
        output.push_str(&encode_hex(path));
        output.push('\t');
        output.push_str(&encode_hex(name));
        output.push('\n');
    }

    let destination = change_lists_file(repo);
    let temporary = destination.with_extension("tmp");
    std::fs::write(&temporary, output).map_err(EngineError::from_gix)?;
    if let Err(error) = std::fs::rename(&temporary, &destination) {
        let _ = std::fs::remove_file(&temporary);
        return Err(EngineError::from_gix(error));
    }
    Ok(())
}

pub(crate) fn default_name(state: &ChangeLists) -> String {
    state
        .lists
        .iter()
        .find(|list| list.is_default)
        .map(|list| list.name.clone())
        .expect("all states have one default list")
}

pub(crate) fn list_for_path(state: &ChangeLists, path: &str) -> String {
    state
        .assignments
        .iter()
        .find(|(candidate, _)| candidate == path)
        .map(|(_, name)| name.clone())
        .unwrap_or_else(|| default_name(state))
}

/// Observe one status snapshot. The first snapshot seeds the ledger without
/// moving existing changes; subsequent newly seen paths are assigned to the
/// active list, matching IntelliJ's active Changelist semantics.
pub(crate) fn observe_paths(state: &mut ChangeLists, current_paths: &[String]) -> bool {
    let current: HashSet<&str> = current_paths.iter().map(String::as_str).collect();
    let mut changed = false;
    if !state.observed {
        state.observed = true;
        state.seen_paths = current_paths.to_vec();
        return true;
    }

    let previous: HashSet<&str> = state.seen_paths.iter().map(String::as_str).collect();
    let default_name = default_name(state);
    // A path that disappeared from the status snapshot must not keep a stale
    // assignment. If it is created again later it is a new change and should
    // be routed through the active-list rule below.
    let before_assignments = state.assignments.len();
    state
        .assignments
        .retain(|(path, _)| current.contains(path.as_str()));
    changed |= state.assignments.len() != before_assignments;
    for path in current_paths {
        if !previous.contains(path.as_str()) && state.active != default_name {
            state.assignments.retain(|(candidate, _)| candidate != path);
            state.assignments.push((path.clone(), state.active.clone()));
            changed = true;
        }
    }
    let next_seen = current_paths.to_vec();
    if state.seen_paths != next_seen {
        state.seen_paths = next_seen;
        changed = true;
    }
    // A deleted path is removed from the observed ledger. If it is recreated,
    // it will be treated as a genuinely new change on the next snapshot.
    state
        .seen_paths
        .retain(|path| current.contains(path.as_str()));
    changed
}

pub(crate) fn metadata(state: &ChangeLists) -> Vec<ChangeListMetadata> {
    state
        .lists
        .iter()
        .map(|list| ChangeListMetadata {
            name: list.name.clone(),
            description: list.description.clone(),
            is_active: state.active == list.name,
            track_context: list.track_context,
            task_identity: list.task_identity.clone(),
        })
        .collect()
}

pub(crate) fn set_metadata(
    state: &mut ChangeLists,
    name: &str,
    description: Option<String>,
    track_context: bool,
    task_identity: Option<String>,
) -> Result<(), EngineError> {
    let Some(list) = state.lists.iter_mut().find(|list| list.name == name) else {
        return Err(EngineError::GitOperation {
            message: format!("changelist: list '{name}' not found"),
        });
    };
    let normalize = |value: Option<String>| {
        value.and_then(|value| {
            let value = value.trim().to_string();
            (!value.is_empty()).then_some(value)
        })
    };
    list.description = normalize(description);
    list.track_context = track_context;
    list.task_identity = normalize(task_identity);
    Ok(())
}

pub(crate) fn to_info(state: &ChangeLists, current_paths: &[String]) -> Vec<ChangeListInfo> {
    let current: HashSet<&str> = current_paths.iter().map(String::as_str).collect();
    state
        .lists
        .iter()
        .map(|list| ChangeListInfo {
            name: list.name.clone(),
            paths: state
                .assignments
                .iter()
                .filter(|(path, name)| name == &list.name && current.contains(path.as_str()))
                .map(|(path, _)| path.clone())
                .chain(if list.is_default {
                    current_paths
                        .iter()
                        .filter(|path| list_for_path(state, path) == list.name)
                        .filter(|path| {
                            !state
                                .assignments
                                .iter()
                                .any(|(candidate, _)| candidate == *path)
                        })
                        .cloned()
                        .collect::<Vec<_>>()
                } else {
                    Vec::new()
                })
                .collect(),
            is_default: list.is_default,
            is_active: state.active == list.name,
        })
        .collect()
}

pub(crate) fn rename(
    state: &mut ChangeLists,
    old_name: &str,
    new_name: &str,
) -> Result<(), EngineError> {
    validate_change_list_name(new_name)?;
    if !state.lists.iter().any(|list| list.name == old_name) {
        return Err(EngineError::GitOperation {
            message: format!("changelist: list '{old_name}' not found"),
        });
    }
    if state.lists.iter().any(|list| list.name == new_name) {
        return Err(EngineError::GitOperation {
            message: format!("changelist: list '{new_name}' already exists"),
        });
    }
    let old_name = old_name.to_string();
    for list in &mut state.lists {
        if list.name == old_name {
            list.name = new_name.to_string();
        }
    }
    for (_, name) in &mut state.assignments {
        if *name == old_name {
            *name = new_name.to_string();
        }
    }
    if state.active == old_name {
        state.active = new_name.to_string();
    }
    Ok(())
}

pub(crate) fn delete(state: &mut ChangeLists, name: &str) -> Result<(), EngineError> {
    let Some(list) = state.lists.iter().find(|list| list.name == name) else {
        return Err(EngineError::GitOperation {
            message: format!("changelist: list '{name}' not found"),
        });
    };
    if list.is_default {
        return Err(EngineError::GitOperation {
            message: "changelist: the default list cannot be deleted".into(),
        });
    }
    let default_name = default_name(state);
    state.lists.retain(|list| list.name != name);
    for (_, list_name) in &mut state.assignments {
        if list_name == name {
            *list_name = default_name.clone();
        }
    }
    if state.active == name {
        state.active = default_name;
    }
    Ok(())
}

pub(crate) fn activate(state: &mut ChangeLists, name: &str) -> Result<(), EngineError> {
    if !state.lists.iter().any(|list| list.name == name) {
        return Err(EngineError::GitOperation {
            message: format!("changelist: list '{name}' not found"),
        });
    }
    state.active = name.to_string();
    Ok(())
}

pub(crate) fn move_paths(
    state: &mut ChangeLists,
    paths: &[String],
    target: &str,
) -> Result<(), EngineError> {
    if !state.lists.iter().any(|list| list.name == target) {
        return Err(EngineError::GitOperation {
            message: format!("changelist: target list '{target}' not found"),
        });
    }
    let mut seen = HashSet::new();
    for path in paths {
        validate_change_path(path)?;
        if seen.insert(path) {
            state.assignments.retain(|(candidate, _)| candidate != path);
            state.assignments.push((path.clone(), target.to_string()));
        }
    }
    Ok(())
}

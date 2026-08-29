//! 本地 Changelist 元数据。
//!
//! Changelist 是 IntelliJ Changes Browser 的工作区分组，不改变 Git 的
//! index/worktree。只持久化路径归属和列表顺序，Git 状态仍由 status() 负责。

use std::collections::HashSet;
use std::path::Path;

use crate::error::EngineError;

pub(crate) const DEFAULT_CHANGE_LIST_NAME: &str = "Default";
const CHANGE_LISTS_FILE: &str = "arbor-changelists";
const CHANGE_LISTS_MAGIC: &str = "ARBOR_CHANGELISTS_V1";

/// 一个本地 Changelist。paths 只包含当前仍存在于 Git Changes Browser 的
/// 变更；空列表仍会保留，便于用户先创建列表再拖入文件。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ChangeListInfo {
    pub name: String,
    pub paths: Vec<String>,
    pub is_default: bool,
    pub is_active: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct StoredChangeList {
    pub name: String,
    pub is_default: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ChangeLists {
    pub lists: Vec<StoredChangeList>,
    pub active: String,
    /// Vec 顺序同时是各列表的成员顺序；未出现的路径隐式属于默认列表。
    pub assignments: Vec<(String, String)>,
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
        }],
        active: DEFAULT_CHANGE_LIST_NAME.into(),
        assignments: Vec::new(),
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
    if lines.next() != Some(CHANGE_LISTS_MAGIC) {
        return Err(EngineError::GitOperation {
            message: "changelist: unsupported metadata format".into(),
        });
    }

    let mut lists = Vec::new();
    let mut active = None;
    let mut assignments = Vec::new();
    let mut seen_names = HashSet::new();
    let mut seen_paths = HashSet::new();

    for line in lines {
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split('\t');
        match fields.next() {
            Some("L") => {
                let encoded_name = fields.next().ok_or_else(|| metadata_error())?;
                let default_marker = fields.next().ok_or_else(|| metadata_error())?;
                if fields.next().is_some() {
                    return Err(metadata_error());
                }
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
                lists.push(StoredChangeList { name, is_default });
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
                if !seen_paths.insert(path.clone()) {
                    return Err(EngineError::GitOperation {
                        message: format!("changelist: duplicate path '{path}'"),
                    });
                }
                assignments.push((path, name));
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

    let mut output = String::from(CHANGE_LISTS_MAGIC);
    output.push('\n');
    for list in &state.lists {
        output.push_str("L\t");
        output.push_str(&encode_hex(&list.name));
        output.push('\t');
        output.push(if list.is_default { '1' } else { '0' });
        output.push('\n');
    }
    output.push_str("A\t");
    output.push_str(&encode_hex(&state.active));
    output.push('\n');
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

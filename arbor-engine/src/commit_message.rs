//! Commit-message cleanup used by the object-level commit paths.
//!
//! IntelliJ's in-memory Git implementation formats the message before it
//! calls `git commit-tree`, because `commit-tree` does not apply Git's
//! `commit.cleanup` configuration itself. Arbor's gix-backed commit paths
//! have the same requirement.

use gix::Repository as GixRepository;

use crate::error::EngineError;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CleanupMode {
    Space,
    None,
    All,
}

/// Format a message using the effective repository `commit.cleanup` and
/// `core.commentChar` settings, matching IntelliJ's
/// `GitCommitMessageFormatter` behavior.
pub(crate) fn format(repo: &GixRepository, message: String) -> Result<String, EngineError> {
    let Some(workdir) = repo.workdir() else {
        return Ok(message);
    };

    let cleanup = crate::repo::git_config_effective_value(workdir, "commit.cleanup")?
        .unwrap_or_else(|| "default".to_string());
    let mode = match cleanup.to_ascii_lowercase().as_str() {
        "default" | "whitespace" | "scissors" => CleanupMode::Space,
        "verbatim" => CleanupMode::None,
        "strip" => CleanupMode::All,
        other => {
            return Err(EngineError::GitOperation {
                message: format!("invalid commit.cleanup value: {other}"),
            });
        }
    };

    if mode == CleanupMode::None {
        return Ok(message);
    }

    let comment_char = if mode == CleanupMode::All {
        Some(
            crate::repo::git_config_effective_value(workdir, "core.commentChar")?
                .unwrap_or_else(|| "#".to_string()),
        )
    } else {
        None
    };
    Ok(cleanup_message(&message, comment_char.as_deref()))
}

/// The cleanup algorithm is intentionally kept separate from Git process
/// execution so it can be checked against the reference formatter directly.
fn cleanup_message(message: &str, comment_char: Option<&str>) -> String {
    let lines: Vec<&str> = message.lines().collect();
    let is_comment = |line: &str| comment_char.is_some_and(|prefix| line.starts_with(prefix));
    let start = lines
        .iter()
        .position(|line| !line.trim().is_empty() && !is_comment(line));
    let Some(start) = start else {
        return String::new();
    };
    let end = lines
        .iter()
        .rposition(|line| !line.trim().is_empty() && !is_comment(line))
        .expect("start guarantees a non-comment non-blank line");

    let mut result = String::new();
    let mut previous_line_empty = false;
    for line in &lines[start..=end] {
        let line = line.trim_end();
        if is_comment(line) {
            continue;
        }
        if line.is_empty() {
            if !previous_line_empty {
                result.push('\n');
            }
            previous_line_empty = true;
            continue;
        }
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(line);
        previous_line_empty = false;
    }
    result.push('\n');
    result
}

#[cfg(test)]
mod tests {
    use super::cleanup_message;

    #[test]
    fn space_cleanup_trims_edges_and_collapses_blank_lines() {
        assert_eq!(
            cleanup_message("\n subject  \n\n\nbody \n# keep\n", None),
            " subject\n\nbody\n# keep\n"
        );
    }

    #[test]
    fn strip_cleanup_uses_the_configured_comment_prefix() {
        assert_eq!(
            cleanup_message("; remove\nsubject\n# keep\n; remove too\nbody\n", Some(";")),
            "subject\n# keep\nbody\n"
        );
    }

    #[test]
    fn empty_or_comment_only_message_is_empty() {
        assert_eq!(cleanup_message("# one\n# two\n", Some("#")), "");
    }
}

mod common;

use std::process::Command;

use arbor_engine::{BlameMovement, BlameOptions};
use common::{commit, git, TestRepo};

#[test]
fn worktree_blame_uses_current_text_and_line_metadata() {
    let repo = TestRepo::new();
    let initial = commit(
        &repo.path,
        "src/main.rs",
        "fn main() {\n    println!(\"old\");\n}\n",
        "initial source",
    );
    repo.write(
        "src/main.rs",
        "fn main() {\n    println!(\"new\");\n    println!(\"added\");\n}\n",
    );

    let lines = repo
        .open()
        .blame_worktree("src/main.rs".into())
        .expect("worktree blame");
    assert_eq!(lines.len(), 4);
    assert_eq!(
        lines.iter().map(|line| line.line).collect::<Vec<_>>(),
        [1, 2, 3, 4]
    );
    assert_eq!(lines[0].text, "fn main() {");
    assert_eq!(lines[1].text, "    println!(\"new\");");
    assert_eq!(lines[2].text, "    println!(\"added\");");
    assert_eq!(lines[0].commit_id, initial);
    assert_eq!(lines[0].summary, "initial source");
    assert!(!lines[0].author.is_empty());
}

#[test]
fn worktree_blame_reports_untracked_files_as_unavailable() {
    let repo = TestRepo::new();
    repo.write("untracked.txt", "not committed\n");

    let error = repo
        .open()
        .blame_worktree("untracked.txt".into())
        .expect_err("untracked files cannot be blamed");
    assert!(error.to_string().contains("git blame failed"));
}

#[test]
fn worktree_blame_options_match_git_annotation_semantics() {
    let repo = TestRepo::new();
    let initial = commit(
        &repo.path,
        "src/main.rs",
        "This is a long line that should move between positions.\nkeep\n",
        "initial source",
    );

    repo.write(
        "src/main.rs",
        "keep\nThis is a long line that should move between positions.\n",
    );
    repo.git(&["add", "src/main.rs"]);
    let output = Command::new("git")
        .args(["commit", "-q", "-m", "move source"])
        .env("GIT_AUTHOR_DATE", "2001-01-01T00:00:00Z")
        .env("GIT_COMMITTER_DATE", "2002-01-01T00:00:00Z")
        .current_dir(&repo.path)
        .output()
        .expect("dated commit");
    assert!(output.status.success());
    let moved = git(&repo.path, &["rev-parse", "HEAD"]);

    let without_movement = repo
        .open()
        .blame_worktree_with_options(
            "src/main.rs".into(),
            BlameOptions {
                ignore_whitespaces: false,
                movement: BlameMovement::None,
                prefer_commit_date: false,
            },
        )
        .expect("blame without movement detection");
    assert_eq!(without_movement[1].commit_id, moved);

    let with_inner_movement = repo
        .open()
        .blame_worktree_with_options(
            "src/main.rs".into(),
            BlameOptions {
                ignore_whitespaces: false,
                movement: BlameMovement::Inner,
                prefer_commit_date: false,
            },
        )
        .expect("blame with inner movement detection");
    assert_eq!(with_inner_movement[1].commit_id, initial);

    let author_timestamp: i64 = git(&repo.path, &["show", "-s", "--format=%at", &moved])
        .parse()
        .expect("author timestamp");
    let committer_timestamp: i64 = git(&repo.path, &["show", "-s", "--format=%ct", &moved])
        .parse()
        .expect("committer timestamp");
    let author_date = repo
        .open()
        .blame_worktree_with_options(
            "src/main.rs".into(),
            BlameOptions {
                ignore_whitespaces: false,
                movement: BlameMovement::None,
                prefer_commit_date: false,
            },
        )
        .expect("author-date blame");
    let committer_date = repo
        .open()
        .blame_worktree_with_options(
            "src/main.rs".into(),
            BlameOptions {
                ignore_whitespaces: false,
                movement: BlameMovement::None,
                prefer_commit_date: true,
            },
        )
        .expect("committer-date blame");
    assert_eq!(author_date[1].time, author_timestamp);
    assert_eq!(committer_date[1].time, committer_timestamp);
    assert_ne!(author_date[1].time, committer_date[1].time);

    repo.write(
        "src/main.rs",
        "keep \nThis is a long line that should move between positions. changed\n",
    );
    let with_whitespace_ignored = repo
        .open()
        .blame_worktree_with_options(
            "src/main.rs".into(),
            BlameOptions {
                ignore_whitespaces: true,
                movement: BlameMovement::None,
                prefer_commit_date: false,
            },
        )
        .expect("blame with whitespace ignored");
    assert_eq!(with_whitespace_ignored.len(), 2);
}

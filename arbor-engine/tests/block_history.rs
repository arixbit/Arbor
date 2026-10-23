mod common;

use common::{commit, TestRepo};

/// IntelliJ 对照：`Vcs.ShowHistoryForBlock` / `SelectedBlockHistoryAction`
/// 打开的 `VcsSelectionHistoryDialog`。fork 侧 `GitVcs.getVcsBlockHistoryProvider()`
/// 复用的是普通 `GitHistoryProvider`，`BlockLoader` 把选中行范围逐版本跟随；
/// Arbor 用 `git log -L` 直接取「改动过这几行的提交」，并带回每个提交之后
/// 该选区的内容。
#[test]
fn block_history_returns_only_commits_touching_the_selection() {
    let repo = TestRepo::new();
    let first = commit(&repo.path, "notes.txt", "a\nb\nc\nd\ne\n", "first");
    let second = commit(&repo.path, "notes.txt", "a\nb\nC\nd\ne\n", "touch line 3");
    // 只改第一行：不在 3,3 选区的历史里。
    let _third = commit(&repo.path, "notes.txt", "A\nb\nC\nd\ne\n", "touch line 1");

    let engine = repo.open();
    let entries = engine
        .block_history("notes.txt".into(), 3, 3, 20)
        .expect("block history");

    let ids: Vec<String> = entries
        .iter()
        .map(|entry| entry.commit.id.clone())
        .collect();
    assert_eq!(ids, vec![second, first]);
    // 最新一条就是选区当前内容。
    assert_eq!(entries[0].lines, vec!["C".to_string()]);
    assert_eq!(entries[1].lines, vec!["c".to_string()]);
}

#[test]
fn block_history_reports_the_line_number_in_each_revision() {
    let repo = TestRepo::new();
    commit(&repo.path, "notes.txt", "a\nb\nc\n", "first");
    // 在顶部插入一行：选区内容 "c" 不变，但它的行号从 3 后移到 4。
    commit(&repo.path, "notes.txt", "zero\na\nb\nc\n", "prepend");

    let engine = repo.open();
    let entries = engine
        .block_history("notes.txt".into(), 4, 4, 20)
        .expect("block history");

    // `-L` 跟的是行位置：HEAD 上的第 4 行回到父提交就是第 3 行。只插入而\n    // 不改内容的提交不算「改过这段选区」，所以只返回引入它的那个提交。
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].commit.summary, "first");
    assert_eq!(entries[0].start_line, 3);
    assert_eq!(entries[0].lines, vec!["c".to_string()]);
}

#[test]
fn block_history_covers_a_multi_line_selection() {
    let repo = TestRepo::new();
    commit(&repo.path, "notes.txt", "a\nb\nc\nd\n", "first");
    commit(&repo.path, "notes.txt", "a\nB\nC\nd\n", "touch middle");

    let engine = repo.open();
    let entries = engine
        .block_history("notes.txt".into(), 2, 3, 20)
        .expect("block history");

    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].lines, vec!["B".to_string(), "C".to_string()]);
    assert_eq!(entries[1].lines, vec!["b".to_string(), "c".to_string()]);
}

#[test]
fn block_history_ignores_an_empty_or_inverted_range() {
    let repo = TestRepo::new();
    commit(&repo.path, "notes.txt", "a\nb\n", "first");
    let engine = repo.open();

    assert!(engine
        .block_history("notes.txt".into(), 0, 1, 20)
        .expect("zero start")
        .is_empty());
    assert!(engine
        .block_history("notes.txt".into(), 3, 2, 20)
        .expect("inverted range")
        .is_empty());
    assert!(engine
        .block_history("notes.txt".into(), 1, 1, 0)
        .expect("zero limit")
        .is_empty());
}

#[test]
fn block_history_fails_closed_for_an_untracked_path() {
    let repo = TestRepo::new();
    commit(&repo.path, "notes.txt", "a\n", "first");
    repo.write("scratch.txt", "not tracked\n");

    let engine = repo.open();
    let error = engine
        .block_history("scratch.txt".into(), 1, 1, 20)
        .expect_err("untracked path must fail");
    // Git 侧拒绝的理由原样透传，不伪装成空历史。
    assert!(matches!(
        error,
        arbor_engine::EngineError::GitOperation { .. }
    ));
}

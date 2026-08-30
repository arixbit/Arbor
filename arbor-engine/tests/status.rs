//! D5：status 双维度断言。
//! 4 状态夹具：unstaged Modified / Untracked / staged Added / staged Deleted，
//! 每个断言 staged + unstaged 两维与预期一致。

mod common;

use arbor_engine::{ChangeKind, IgnoreRuleSource};

use common::TestRepo;

/// 工作区修改已跟踪文件（未暂存）：staged=Unchanged, unstaged=Modified。
#[test]
fn unstaged_modified() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2-modified");
    let st = r.open().status().unwrap();

    let e = st.iter().find(|e| e.path == "a.txt").expect("a.txt entry");
    assert_eq!(e.staged, ChangeKind::Unchanged);
    assert_eq!(e.unstaged, ChangeKind::Modified);
}

/// 未跟踪新文件：staged=Unchanged, unstaged=Untracked。
#[test]
fn untracked() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("new.txt", "hello");
    let st = r.open().status().unwrap();

    let e = st
        .iter()
        .find(|e| e.path == "new.txt")
        .expect("new.txt entry");
    assert_eq!(e.staged, ChangeKind::Unchanged);
    assert_eq!(e.unstaged, ChangeKind::Untracked);
}

/// 暂存新增文件：staged=Added, unstaged=Unchanged。
#[test]
fn staged_added() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("added.txt", "staged");
    r.git(&["add", "added.txt"]);
    let st = r.open().status().unwrap();

    let e = st
        .iter()
        .find(|e| e.path == "added.txt")
        .expect("added.txt entry");
    assert_eq!(e.staged, ChangeKind::Added);
    assert_eq!(e.unstaged, ChangeKind::Unchanged);
}

/// 暂存删除已跟踪文件（索引 + 工作区均删）：staged=Deleted, unstaged=Unchanged。
#[test]
fn staged_deleted() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    common::commit(&r.path, "b.txt", "v1", "add b");

    // git rm 同时删索引与工作区 -> 纯 staged Deleted（unstaged 无条目 = Unchanged）
    r.git(&["rm", "-q", "b.txt"]);
    let st = r.open().status().unwrap();

    let e = st.iter().find(|e| e.path == "b.txt").expect("b.txt entry");
    assert_eq!(e.staged, ChangeKind::Deleted);
    assert_eq!(e.unstaged, ChangeKind::Unchanged);
}

/// 混合：暂存后工作区再次修改 -> staged=Modified, unstaged=Modified。
#[test]
fn staged_and_unstaged_modified() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("a.txt", "v2-staged");
    r.git(&["add", "a.txt"]);
    r.write("a.txt", "v3-worktree");
    let st = r.open().status().unwrap();

    let e = st.iter().find(|e| e.path == "a.txt").expect("a.txt entry");
    assert_eq!(e.staged, ChangeKind::Modified);
    assert_eq!(e.unstaged, ChangeKind::Modified);
}

#[test]
fn status_paths_only_refreshes_requested_pathspec() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    common::commit(&r.path, "b.txt", "v1", "second");
    r.write("a.txt", "v2");
    r.write("b.txt", "v2");
    let st = r.open().status_paths(vec!["a.txt".into()]).unwrap();
    assert_eq!(st.len(), 1);
    assert_eq!(st[0].path, "a.txt");
    assert_eq!(st[0].unstaged, ChangeKind::Modified);
}

/// Ignored paths are visible as a separate status until the user explicitly
/// chooses the Add to Git action.
#[test]
fn ignored_file_is_reported_separately() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write(".gitignore", "build/\n");
    r.write("build/generated.txt", "generated");
    let st = r.open().status().unwrap();

    let e = st
        .iter()
        .find(|e| e.path == "build/generated.txt")
        .expect("ignored file entry");
    assert_eq!(e.staged, ChangeKind::Unchanged);
    assert_eq!(e.unstaged, ChangeKind::Ignored);
}

#[test]
fn generated_ignored_directories_are_excluded_without_hiding_tracked_files() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write("target/tracked.txt", "tracked");
    r.git(&["add", "target/tracked.txt"]);
    common::commit(
        &r.path,
        "target/tracked.txt",
        "tracked",
        "tracked target file",
    );
    r.write(".gitignore", ".build/\ntarget/\n");
    r.write(".build/DerivedData/large-output.bin", "generated");
    r.write("target/tracked.txt", "changed");
    let entries = r.open().status().unwrap();

    assert!(
        entries
            .iter()
            .all(|entry| !entry.path.starts_with(".build/") || entry.path == ".build/"),
        "generated directory contents should remain collapsed: {entries:?}"
    );
    assert!(
        entries.iter().any(|entry| {
            entry.path == "target/tracked.txt" && entry.unstaged == ChangeKind::Modified
        }),
        "tracked files under generated directory names must remain visible: {entries:?}"
    );
}

#[test]
fn explicitly_staging_an_ignored_file_adds_its_contents_to_the_index() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");

    r.write(".gitignore", "*.tmp\n");
    r.write("secret.tmp", "must be committed");
    let repo = r.open();

    let ignored = repo
        .status()
        .unwrap()
        .into_iter()
        .find(|entry| entry.path == "secret.tmp")
        .expect("ignored file entry");
    assert_eq!(ignored.unstaged, ChangeKind::Ignored);

    // The UI confirmation is the safety boundary. Once explicitly approved,
    // the existing staging primitive must be able to add the ignored path.
    repo.stage("secret.tmp".into())
        .expect("explicitly stage ignored file");

    let staged = r.git(&["ls-files", "--stage", "--", "secret.tmp"]);
    assert!(
        staged.contains("secret.tmp"),
        "ignored path should be indexed: {staged}"
    );
    let final_entry = repo
        .status()
        .unwrap()
        .into_iter()
        .find(|entry| entry.path == "secret.tmp")
        .expect("staged ignored file entry");
    assert_eq!(final_entry.staged, ChangeKind::Added);
    assert_eq!(final_entry.unstaged, ChangeKind::Unchanged);
}

#[test]
fn ignored_rule_reports_gitignore_source_and_pattern() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "v1", "init");
    r.write(".gitignore", "build/\n*.tmp\n");
    r.write("build/generated.txt", "generated");
    r.write("scratch.tmp", "temporary");

    let rules = r.open().ignored_rules().unwrap();
    let build = rules.iter().find(|rule| rule.path == "build/");
    let scratch = rules.iter().find(|rule| rule.path == "scratch.tmp");
    assert!(build.is_some() || rules.iter().any(|rule| rule.path == "build/generated.txt"));
    assert!(scratch.is_some());
    let scratch = scratch.unwrap();
    assert_eq!(scratch.source, IgnoreRuleSource::Gitignore);
    assert_eq!(scratch.pattern, "*.tmp");
    assert!(scratch.line > 0);
}

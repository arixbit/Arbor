mod common;

use common::{git, TestRepo};

/// IntelliJ 对照：`GitCommittedChangeListProvider.getOneList` 的改名兜底。
/// fork 用 `--after=commitTime` 的文件历史最后一条记录解析文件在该提交时的
/// 路径；Arbor 的 `path_at_revision` 沿首父链回溯并 follow 改名。
#[test]
fn path_at_revision_returns_current_path_without_rename() {
    let repo = TestRepo::new();
    let first = common::commit(&repo.path, "notes.txt", "one\n", "first");
    let head = common::commit(&repo.path, "notes.txt", "two\n", "second");

    let engine = repo.open();
    assert_eq!(
        engine
            .path_at_revision(head.clone(), "notes.txt".into())
            .unwrap(),
        Some("notes.txt".into())
    );
    assert_eq!(
        engine
            .path_at_revision(first, "notes.txt".into())
            .unwrap(),
        Some("notes.txt".into())
    );
}

#[test]
fn path_at_revision_resolves_rename_backwards_from_head() {
    let repo = TestRepo::new();
    let first = common::commit(&repo.path, "old-name.txt", "content\n", "first");
    // 带内容改动的重命名：git mv + 修改，等价于 fork 覆盖的 rewrite 场景。
    repo.git(&["mv", "old-name.txt", "new-name.txt"]);
    repo.write("new-name.txt", "changed\n");
    let rename = repo.git(&[
        "-c",
        "user.name=Arbor Test",
        "-c",
        "user.email=test@arbor.local",
        "commit",
        "-m",
        "rename",
    ]);
    let head = repo.git(&["rev-parse", "HEAD"]);
    let _ = rename;
    let _ = head.clone();

    let engine = repo.open();
    // HEAD 上是现名：直接命中。
    assert_eq!(
        engine
            .path_at_revision(head.trim().to_string(), "new-name.txt".into())
            .unwrap(),
        Some("new-name.txt".into())
    );
    // 首个提交上是旧名：follow 兜底解析出当时路径。
    assert_eq!(
        engine
            .path_at_revision(first, "new-name.txt".into())
            .unwrap(),
        Some("old-name.txt".into())
    );
}

#[test]
fn path_at_revision_fails_closed_for_missing_file_and_unknown_revision() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "a.txt", "one\n", "first");
    let head = repo.git(&["rev-parse", "HEAD"]);

    let engine = repo.open();
    // 文件在 HEAD 不存在：无法解析。
    assert_eq!(
        engine
            .path_at_revision(head.trim().to_string(), "missing.txt".into())
            .unwrap(),
        None
    );
    // 未知的 revision 表达式：fail-closed 返回错误而不是猜测。
    assert!(engine
        .path_at_revision("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".into(), "a.txt".into())
        .is_err());
    // 空 revision / 空 path：fail-closed None。
    assert_eq!(engine.path_at_revision("".into(), "a.txt".into()).unwrap(), None);
    assert_eq!(
        engine
            .path_at_revision(head.trim().to_string(), "".into())
            .unwrap(),
        None
    );
}

#[test]
fn path_at_revision_follows_chain_through_multiple_renames() {
    let repo = TestRepo::new();
    let first = common::commit(&repo.path, "one.txt", "content\n", "first");
    repo.git(&["mv", "one.txt", "two.txt"]);
    repo.git(&[
        "-c",
        "user.name=Arbor Test",
        "-c",
        "user.email=test@arbor.local",
        "commit",
        "-m",
        "rename one",
    ]);
    repo.git(&["mv", "two.txt", "three.txt"]);
    repo.git(&[
        "-c",
        "user.name=Arbor Test",
        "-c",
        "user.email=test@arbor.local",
        "commit",
        "-m",
        "rename two",
    ]);

    let engine = repo.open();
    let head = git(&repo.path, &["rev-parse", "HEAD"]);
    assert_eq!(
        engine
            .path_at_revision(head.trim().to_string(), "three.txt".into())
            .unwrap(),
        Some("three.txt".into())
    );
    assert_eq!(
        engine
            .path_at_revision(first, "three.txt".into())
            .unwrap(),
        Some("one.txt".into())
    );
}

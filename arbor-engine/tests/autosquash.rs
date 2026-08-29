//! v0.9：squash!/fixup! 标题自动归组。

mod common;

use arbor_engine::RebaseAction;
use common::TestRepo;

#[test]
fn autosquash_moves_squash_commit_after_target() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "feature.txt", "v1", "add feature");
    common::commit(&r.path, "feature.txt", "v2", "squash! add feature");
    common::commit(&r.path, "next.txt", "next", "next");

    let outcome = r
        .open()
        .rebase_with_options(
            onto.clone(),
            vec![RebaseAction::Pick, RebaseAction::Pick, RebaseAction::Pick],
            false,
            true,
        )
        .unwrap();
    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["rev-list", "--count", &format!("{onto}..HEAD")]),
        "2"
    );
    assert_eq!(r.git(&["log", "-2", "--format=%s"]), "next\nadd feature");
    assert_eq!(
        r.git(&["show", "-s", "--format=%B", "HEAD~1"]),
        "add feature\n\nsquash! add feature"
    );
    assert_eq!(r.read("feature.txt"), "v2");
}

#[test]
fn native_autosquash_matches_commit_and_rebase_executor() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "feature.txt", "v1", "add feature");
    common::commit(&r.path, "feature.txt", "v2", "fixup! add feature");

    let outcome = r
        .open()
        .rebase_with_advanced_options(
            onto,
            vec![RebaseAction::Pick, RebaseAction::Pick],
            false,
            true,
            false,
            false,
            false,
        )
        .expect("native autosquash");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "add feature");
    assert_eq!(r.git(&["rev-list", "--count", "HEAD~1..HEAD"]), "1");
    assert_eq!(r.read("feature.txt"), "v2");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn autosquash_todo_execution_matches_commit_and_rebase_executor() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "feature.txt", "v1", "add feature");
    let target = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "feature.txt", "v2", "fixup! add feature");

    let repo = r.open();
    let todo = repo
        .rebase_todo(onto.clone(), true)
        .expect("autosquash todo");
    assert_eq!(todo.items.len(), 2);
    assert_eq!(todo.items[0].commit_id, target);
    assert_eq!(todo.items[1].action, arbor_engine::RebaseTodoAction::Fixup);

    let outcome = repo
        .rebase_with_todo(onto, todo, false)
        .expect("execute autosquashed todo");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "HEAD~1..HEAD"]), "1");
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "add feature");
    assert_eq!(r.read("feature.txt"), "v2");
}

#[test]
fn autosquash_root_target_uses_root_rebase_and_collapses_fixup() {
    let r = TestRepo::new();
    common::commit(&r.path, "feature.txt", "v1", "root feature");
    let target = r.git(&["rev-parse", "HEAD"]);
    r.write("feature.txt", "v2");
    r.git(&["add", "feature.txt"]);
    r.git(&["commit", "-q", "-m", "fixup! root feature"]);
    let fixup = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let todo = repo
        .rebase_root_todo(true, false)
        .expect("root autosquash todo");
    assert_eq!(todo.onto, "");
    assert_eq!(todo.items[0].commit_id, target);
    assert_eq!(todo.items[0].action, arbor_engine::RebaseTodoAction::Pick);
    assert_eq!(todo.items[1].commit_id, fixup);
    assert_eq!(todo.items[1].action, arbor_engine::RebaseTodoAction::Fixup);

    let outcome = repo
        .rebase_root_with_todo_and_policy(todo, false, arbor_engine::LocalChangesSavePolicy::Stash)
        .expect("root autosquash execution");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "HEAD"]), "1");
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "root feature");
    assert_eq!(r.read("feature.txt"), "v2");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn native_autosquash_root_matches_commit_and_rebase_executor() {
    let r = TestRepo::new();
    common::commit(&r.path, "feature.txt", "v1", "root feature");
    r.write("feature.txt", "v2");
    r.git(&["add", "feature.txt"]);
    r.git(&["commit", "-q", "-m", "fixup! root feature"]);

    let outcome = r
        .open()
        .rebase_with_advanced_options(
            String::new(),
            vec![RebaseAction::Pick, RebaseAction::Pick],
            false,
            true,
            false,
            false,
            true,
        )
        .expect("native root autosquash");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "HEAD"]), "1");
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "root feature");
    assert_eq!(r.read("feature.txt"), "v2");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn autosquash_fixup_does_not_append_message() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "feature.txt", "v1", "add feature");
    common::commit(&r.path, "feature.txt", "v2", "fixup! add feature");

    r.open()
        .rebase_with_options(
            onto,
            vec![RebaseAction::Pick, RebaseAction::Pick],
            false,
            true,
        )
        .unwrap();
    assert_eq!(r.git(&["rev-list", "--count", "HEAD~1..HEAD"]), "1");
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "add feature");
    assert_eq!(r.read("feature.txt"), "v2");
}

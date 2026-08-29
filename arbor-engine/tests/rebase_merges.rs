//! v0.9：近似 `git rebase --rebase-merges` 的拓扑重放。

mod common;

use arbor_engine::RebaseAction;
use common::TestRepo;

#[test]
fn preserves_merge_commit_and_side_branch_tree() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post");

    // 原生 merge-preserving todo 先展开 side branch，再展开 first-parent；
    // merge 节点本身不占 action 位。
    let outcome = r
        .open()
        .rebase_with_options(
            onto.clone(),
            vec![RebaseAction::Pick, RebaseAction::Pick, RebaseAction::Pick],
            true,
            false,
        )
        .unwrap();
    assert!(!outcome.paused);
    assert_eq!(r.read("main.txt"), "main");
    assert_eq!(r.read("feature.txt"), "feature");
    assert_eq!(r.read("post.txt"), "post");
    assert_eq!(
        r.git(&["rev-list", "--merges", "--count", &format!("{onto}..HEAD")]),
        "1"
    );
    assert_eq!(r.git(&["status", "--porcelain"]), "");
}

#[test]
fn preserve_merges_supports_squash_and_edit_continue() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "feature.txt", "v1", "first");
    common::commit(&r.path, "feature.txt", "v2", "second");
    let outcome = r
        .open()
        .rebase_with_options(
            onto.clone(),
            vec![RebaseAction::Pick, RebaseAction::Squash],
            true,
            false,
        )
        .unwrap();
    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["rev-list", "--count", &format!("{onto}..HEAD")]),
        "1"
    );
    assert_eq!(r.read("feature.txt"), "v2");

    let onto = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "feature.txt", "v3", "edit me");
    let paused = r
        .open()
        .rebase_with_options(onto, vec![RebaseAction::Edit], true, false)
        .unwrap();
    assert!(paused.paused);
    assert_eq!(
        paused.pause_reason,
        Some(arbor_engine::RebasePauseReason::Edit)
    );
    r.write("feature.txt", "edited during rebase");
    let completed = r.open().rebase_continue().unwrap();
    assert!(!completed.paused);
    assert_eq!(r.read("feature.txt"), "edited during rebase");
}

#[test]
fn preserve_merges_allows_intra_branch_fixup_but_keeps_merge_boundary() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "v1", "feature change");
    common::commit(&r.path, "feature.txt", "v2", "feature follow-up");
    let follow_up = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let repo = r.open();
    let mut todo = repo
        .rebase_todo_with_options(onto.clone(), false, true)
        .expect("merge-preserving todo");
    let follow_up_item = todo
        .items
        .iter_mut()
        .find(|item| item.commit_id == follow_up)
        .expect("intra-branch follow-up row");
    assert!(follow_up_item.can_squash_or_fixup);
    follow_up_item.action = arbor_engine::RebaseTodoAction::Fixup;
    todo.items
        .iter_mut()
        .find(|item| item.commit_id == feature)
        .expect("feature predecessor row")
        .action = arbor_engine::RebaseTodoAction::Drop;

    let dropped_predecessor_error = repo
        .rebase_with_todo(onto.clone(), todo.clone(), true)
        .expect_err("fixup after dropping its predecessor must be rejected");
    assert!(
        dropped_predecessor_error
            .to_string()
            .contains("no valid kept predecessor"),
        "unexpected dropped-predecessor error: {dropped_predecessor_error}"
    );

    todo.items
        .iter_mut()
        .find(|item| item.commit_id == feature)
        .expect("feature predecessor row")
        .action = arbor_engine::RebaseTodoAction::Pick;

    let outcome = repo
        .rebase_with_todo(onto, todo, true)
        .expect("intra-branch fixup");
    assert!(!outcome.paused);
    assert_eq!(r.read("feature.txt"), "v2");
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "HEAD"]), "1");
    assert!(!r
        .git(&["log", "--format=%s", "HEAD"])
        .lines()
        .any(|line| line == "feature follow-up"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn preserve_merges_applies_actions_to_side_branch_todo_entries() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature change");
    let feature = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    let main = r.git(&["rev-parse", "HEAD"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    let merge = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "post.txt", "post", "post change");
    let post = r.git(&["rev-parse", "HEAD"]);

    // 结构化编辑器展示 merge 拓扑行；Git 原生 --rebase-merges 的
    // label/reset/merge 指令仍由执行器保留。
    let mut todo = r
        .open()
        .rebase_todo_with_options(onto.clone(), false, true)
        .expect("merge-preserving todo");
    assert_eq!(
        todo.items
            .iter()
            .map(|item| item.commit_id.clone())
            .collect::<Vec<_>>(),
        vec![feature.clone(), main.clone(), merge.clone(), post.clone()]
    );
    todo.items[0].action = arbor_engine::RebaseTodoAction::Drop;
    todo.items[1].action = arbor_engine::RebaseTodoAction::Reword;
    todo.items[1].message = Some("renamed main change".into());

    let outcome = r.open().rebase_with_todo(onto.clone(), todo, true).unwrap();
    assert!(
        !outcome.paused,
        "preserve-merges action mapping failed: {outcome:?}"
    );
    assert_eq!(r.read("main.txt"), "main");
    assert!(
        !r.exists("feature.txt"),
        "dropped side branch must not be replayed"
    );
    assert_eq!(r.read("post.txt"), "post");
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "post change");
    let log = r.git(&["log", "--format=%s", "HEAD"]);
    assert!(log.lines().any(|line| line == "renamed main change"));
    assert_ne!(merge, r.git(&["rev-parse", "HEAD"]));
    assert_ne!(main, r.git(&["rev-parse", "HEAD"]));
    assert_ne!(feature, r.git(&["rev-parse", "HEAD"]));
    assert_ne!(post, r.git(&["rev-parse", "HEAD"]));
}

#[test]
fn preserve_merges_applies_structured_squash_message_on_a_side_branch() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "one", "feature one");
    let feature_one = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "feature.txt", "two", "feature two");
    let feature_two = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let repo = r.open();
    let mut todo = repo
        .rebase_todo_with_options(onto, false, true)
        .expect("merge-preserving todo");
    let feature_two_item = todo
        .items
        .iter_mut()
        .find(|item| item.commit_id == feature_two)
        .expect("side branch follow-up");
    feature_two_item.action = arbor_engine::RebaseTodoAction::Squash;
    feature_two_item.message = Some("feature combined\n\nreviewed".into());

    let outcome = repo
        .rebase_with_todo(todo.onto.clone(), todo, true)
        .expect("merge-preserving squash");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "HEAD"]), "1");
    let log = r.git(&["log", "--format=%B", "HEAD"]);
    assert!(log.contains("feature combined\n\nreviewed"), "log: {log}");
    assert!(log.contains("main change"), "log: {log}");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
    assert_ne!(feature_one, r.git(&["rev-parse", "HEAD"]));
}

#[test]
fn rebase_range_matches_default_and_preserve_merge_action_models() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    let feature = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    let main = r.git(&["rev-parse", "HEAD"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post");
    let post = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let default_ids: Vec<_> = repo
        .rebase_range(onto.clone(), false)
        .unwrap()
        .into_iter()
        .map(|commit| commit.id)
        .collect();
    let preserve_ids: Vec<_> = repo
        .rebase_range(onto, true)
        .unwrap()
        .into_iter()
        .map(|commit| commit.id)
        .collect();

    assert_eq!(default_ids, vec![main.clone(), post.clone()]);
    assert_eq!(preserve_ids, vec![feature, main, post]);
}

#[test]
fn merge_preserving_todo_uses_native_non_merge_topology_order() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    let feature = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    let main = r.git(&["rev-parse", "HEAD"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post");
    let post = r.git(&["rev-parse", "HEAD"]);

    let todo = r
        .open()
        .rebase_todo_with_options(onto, false, true)
        .expect("merge-preserving todo");
    let ids: Vec<_> = todo
        .items
        .iter()
        .map(|item| item.commit_id.clone())
        .collect();
    assert_eq!(
        ids,
        vec![
            feature.clone(),
            main.clone(),
            r.git(&["rev-parse", "HEAD~1"]),
            post
        ]
    );
    assert!(todo.items[2].is_merge_commit);
    assert!(todo.items[..2].iter().all(|item| !item.is_merge_commit));
}

#[test]
fn merge_preserving_structured_todo_rejects_cross_branch_squash() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    let feature = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    let main = r.git(&["rev-parse", "HEAD"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post");
    let post = r.git(&["rev-parse", "HEAD"]);

    let mut todo = r
        .open()
        .rebase_todo_with_options(onto.clone(), false, true)
        .expect("merge-preserving todo");
    assert_eq!(
        todo.items
            .iter()
            .map(|item| item.commit_id.clone())
            .collect::<Vec<_>>(),
        vec![feature, main, r.git(&["rev-parse", "HEAD~1"]), post]
    );
    assert!(!todo.items[1].can_squash_or_fixup);
    todo.items[2].action = arbor_engine::RebaseTodoAction::Drop;

    let merge_error = r
        .open()
        .rebase_with_todo(onto.clone(), todo.clone(), true)
        .expect_err("merge topology rows must remain pick");
    assert!(
        merge_error.to_string().contains("merge commit")
            && merge_error.to_string().contains("must remain pick"),
        "unexpected merge-row error: {merge_error}"
    );

    todo.items[2].action = arbor_engine::RebaseTodoAction::Pick;
    todo.items[1].action = arbor_engine::RebaseTodoAction::Squash;

    let error = r
        .open()
        .rebase_with_todo(onto, todo, true)
        .expect_err("structured merge todo must reject cross-control squash");
    assert!(
        error.to_string().contains("squash/fixup"),
        "unexpected error: {error}"
    );
}

#[test]
fn merge_preserving_structured_todo_rejects_rows_crossing_branch_segments() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature change");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let mut todo = r
        .open()
        .rebase_todo_with_options(onto.clone(), false, true)
        .expect("merge-preserving todo");
    todo.items.swap(0, 1);
    todo.items[0].action = arbor_engine::RebaseTodoAction::Reword;
    todo.items[0].message = Some("renamed main change".into());
    todo.items[1].action = arbor_engine::RebaseTodoAction::Drop;

    let error = r
        .open()
        .rebase_with_todo(onto, todo, true)
        .expect_err("rows must not cross a native branch segment boundary");
    assert!(
        error.to_string().contains("merge control boundary"),
        "unexpected cross-segment error: {error}"
    );
}

#[test]
fn merge_preserving_structured_todo_reorders_rows_inside_a_branch_segment() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature-one.txt", "one", "feature one");
    common::commit(&r.path, "feature-two.txt", "two", "feature two");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let mut todo = r
        .open()
        .rebase_todo_with_options(onto.clone(), false, true)
        .expect("merge-preserving todo");
    let feature_one = todo
        .items
        .iter()
        .position(|item| item.summary == "feature one")
        .expect("feature one row");
    let feature_two = todo
        .items
        .iter()
        .position(|item| item.summary == "feature two")
        .expect("feature two row");
    assert_eq!(feature_two, feature_one + 1);
    todo.items.swap(feature_one, feature_two);

    let outcome = r
        .open()
        .rebase_with_todo(onto, todo, true)
        .expect("same-segment reorder should execute");
    assert!(!outcome.paused);
    assert_eq!(r.read("feature-one.txt"), "one");
    assert_eq!(r.read("feature-two.txt"), "two");

    let feature_one_id = r.git(&[
        "log",
        "--all",
        "--format=%H",
        "--grep=feature one",
        "-n",
        "1",
    ]);
    let feature_two_id = r.git(&[
        "log",
        "--all",
        "--format=%H",
        "--grep=feature two",
        "-n",
        "1",
    ]);
    assert_eq!(
        r.git(&["rev-parse", &format!("{feature_one_id}^")]),
        feature_two_id,
        "the edited order must be passed to Git's native pick slots"
    );
}

#[test]
fn root_merge_preserving_todo_exposes_and_preserves_merge_row() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["switch", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature change");
    r.git(&["switch", "-q", "main"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let repo = r.open();
    let mut todo = repo
        .rebase_root_todo(false, true)
        .expect("root merge-preserving todo");
    assert!(todo.items.iter().any(|item| item.is_merge_commit));
    assert!(todo
        .items
        .iter()
        .filter(|item| item.is_merge_commit)
        .all(|item| item.action == arbor_engine::RebaseTodoAction::Pick));
    let merge_item = todo
        .items
        .iter_mut()
        .find(|item| item.is_merge_commit)
        .expect("merge row");
    merge_item.action = arbor_engine::RebaseTodoAction::Reword;
    merge_item.message = Some("rewritten merge message".into());

    let outcome = repo
        .rebase_root_with_todo_and_policy(todo, true, arbor_engine::LocalChangesSavePolicy::Stash)
        .expect("root merge-preserving rebase");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "--merges", "HEAD"]), "1");
    assert!(r
        .git(&["log", "--format=%s", "HEAD"])
        .lines()
        .any(|line| line == "rewritten merge message"));
}

#[test]
fn root_merge_preserving_todo_rewords_root_and_keeps_merge_descendant() {
    let r = TestRepo::new();
    let root = common::commit(&r.path, "root.txt", "root", "root commit");
    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["switch", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature change");
    r.git(&["switch", "-q", "main"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let repo = r.open();
    let mut todo = repo
        .rebase_root_todo(false, true)
        .expect("root merge-preserving todo");
    let root_item = todo
        .items
        .iter_mut()
        .find(|item| item.commit_id == root)
        .expect("root row");
    root_item.action = arbor_engine::RebaseTodoAction::Reword;
    root_item.message = Some("rewritten root message\n\nbody".into());

    let outcome = repo
        .rebase_root_with_todo_and_policy(todo, true, arbor_engine::LocalChangesSavePolicy::Stash)
        .expect("root merge-preserving reword");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "--merges", "HEAD"]), "1");
    assert!(r
        .git(&["log", "--format=%B", "--all"])
        .contains("rewritten root message\n\nbody"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn merge_preserving_todo_rewords_non_root_merge_row() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature change");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let repo = r.open();
    let mut todo = repo
        .rebase_todo_with_options(onto.clone(), false, true)
        .expect("merge-preserving todo");
    let merge_item = todo
        .items
        .iter_mut()
        .find(|item| item.is_merge_commit)
        .expect("merge row");
    merge_item.action = arbor_engine::RebaseTodoAction::Reword;
    merge_item.message = Some("rewritten non-root merge message".into());

    let outcome = repo
        .rebase_with_todo(onto, todo, true)
        .expect("non-root merge reword");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "--merges", "HEAD"]), "1");
    assert!(r
        .git(&["log", "--format=%s", "HEAD"])
        .lines()
        .any(|line| line == "rewritten non-root merge message"));
}

#[test]
fn preserve_merges_autosquash_collapses_side_branch_fixup() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "v1", "add feature");
    common::commit(&r.path, "feature.txt", "v2", "fixup! add feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post", "post change");

    let repo = r.open();
    let actions = repo
        .rebase_range_for_branch(onto.clone(), true, false, "main".into())
        .expect("merge-preserving range")
        .into_iter()
        .map(|_| RebaseAction::Pick)
        .collect();
    let outcome = repo
        .rebase_with_advanced_options(onto, actions, true, true, false, false, false)
        .expect("preserve-merges autosquash");

    assert!(!outcome.paused);
    assert_eq!(r.read("feature.txt"), "v2");
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "HEAD"]), "1");
    assert!(!r
        .git(&["log", "--format=%s", "HEAD"])
        .lines()
        .any(|line| line == "fixup! add feature"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

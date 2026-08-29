//! REBASE-001 高级选项：`--root`、`--keep-empty`、`--update-refs`。

mod common;

use arbor_engine::{
    GitCancelHandle, LocalChangesSavePolicy, MultiRootRebaseSpec, OperationKind, RebaseAction,
};
use common::TestRepo;

fn all_picks(
    repo: &std::sync::Arc<arbor_engine::Repository>,
    onto: &str,
    root: bool,
) -> Vec<RebaseAction> {
    repo.rebase_range_with_options(onto.to_string(), false, root)
        .expect("rebase range")
        .into_iter()
        .map(|_| RebaseAction::Pick)
        .collect()
}

#[test]
fn root_rebase_replays_root_commit_onto_unrelated_history() {
    let r = TestRepo::new();
    common::commit(&r.path, "root.txt", "root\n", "root commit");
    common::commit(&r.path, "feature.txt", "feature\n", "feature commit");
    let original_head = r.git(&["rev-parse", "HEAD"]);

    r.git(&["switch", "--orphan", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto commit");
    let onto = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "main"]);

    let repo = r.open();
    let actions = all_picks(&repo, &onto, true);
    assert_eq!(actions.len(), 2);
    let outcome = repo
        .rebase_with_advanced_options(onto.clone(), actions, false, false, false, false, true)
        .expect("root rebase");
    assert!(!outcome.paused);
    assert_ne!(outcome.head_id, original_head);
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse"]),
        "onto commit\nroot commit\nfeature commit"
    );
    assert_eq!(r.git(&["rev-parse", "HEAD~2"]), onto);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn root_rebase_uses_structured_squash_message_in_native_git_path() {
    let r = TestRepo::new();
    common::commit(&r.path, "root.txt", "root\n", "root commit");
    common::commit(&r.path, "feature.txt", "one\n", "feature one");
    common::commit(&r.path, "feature.txt", "two\n", "feature two");

    let repo = r.open();
    let mut todo = repo.rebase_root_todo(false, false).expect("root todo");
    todo.items[2].action = arbor_engine::RebaseTodoAction::Squash;
    todo.items[2].message = Some("feature combined\n\nreviewed".into());

    let outcome = repo
        .rebase_root_with_todo_and_policy(todo, false, LocalChangesSavePolicy::Stash)
        .expect("root squash");

    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["show", "--format=%B", "--no-patch", "HEAD"]),
        "feature combined\n\nreviewed"
    );
    assert_eq!(r.read("feature.txt"), "two\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn root_rebase_can_preserve_merge_topology() {
    let r = TestRepo::new();
    common::commit(&r.path, "root.txt", "root\n", "root");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post\n", "post");

    r.git(&["switch", "--orphan", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    let onto = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "main"]);

    let repo = r.open();
    let actions = all_picks(&repo, &onto, true);
    assert_eq!(actions.len(), 4);
    repo.rebase_with_advanced_options(onto.clone(), actions, true, false, false, false, true)
        .expect("root rebase preserving merges");
    assert_eq!(r.git(&["rev-parse", "HEAD~4"]), onto);
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "HEAD"]), "1");
    assert_eq!(r.git(&["show", "HEAD:feature.txt"]), "feature");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn noninteractive_branch_rebase_uses_native_git_options() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    let base = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    r.git(&["branch", "onto", &base]);
    r.git(&["switch", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    let onto = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "main"]);

    let outcome = r
        .open()
        .rebase_branch_with_options_and_policy(
            onto,
            "main".into(),
            true,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("noninteractive rebase");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["branch", "--show-current"]), "main");
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "main"]), "1");
    assert_eq!(r.git(&["show", "main:feature.txt"]), "feature");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn root_rebase_without_onto_supports_range_and_branch_execution() {
    let r = TestRepo::new();
    common::commit(&r.path, "root.txt", "root\n", "root");
    common::commit(&r.path, "a.txt", "a\n", "a");
    common::commit(&r.path, "b.txt", "b\n", "b");

    let repo = r.open();
    let range = repo
        .rebase_range_for_branch("".into(), false, true, "main".into())
        .expect("root range without onto");
    assert_eq!(range.len(), 3);

    let mut actions = range
        .into_iter()
        .map(|_| RebaseAction::Pick)
        .collect::<Vec<_>>();
    actions[0] = RebaseAction::Reword {
        message: "rewritten root".into(),
    };
    let outcome = repo
        .rebase_branch_with_advanced_options_and_policy(
            "".into(),
            "main".into(),
            actions,
            false,
            false,
            false,
            false,
            true,
            LocalChangesSavePolicy::Stash,
        )
        .expect("root rebase without onto");
    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse"]),
        "rewritten root\na\nb"
    );
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn keep_empty_preserves_an_intentionally_empty_commit() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["commit", "--allow-empty", "-q", "-m", "intentional empty"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");

    let base = r.git(&["rev-parse", "HEAD~2"]);
    r.git(&["branch", "onto", &base]);
    r.git(&["switch", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    let onto = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "main"]);

    let repo = r.open();
    let actions = all_picks(&repo, &onto, false);
    assert_eq!(actions.len(), 2);
    repo.rebase_with_advanced_options(onto, actions, false, false, true, false, false)
        .expect("rebase with keep-empty");
    let subjects = r.git(&["log", "--format=%s", "--reverse"]);
    assert!(subjects.lines().any(|line| line == "intentional empty"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn update_refs_moves_another_local_branch_into_rewritten_history() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    common::commit(&r.path, "a.txt", "a\n", "a");
    let old_a = r.git(&["rev-parse", "HEAD"]);
    r.git(&["branch", "topic"]);
    common::commit(&r.path, "b.txt", "b\n", "b");

    let base = r.git(&["rev-parse", "HEAD~2"]);
    r.git(&["branch", "onto", &base]);
    r.git(&["switch", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    let onto = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "main"]);

    let repo = r.open();
    let actions = all_picks(&repo, &onto, false);
    repo.rebase_with_advanced_options(onto.clone(), actions, false, false, false, true, false)
        .expect("rebase with update-refs");
    let new_topic = r.git(&["rev-parse", "topic"]);
    assert_ne!(new_topic, old_a);
    assert_eq!(r.git(&["rev-parse", "topic^"]), onto);
    assert_eq!(r.git(&["merge-base", "--is-ancestor", "topic", "HEAD"]), "");
}

#[test]
fn cancelled_native_structured_rebase_kills_pre_rebase_hook() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    common::commit(&r.path, "feature.txt", "feature\n", "feature");

    let hook = r.path.join(".git/hooks/pre-rebase");
    let marker = r.path.join(".git/pre-rebase.started");
    std::fs::write(
        &hook,
        "#!/bin/sh\nprintf started > .git/pre-rebase.started\nsleep 10\n",
    )
    .expect("write pre-rebase hook");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755))
        .expect("make pre-rebase hook executable");

    let repo = r.open();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.rebase_with_advanced_options_and_policy_and_cancel(
            base,
            vec![RebaseAction::Pick],
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
            worker_cancel,
        )
    });

    for _ in 0..100 {
        if marker.exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(marker.exists(), "pre-rebase hook did not start");
    cancel.cancel();

    let result = worker.join().expect("cancelled native rebase worker");
    assert!(matches!(result, Err(arbor_engine::EngineError::Cancelled)));
    assert!(repo.operation_state().expect("operation state").is_none());
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn selected_branch_range_and_rebase_do_not_use_current_head() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let main_head = r.git(&["rev-parse", "main"]);

    let repo = r.open();
    let range = repo
        .rebase_range_for_branch("main".into(), false, false, "feature".into())
        .expect("selected branch range");
    assert_eq!(range.len(), 1);
    assert_eq!(range[0].summary, "feature");

    let actions = range.into_iter().map(|_| RebaseAction::Pick).collect();
    let outcome = repo
        .rebase_branch_with_advanced_options(
            "main".into(),
            "feature".into(),
            actions,
            false,
            false,
            false,
            false,
            false,
        )
        .expect("selected branch rebase");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert_eq!(r.git(&["rev-parse", "feature^"]), main_head);
    assert_eq!(r.git(&["show", "feature:feature.txt"]), "feature");
}

#[test]
fn restore_branch_if_expected_rolls_back_current_rebased_branch() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let initial = r.git(&["rev-parse", "feature"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let onto = r.git(&["rev-parse", "main"]);

    let repo = r.open();
    let actions = repo
        .rebase_range_for_branch(onto.clone(), false, false, "feature".into())
        .expect("selected branch range")
        .into_iter()
        .map(|_| RebaseAction::Pick)
        .collect();
    repo.rebase_branch_with_advanced_options(
        onto,
        "feature".into(),
        actions,
        false,
        false,
        false,
        false,
        false,
    )
    .expect("selected branch rebase");
    let expected = r.git(&["rev-parse", "feature"]);
    assert_ne!(expected, initial);

    repo.restore_branch_if_expected("feature".into(), initial.clone(), expected)
        .expect("safe branch rollback");
    assert_eq!(r.git(&["rev-parse", "feature"]), initial);
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert_eq!(r.read("feature.txt"), "feature\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn restore_branch_if_expected_does_not_move_changed_branch() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let initial = r.git(&["rev-parse", "feature"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let onto = r.git(&["rev-parse", "main"]);

    let repo = r.open();
    let actions = repo
        .rebase_range_for_branch(onto.clone(), false, false, "feature".into())
        .expect("selected branch range")
        .into_iter()
        .map(|_| RebaseAction::Pick)
        .collect();
    repo.rebase_branch_with_advanced_options(
        onto,
        "feature".into(),
        actions,
        false,
        false,
        false,
        false,
        false,
    )
    .expect("selected branch rebase");
    let expected = r.git(&["rev-parse", "feature"]);
    r.git(&["switch", "-q", "main"]);

    repo.restore_branch_if_expected("feature".into(), initial.clone(), expected)
        .expect("safe non-current branch rollback");
    assert_eq!(r.git(&["branch", "--show-current"]), "main");
    assert_eq!(r.git(&["rev-parse", "feature"]), initial);
    assert_eq!(r.read("main.txt"), "main\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn aborting_selected_branch_rebase_restores_the_original_branch() {
    let r = TestRepo::new();
    common::commit(&r.path, "shared.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "shared.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "shared.txt", "main\n", "main");

    let repo = r.open();
    let actions = repo
        .rebase_range_for_branch("main".into(), false, false, "feature".into())
        .expect("selected branch range")
        .into_iter()
        .map(|_| RebaseAction::Pick)
        .collect();
    let outcome = repo
        .rebase_branch_with_advanced_options(
            "main".into(),
            "feature".into(),
            actions,
            false,
            false,
            false,
            false,
            false,
        )
        .expect("rebase should pause on conflict");
    assert!(outcome.paused);
    repo.rebase_abort().expect("abort selected branch rebase");
    assert_eq!(r.git(&["branch", "--show-current"]), "main");
    assert_eq!(r.read("shared.txt"), "main\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

fn init_nested_repo(path: &std::path::Path) {
    std::fs::create_dir_all(path).expect("nested repo directory");
    common::git(path, &["init", "-q"]);
    common::git(path, &["config", "user.name", "Arbor Test"]);
    common::git(path, &["config", "user.email", "test@arbor.local"]);
    common::git(path, &["config", "commit.gpgsign", "false"]);
    common::git(path, &["symbolic-ref", "HEAD", "refs/heads/main"]);
}

fn make_branch_rebase_spec(
    path: &std::path::Path,
    branch: &str,
    onto: &str,
    interactive: bool,
) -> MultiRootRebaseSpec {
    let repo = arbor_engine::open_repository(path.to_string_lossy().into_owned())
        .expect("open multi-root repo");
    let actions = if interactive {
        repo.rebase_range_for_branch(onto.to_string(), false, false, branch.to_string())
            .expect("multi-root range")
            .into_iter()
            .map(|_| RebaseAction::Pick)
            .collect()
    } else {
        Vec::new()
    };
    MultiRootRebaseSpec {
        root_path: path.to_string_lossy().into_owned(),
        branch: branch.into(),
        onto: onto.into(),
        actions,
        ordered_commit_ids: Vec::new(),
        raw_todo: None,
        preserve_merges: false,
        auto_squash: false,
        keep_empty: false,
        update_refs: false,
        root: false,
        interactive,
        save_policy: LocalChangesSavePolicy::Shelve,
    }
}

#[test]
fn multi_root_rebase_runs_each_root_with_its_own_todo() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let root_onto = r.git(&["rev-parse", "main"]);
    let root_feature_tip = r.git(&["rev-parse", "feature"]);

    let child = r.path.join("nested");
    init_nested_repo(&child);
    common::commit(&child, "base.txt", "base\n", "base");
    common::git(&child, &["switch", "-q", "-c", "feature"]);
    common::commit(&child, "feature.txt", "feature\n", "feature");
    common::git(&child, &["switch", "-q", "main"]);
    common::commit(&child, "main.txt", "main\n", "main");
    let child_onto = common::git(&child, &["rev-parse", "main"]);
    let child_feature_tip = common::git(&child, &["rev-parse", "feature"]);

    let results = arbor_engine::run_multi_root_rebase(vec![
        make_branch_rebase_spec(&r.path, "feature", &root_onto, true),
        make_branch_rebase_spec(&child, "feature", &child_onto, true),
    ])
    .expect("multi-root rebase");
    assert_eq!(results.len(), 2);
    assert!(results
        .iter()
        .all(|result| result.success && result.completed));
    assert_eq!(
        results
            .iter()
            .find(|result| result.root_path == r.path.to_string_lossy())
            .and_then(|result| result.initial_head.as_deref()),
        Some(root_feature_tip.as_str())
    );
    assert_eq!(
        results
            .iter()
            .find(|result| result.root_path == child.to_string_lossy())
            .and_then(|result| result.initial_head.as_deref()),
        Some(child_feature_tip.as_str())
    );
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert_eq!(
        common::git(&child, &["branch", "--show-current"]),
        "feature"
    );
    assert_eq!(r.git(&["rev-parse", "feature^"]), root_onto);
    assert_eq!(common::git(&child, &["rev-parse", "feature^"]), child_onto);
}

#[test]
fn multi_root_raw_todo_uses_each_root_branch_and_native_commands() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let root_feature_tip = r.git(&["rev-parse", "feature"]);
    r.git(&["switch", "-q", "main"]);
    let root_onto = r.git(&["rev-parse", "main"]);

    let child = r.path.join("nested");
    init_nested_repo(&child);
    common::commit(&child, "base.txt", "base\n", "base");
    common::git(&child, &["switch", "-q", "-c", "feature"]);
    common::commit(&child, "feature.txt", "feature\n", "feature");
    let child_feature_tip = common::git(&child, &["rev-parse", "feature"]);
    common::git(&child, &["switch", "-q", "main"]);
    let child_onto = common::git(&child, &["rev-parse", "main"]);

    let root_repo = r.open();
    let root_raw = root_repo
        .rebase_raw_todo_for_branch_with_options_and_policy(
            root_onto.clone(),
            "feature".into(),
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("capture root native todo");
    let root_drop = root_raw.replacen(
        &format!("pick {}", &root_feature_tip[..7]),
        &format!("drop {}", &root_feature_tip[..7]),
        1,
    );

    let child_repo = arbor_engine::open_repository(child.to_string_lossy().into_owned())
        .expect("open child repo");
    let child_raw = child_repo
        .rebase_raw_todo_for_branch_with_options_and_policy(
            child_onto.clone(),
            "feature".into(),
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("capture child native todo");
    let child_drop = child_raw.replacen(
        &format!("pick {}", &child_feature_tip[..7]),
        &format!("drop {}", &child_feature_tip[..7]),
        1,
    );

    let results = arbor_engine::run_multi_root_rebase(vec![
        MultiRootRebaseSpec {
            root_path: r.path.to_string_lossy().into_owned(),
            branch: "feature".into(),
            onto: root_onto.clone(),
            actions: Vec::new(),
            ordered_commit_ids: Vec::new(),
            raw_todo: Some(root_drop),
            preserve_merges: false,
            auto_squash: false,
            keep_empty: false,
            update_refs: false,
            root: false,
            interactive: true,
            save_policy: LocalChangesSavePolicy::Stash,
        },
        MultiRootRebaseSpec {
            root_path: child.to_string_lossy().into_owned(),
            branch: "feature".into(),
            onto: child_onto.clone(),
            actions: Vec::new(),
            ordered_commit_ids: Vec::new(),
            raw_todo: Some(child_drop),
            preserve_merges: false,
            auto_squash: false,
            keep_empty: false,
            update_refs: false,
            root: false,
            interactive: true,
            save_policy: LocalChangesSavePolicy::Stash,
        },
    ])
    .expect("multi-root raw rebase");

    assert!(results
        .iter()
        .all(|result| result.success && result.completed));
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert_eq!(
        common::git(&child, &["branch", "--show-current"]),
        "feature"
    );
    assert_eq!(r.git(&["rev-parse", "feature"]), root_onto);
    assert_eq!(common::git(&child, &["rev-parse", "feature"]), child_onto);
    assert!(r
        .git(&["status", "--porcelain", "--untracked-files=no"])
        .is_empty());
    assert!(common::git(&child, &["status", "--porcelain"]).is_empty());
}

#[test]
fn cancelled_multi_root_raw_todo_keeps_active_root_recoverable_and_skips_later_roots() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let feature_id = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);

    let child = TestRepo::new();
    common::commit(&child.path, "base.txt", "base\n", "base");
    common::commit(&child.path, "feature.txt", "feature\n", "feature");
    let child_feature_id = child.git(&["rev-parse", "HEAD"]);
    child.git(&["switch", "-q", "main"]);
    let child_base = child.git(&["rev-parse", "HEAD~1"]);

    let root_raw = format!("pick {}\nexec sleep 10\n", &feature_id[..7]);
    let child_raw = format!("pick {}\n", &child_feature_id[..7]);
    let cancel = GitCancelHandle::new();
    let worker_cancel = cancel.clone();
    let root_path = r.path.to_string_lossy().into_owned();
    let child_path = child.path.to_string_lossy().into_owned();
    let worker = std::thread::spawn(move || {
        arbor_engine::run_multi_root_rebase_with_cancel(
            vec![
                MultiRootRebaseSpec {
                    root_path,
                    branch: "main".into(),
                    onto: base,
                    actions: Vec::new(),
                    ordered_commit_ids: Vec::new(),
                    raw_todo: Some(root_raw),
                    preserve_merges: false,
                    auto_squash: false,
                    keep_empty: false,
                    update_refs: false,
                    root: false,
                    interactive: true,
                    save_policy: LocalChangesSavePolicy::Stash,
                },
                MultiRootRebaseSpec {
                    root_path: child_path,
                    branch: "main".into(),
                    onto: child_base,
                    actions: Vec::new(),
                    ordered_commit_ids: Vec::new(),
                    raw_todo: Some(child_raw),
                    preserve_merges: false,
                    auto_squash: false,
                    keep_empty: false,
                    update_refs: false,
                    root: false,
                    interactive: true,
                    save_policy: LocalChangesSavePolicy::Stash,
                },
            ],
            worker_cancel,
        )
    });

    std::thread::sleep(std::time::Duration::from_millis(300));
    cancel.cancel();
    let results = worker
        .join()
        .expect("multi-root cancellation worker")
        .expect("multi-root cancellation results");

    assert_eq!(results.len(), 2);
    let root_result = results
        .iter()
        .find(|result| result.root_path == r.path.to_string_lossy())
        .expect("root result");
    assert!(!root_result.success);
    assert!(!root_result.skipped);
    assert!(root_result.requires_finish);
    assert!(root_result.message.contains("recovery"));
    let child_result = results
        .iter()
        .find(|result| result.root_path == child.path.to_string_lossy())
        .expect("child result");
    assert!(child_result.skipped);
    assert_eq!(child.git(&["branch", "--show-current"]), "main");

    r.open().rebase_abort().expect("abort active root rebase");
    assert_eq!(r.git(&["branch", "--show-current"]), "main");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn multi_root_raw_todo_message_editor_can_be_driven_while_batch_waits() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let feature_id = r.git(&["rev-parse", "feature"]);
    r.git(&["switch", "-q", "main"]);
    let repo = r.open();
    let raw = repo
        .rebase_raw_todo_for_branch_with_options_and_policy(
            base.clone(),
            "feature".into(),
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("capture branch raw todo");
    let edited = raw.replacen(
        &format!("pick {}", &feature_id[..7]),
        &format!("reword {}", &feature_id[..7]),
        1,
    );

    let root_path = r.path.to_string_lossy().into_owned();
    let worker = std::thread::spawn(move || {
        arbor_engine::run_multi_root_rebase(vec![MultiRootRebaseSpec {
            root_path,
            branch: "feature".into(),
            onto: base,
            actions: Vec::new(),
            ordered_commit_ids: Vec::new(),
            raw_todo: Some(edited),
            preserve_merges: false,
            auto_squash: false,
            keep_empty: false,
            update_refs: false,
            root: false,
            interactive: true,
            save_policy: LocalChangesSavePolicy::Stash,
        }])
    });

    let mut pending = None;
    for _ in 0..1500 {
        if let Some(message) = repo.rebase_pending_message().expect("read pending message") {
            pending = Some(message);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(pending
        .as_deref()
        .is_some_and(|message| message.starts_with("feature\n")));
    repo.rebase_set_pending_message("rewritten multi-root feature\n".into())
        .expect("write pending message");
    assert!(repo
        .rebase_pending_message()
        .expect("read handled multi-root pending message")
        .is_none());

    let results = worker
        .join()
        .expect("multi-root raw worker")
        .expect("multi-root raw rebase");
    assert_eq!(results.len(), 1);
    assert!(results[0].success && results[0].completed, "{results:?}");
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert!(r
        .git(&["log", "--format=%s", "feature"])
        .lines()
        .any(|line| line == "rewritten multi-root feature"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn multi_root_raw_todo_message_editor_remains_available_after_continue() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "a.txt", "a\n", "a");
    let first_id = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "b.txt", "b\n", "b");
    let second_id = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);

    let repo = r.open();
    let raw = repo
        .rebase_raw_todo_for_branch_with_options_and_policy(
            base.clone(),
            "feature".into(),
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("capture branch raw todo");
    let edited = raw
        .replacen(
            &format!("pick {}", &first_id[..7]),
            &format!("edit {}", &first_id[..7]),
            1,
        )
        .replacen(
            &format!("pick {}", &second_id[..7]),
            &format!("reword {}", &second_id[..7]),
            1,
        );

    let root_path = r.path.to_string_lossy().into_owned();
    let initial = arbor_engine::run_multi_root_rebase(vec![MultiRootRebaseSpec {
        root_path,
        branch: "feature".into(),
        onto: base,
        actions: Vec::new(),
        ordered_commit_ids: Vec::new(),
        raw_todo: Some(edited),
        preserve_merges: false,
        auto_squash: false,
        keep_empty: false,
        update_refs: false,
        root: false,
        interactive: true,
        save_policy: LocalChangesSavePolicy::Stash,
    }])
    .expect("start multi-root raw rebase");
    assert_eq!(initial.len(), 1);
    assert!(initial[0].success && initial[0].requires_finish);
    assert!(!initial[0].completed);

    let continuation_repo = repo.clone();
    let continuation = std::thread::spawn(move || continuation_repo.rebase_continue());
    let mut pending = None;
    for _ in 0..1500 {
        if let Some(message) = repo.rebase_pending_message().expect("read pending message") {
            pending = Some(message);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(pending
        .as_deref()
        .is_some_and(|message| message.starts_with("b\n")));
    repo.rebase_set_pending_message("rewritten b after continue\n".into())
        .expect("write pending message after continue");

    let final_outcome = continuation
        .join()
        .expect("continue worker")
        .expect("continue multi-root raw rebase");
    assert!(!final_outcome.paused);
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert!(r
        .git(&["log", "--format=%s", "feature"])
        .lines()
        .any(|line| line == "rewritten b after continue"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn multi_root_rebase_preserves_merge_rows_and_rewords_the_merge() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base\n", "base");

    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main\n", "main change");
    r.git(&["switch", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature change");
    r.git(&["switch", "-q", "main"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post\n", "post merge change");

    let repo = r.open();
    let todo = repo
        .rebase_todo_for_branch_with_options(onto.clone(), false, true, false, "main".into())
        .expect("merge-preserving branch todo");
    assert!(todo.items.iter().any(|item| item.is_merge_commit));
    let actions = todo
        .items
        .iter()
        .map(|item| {
            if item.is_merge_commit {
                RebaseAction::Reword {
                    message: "rewritten merge feature".into(),
                }
            } else {
                RebaseAction::Pick
            }
        })
        .collect();

    let results = arbor_engine::run_multi_root_rebase(vec![MultiRootRebaseSpec {
        root_path: r.path.to_string_lossy().into_owned(),
        branch: "main".into(),
        onto,
        actions,
        ordered_commit_ids: todo
            .items
            .iter()
            .map(|item| item.commit_id.clone())
            .collect(),
        raw_todo: None,
        preserve_merges: true,
        auto_squash: false,
        keep_empty: false,
        update_refs: false,
        root: false,
        interactive: true,
        save_policy: LocalChangesSavePolicy::Shelve,
    }])
    .expect("multi-root preserve-merges rebase");

    assert_eq!(results.len(), 1);
    assert!(results[0].success && results[0].completed, "{results:?}");
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "main"]), "1");
    assert!(r
        .git(&["log", "--format=%s", "main"])
        .lines()
        .any(|line| line == "rewritten merge feature"));
    assert!(r.read("feature.txt") == "feature\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn multi_root_preserve_merges_reorders_commits_inside_one_branch_segment() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base\n", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    let feature_one = common::commit(&r.path, "feature-one.txt", "one\n", "feature one");
    let feature_two = common::commit(&r.path, "feature-two.txt", "two\n", "feature two");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post\n", "post merge change");

    let repo = r.open();
    let todo = repo
        .rebase_todo_for_branch_with_options(onto.clone(), false, true, false, "main".into())
        .expect("merge-preserving branch todo");
    let feature_one_index = todo
        .items
        .iter()
        .position(|item| item.commit_id == feature_one)
        .expect("feature one row");
    let feature_two_index = todo
        .items
        .iter()
        .position(|item| item.commit_id == feature_two)
        .expect("feature two row");
    assert_eq!(feature_two_index, feature_one_index + 1);

    let mut edited = todo.items.clone();
    edited.swap(feature_one_index, feature_two_index);
    let actions = edited
        .iter()
        .map(|item| {
            if item.commit_id == feature_two {
                RebaseAction::Reword {
                    message: "feature two reordered".into(),
                }
            } else {
                RebaseAction::Pick
            }
        })
        .collect();
    let ordered_commit_ids = edited.iter().map(|item| item.commit_id.clone()).collect();

    let results = arbor_engine::run_multi_root_rebase(vec![MultiRootRebaseSpec {
        root_path: r.path.to_string_lossy().into_owned(),
        branch: "main".into(),
        onto,
        actions,
        ordered_commit_ids,
        raw_todo: None,
        preserve_merges: true,
        auto_squash: false,
        keep_empty: false,
        update_refs: false,
        root: false,
        interactive: true,
        save_policy: LocalChangesSavePolicy::Shelve,
    }])
    .expect("multi-root preserve-merges reorder");

    assert!(results[0].success && results[0].completed, "{results:?}");
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "main"]), "1");
    let merge = r.git(&["rev-list", "--merges", "--max-count=1", "main"]);
    let rewritten_feature_tip = format!("{merge}^2");
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse", &rewritten_feature_tip]),
        "base\nfeature two reordered\nfeature one"
    );
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn multi_root_preserve_merges_rejects_cross_segment_reorder_before_rewriting() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base\n", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature-one.txt", "one\n", "feature one");
    let feature_two = common::commit(&r.path, "feature-two.txt", "two\n", "feature two");
    r.git(&["switch", "-q", "main"]);
    let main_commit = common::commit(&r.path, "main.txt", "main\n", "main change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post\n", "post merge change");
    let original_head = r.git(&["rev-parse", "main"]);

    let repo = r.open();
    let todo = repo
        .rebase_todo_for_branch_with_options(onto.clone(), false, true, false, "main".into())
        .expect("merge-preserving branch todo");
    let feature_two_index = todo
        .items
        .iter()
        .position(|item| item.commit_id == feature_two)
        .expect("feature two row");
    let main_index = todo
        .items
        .iter()
        .position(|item| item.commit_id == main_commit)
        .expect("main row");
    let mut edited = todo.items.clone();
    edited.swap(feature_two_index, main_index);
    let actions = edited.iter().map(|_| RebaseAction::Pick).collect();

    let results = arbor_engine::run_multi_root_rebase(vec![MultiRootRebaseSpec {
        root_path: r.path.to_string_lossy().into_owned(),
        branch: "main".into(),
        onto,
        actions,
        ordered_commit_ids: edited.iter().map(|item| item.commit_id.clone()).collect(),
        raw_todo: None,
        preserve_merges: true,
        auto_squash: false,
        keep_empty: false,
        update_refs: false,
        root: false,
        interactive: true,
        save_policy: LocalChangesSavePolicy::Shelve,
    }])
    .expect("multi-root rejection is a result, not a transport error");

    assert!(!results[0].success && !results[0].completed, "{results:?}");
    assert!(results[0].message.contains("merge control boundary"));
    assert_eq!(r.git(&["rev-parse", "main"]), original_head);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn raw_todo_round_trip_keeps_native_merge_control_rows_editable() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base\n", "base");

    r.git(&["branch", "feature"]);
    common::commit(&r.path, "main.txt", "main\n", "main change");
    r.git(&["switch", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature change");
    r.git(&["switch", "-q", "main"]);
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);
    common::commit(&r.path, "post.txt", "post\n", "post merge change");
    let post_id = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let raw = repo
        .rebase_raw_todo_with_options(onto.clone(), true, false, false, false, false)
        .expect("capture native todo");
    assert!(raw.lines().any(|line| line.starts_with("label ")));
    assert!(raw.lines().any(|line| line.starts_with("reset ")));
    assert!(raw.lines().any(|line| line.starts_with("merge ")));

    let post_pick = format!("pick {}", &post_id[..7]);
    let post_drop = format!("drop {}", &post_id[..7]);
    let edited = raw.replacen(&post_pick, &post_drop, 1);
    assert_ne!(edited, raw);
    let outcome = repo
        .rebase_with_raw_todo_and_policy(
            onto,
            edited,
            true,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("execute edited native todo");

    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--merges", "--count", "HEAD"]), "1");
    assert!(!r
        .git(&["log", "--format=%s"])
        .lines()
        .any(|line| line == "post merge change"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn raw_todo_message_editor_can_be_driven_while_git_is_waiting() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["branch", "onto", &base]);
    r.git(&["switch", "-q", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let feature_id = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let raw = repo
        .rebase_raw_todo_with_options("onto".into(), false, false, false, false, false)
        .expect("capture raw todo");
    let edited = raw.replacen(
        &format!("pick {}", &feature_id[..7]),
        &format!("reword {}", &feature_id[..7]),
        1,
    );
    assert_ne!(edited, raw);

    let worker_repo = repo.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.rebase_with_raw_todo_and_policy(
            "onto".into(),
            edited,
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
    });
    let mut pending = None;
    for _ in 0..1500 {
        if let Some(message) = repo.rebase_pending_message().expect("read pending message") {
            pending = Some(message);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(pending
        .as_deref()
        .is_some_and(|message| message.starts_with("feature\n")));
    repo.rebase_set_pending_message("rewritten feature\n".into())
        .expect("write pending message");
    assert!(repo
        .rebase_pending_message()
        .expect("read handled pending message")
        .is_none());

    let outcome = worker
        .join()
        .expect("raw rebase worker")
        .expect("execute raw rebase");
    assert!(!outcome.paused);
    assert!(r
        .git(&["log", "--format=%s"])
        .lines()
        .any(|line| line == "rewritten feature"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn raw_todo_message_editor_remains_available_after_rebase_continue() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["branch", "onto", &base]);
    r.git(&["switch", "-q", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "a.txt", "a\n", "a");
    let first_id = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "b.txt", "b\n", "b");
    let second_id = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let raw = repo
        .rebase_raw_todo_with_options("onto".into(), false, false, false, false, false)
        .expect("capture raw todo");
    let edited = raw
        .replacen(
            &format!("pick {}", &first_id[..7]),
            &format!("edit {}", &first_id[..7]),
            1,
        )
        .replacen(
            &format!("pick {}", &second_id[..7]),
            &format!("reword {}", &second_id[..7]),
            1,
        );

    let worker_repo = repo.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.rebase_with_raw_todo_and_policy(
            "onto".into(),
            edited,
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
    });
    let initial = worker
        .join()
        .expect("raw rebase worker")
        .expect("execute raw rebase");
    assert!(initial.paused);

    let continuation_repo = repo.clone();
    let continuation = std::thread::spawn(move || continuation_repo.rebase_continue());
    let mut pending = None;
    for _ in 0..1500 {
        if let Some(message) = repo.rebase_pending_message().expect("read pending message") {
            pending = Some(message);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(pending
        .as_deref()
        .is_some_and(|message| message.starts_with("b\n")));
    repo.rebase_set_pending_message("rewritten b\n".into())
        .expect("write pending message after continue");

    let final_outcome = continuation
        .join()
        .expect("continue worker")
        .expect("continue raw rebase");
    assert!(!final_outcome.paused);
    assert!(r
        .git(&["log", "--format=%s"])
        .lines()
        .any(|line| line == "rewritten b"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn raw_todo_message_editor_cancel_is_abortable_without_hanging() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["branch", "onto", &base]);
    r.git(&["switch", "-q", "onto"]);
    common::commit(&r.path, "onto.txt", "onto\n", "onto");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let feature_id = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let raw = repo
        .rebase_raw_todo_with_options("onto".into(), false, false, false, false, false)
        .expect("capture raw todo");
    let edited = raw.replacen(
        &format!("pick {}", &feature_id[..7]),
        &format!("reword {}", &feature_id[..7]),
        1,
    );

    let worker_repo = repo.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.rebase_with_raw_todo_and_policy(
            "onto".into(),
            edited,
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
        )
    });
    let mut pending = false;
    for _ in 0..1500 {
        if repo
            .rebase_pending_message()
            .expect("read pending message")
            .is_some()
        {
            pending = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(pending, "native message editor did not become available");
    repo.rebase_cancel_pending_message()
        .expect("cancel pending message");

    let result = worker.join().expect("raw rebase worker after cancel");
    let outcome = result.expect("cancelled message should leave an abortable pause");
    assert!(outcome.paused);
    assert_eq!(
        outcome.pause_reason,
        Some(arbor_engine::RebasePauseReason::Edit)
    );
    assert_eq!(
        repo.operation_state()
            .expect("operation state after cancel")
            .map(|state| state.kind),
        Some(OperationKind::Rebase)
    );
    repo.rebase_abort().expect("abort cancelled raw rebase");
    assert!(repo
        .operation_state()
        .expect("final operation state")
        .is_none());
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn cancelled_raw_todo_rebase_kills_git_and_keeps_saved_scene_for_abort() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base\n", "base");
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    let feature_id = r.git(&["rev-parse", "HEAD"]);
    r.write("local.txt", "local edit\n");
    r.write("scratch.txt", "untracked\n");

    let repo = r.open();
    let raw = format!("pick {}\nexec sleep 10\n", &feature_id[..7]);
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.rebase_with_raw_todo_and_policy_and_cancel(
            base,
            raw,
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Shelve,
            worker_cancel,
        )
    });

    std::thread::sleep(std::time::Duration::from_millis(300));
    cancel.cancel();
    let result = worker.join().expect("cancelled raw rebase worker");
    assert!(matches!(result, Err(arbor_engine::EngineError::Cancelled)));
    assert_eq!(
        repo.operation_state()
            .expect("operation state after raw cancellation")
            .map(|state| state.kind),
        Some(OperationKind::Rebase)
    );
    assert!(
        !r.exists("scratch.txt"),
        "saved scene must stay out of the rebase worktree"
    );
    assert!(repo
        .shelve_list()
        .expect("saved scene shelf")
        .iter()
        .any(|shelf| shelf.name.starts_with("Arbor: Rebase local changes")));

    repo.rebase_abort().expect("abort cancelled raw rebase");
    assert_eq!(r.read("local.txt"), "local edit\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
    assert!(repo.shelve_list().expect("final shelves").is_empty());
    assert!(r
        .git(&["status", "--porcelain"])
        .lines()
        .any(|line| line.ends_with("local.txt")));
}

#[test]
fn multi_root_rebase_shelve_policy_preserves_dirty_files_in_each_root() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    common::commit(&r.path, "local.txt", "clean\n", "local baseline");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let root_onto = r.git(&["rev-parse", "main"]);
    r.write("local.txt", "root local edit\n");
    r.write("root-scratch.txt", "root untracked\n");

    let child = r.path.join("nested");
    init_nested_repo(&child);
    common::commit(&child, "base.txt", "base\n", "base");
    common::commit(&child, "local.txt", "clean\n", "local baseline");
    common::git(&child, &["switch", "-q", "-c", "feature"]);
    common::commit(&child, "feature.txt", "feature\n", "feature");
    common::git(&child, &["switch", "-q", "main"]);
    common::commit(&child, "main.txt", "main\n", "main");
    let child_onto = common::git(&child, &["rev-parse", "main"]);
    std::fs::write(child.join("local.txt"), "child local edit\n").expect("child local edit");
    std::fs::write(child.join("child-scratch.txt"), "child untracked\n").expect("child untracked");

    let results = arbor_engine::run_multi_root_rebase(vec![
        make_branch_rebase_spec(&r.path, "feature", &root_onto, true),
        make_branch_rebase_spec(&child, "feature", &child_onto, true),
    ])
    .expect("multi-root shelve-policy rebase");

    assert!(results
        .iter()
        .all(|result| result.success && result.completed));
    assert_eq!(r.read("local.txt"), "root local edit\n");
    assert_eq!(r.read("root-scratch.txt"), "root untracked\n");
    assert_eq!(
        std::fs::read_to_string(child.join("local.txt")).expect("child local file"),
        "child local edit\n"
    );
    assert_eq!(
        std::fs::read_to_string(child.join("child-scratch.txt")).expect("child scratch file"),
        "child untracked\n"
    );
    assert!(r.open().shelve_list().expect("root shelves").is_empty());
    assert!(
        arbor_engine::open_repository(child.to_string_lossy().into_owned())
            .expect("child repository")
            .shelve_list()
            .expect("child shelves")
            .is_empty()
    );
}

#[test]
fn multi_root_rebase_preserves_failure_and_skips_later_roots() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let onto = r.git(&["rev-parse", "main"]);

    let child = r.path.join("nested");
    init_nested_repo(&child);
    common::commit(&child, "base.txt", "base\n", "base");
    common::git(&child, &["switch", "-q", "-c", "feature"]);
    common::commit(&child, "feature.txt", "feature\n", "feature");
    common::git(&child, &["switch", "-q", "main"]);
    common::commit(&child, "main.txt", "main\n", "main");
    let child_onto = common::git(&child, &["rev-parse", "main"]);

    let mut failed = make_branch_rebase_spec(&child, "feature", &child_onto, true);
    failed.branch = "missing".into();
    let results = arbor_engine::run_multi_root_rebase(vec![
        make_branch_rebase_spec(&r.path, "feature", &onto, true),
        failed,
    ])
    .expect("multi-root partial result");
    assert_eq!(results.len(), 2);
    assert!(results
        .iter()
        .any(|result| !result.success && !result.skipped));
    assert!(results.iter().any(|result| result.skipped));
    assert_eq!(r.git(&["branch", "--show-current"]), "main");
    assert_eq!(common::git(&child, &["branch", "--show-current"]), "main");
}

#[test]
fn multi_root_noninteractive_rebase_runs_native_command_per_root() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main");
    let onto = r.git(&["rev-parse", "main"]);

    let results = arbor_engine::run_multi_root_rebase(vec![make_branch_rebase_spec(
        &r.path, "feature", &onto, false,
    )])
    .expect("noninteractive multi-root rebase");
    assert_eq!(results.len(), 1);
    assert!(results[0].success && results[0].completed);
    assert_eq!(r.git(&["branch", "--show-current"]), "feature");
    assert_eq!(r.git(&["rev-parse", "feature^"]), onto);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

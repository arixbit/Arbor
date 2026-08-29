//! REBASE-001：interactive rebase 显式 todo。
//! todo 生成（含 autosquash 预览）、拖拽排序（顺序=最终拓扑）、批量 action
//! （pick/reword/edit/squash/fixup/drop）、todo 校验、冲突暂停恢复、
//! preserve-merges 场景。

mod common;

use arbor_engine::{GitCancelHandle, LocalChangesSavePolicy, RebaseTodoAction, RebaseTodoItem};
use common::TestRepo;

/// 线性提交链 base -> a -> b -> c（c 是 HEAD），返回 (base_id, a_id, b_id, c_id)。
fn linear_three(r: &TestRepo) -> (String, String, String, String) {
    common::commit(&r.path, "base.txt", "0\n", "base");
    let base = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "f.txt", "1\n", "commit a");
    let a = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "commit b"]);
    let b = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n3\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "commit c"]);
    let c = r.git(&["rev-parse", "HEAD"]);
    (base, a, b, c)
}

#[test]
fn todo_generation_oldest_first() {
    let r = TestRepo::new();
    let (base, a, b, c) = linear_three(&r);
    let repo = r.open();
    let todo = repo.rebase_todo(base.clone(), false).expect("todo");
    assert_eq!(todo.items.len(), 3);
    // 旧→新顺序
    assert_eq!(todo.items[0].commit_id, a);
    assert_eq!(todo.items[1].commit_id, b);
    assert_eq!(todo.items[2].commit_id, c);
    // 全部 pick,summary 为提交标题
    for item in &todo.items {
        assert_eq!(item.action, RebaseTodoAction::Pick);
        assert!(
            item.summary.starts_with("commit "),
            "summary: {}",
            item.summary
        );
    }
    // onto 是 base,不含在 items 中
    assert_eq!(todo.onto, base);
}

#[test]
fn structured_squash_can_override_the_combined_commit_message() {
    let r = TestRepo::new();
    let (base, _a, _b, _c) = linear_three(&r);
    let repo = r.open();
    let mut todo = repo.rebase_todo(base, false).expect("todo");
    todo.items[1].action = RebaseTodoAction::Squash;
    todo.items[1].message = Some("combined title\n\nreviewed in Arbor".into());

    let outcome = repo
        .rebase_with_todo(todo.onto.clone(), todo, false)
        .expect("structured squash");

    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["show", "--format=%B", "--no-patch", "HEAD~1"]),
        "combined title\n\nreviewed in Arbor"
    );
    assert_eq!(
        r.git(&["log", "-2", "--format=%s"]),
        "commit c\ncombined title"
    );
    assert_eq!(r.read("f.txt"), "1\n2\n3\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn forced_native_current_head_rebase_honors_structured_actions() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    let base = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "a.txt", "a\n", "commit a");
    common::commit(&r.path, "b.txt", "b\n", "commit b");
    common::commit(&r.path, "c.txt", "c\n", "commit c");

    let outcome = r
        .open()
        .rebase_with_advanced_options_and_policy_and_cancel(
            base,
            vec![
                arbor_engine::RebaseAction::Reword {
                    message: "native commit a".into(),
                },
                arbor_engine::RebaseAction::Drop,
                arbor_engine::RebaseAction::Pick,
            ],
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
            GitCancelHandle::new(),
        )
        .expect("forced native rebase");

    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse"]),
        "base\nnative commit a\ncommit c"
    );
    assert!(!r.git(&["log", "--format=%s"]).contains("commit b"));
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn root_todo_includes_root_and_honors_reorder_and_reword() {
    let r = TestRepo::new();
    common::commit(&r.path, "root.txt", "root\n", "root commit");
    let root = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "a.txt", "a\n", "commit a");
    common::commit(&r.path, "b.txt", "b\n", "commit b");

    let repo = r.open();
    let todo = repo.rebase_root_todo(false, false).expect("root todo");
    assert!(todo.onto.is_empty());
    assert_eq!(todo.items.len(), 3);
    assert_eq!(todo.items[0].commit_id, root);

    let mut items = todo.items;
    let b = items.remove(2);
    items.insert(0, b);
    let root_index = items
        .iter()
        .position(|item| item.commit_id == root)
        .expect("root item");
    let mut root_item = items.remove(root_index);
    root_item.action = RebaseTodoAction::Reword;
    root_item.message = Some("rewritten root".into());
    items.push(root_item);

    let outcome = repo
        .rebase_root_with_todo_and_policy(
            arbor_engine::RebaseTodo {
                onto: String::new(),
                items,
            },
            false,
            LocalChangesSavePolicy::Stash,
        )
        .expect("root rebase");
    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse"]),
        "commit b\ncommit a\nrewritten root"
    );
    assert!(r.git(&["rev-list", "--max-parents=0", "HEAD"]).len() > 0);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn autosquash_preview_attaches_fixup_and_squash() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "f.txt", "1\n", "feature x");
    let target = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "fixup! feature x"]);
    let fixup = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n3\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "squash! feature x"]);
    let squash = r.git(&["rev-parse", "HEAD"]);
    let repo = r.open();
    // 非 autosquash:顺序保持提交序(onto = base,HEAD~3)
    let plain = repo
        .rebase_todo(r.git(&["rev-parse", "HEAD~3"]), false)
        .expect("plain");
    assert_eq!(plain.items[0].commit_id, target);
    assert_eq!(plain.items[1].commit_id, fixup);
    assert_eq!(plain.items[2].commit_id, squash);

    // autosquash 预览:fixup!/squash! 吸附到目标后
    let todo = repo
        .rebase_todo(r.git(&["rev-parse", "HEAD~3"]), true)
        .expect("todo");
    assert_eq!(todo.items.len(), 3);
    assert_eq!(todo.items[0].commit_id, target);
    assert_eq!(todo.items[0].action, RebaseTodoAction::Pick);
    // git autosquash 语义:同目标的 squash! 在 fixup! 之前
    assert_eq!(todo.items[1].commit_id, squash);
    assert_eq!(
        todo.items[1].action,
        RebaseTodoAction::Squash,
        "squash attaches after target"
    );
    assert_eq!(todo.items[2].commit_id, fixup);
    assert_eq!(todo.items[2].action, RebaseTodoAction::Fixup);
}

#[test]
fn reordered_todo_defines_final_topology() {
    let r = TestRepo::new();
    // 三个提交各改各的文件:重排后无冲突(重排语义下父未重放的提交会暂停,
    // 那是真实 git 行为;此处验证干净重排的拓扑)
    common::commit(&r.path, "base.txt", "0\n", "base");
    let base = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "a.txt", "a\n", "commit a");
    let a = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "b.txt", "b\n", "commit b");
    let b = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "c.txt", "c\n", "commit c");
    let c = r.git(&["rev-parse", "HEAD"]);
    let repo = r.open();
    let todo = repo.rebase_todo(base, false).expect("todo");
    assert_eq!(todo.items.len(), 3);

    // 拖拽排序:把 c 提到最前(模拟用户在 UI 里拖拽)
    let mut items = todo.items.clone();
    let c = items.remove(2);
    items.insert(0, c);
    let reordered = arbor_engine::RebaseTodo {
        onto: todo.onto.clone(),
        items,
    };
    let outcome = repo
        .rebase_with_todo(todo.onto, reordered, false)
        .expect("rebase with reordered todo");
    assert!(!outcome.paused);
    // 最终提交顺序与 todo 一致:HEAD 是原 c 的重放,其下依次是 b、a
    let subjects = r.git(&["log", "--format=%s", "--reverse", "HEAD~3..HEAD"]);
    let lines: Vec<&str> = subjects.lines().collect();
    assert_eq!(
        lines,
        vec!["commit c", "commit a", "commit b"],
        "topology must follow todo order: {subjects}"
    );
}

#[test]
fn reordered_non_contiguous_squash_group_replays_unselected_commits_after_group() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    let base = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "a.txt", "a\n", "commit a");
    common::commit(&r.path, "b.txt", "b\n", "commit b");
    common::commit(&r.path, "c.txt", "c\n", "commit c");

    let repo = r.open();
    let todo = repo.rebase_todo(base, false).expect("todo");
    let mut items = todo.items.clone();
    let c = items.remove(2);
    items.insert(1, c); // IntelliJ unite: a + c, then the unselected b.
    items[0].action = RebaseTodoAction::Reword;
    items[0].message = Some("combined a and c".into());
    items[1].action = RebaseTodoAction::Fixup;
    items[1].message = None;
    items[2].action = RebaseTodoAction::Pick;

    let outcome = repo
        .rebase_with_todo(
            todo.onto.clone(),
            arbor_engine::RebaseTodo {
                onto: todo.onto,
                items,
            },
            false,
        )
        .expect("rebase with non-contiguous squash group");
    assert!(!outcome.paused);
    assert_eq!(r.git(&["rev-list", "--count", "HEAD"]), "3");
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse"]),
        "base\ncombined a and c\ncommit b"
    );
    assert_eq!(r.git(&["show", "HEAD:a.txt"]), "a");
    assert_eq!(r.git(&["show", "HEAD:b.txt"]), "b");
    assert_eq!(r.git(&["show", "HEAD:c.txt"]), "c");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn todo_rejects_squash_or_fixup_after_dropped_predecessor() {
    let r = TestRepo::new();
    let (base, _a, _b, _c) = linear_three(&r);
    let repo = r.open();
    let mut todo = repo.rebase_todo(base, false).expect("todo");
    todo.items[0].action = RebaseTodoAction::Drop;
    todo.items[1].action = RebaseTodoAction::Fixup;

    let error = repo
        .rebase_with_todo(todo.onto.clone(), todo, false)
        .expect_err("fixup cannot consume a dropped predecessor");
    assert!(
        error.to_string().contains("no valid kept predecessor"),
        "unexpected error: {error}"
    );
}

#[test]
fn batch_actions_pick_reword_squash_fixup_drop() {
    let r = TestRepo::new();
    // 4 个提交:keep / reword me / squash me / drop me
    common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "f.txt", "1\n", "keep");
    let keep = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "reword me"]);
    let reword = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n3\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "squash me"]);
    let squash = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "1\n2\n3\n4\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "drop me"]);
    let drop = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let onto = r.git(&["rev-parse", "HEAD~4"]);
    let todo = arbor_engine::RebaseTodo {
        onto: onto.clone(),
        items: vec![
            RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: keep,
                summary: "keep".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            RebaseTodoItem {
                action: RebaseTodoAction::Reword,
                commit_id: reword,
                summary: "reword me".into(),
                message: Some("renamed".into()),
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            RebaseTodoItem {
                action: RebaseTodoAction::Squash,
                commit_id: squash,
                summary: "squash me".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            RebaseTodoItem {
                action: RebaseTodoAction::Drop,
                commit_id: drop,
                summary: "drop me".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
        ],
    };
    let outcome = repo.rebase_with_todo(onto, todo, false).expect("rebase");
    assert!(!outcome.paused);

    let subjects = r.git(&["log", "--format=%s", "--reverse", "HEAD~2..HEAD"]);
    let lines: Vec<&str> = subjects.lines().collect();
    // 验证:drop me 消失;reword 变 renamed;squash 并入 renamed(合并 message 含 squash 标题)
    assert_eq!(
        lines.len(),
        2,
        "keep + (reword+squash) = 2 commits: {subjects}"
    );
    assert_eq!(lines[0], "keep");
    assert_eq!(
        lines[1], "renamed",
        "squash merges into reworded commit: {subjects}"
    );
    // fixup 语义:不打开多余 message 编辑 —— 用 fixup! 提交验证
    let r2 = TestRepo::new();
    common::commit(&r2.path, "base.txt", "0\n", "base");
    common::commit(&r2.path, "g.txt", "1\n", "base2");
    r2.write("g.txt", "1\n2\n");
    r2.git(&["add", "g.txt"]);
    r2.git(&["commit", "-q", "-m", "target"]);
    let target2 = r2.git(&["rev-parse", "HEAD"]);
    r2.write("g.txt", "1\n2\n3\n");
    r2.git(&["add", "g.txt"]);
    r2.git(&["commit", "-q", "-m", "fixup! target"]);
    let fixup2 = r2.git(&["rev-parse", "HEAD"]);
    let repo2 = r2.open();
    let onto2 = r2.git(&["rev-parse", "HEAD~2"]);
    let todo2 = arbor_engine::RebaseTodo {
        onto: onto2.clone(),
        items: vec![
            RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: target2,
                summary: "target".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            RebaseTodoItem {
                action: RebaseTodoAction::Fixup,
                commit_id: fixup2,
                summary: "fixup! target".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
        ],
    };
    let outcome2 = repo2
        .rebase_with_todo(onto2, todo2, false)
        .expect("fixup rebase");
    assert!(!outcome2.paused);
    // fixup 后只有目标提交,信息保持 "target"
    let subjects2 = r2.git(&["log", "--format=%s", "--reverse", "HEAD~1..HEAD"]);
    assert_eq!(
        subjects2, "target",
        "fixup keeps target message: {subjects2}"
    );
}

#[test]
fn edit_pauses_and_continues() {
    let r = TestRepo::new();
    let (base, _a, b, _c) = linear_three(&r);
    let repo = r.open();
    let todo = repo.rebase_todo(base, false).expect("todo");
    // b 标记为 edit
    let mut items = todo.items.clone();
    for item in items.iter_mut() {
        if item.commit_id == b {
            item.action = RebaseTodoAction::Edit;
        }
    }
    let edited = arbor_engine::RebaseTodo {
        onto: todo.onto.clone(),
        items,
    };
    let outcome = repo
        .rebase_with_todo(todo.onto, edited, false)
        .expect("rebase with edit");
    assert!(outcome.paused, "edit action must pause: {outcome:?}");
    assert_eq!(
        outcome.pause_reason,
        Some(arbor_engine::RebasePauseReason::Edit)
    );
    // continue 完成剩余
    let cont = repo.rebase_continue().expect("continue");
    assert!(!cont.paused);
    assert!(repo.operation_state().expect("op").is_none());
}

#[test]
fn rebase_preserves_dirty_tracked_and_untracked_files() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "local.txt", "committed\n", "local baseline");
    let onto = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");

    r.write("local.txt", "local edit\n");
    r.write("scratch.txt", "untracked\n");

    let outcome = r
        .open()
        .rebase_with_options(onto, vec![arbor_engine::RebaseAction::Pick], false, false)
        .expect("rebase with local changes");
    assert!(!outcome.paused);
    assert_eq!(r.read("local.txt"), "local edit\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
    let status = r.git(&["status", "--porcelain"]);
    assert!(status.lines().any(|line| line.ends_with("local.txt")));
    assert!(status.lines().any(|line| line.ends_with("scratch.txt")));
}

#[test]
fn rebase_shelve_policy_preserves_dirty_tracked_and_untracked_files() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "local.txt", "committed\n", "local baseline");
    let onto = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");

    r.write("local.txt", "local edit\n");
    r.write("scratch.txt", "untracked\n");

    let outcome = r
        .open()
        .rebase_with_advanced_options_and_policy(
            onto,
            vec![arbor_engine::RebaseAction::Pick],
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Shelve,
        )
        .expect("shelve-policy rebase");
    assert!(!outcome.paused);
    assert_eq!(r.read("local.txt"), "local edit\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
    assert!(r.open().shelve_list().expect("shelf list").is_empty());
    assert!(!r.path.join(".git/arbor-rebase-local-stash").exists());
}

#[test]
fn rebase_local_changes_restore_info_reads_exact_marker_identity() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "base");
    let stash_id = r.git(&["rev-parse", "HEAD"]);
    let marker = r.path.join(".git/arbor-rebase-local-stash");
    let repo = r.open();

    std::fs::write(&marker, format!("{stash_id}\n")).expect("write stash marker");
    let stash_info = repo
        .rebase_local_changes_restore_info()
        .expect("read stash marker")
        .expect("stash restore info");
    assert_eq!(stash_info.operation, "rebase");
    assert_eq!(stash_info.kind, "stash");
    assert_eq!(stash_info.identifier, stash_id);

    std::fs::write(&marker, "shelf:Arbor: Rebase local changes\n").expect("write shelf marker");
    let shelf_info = repo
        .rebase_local_changes_restore_info()
        .expect("read shelf marker")
        .expect("shelf restore info");
    assert_eq!(shelf_info.operation, "rebase");
    assert_eq!(shelf_info.kind, "shelf");
    assert_eq!(shelf_info.identifier, "Arbor: Rebase local changes");
}

#[test]
fn cancelled_shelve_policy_rebase_keeps_local_scene_before_preservation() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.write("local.txt", "local edit\n");
    r.write("scratch.txt", "untracked\n");

    let repo = r.open();
    let todo = repo.rebase_todo(base.clone(), false).expect("todo");
    let cancel = GitCancelHandle::new();
    cancel.cancel();
    let result = repo.rebase_with_todo_and_policy_and_cancel(
        base,
        todo,
        false,
        LocalChangesSavePolicy::Shelve,
        cancel,
    );

    assert!(matches!(result, Err(arbor_engine::EngineError::Cancelled)));
    assert_eq!(r.read("local.txt"), "local edit\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
    assert!(repo.shelve_list().expect("shelf list").is_empty());
    assert!(!r.path.join(".git/arbor-rebase-local-stash").exists());
}

#[test]
fn rebase_shelve_policy_survives_reopen_before_edit_continue() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.write("local.txt", "local edit\n");
    r.write("scratch.txt", "untracked\n");

    let repo = r.open();
    let todo = repo.rebase_todo(base, false).expect("todo");
    let mut items = todo.items.clone();
    items[0].action = arbor_engine::RebaseTodoAction::Edit;
    let paused = repo
        .rebase_with_todo_and_policy(
            todo.onto.clone(),
            arbor_engine::RebaseTodo {
                onto: todo.onto,
                items,
            },
            false,
            LocalChangesSavePolicy::Shelve,
        )
        .expect("shelve-policy edit rebase");
    assert!(paused.paused);
    assert!(!r.exists("scratch.txt"));
    assert!(r
        .open()
        .shelve_list()
        .expect("shelf list")
        .iter()
        .any(|shelf| shelf.name.starts_with("Arbor: Rebase local changes")));

    let reopened = r.open();
    let completed = reopened.rebase_continue().expect("continue after reopen");
    assert!(!completed.paused);
    assert_eq!(r.read("local.txt"), "local edit\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
    assert!(reopened.shelve_list().expect("shelf list").is_empty());
    assert!(!r.path.join(".git/arbor-rebase-local-stash").exists());
}

#[test]
fn rebase_abort_restores_local_changes_saved_before_edit_pause() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    common::commit(&r.path, "local.txt", "committed\n", "local baseline");
    let onto = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "feature.txt", "feature\n", "feature");
    r.write("local.txt", "local edit\n");
    r.write("scratch.txt", "untracked\n");

    let repo = r.open();
    let paused = repo
        .rebase_with_options(onto, vec![arbor_engine::RebaseAction::Edit], false, false)
        .expect("edit rebase");
    assert!(paused.paused);
    assert!(!r.exists("scratch.txt"));
    assert_eq!(r.read("local.txt"), "committed\n");

    repo.rebase_abort().expect("abort rebase");
    assert_eq!(r.read("local.txt"), "local edit\n");
    assert_eq!(r.read("scratch.txt"), "untracked\n");
}

#[test]
fn todo_validation_rejects_wrong_sets() {
    let r = TestRepo::new();
    let (base, a, b, c) = linear_three(&r);
    let repo = r.open();
    let todo = repo.rebase_todo(base, false).expect("todo");

    // 缺一个提交
    let mut short = todo.items.clone();
    short.pop();
    let err = repo
        .rebase_with_todo(
            todo.onto.clone(),
            arbor_engine::RebaseTodo {
                onto: todo.onto.clone(),
                items: short,
            },
            false,
        )
        .unwrap_err()
        .to_string();
    assert!(
        err.contains("2 items for 3 commits"),
        "missing commit error: {err}"
    );

    // 重复（长度保持，但同一提交出现两次）
    let mut dup = todo.items.clone();
    dup[2].commit_id = b.clone();
    let err = repo
        .rebase_with_todo(
            todo.onto.clone(),
            arbor_engine::RebaseTodo {
                onto: todo.onto.clone(),
                items: dup,
            },
            false,
        )
        .unwrap_err()
        .to_string();
    assert!(err.contains("duplicate"), "duplicate error: {err}");

    // 不在范围内（onto 本身不属于范围提交）
    let mut foreign = todo.items.clone();
    foreign[0].commit_id = todo.onto.clone();
    let err = repo
        .rebase_with_todo(
            todo.onto.clone(),
            arbor_engine::RebaseTodo {
                onto: todo.onto.clone(),
                items: foreign,
            },
            false,
        )
        .unwrap_err()
        .to_string();
    assert!(
        err.contains("not in the rebase range"),
        "foreign error: {err}"
    );
}

#[test]
fn todo_conflict_pauses_then_recovery() {
    let r = TestRepo::new();
    // main 与 feature 分叉后,feature 上有两个提交;rebase 到 main 冲突
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "ours\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("f.txt", "theirs-1\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "t1"]);
    r.write("f.txt", "theirs-2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "t2"]);

    let repo = r.open();
    let onto = r.git(&["rev-parse", "main"]);
    let todo = repo.rebase_todo(onto.clone(), false).expect("todo");
    assert_eq!(todo.items.len(), 2);
    let outcome = repo.rebase_with_todo(onto, todo, false).expect("rebase");
    assert!(outcome.paused);
    assert_eq!(
        outcome.pause_reason,
        Some(arbor_engine::RebasePauseReason::Conflict)
    );
    assert!(!outcome.conflicts.is_empty());

    // 解决后 continue;t2 与解决结果重叠时也会冲突,循环解决直到完成
    let mut guard = 0;
    loop {
        r.write("f.txt", "resolved\n");
        r.git(&["add", "f.txt"]);
        let cont = repo.rebase_continue().expect("continue");
        guard += 1;
        assert!(guard < 5, "rebase should finish within 5 continues");
        if !cont.paused {
            break;
        }
    }
    assert_eq!(r.read("f.txt").trim(), "resolved");
}

#[test]
fn native_retry_can_follow_an_aborted_in_memory_conflict() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "base\n", "init");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "ours\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("f.txt", "theirs-1\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "t1"]);
    r.write("f.txt", "theirs-2\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "t2"]);

    let repo = r.open();
    let onto = r.git(&["rev-parse", "main"]);
    let todo = repo.rebase_todo(onto.clone(), false).expect("todo");
    let in_memory = repo
        .rebase_with_todo(onto.clone(), todo, false)
        .expect("in-memory rebase");
    assert_eq!(
        in_memory.pause_reason,
        Some(arbor_engine::RebasePauseReason::Conflict)
    );

    // The Swift execution path uses the same abort boundary before retrying
    // native Git, intentionally discarding object-level progress.
    repo.rebase_abort().expect("abort in-memory rebase");
    let original_head = r.git(&["rev-parse", "HEAD"]);
    assert_eq!(original_head, r.git(&["rev-parse", "feature"]));
    assert!(r.git(&["status", "--porcelain"]).is_empty());

    let native = repo
        .rebase_branch_with_advanced_options_and_policy_and_cancel(
            onto,
            "feature".into(),
            vec![
                arbor_engine::RebaseAction::Pick,
                arbor_engine::RebaseAction::Pick,
            ],
            false,
            false,
            false,
            false,
            false,
            LocalChangesSavePolicy::Stash,
            GitCancelHandle::new(),
        )
        .expect("native retry");
    assert_eq!(
        native.pause_reason,
        Some(arbor_engine::RebasePauseReason::Conflict)
    );
    repo.rebase_abort().expect("abort native retry");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), original_head);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn todo_through_preserve_merges_system_path() {
    let r = TestRepo::new();
    // 含 merge 提交的历史:main 上 feature 合入
    common::commit(&r.path, "f.txt", "1\n", "base");
    r.git(&["branch", "feature"]);
    r.write("f.txt", "1\nm1\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "main commit"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("g.txt", "g\n");
    r.git(&["add", "g.txt"]);
    r.git(&["commit", "-q", "-m", "feature commit"]);
    r.git(&["checkout", "-q", "main"]);
    // 手动 merge --no-ff 制造 merge commit
    common::git_allow_failure(
        &r.path,
        &["merge", "-q", "--no-ff", "feature", "-m", "merge feature"],
    );
    r.write("h.txt", "h\n");
    r.git(&["add", "h.txt"]);
    r.git(&["commit", "-q", "-m", "after merge"]);

    let repo = r.open();
    let onto = r.git(&["rev-parse", "HEAD~3"]);
    // 系统 --rebase-merges 的原生 todo 包含 feature 分支提交和 merge 拓扑行。
    let m1 = r.git(&["rev-parse", "HEAD~2"]);
    let feature_id = r.git(&["rev-parse", "HEAD~1^2"]);
    let merge_id = r.git(&["rev-parse", "HEAD~1"]);
    let after = r.git(&["rev-parse", "HEAD"]);
    let todo = arbor_engine::RebaseTodo {
        onto: onto.clone(),
        items: vec![
            arbor_engine::RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: feature_id,
                summary: "feature commit".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            arbor_engine::RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: m1,
                summary: "main commit".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
            arbor_engine::RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: merge_id,
                summary: "merge feature".into(),
                message: None,
                is_merge_commit: true,
                can_squash_or_fixup: false,
            },
            arbor_engine::RebaseTodoItem {
                action: RebaseTodoAction::Pick,
                commit_id: after,
                summary: "after merge".into(),
                message: None,
                is_merge_commit: false,
                can_squash_or_fixup: false,
            },
        ],
    };
    // preserve-merges 走系统 git --rebase-merges
    let outcome = repo
        .rebase_with_todo(onto, todo, true)
        .expect("preserve merges rebase");
    assert!(
        !outcome.paused,
        "preserve-merges should complete: {outcome:?}"
    );
    // merge 提交结构保留(HEAD 前有双父提交)
    let parents = r.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(
        parents.split_whitespace().count(),
        2,
        "HEAD is not a merge commit: {parents}"
    );
}

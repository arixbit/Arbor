//! D4：交互式 rebase round-trip。
//! pick/drop/reword/squash + edit-pause-rebase_continue，断言最终 HEAD 树与预期一致。

mod common;

use arbor_engine::{ChangeKind, RebaseAction, RebasePauseReason};

use common::TestRepo;

/// pick/drop/squash/reword 一次过：最终树去掉被 drop 的文件，HEAD 信息为 reword 文本。
#[test]
fn rebase_pick_drop_squash_reword() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "a.txt", "1", "c1"); // Pick
    common::commit(&r.path, "b.txt", "2", "c2"); // Drop
    common::commit(&r.path, "c.txt", "3", "c3"); // Squash（并入 c1）
    common::commit(&r.path, "d.txt", "4", "c4"); // Reword

    let repo = r.open();
    let outcome = repo
        .rebase(
            onto.clone(),
            vec![
                RebaseAction::Pick,
                RebaseAction::Drop,
                RebaseAction::Squash,
                RebaseAction::Reword {
                    message: "final".into(),
                },
            ],
        )
        .unwrap();

    assert!(!outcome.paused, "non-edit rebase should not pause");

    // b.txt 被 drop；其余保留
    assert!(r.exists("a.txt"), "a.txt kept");
    assert!(!r.exists("b.txt"), "b.txt dropped");
    assert!(r.exists("c.txt"), "c.txt kept");
    assert!(r.exists("d.txt"), "d.txt kept");
    assert_eq!(r.read("a.txt"), "1");
    assert_eq!(r.read("c.txt"), "3");
    assert_eq!(r.read("d.txt"), "4");

    // HEAD 信息 = reword 文本
    let subject = r.git(&["log", "-1", "--format=%s"]);
    assert_eq!(subject, "final");

    // onto 之上有 2 个提交（squash 合并 c1+c3，reword c4）
    let count = r.git(&["rev-list", "--count", &format!("{onto}..HEAD")]);
    assert_eq!(count, "2");

    // git status 干净
    let clean = r.git(&["status", "--porcelain"]);
    assert!(clean.is_empty(), "git status should be clean, got: {clean}");
}

/// The Log Squash dialog is implemented as a custom-message reword followed
/// by fixups. This must produce one commit with the edited full message,
/// rather than Git's default concatenation of the original subjects.
#[test]
fn rebase_reword_then_fixup_uses_custom_squash_message() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "a.txt", "1", "first");
    common::commit(&r.path, "b.txt", "2", "second");

    let repo = r.open();
    let outcome = repo
        .rebase(
            onto.clone(),
            vec![
                RebaseAction::Reword {
                    message: "combined title\n\ncombined body".into(),
                },
                RebaseAction::Fixup,
            ],
        )
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["log", "-1", "--format=%B"]),
        "combined title\n\ncombined body"
    );
    assert!(r.exists("a.txt"));
    assert!(r.exists("b.txt"));
    assert_eq!(
        r.git(&["rev-list", "--count", &format!("{onto}..HEAD")]),
        "1"
    );
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

/// edit 暂停 -> 工作区编辑 -> rebase_continue 续跑，最终树含编辑内容。
#[test]
fn rebase_edit_pause_continue() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "a.txt", "1", "c1"); // Pick
    common::commit(&r.path, "b.txt", "2", "c2"); // Edit（暂停）
    common::commit(&r.path, "c.txt", "3", "c3"); // Pick

    let repo = r.open();
    let outcome = repo
        .rebase(
            onto.clone(),
            vec![RebaseAction::Pick, RebaseAction::Edit, RebaseAction::Pick],
        )
        .unwrap();
    assert!(outcome.paused, "Edit should pause the rebase");

    // 暂停期间编辑工作区（模拟用户 amend）：改 b.txt 内容
    r.write("b.txt", "EDITED");

    // 重开句柄续跑（rebase 状态存文件，跨进程可续）
    let repo2 = r.open();
    let outcome2 = repo2.rebase_continue().unwrap();
    assert!(!outcome2.paused, "continue should finish the rebase");

    // 最终树：a=1, b=EDITED, c=3
    assert_eq!(r.read("a.txt"), "1");
    assert_eq!(r.read("b.txt"), "EDITED");
    assert_eq!(r.read("c.txt"), "3");

    // onto 之上有 3 个提交（c1 / 编辑后的 c2 / c3）
    let count = r.git(&["rev-list", "--count", &format!("{onto}..HEAD")]);
    assert_eq!(count, "3");

    let clean = r.git(&["status", "--porcelain"]);
    assert!(clean.is_empty(), "git status should be clean, got: {clean}");
}

/// The Commit tool window can amend the paused edit commit before Continue.
/// Continue must reuse that commit instead of creating a second synthetic
/// commit, and it must preserve the amended message.
#[test]
fn rebase_edit_amend_then_continue_reuses_amended_commit() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "edited.txt", "before", "edit me");
    common::commit(&r.path, "after.txt", "after", "after");

    let repo = r.open();
    let outcome = repo
        .rebase(onto.clone(), vec![RebaseAction::Edit, RebaseAction::Pick])
        .unwrap();
    assert!(outcome.paused);

    r.write("edited.txt", "after amend");
    r.git(&["add", "edited.txt"]);
    let amended_id = repo.amend("amended edit message".into(), false).unwrap();
    r.write("edited.txt", "local edit after amend");
    let error = repo
        .rebase_continue()
        .expect_err("continue must not discard post-amend local edits");
    assert!(error.to_string().contains("uncommitted changes"));
    assert_eq!(r.git(&["rev-parse", "HEAD"]), amended_id);

    r.write("edited.txt", "after amend");
    let completed = repo.rebase_continue().unwrap();

    assert!(!completed.paused);
    assert_eq!(r.read("edited.txt"), "after amend");
    assert_eq!(r.read("after.txt"), "after");
    assert_eq!(
        r.git(&[
            "show",
            "-s",
            "--format=%s",
            &format!("{}^", completed.head_id)
        ]),
        "amended edit message"
    );
    assert_eq!(r.git(&["rev-parse", "HEAD^1^"]), onto);
    assert_ne!(completed.head_id, amended_id);
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

/// rebase_abort 恢复原 HEAD/工作区。
#[test]
fn rebase_edit_abort_restores() {
    let r = TestRepo::new();
    let onto = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "a.txt", "1", "c1");
    common::commit(&r.path, "b.txt", "2", "c2"); // Edit
    let original_head = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let outcome = repo
        .rebase(onto, vec![RebaseAction::Pick, RebaseAction::Edit])
        .unwrap();
    assert!(outcome.paused);

    // 中止应恢复原 HEAD
    repo.rebase_abort().unwrap();
    let after = r.git(&["rev-parse", "HEAD"]);
    assert_eq!(after, original_head, "abort should restore original HEAD");

    // 工作区恢复（a.txt, b.txt 都在，原内容）
    assert_eq!(r.read("a.txt"), "1");
    assert_eq!(r.read("b.txt"), "2");
}

#[test]
fn rebase_conflict_pauses_resolves_and_continues() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "value.txt", "base\n", "base");
    common::commit(&r.path, "value.txt", "ours\n", "ours");
    let original_head = r.git(&["rev-parse", "HEAD"]);

    r.git(&["switch", "-q", "-c", "onto", &base]);
    let onto = common::commit(&r.path, "value.txt", "theirs\n", "theirs");
    r.git(&["switch", "-q", "main"]);

    let repo = r.open();
    let outcome = repo.rebase(onto, vec![RebaseAction::Pick]).unwrap();
    assert!(outcome.paused);
    assert_eq!(outcome.pause_reason, Some(RebasePauseReason::Conflict));
    assert_eq!(outcome.conflicts, vec!["value.txt"]);
    assert!(r.read("value.txt").contains("<<<<<<<"));
    assert!(repo
        .status()
        .unwrap()
        .iter()
        .any(|entry| entry.staged == ChangeKind::Conflicted
            || entry.unstaged == ChangeKind::Conflicted));

    // 未解决时 continue 只报错，暂停状态仍保留。
    assert!(repo.rebase_continue().is_err());

    let repo2 = r.open();
    repo2
        .resolve_edited("value.txt".into(), "resolved\n".into())
        .unwrap();
    let completed = repo2.rebase_continue().unwrap();
    assert!(!completed.paused);
    assert_eq!(completed.pause_reason, None);
    assert!(completed.conflicts.is_empty());
    assert_eq!(r.read("value.txt"), "resolved\n");
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "ours");
    assert_ne!(r.git(&["rev-parse", "HEAD"]), original_head);
    let status = r.git(&["status", "--porcelain"]);
    assert!(status.is_empty(), "unexpected status: {status}");
}

#[test]
fn rebase_conflict_abort_restores_original_tree() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "value.txt", "base\n", "base");
    common::commit(&r.path, "value.txt", "ours\n", "ours");
    let original_head = r.git(&["rev-parse", "HEAD"]);

    r.git(&["switch", "-q", "-c", "onto", &base]);
    let onto = common::commit(&r.path, "value.txt", "theirs\n", "theirs");
    r.git(&["switch", "-q", "main"]);

    let repo = r.open();
    assert!(repo.rebase(onto, vec![RebaseAction::Pick]).unwrap().paused);
    repo.rebase_abort().unwrap();

    assert_eq!(r.git(&["rev-parse", "HEAD"]), original_head);
    assert_eq!(r.read("value.txt"), "ours\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn rebase_conflict_continue_can_pause_again_for_edit() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "value.txt", "base\n", "base");
    common::commit(&r.path, "value.txt", "ours\n", "ours");
    common::commit(&r.path, "after.txt", "after\n", "after");

    r.git(&["switch", "-q", "-c", "onto", &base]);
    let onto = common::commit(&r.path, "value.txt", "theirs\n", "theirs");
    r.git(&["switch", "-q", "main"]);

    let repo = r.open();
    let paused = repo
        .rebase(onto, vec![RebaseAction::Pick, RebaseAction::Edit])
        .unwrap();
    assert_eq!(paused.pause_reason, Some(RebasePauseReason::Conflict));

    repo.resolve_edited("value.txt".into(), "resolved\n".into())
        .unwrap();
    let paused_again = repo.rebase_continue().unwrap();
    assert_eq!(paused_again.pause_reason, Some(RebasePauseReason::Edit));
    assert_eq!(r.read("value.txt"), "resolved\n");
    assert_eq!(r.read("after.txt"), "after\n");

    r.write("after.txt", "edited-after\n");
    let completed = repo.rebase_continue().unwrap();
    assert!(!completed.paused);
    assert_eq!(r.read("after.txt"), "edited-after\n");
    let status = r.git(&["status", "--porcelain"]);
    assert!(status.is_empty(), "unexpected status: {status}");
}

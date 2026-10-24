//! 用户旅程级回归：把「日常提交」「分支与冲突」「历史与恢复」三组操作
//! 按 UI 的真实调用顺序串起来，在临时仓库 + 本地 bare remote 上执行。
//!
//! 这些测试不替代各能力的单元测试；它们验证跨步骤组合后 Git 状态仍然
//! 正确，也就是用户从打开仓库到完成一次完整任务时看到的结果。

mod common;

use arbor_engine::{BlockDecision, ChangeKind, PickKind, ResetMode};
use common::TestRepo;

fn bare_remote(r: &TestRepo, name: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    common::git(dir.path(), &["init", "--bare", "-q"]);
    r.open()
        .remote_add(name.into(), dir.path().to_string_lossy().into_owned())
        .unwrap();
    dir
}

fn two_way_conflict(r: &TestRepo, branch: &str) -> String {
    // base 提交后分叉：main 侧写 ours，分支侧写 theirs。
    let base = common::commit(&r.path, "file.txt", "line1\nbase\nline3\n", "base");
    r.git(&["branch", branch]);
    common::commit(&r.path, "file.txt", "line1\nours\nline3\n", "ours");
    r.git(&["checkout", "-q", branch]);
    common::commit(&r.path, "file.txt", "line1\ntheirs\nline3\n", "theirs");
    base
}

#[test]
fn daily_flow_open_edit_partial_stage_commit_push() {
    let r = TestRepo::new();
    common::commit(
        &r.path,
        "notes.txt",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n",
        "base",
    );
    let remote = bare_remote(&r, "origin");
    let repo = r.open();
    repo.push_with_options(Some("origin".into()), "main".into(), false, true)
        .expect("publish main");

    // 用户编辑：同一文件两处独立修改。
    r.write(
        "notes.txt",
        "l1\nstaged\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nlocal\n",
    );
    let diff = repo
        .staging_diff("notes.txt".into(), false)
        .expect("worktree diff");
    assert_eq!(
        diff.unstaged.expect("unstaged diff").hunks.len(),
        2,
        "two separate hunks"
    );
    // 只暂存第一处（新增行）。
    repo.stage_lines(
        "notes.txt".into(),
        vec![arbor_engine::LineSelection {
            hunk_index: 0,
            old_lines: Vec::new(),
            new_lines: vec![2],
        }],
    )
    .expect("stage first hunk");

    let status = repo.status().expect("status");
    let entry = status
        .iter()
        .find(|entry| entry.path == "notes.txt")
        .expect("notes.txt");
    assert_eq!(entry.staged, ChangeKind::Modified, "staged hunk");
    assert_eq!(
        entry.unstaged,
        ChangeKind::Modified,
        "remaining worktree edit"
    );

    let commit = repo
        .commit_with_options(
            "feat: stage one hunk".into(),
            false,
            None,
            None,
            None,
            None,
            None,
            false,
            Vec::new(),
            false,
        )
        .expect("commit");
    assert_eq!(
        r.git(&["show", "-s", "--format=%s", &commit]),
        "feat: stage one hunk"
    );
    let committed = r.git(&["show", &format!("{commit}:notes.txt")]);
    assert!(committed.contains("staged"), "commit has the staged hunk");
    assert!(
        !committed.contains("local"),
        "commit excludes the unstaged hunk"
    );
    assert!(
        r.read("notes.txt").contains("local"),
        "worktree keeps the rest"
    );

    repo.push_with_options(Some("origin".into()), "main".into(), false, false)
        .expect("push");
    assert_eq!(
        common::git(remote.path(), &["rev-parse", "refs/heads/main"]),
        commit
    );
}

#[test]
fn branch_flow_fetch_checkout_merge_conflict_continue_and_rebase_abort() {
    let r = TestRepo::new();
    let base = two_way_conflict(&r, "feature");
    let remote = bare_remote(&r, "origin");
    let repo = r.open();
    repo.push_with_options(Some("origin".into()), "main".into(), false, true)
        .unwrap();
    repo.push_refspec("origin".into(), "feature:refs/heads/feature".into(), false)
        .unwrap();

    // Fetch → 远程分支落地为本地分支并切过去。
    repo.fetch(Some("origin".into())).expect("fetch");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["branch", "-D", "feature"]);
    r.git(&["checkout", "-q", "-b", "feature", "origin/feature"]);
    repo.branch_set_upstream("feature".into(), "origin/feature".into())
        .expect("upstream");

    // 本地 feature 与 main 冲突的合并：暂停 → 解决 → Continue。
    let outcome = repo.merge("main".into()).expect("merge pauses on conflict");
    assert_eq!(outcome.conflicts, vec!["file.txt".to_string()]);
    assert!(repo.merge_in_progress());
    let conflict = repo.conflict_file("file.txt".into()).unwrap();
    assert!(conflict.result.contains("<<<<<<<"));
    repo.resolve(
        "file.txt".into(),
        vec![BlockDecision {
            block_index: 0,
            pick: PickKind::Ours,
        }],
    )
    .unwrap();
    let merge_commit = repo.merge_continue(None).expect("continue merge");
    assert_eq!(
        r.git(&["rev-list", "--parents", "-n", "1", &merge_commit])
            .split_whitespace()
            .count(),
        3,
        "merge commit has two parents"
    );
    assert_eq!(r.read("file.txt"), "line1\ntheirs\nline3\n");
    assert!(!repo.merge_in_progress());

    // Rebase 冲突 → Abort 必须恢复原分支现场。
    r.git(&["checkout", "-q", "main"]);
    r.git(&["checkout", "-q", "-b", "rebase-me", &base]);
    common::commit(
        &r.path,
        "file.txt",
        "line1\nrebase-side\nline3\n",
        "rebase side",
    );
    r.git(&["checkout", "-q", "main"]);
    common::commit(
        &r.path,
        "file.txt",
        "line1\nmain-side\nline3\n",
        "main side",
    );
    r.git(&["checkout", "-q", "rebase-me"]);
    let rebase_side_head = r.git(&["rev-parse", "HEAD"]);
    let paused = repo
        .rebase("main".into(), vec![arbor_engine::RebaseAction::Pick])
        .expect("rebase pauses on conflict");
    assert!(paused.paused, "rebase is paused");
    assert!(!paused.conflicts.is_empty(), "rebase reports the conflict");
    repo.rebase_abort().expect("abort rebase");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), rebase_side_head);
    assert_eq!(r.read("file.txt"), "line1\nrebase-side\nline3\n");
    assert!(r.git(&["status", "--porcelain"]).is_empty());
    let _ = remote;
}

#[test]
fn history_flow_diff_cherry_pick_revert_reset_stash() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "file.txt", "one\n", "one");
    let two = common::commit(&r.path, "file.txt", "one\ntwo\n", "two");
    common::commit(&r.path, "file.txt", "one\ntwo\nthree\n", "three");

    let repo = r.open();

    // 查看 Diff：提交与路径过滤。
    let commit_diff = repo.commit_diff(two.clone(), None).expect("commit diff");
    assert!(commit_diff
        .changes
        .iter()
        .any(|file| file.path == "file.txt"));
    let path_diff = repo
        .diff_commits_with_paths(
            base.clone(),
            "file.txt".into(),
            two.clone(),
            "file.txt".into(),
            false,
        )
        .expect("path diff");
    assert_eq!(path_diff.path, "file.txt");
    assert!(!path_diff.hunks.is_empty());

    // Cherry-pick 到 base 处的分支：与已有工作区无冲突。
    r.git(&["checkout", "-q", "-b", "pick-target", &base]);
    let picked = repo.cherry_pick(two.clone()).expect("cherry-pick");
    assert_eq!(r.git(&["show", "-s", "--format=%s", &picked]), "two");
    assert_eq!(r.read("file.txt"), "one\ntwo\n");

    // Revert 该提交：生成反向提交。
    let reverted = repo.revert(picked.clone()).expect("revert");
    assert_eq!(r.read("file.txt"), "one\n");
    assert_eq!(
        r.git(&["show", "-s", "--format=%s", &reverted]),
        "Revert \"two\""
    );

    // Reset soft 到 revert 之前：反向变更保留在 index/worktree。
    let target = picked.clone();
    repo.reset(target.clone(), ResetMode::Soft)
        .expect("soft reset");
    assert_eq!(r.git(&["rev-parse", "HEAD"]), target);
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .contains("file.txt"));
    assert_eq!(r.read("file.txt"), "one\n");

    // Stash 保存现场（含 index）→ 工作区干净 → Apply --index 恢复 → Pop 消费。
    repo.stash_save_with_options(Some("journey stash".into()), false, false)
        .expect("stash save");
    assert_eq!(r.git(&["status", "--porcelain"]), "");
    let stashes = repo.stash_list().expect("stash list");
    assert_eq!(stashes.len(), 1);
    repo.stash_apply_with_index(0, true).expect("stash apply");
    assert_eq!(r.read("file.txt"), "one\n");
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .contains("file.txt"));
    assert_eq!(repo.stash_list().unwrap().len(), 1, "apply keeps the stash");
    repo.stash_drop(0).expect("drop applied stash");
    assert!(repo.stash_list().unwrap().is_empty());

    assert!(
        repo.operation_state().unwrap().is_none(),
        "history operations leave no in-progress state"
    );
}

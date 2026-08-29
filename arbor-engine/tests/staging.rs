//! C：partial staging / amend / merged branch 夹具。
//! C1 双维度同时非空、C2 逐行 unstage、C3 整组应用、C4 amend、C5 branch_list_merged。

mod common;

use arbor_engine::{ChangeKind, LineSelection};

use common::TestRepo;

#[test]
fn selected_commit_preserves_unselected_index_and_partial_worktree_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "base-a\n", "init-a");
    common::commit(&r.path, "b.txt", "base-b\n", "init-b");

    r.write("a.txt", "base-a\nstaged-a\n");
    r.write("b.txt", "base-b\nstaged-b\n");
    let repo = r.open();
    repo.stage("a.txt".into()).expect("stage a");
    repo.stage("b.txt".into()).expect("stage b");
    r.write("a.txt", "base-a\nstaged-a\nlocal-a\n");

    let commit_id = repo
        .commit_with_options_paths(
            "selected commit".into(),
            vec!["a.txt".into()],
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
        .expect("selected commit");

    assert_eq!(
        r.git(&["show", "-s", "--format=%s", &commit_id]),
        "selected commit"
    );
    assert_eq!(
        r.git(&["show", &format!("{commit_id}:a.txt")]),
        "base-a\nstaged-a"
    );
    assert!(
        r.git(&["diff", "a.txt"]).contains("local-a"),
        "unstaged edit must remain outside the selected commit"
    );
    assert!(
        r.git(&["diff", "--cached", "b.txt"]).contains("staged-b"),
        "unselected staged file must remain staged"
    );
    let status = repo.status().expect("status after selected commit");
    let a = status
        .iter()
        .find(|entry| entry.path == "a.txt")
        .expect("a");
    let b = status
        .iter()
        .find(|entry| entry.path == "b.txt")
        .expect("b");
    assert_eq!(a.staged, arbor_engine::ChangeKind::Unchanged);
    assert_eq!(a.unstaged, arbor_engine::ChangeKind::Modified);
    assert_eq!(b.staged, arbor_engine::ChangeKind::Modified);
}

#[test]
fn selected_commit_handles_staged_rename_and_deletion_without_consuming_other_index_entries() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "old\n", "init-old");
    common::commit(&r.path, "delete.txt", "delete\n", "init-delete");
    r.write("keep.txt", "keep\n");
    common::git(&r.path, &["add", "keep.txt"]);
    common::git(&r.path, &["mv", "old.txt", "renamed.txt"]);

    let repo = r.open();
    repo.commit_with_options_paths(
        "rename selected".into(),
        vec!["old.txt".into(), "renamed.txt".into()],
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
    .expect("selected rename commit");
    assert_eq!(
        r.git(&["show", "--format=", "--name-status", "HEAD"]),
        "R100\told.txt\trenamed.txt"
    );
    assert_eq!(r.git(&["diff", "--cached", "--name-only"]), "keep.txt");

    common::git(&r.path, &["rm", "-q", "delete.txt"]);
    repo.commit_with_options_paths(
        "deletion selected".into(),
        vec!["delete.txt".into()],
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
    .expect("selected deletion commit");
    assert_eq!(
        r.git(&["show", "--format=", "--name-status", "HEAD"]),
        "D\tdelete.txt"
    );
    assert_eq!(r.git(&["diff", "--cached", "--name-only"]), "keep.txt");
}

/// C1：同文件两处独立修改，逐行暂存其中一处 -> staged=Modified 且 unstaged=Modified。
/// `git diff --cached` 与 `git diff` 各自只含对应修改。
#[test]
fn stage_lines_partial_double_dimension() {
    let r = TestRepo::new();
    // 14 行，改第 2 行（l2->C2）和第 11 行（l11->C11），间距足够成两个 hunk
    r.write(
        "f.txt",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n",
    );
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "init"]);
    r.write(
        "f.txt",
        "l1\nC2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nC11\nl12\nl13\nl14\n",
    );

    let repo = r.open();
    // 暂存第 1 处：hunk 0 的删除行 old_line=2
    repo.stage_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![2],
            new_lines: vec![],
        }],
    )
    .unwrap();

    // 双维度同时非空
    let st = repo.status().unwrap();
    let e = st.iter().find(|e| e.path == "f.txt").expect("f.txt entry");
    assert_eq!(e.staged, ChangeKind::Modified, "staged should be Modified");
    assert_eq!(
        e.unstaged,
        ChangeKind::Modified,
        "unstaged should be Modified"
    );

    // git diff --cached（HEAD vs 索引）只含 C2
    let cached = r.git(&["diff", "--cached", "f.txt"]);
    assert!(cached.contains("C2"), "cached diff should contain C2");
    assert!(
        !cached.contains("C11"),
        "cached diff should NOT contain C11"
    );
    // git diff（索引 vs 工作区）只含 C11
    let unstaged = r.git(&["diff", "f.txt"]);
    assert!(unstaged.contains("C11"), "unstaged diff should contain C11");
    assert!(
        !unstaged.contains("C2"),
        "unstaged diff should NOT contain C2"
    );
}

/// 子模块变更必须在父仓库中更新 160000 gitlink，而不能把子模块目录当作
/// 普通文件读取。取消暂存则恢复父仓库 HEAD 中的旧 gitlink，嵌套仓库自身
/// 的 detached HEAD 保持不变。
#[test]
fn stage_and_unstage_changed_submodule_gitlink() {
    let outer = TestRepo::new();
    let source = tempfile::tempdir().expect("submodule source");
    common::git(source.path(), &["init", "-q"]);
    common::git(source.path(), &["config", "user.name", "Arbor Test"]);
    common::git(source.path(), &["config", "user.email", "test@arbor.local"]);
    let old_submodule_head = common::commit(source.path(), "lib.txt", "v1\n", "lib v1");

    common::commit(&outer.path, "main.txt", "main\n", "outer init");
    common::git(
        &outer.path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &source.path().to_string_lossy(),
            "vendor/lib",
        ],
    );
    common::git(&outer.path, &["commit", "-q", "-m", "add submodule"]);

    let new_submodule_head = common::commit(source.path(), "lib.txt", "v2\n", "lib v2");
    let submodule_path = outer.path.join("vendor/lib");
    common::git(&submodule_path, &["fetch", "-q", "origin"]);
    common::git(&submodule_path, &["checkout", "-q", &new_submodule_head]);

    let repo = outer.open();
    let status = repo.status().expect("parent status");
    let changed = status
        .iter()
        .find(|entry| entry.path == "vendor/lib")
        .expect("changed gitlink status");
    assert_eq!(changed.staged, ChangeKind::Unchanged);
    assert_eq!(changed.unstaged, ChangeKind::Modified);

    repo.stage("vendor/lib".into()).expect("stage gitlink");
    let staged = outer.git(&["ls-files", "--stage", "--", "vendor/lib"]);
    assert!(
        staged.contains(&new_submodule_head) && staged.contains("vendor/lib"),
        "staged gitlink should point at nested HEAD: {staged}"
    );

    repo.unstage("vendor/lib".into()).expect("unstage gitlink");
    let restored = outer.git(&["ls-files", "--stage", "--", "vendor/lib"]);
    assert!(
        restored.contains(&old_submodule_head) && restored.contains("vendor/lib"),
        "unstage should restore the parent HEAD gitlink: {restored}"
    );
    let after = repo
        .status()
        .expect("status after unstage")
        .into_iter()
        .find(|entry| entry.path == "vendor/lib")
        .expect("gitlink remains changed after unstage");
    assert_eq!(after.staged, ChangeKind::Unchanged);
    assert_eq!(after.unstaged, ChangeKind::Modified);
}

/// 未初始化的子模块目录不能让 discovery 向上找到父仓库，更不能把父 HEAD
/// 错写进 160000 gitlink；失败时原 index 必须保持不变。
#[test]
fn stage_uninitialized_submodule_directory_fails_without_mutating_index() {
    let outer = TestRepo::new();
    let source = tempfile::tempdir().expect("submodule source");
    common::git(source.path(), &["init", "-q"]);
    common::git(source.path(), &["config", "user.name", "Arbor Test"]);
    common::git(source.path(), &["config", "user.email", "test@arbor.local"]);
    let gitlink_head = common::commit(source.path(), "lib.txt", "v1\n", "lib v1");

    std::fs::create_dir_all(outer.path.join("vendor/lib")).expect("uninitialized directory");
    let cacheinfo = format!("160000,{gitlink_head},vendor/lib");
    common::git(
        &outer.path,
        &["update-index", "--add", "--cacheinfo", &cacheinfo],
    );
    let before = outer.git(&["ls-files", "--stage", "--", "vendor/lib"]);

    let repo = outer.open();
    let error = repo
        .stage("vendor/lib".into())
        .expect_err("uninitialized submodule must fail closed");
    assert!(!error.to_string().is_empty());

    let after = outer.git(&["ls-files", "--stage", "--", "vendor/lib"]);
    assert_eq!(
        after, before,
        "failed stage must not mutate the gitlink index"
    );
}

/// C2：先全量暂存两处，再逐行 unstage 其中一处（HEAD 侧选择）-> 反向双维度。
#[test]
fn unstage_lines_partial_reverse() {
    let r = TestRepo::new();
    r.write(
        "f.txt",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n",
    );
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "init"]);
    r.write(
        "f.txt",
        "l1\nC2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nC11\nl12\nl13\nl14\n",
    );
    // 全量暂存两处
    r.git(&["add", "f.txt"]);

    let repo = r.open();
    // unstage 第 1 处：IndexToHead 的 old 侧 = HEAD，old_line=2（l2）
    repo.unstage_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![2],
            new_lines: vec![],
        }],
    )
    .unwrap();

    // 第 1 处回退到 unstaged，第 2 处仍 staged
    let st = repo.status().unwrap();
    let e = st.iter().find(|e| e.path == "f.txt").expect("f.txt entry");
    assert_eq!(
        e.staged,
        ChangeKind::Modified,
        "staged should be Modified (C11)"
    );
    assert_eq!(
        e.unstaged,
        ChangeKind::Modified,
        "unstaged should be Modified (C2)"
    );

    // cached 只含 C11，unstaged 只含 C2
    let cached = r.git(&["diff", "--cached", "f.txt"]);
    assert!(cached.contains("C11") && !cached.contains("C2"));
    let unstaged = r.git(&["diff", "f.txt"]);
    assert!(unstaged.contains("C2") && !unstaged.contains("C11"));
}

/// C3：多行变更组不可拆分--选中组内一行 -> 整组应用。
#[test]
fn stage_lines_whole_group() {
    let r = TestRepo::new();
    // l2,l3 两行一起改成 C2,C3（一个变更组）
    r.write("f.txt", "l1\nl2\nl3\nl4\nl5\n");
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "init"]);
    r.write("f.txt", "l1\nC2\nC3\nl4\nl5\n");

    let repo = r.open();
    // 只选中组内第一行（old_line=2），整组（l2,l3 -> C2,C3）应一起暂存
    repo.stage_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![2],
            new_lines: vec![],
        }],
    )
    .unwrap();

    // 索引内容 = l1,C2,C3,l4,l5（整组都已暂存）
    let staged = r.git(&["show", ":f.txt"]);
    assert_eq!(staged, "l1\nC2\nC3\nl4\nl5");
    // 工作区未动
    assert_eq!(r.read("f.txt"), "l1\nC2\nC3\nl4\nl5\n");
    // staged=Modified，unstaged=Unchanged（整组都暂存了，工作区与索引一致）
    let st = repo.status().unwrap();
    let e = st.iter().find(|e| e.path == "f.txt").expect("f.txt entry");
    assert_eq!(e.staged, ChangeKind::Modified);
    assert_eq!(e.unstaged, ChangeKind::Unchanged);
}

/// 纯新增变更没有 old 侧行号，必须用 new_lines 选择后才能逐行暂存。
#[test]
fn stage_lines_pure_insertion_selected_by_new_line() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "l1\nl2\n", "init");
    r.write("f.txt", "l1\ninserted\nl2\n");

    let repo = r.open();
    repo.stage_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![],
            new_lines: vec![2],
        }],
    )
    .unwrap();

    assert_eq!(r.git(&["show", ":f.txt"]), "l1\ninserted\nl2");
    assert!(r.git(&["diff", "--", "f.txt"]).is_empty());
}

/// C3b：hunk 级暂存（old_lines 空 = 选中该 hunk 全部变更组）。
#[test]
fn stage_lines_hunk_level() {
    let r = TestRepo::new();
    r.write(
        "f.txt",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n",
    );
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "init"]);
    r.write(
        "f.txt",
        "l1\nC2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nC11\nl12\nl13\nl14\n",
    );

    let repo = r.open();
    // hunk 级：old_lines 空 = 暂存 hunk 0 全部组
    repo.stage_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![],
            new_lines: vec![],
        }],
    )
    .unwrap();

    let staged = r.git(&["show", ":f.txt"]);
    assert!(staged.contains("C2"), "hunk-level should stage C2");
    assert!(!staged.contains("C11"), "hunk 1 (C11) should NOT be staged");
}

/// Staging diff 的文件级 Revert 只能回到 index，不能把部分暂存内容
/// 错误地回退到 HEAD。
#[test]
fn restore_unstaged_path_keeps_staged_content() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "head\n", "init");
    r.write("f.txt", "staged\n");
    let repo = r.open();
    repo.stage("f.txt".into()).unwrap();
    r.write("f.txt", "unstaged\n");

    repo.restore_unstaged_path("f.txt".into()).unwrap();

    assert_eq!(r.read("f.txt"), "staged\n");
    assert_eq!(r.git(&["show", ":f.txt"]), "staged");
    assert!(r
        .git(&["diff", "--cached", "--", "f.txt"])
        .contains("staged"));
    assert!(r.git(&["diff", "--", "f.txt"]).is_empty());
}

/// Hunk rollback 只恢复选中的 worktree hunk，既保留另一个 hunk，也不动 index。
#[test]
fn restore_unstaged_lines_keeps_other_hunk_and_index() {
    let r = TestRepo::new();
    r.write(
        "f.txt",
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n",
    );
    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "init"]);
    r.write(
        "f.txt",
        "l1\nS2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n",
    );
    let repo = r.open();
    repo.stage_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![2],
            new_lines: vec![],
        }],
    )
    .unwrap();
    r.write(
        "f.txt",
        "l1\nS2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nU11\nl12\nl13\nl14\n",
    );

    repo.restore_unstaged_lines(
        "f.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![],
            new_lines: vec![],
        }],
    )
    .unwrap();

    assert_eq!(
        r.read("f.txt"),
        "l1\nS2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"
    );
    assert_eq!(
        r.git(&["show", ":f.txt"]),
        "l1\nS2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14"
    );
    assert!(r.git(&["diff", "--cached", "--", "f.txt"]).contains("S2"));
    assert!(r.git(&["diff", "--", "f.txt"]).is_empty());
}

/// 对 index 中不存在的新增文件，hunk rollback 应删除文件而不是留下空文件。
#[test]
fn restore_unstaged_lines_removes_selected_untracked_addition() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base\n", "init");
    r.write("new.txt", "new content\n");
    let repo = r.open();

    repo.restore_unstaged_lines(
        "new.txt".into(),
        vec![LineSelection {
            hunk_index: 0,
            old_lines: vec![],
            new_lines: vec![],
        }],
    )
    .unwrap();

    assert!(!r.exists("new.txt"));
    assert_eq!(r.git(&["status", "--porcelain"]), "");
}

/// C4：amend 后 parent 链正确、树=索引、信息更新。
#[test]
fn amend_updates_tree_and_parent() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "v1", "first");
    let first = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "f.txt", "v2", "second");

    // 改并暂存 v3
    r.write("f.txt", "v3");
    r.git(&["add", "f.txt"]);

    let repo = r.open();
    let new_id = repo.amend("amended message".into(), true).unwrap();
    assert!(!new_id.is_empty());

    // HEAD 信息 = amended message
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "amended message");
    // HEAD 的第一父 = first（second 被替换）
    let parent = r.git(&["log", "-1", "--format=%P"]);
    assert_eq!(parent, first, "amend parent should be 'first' commit");
    // 树 = 索引（f.txt=v3）
    assert_eq!(r.git(&["show", "HEAD:f.txt"]), "v3");
}

#[test]
fn reword_head_does_not_include_staged_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "initial");
    let original_tree = r.git(&["rev-parse", "HEAD^{tree}"]);
    r.write("staged.txt", "keep staged");
    r.git(&["add", "staged.txt"]);

    let repo = r.open();
    let new_id = repo.reword_head("renamed only".into(), true).unwrap();

    assert_eq!(r.git(&["rev-parse", "HEAD"]), new_id);
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "renamed only");
    assert_eq!(r.git(&["rev-parse", "HEAD^{tree}"]), original_tree);
    assert_eq!(r.git(&["diff", "--cached", "--name-only"]), "staged.txt");
}

#[test]
fn reword_undo_restores_head_without_touching_local_scene() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "initial");
    let initial_head = r.git(&["rev-parse", "HEAD"]);
    r.write("staged.txt", "keep staged");
    r.git(&["add", "staged.txt"]);

    let repo = r.open();
    let expected_head = repo.reword_head("renamed only".into(), true).unwrap();
    repo.restore_head_ref_if_expected(
        initial_head.clone(),
        expected_head.clone(),
        Some("main".into()),
    )
    .unwrap();

    assert_eq!(r.git(&["rev-parse", "HEAD"]), initial_head);
    assert_eq!(r.git(&["diff", "--cached", "--name-only"]), "staged.txt");
    assert_eq!(r.read("staged.txt"), "keep staged");

    let stale = repo
        .restore_head_ref_if_expected(initial_head, expected_head, Some("main".into()))
        .expect_err("a second undo must fail after the expected HEAD changed");
    assert!(
        stale.to_string().contains("HEAD changed"),
        "unexpected stale undo error: {stale}"
    );
}

#[test]
fn reword_head_preserves_merge_parents() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    r.git(&["switch", "-q", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);

    let repo = r.open();
    let new_id = repo.reword_head("renamed merge".into(), true).unwrap();
    let parents = r.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);

    assert_eq!(r.git(&["rev-parse", "HEAD"]), new_id);
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "renamed merge");
    assert_eq!(
        parents.split_whitespace().count(),
        3,
        "merge parents were lost: {parents}"
    );
    assert_eq!(r.git(&["status", "--porcelain"]), "");
}

#[test]
fn reword_non_head_root_rebuilds_linear_history() {
    let r = TestRepo::new();
    let root = common::commit(&r.path, "root.txt", "root", "initial");
    common::commit(&r.path, "second.txt", "second", "second");
    common::commit(&r.path, "third.txt", "third", "third");

    let repo = r.open();
    let outcome = repo
        .reword_root_commit(root, "renamed root\n\nroot details".into())
        .unwrap();

    assert!(!outcome.paused);
    assert_eq!(
        r.git(&["log", "--format=%s", "--reverse"]),
        "renamed root\nsecond\nthird"
    );
    assert_eq!(r.git(&["log", "-1", "--format=%B"]), "third");
    assert_eq!(r.git(&["rev-list", "--count", "HEAD"]), "3");
    assert_eq!(r.git(&["show", "HEAD:root.txt"]), "root");
    assert_eq!(r.git(&["status", "--porcelain"]), "");
}

/// C5：branch_list_merged 返回已合并分支，不含未合并分支与当前分支。
#[test]
fn branch_list_merged_filters() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "base");

    // merged 分支：提交后 ff 合并入 main
    r.git(&["branch", "merged"]);
    r.git(&["checkout", "-q", "merged"]);
    common::commit(&r.path, "m.txt", "m", "on merged");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["merge", "--ff-only", "-q", "merged"]);

    // unmerged 分支：有 main 未包含的提交
    r.git(&["branch", "unmerged"]);
    r.git(&["checkout", "-q", "unmerged"]);
    common::commit(&r.path, "u.txt", "u", "on unmerged");
    r.git(&["checkout", "-q", "main"]);

    let merged = r.open().branch_list_merged().unwrap();
    let names: Vec<String> = merged.iter().map(|b| b.name.clone()).collect();
    assert!(
        names.contains(&"merged".to_string()),
        "merged branch should be listed"
    );
    assert!(
        !names.contains(&"unmerged".to_string()),
        "unmerged branch should NOT be listed"
    );
    assert!(
        !names.contains(&"main".to_string()),
        "current branch should NOT be listed"
    );
}

/// Merge Dialog 的 all-refs 校验必须覆盖 remote-tracking 分支和当前分支，
/// 而 cleanup 专用的 branch_list_merged 仍保持“仅本地、排除当前分支”语义。
#[test]
fn branch_list_merged_all_includes_remote_tracking_refs() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "base");

    r.git(&["branch", "merged"]);
    r.git(&["checkout", "-q", "merged"]);
    let merged_tip = common::commit(&r.path, "m.txt", "m", "on merged");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["merge", "--ff-only", "-q", "merged"]);
    r.git(&["update-ref", "refs/remotes/origin/feature", &merged_tip]);
    r.git(&["update-ref", "refs/remotes/origin/topic/HEAD", &merged_tip]);

    r.git(&["branch", "remote-unmerged"]);
    r.git(&["checkout", "-q", "remote-unmerged"]);
    let unmerged_tip = common::commit(&r.path, "u.txt", "u", "remote only");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["update-ref", "refs/remotes/origin/unmerged", &unmerged_tip]);

    let merged = r.open().branch_list_merged_all().unwrap();
    let names: Vec<String> = merged.iter().map(|branch| branch.name.clone()).collect();
    assert!(names.contains(&"merged".to_string()));
    assert!(names.contains(&"origin/feature".to_string()));
    assert!(names.contains(&"origin/topic/HEAD".to_string()));
    assert!(!names.contains(&"origin/unmerged".to_string()));
    assert!(names.contains(&"main".to_string()));
}

/// C6：Cleanup 预览按指定目标分支和名称前缀计算，不只依赖当前 HEAD。
#[test]
fn branch_list_merged_into_target_and_prefix() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "base");

    r.git(&["branch", "feature/merged"]);
    r.git(&["checkout", "-q", "feature/merged"]);
    common::commit(&r.path, "m.txt", "m", "merged feature");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["merge", "--ff-only", "-q", "feature/merged"]);

    r.git(&["branch", "feature/unmerged"]);
    r.git(&["checkout", "-q", "feature/unmerged"]);
    common::commit(&r.path, "u.txt", "u", "unmerged feature");
    r.git(&["checkout", "-q", "main"]);

    let merged = r
        .open()
        .branch_list_merged_into("main".into(), "feature/".into())
        .unwrap();
    let names: Vec<String> = merged.iter().map(|b| b.name.clone()).collect();
    assert!(names.contains(&"feature/merged".to_string()));
    assert!(!names.contains(&"feature/unmerged".to_string()));
    assert!(merged
        .iter()
        .find(|branch| branch.name == "feature/merged")
        .is_some_and(|branch| branch.last_commit_time > 0));
}

#[test]
fn branch_list_merged_into_excludes_target_branch_with_empty_prefix() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "base");
    r.git(&["branch", "feature/merged"]);
    r.git(&["checkout", "-q", "feature/merged"]);
    common::commit(&r.path, "m.txt", "m", "merged feature");
    r.git(&["checkout", "-q", "main"]);
    r.git(&["merge", "--ff-only", "-q", "feature/merged"]);

    let merged = r
        .open()
        .branch_list_merged_into("main".into(), "".into())
        .unwrap();
    let names: Vec<String> = merged.iter().map(|branch| branch.name.clone()).collect();
    assert!(!names.contains(&"main".to_string()));
    assert!(names.contains(&"feature/merged".to_string()));
}

/// FindMergedLocalBranches follows IntelliJ DeepComparator semantics: a
/// branch whose complete patch series was cherry-picked into the target is
/// merged even when its commit ids and messages differ.
#[test]
fn branch_list_merged_into_recognizes_patch_equivalent_cherry_pick() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature/picked"]);
    common::commit(&r.path, "picked.txt", "same patch", "source message");

    r.git(&["switch", "-q", "main"]);
    common::commit(
        &r.path,
        "picked.txt",
        "same patch",
        "different target message",
    );

    r.git(&["switch", "-q", "-c", "feature/mixed"]);
    common::commit(&r.path, "unpicked.txt", "not in target", "unpicked message");
    r.git(&["switch", "-q", "main"]);

    let merged = r
        .open()
        .branch_list_merged_into("main".into(), "feature/".into())
        .unwrap();
    let names: Vec<String> = merged.iter().map(|branch| branch.name.clone()).collect();
    assert!(names.contains(&"feature/picked".to_string()));
    assert!(!names.contains(&"feature/mixed".to_string()));
}

/// C7：Cleanup 批量删除复用 branch_delete，并继续保护当前分支。
#[test]
fn branch_cleanup_delete_preserves_current_branch_guard() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "base");
    r.git(&["branch", "cleanup-candidate"]);

    r.open()
        .branch_delete("cleanup-candidate".into(), false)
        .unwrap();
    assert!(!r
        .git(&["branch", "--list", "cleanup-candidate"])
        .contains("cleanup-candidate"));

    let error = r.open().branch_delete("main".into(), false).unwrap_err();
    assert!(error
        .to_string()
        .to_lowercase()
        .contains("cannot delete branch"));
}

/// recent_commit_messages 去重 + 顺序（新->旧）。
#[test]
fn recent_commit_messages_dedup() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "feat: add");
    common::commit(&r.path, "a.txt", "2", "fix: bug");
    common::commit(&r.path, "a.txt", "3", "feat: add"); // 重复标题

    let msgs = r.open().recent_commit_messages(10).unwrap();
    assert_eq!(msgs.len(), 2, "duplicates should be deduped");
    assert_eq!(msgs[0], "feat: add", "newest first");
    assert_eq!(msgs[1], "fix: bug");
}

/// commit_template：未配置返回 None；配置后读文件内容。
#[test]
fn commit_template_none_when_unset() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "init");
    assert_eq!(r.open().commit_template().unwrap(), None);
}

#[test]
fn commit_template_reads_file() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "1", "init");
    // 写模板文件 + 配置 commit.template（相对工作区根）
    r.write(".commit-template", "feat: \n\nRefs: #");
    r.git(&["config", "commit.template", ".commit-template"]);
    let tpl = r.open().commit_template().unwrap();
    assert_eq!(tpl.as_deref(), Some("feat: \n\nRefs: #"));
}

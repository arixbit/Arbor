//! DIFF-001：完整 diff 行为。
//! attributes-aware binary、CRLF 敏感度、whitespace/word 设置、
//! 多来源统一数据源、rename/binary/submodule。

mod common;

use arbor_engine::{DiffMode, DiffSettings, EngineError, FilePick};
use common::TestRepo;

#[test]
fn attributes_binary_beats_nul_sniffing() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    // 内容无 NUL,但 attributes 声明 binary
    r.write(".gitattributes", "data.bin binary\n");
    r.git(&["add", ".gitattributes"]);
    r.git(&["commit", "-q", "-m", "attrs"]);
    r.write("data.bin", "plain text without nul\n");
    r.git(&["add", "data.bin"]);
    r.git(&["commit", "-q", "-m", "add bin"]);
    r.write("data.bin", "plain text without nul\nchanged\n");

    let repo = r.open();
    let diff = repo
        .diff_file_with_settings(
            "data.bin".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("diff");
    assert!(diff.binary, "attributes binary 优先于 NUL 嗅探");
    assert!(diff.hunks.is_empty());

    // 对照:无 attributes 的普通文本文件正常 diff
    let diff2 = repo
        .diff_file_with_settings(
            ".gitattributes".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("diff2");
    assert!(!diff2.binary);
}

#[test]
fn textconv_diff_is_opt_in_and_reversible() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=upper\n*.bin diff=hex\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attributes",
    );
    r.git(&["config", "diff.upper.textconv", "awk '{print toupper($0)}'"]);
    r.git(&["config", "diff.hex.textconv", "od -An -tx1"]);
    common::commit(&r.path, "f.txt", "old line\n", "init");
    let old_revision = r.git(&["rev-parse", "HEAD"]);
    r.write("f.txt", "new line\n");
    std::fs::write(r.path.join("f.bin"), [0_u8, 1, 2]).expect("binary file");
    r.git(&["add", "f.bin"]);
    r.git(&["commit", "-q", "-m", "binary"]);
    std::fs::write(r.path.join("f.bin"), [0_u8, 1, 3]).expect("changed binary file");

    let repo = r.open();
    let raw = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("raw diff");
    assert!(raw.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "old line")
            && hunk.new_lines.iter().any(|line| line.text == "new line")
    }));

    let converted = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("textconv diff");
    assert!(!converted.binary);
    assert!(converted.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "OLD LINE")
            && hunk.new_lines.iter().any(|line| line.text == "NEW LINE")
    }));

    let reversed = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::IndexToWorktree,
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("reversed textconv diff");
    assert!(reversed.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| {
            line.kind == arbor_engine::DiffLineKind::Deletion && line.text == "NEW LINE"
        }) && hunk.new_lines.iter().any(|line| {
            line.kind == arbor_engine::DiffLineKind::Addition && line.text == "OLD LINE"
        })
    }));

    r.git(&["add", "f.txt"]);
    r.git(&["commit", "-q", "-m", "changed text"]);
    let new_revision = r.git(&["rev-parse", "HEAD"]);

    let binary_textconv = repo
        .diff_file_with_settings(
            "f.bin".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("binary textconv diff");
    assert!(!binary_textconv.binary);
    assert!(!binary_textconv.hunks.is_empty());

    let revision_textconv = repo
        .diff_commits_with_settings(
            old_revision.clone(),
            new_revision.clone(),
            "f.txt".into(),
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("revision textconv diff");
    assert!(revision_textconv.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "OLD LINE")
            && hunk.new_lines.iter().any(|line| line.text == "NEW LINE")
    }));

    let commit_textconv = repo
        .commit_file_diff_with_settings(
            new_revision,
            None,
            "f.txt".into(),
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("commit textconv diff");
    assert!(commit_textconv.hunks.iter().any(|hunk| {
        hunk.old_lines.iter().any(|line| line.text == "OLD LINE")
            && hunk.new_lines.iter().any(|line| line.text == "NEW LINE")
    }));
}

#[test]
fn crlf_sensitivity_changes_matching() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "one\ntwo\n", "init");
    // 工作区改为 CRLF 行尾(内容相同)
    r.write("f.txt", "one\r\ntwo\r\n");

    let repo = r.open();
    // 默认 CRLF 敏感:整行视为变更
    let sensitive = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("sensitive");
    assert!(sensitive
        .hunks
        .iter()
        .any(|h| !h.old_lines.is_empty() || !h.new_lines.is_empty()));

    // crlf_sensitive=false:比较前归一化 CRLF -> 无变更
    let insensitive = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                crlf_sensitive: false,
                ..Default::default()
            },
        )
        .expect("insensitive");
    assert!(insensitive.hunks.is_empty(), "CRLF 归一化后无 diff");
}

#[test]
fn text_attribute_normalizes_worktree_diff_matching() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    common::commit(&r.path, "f.txt", "one\ntwo\n", "init");
    r.write("f.txt", "one\r\ntwo\r\n");

    let repo = r.open();
    let diff = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("attribute-aware diff");
    assert!(
        diff.hunks.is_empty(),
        "text attribute should hide EOL-only drift"
    );
    assert!(
        repo.staging_diff("f.txt".into(), false)
            .expect("staging diff")
            .unstaged
            .is_none(),
        "staging fast path should use the same canonical worktree bytes"
    );
    let revision = r.git(&["rev-parse", "HEAD"]);
    let revision_diff = repo
        .diff_revision_with_worktree(revision, "f.txt".into(), false)
        .expect("attribute-aware revision diff");
    assert!(
        revision_diff.hunks.is_empty(),
        "revision diff should use the same canonical worktree bytes"
    );
}

#[test]
fn ignore_all_space_and_eol_settings() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "alpha beta gamma\n", "init");
    r.write("f.txt", "alpha   beta    gamma  \n");

    let repo = r.open();
    // 默认:行变更
    let plain = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings::default(),
        )
        .expect("plain");
    assert!(!plain.hunks.is_empty(), "默认应报告空白变更");

    // ignore_all_space:无 diff
    let all_space = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                ignore_all_space: true,
                ..Default::default()
            },
        )
        .expect("all space");
    assert!(all_space.hunks.is_empty(), "忽略所有空白后无 diff");

    // ignore_whitespace_at_eol:行尾空白差异忽略,中间空白仍算变更
    let eol = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                ignore_whitespace_at_eol: true,
                ..Default::default()
            },
        )
        .expect("eol");
    assert!(!eol.hunks.is_empty(), "行尾空白忽略但中间空白仍是变更");
}

#[test]
fn word_diff_populates_spans() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "the quick brown fox\n", "init");
    r.write("f.txt", "the quick red fox\n");

    let repo = r.open();
    let diff = repo
        .diff_file_with_settings(
            "f.txt".into(),
            DiffMode::WorktreeToIndex,
            DiffSettings {
                word_diff: true,
                ..Default::default()
            },
        )
        .expect("word diff");
    assert!(!diff.hunks.is_empty());
    // 变更行应有词级 span(高亮区间)
    let has_spans = diff.hunks.iter().any(|h| {
        h.old_lines.iter().any(|l| !l.spans.is_empty())
            || h.new_lines.iter().any(|l| !l.spans.is_empty())
    });
    assert!(has_spans, "word diff 产生词级 span");
}

#[test]
fn unified_data_source_across_modes() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n2\n", "init");
    r.write("f.txt", "1\n2\n3\n");
    r.git(&["add", "f.txt"]);
    r.write("f.txt", "1\n2\n3\n4\n");
    let repo = r.open();

    // 同一 FileDiff 模型服务所有来源
    let unstaged = repo
        .diff_file("f.txt".into(), DiffMode::WorktreeToIndex, false)
        .expect("unstaged");
    let staged = repo
        .diff_file("f.txt".into(), DiffMode::IndexToHead, false)
        .expect("staged");
    let staged_with_local = repo
        .diff_file("f.txt".into(), DiffMode::IndexToWorktree, false)
        .expect("staged with local");
    let full = repo
        .diff_file("f.txt".into(), DiffMode::WorktreeToHead, false)
        .expect("full");
    assert!(!unstaged.binary && !staged.binary && !full.binary);
    // 未暂存只有 3->4;已暂存只有 2->3;整体含两个变更
    let additions = |diff: &arbor_engine::FileDiff| {
        diff.hunks
            .iter()
            .flat_map(|h| h.new_lines.iter())
            .filter(|l| l.kind == arbor_engine::DiffLineKind::Addition)
            .count()
    };
    assert_eq!(additions(&unstaged), 1, "未暂存只有 3->4");
    assert_eq!(additions(&staged), 1, "已暂存只有 2->3");
    assert_eq!(additions(&full), 2, "整体含两个变更");
    assert!(staged_with_local
        .hunks
        .iter()
        .flat_map(|h| h.old_lines.iter())
        .any(|line| line.kind == arbor_engine::DiffLineKind::Deletion));

    // 提交来源(diff_commits)与 clipborad(diff_with_text)同模型
    let head = r.git(&["rev-parse", "HEAD"]);
    let commit_diff = repo
        .diff_commits(head.clone(), head, "f.txt".into(), false)
        .expect("commit diff");
    assert!(!commit_diff.binary);
    let clipboard = repo
        .diff_with_text("f.txt".into(), "1\n2\n3\n5\n".into(), false)
        .expect("clipboard");
    assert!(!clipboard.binary);
    let additions = |diff: &arbor_engine::FileDiff| {
        diff.hunks
            .iter()
            .flat_map(|h| h.new_lines.iter())
            .filter(|l| l.kind == arbor_engine::DiffLineKind::Addition)
            .count()
    };
    assert_eq!(additions(&clipboard), 1);
}

#[test]
fn diff_commits_with_paths_handles_renamed_file_endpoints() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=upper\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attributes",
    );
    r.git(&["config", "diff.upper.textconv", "awk '{print toupper($0)}'"]);
    common::commit(&r.path, "old.txt", "one\n", "initial");
    let old_revision = r.git(&["rev-parse", "HEAD"]);

    r.git(&["mv", "old.txt", "new.txt"]);
    r.write("new.txt", "one\ntwo\n");
    r.git(&["add", "new.txt"]);
    r.git(&["commit", "-q", "-m", "rename and edit"]);
    let new_revision = r.git(&["rev-parse", "HEAD"]);

    let diff = r
        .open()
        .diff_commits_with_paths(
            old_revision,
            "old.txt".into(),
            new_revision,
            "new.txt".into(),
            false,
        )
        .expect("rename-aware revision diff");
    assert_eq!(diff.path, "new.txt");
    assert!(diff
        .hunks
        .iter()
        .flat_map(|h| h.new_lines.iter())
        .any(|line| { line.kind == arbor_engine::DiffLineKind::Addition && line.text == "two" }));

    let converted = r
        .open()
        .diff_commits_with_paths_with_settings(
            r.git(&["rev-parse", "HEAD~1"]),
            "old.txt".into(),
            r.git(&["rev-parse", "HEAD"]),
            "new.txt".into(),
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("rename-aware textconv revision diff");
    assert!(converted
        .hunks
        .iter()
        .any(|hunk| { hunk.new_lines.iter().any(|line| line.text == "TWO") }));

    let error = r
        .open()
        .diff_commits_with_paths(
            r.git(&["rev-parse", "HEAD~1"]),
            "../old.txt".into(),
            r.git(&["rev-parse", "HEAD"]),
            "new.txt".into(),
            false,
        )
        .expect_err("revision paths must stay inside the nested root");
    assert!(error.to_string().contains("path escapes repository"));
}

#[test]
fn diff_texts_compares_snapshots_without_worktree_state() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "worktree\n", "init");
    let repo = r.open();

    let diff = repo
        .diff_texts(
            "f.txt".into(),
            "local stage\n".into(),
            "editable result\n".into(),
            false,
        )
        .expect("snapshot diff");

    assert!(!diff.binary);
    assert!(diff.hunks.iter().any(|h| {
        h.old_lines.iter().any(|line| line.text == "local stage")
            && h.new_lines
                .iter()
                .any(|line| line.text == "editable result")
    }));
}

#[test]
fn revision_to_worktree_diff_handles_text_and_missing_files() {
    let r = TestRepo::new();
    let revision = common::commit(&r.path, "f.txt", "one\ntwo\n", "init");
    let repo = r.open();

    r.write("f.txt", "one\nthree\n");
    let changed = repo
        .diff_revision_with_worktree(revision.clone(), "f.txt".into(), false)
        .expect("revision to worktree diff");
    assert!(!changed.binary);
    assert!(changed.hunks.iter().any(|h| {
        h.old_lines.iter().any(|line| line.text == "two")
            && h.new_lines.iter().any(|line| line.text == "three")
    }));

    std::fs::remove_file(r.path.join("f.txt")).expect("remove worktree file");
    let deleted = repo
        .diff_revision_with_worktree(revision, "f.txt".into(), false)
        .expect("deleted worktree diff");
    assert!(!deleted.binary);
    assert!(deleted
        .hunks
        .iter()
        .any(|h| { !h.old_lines.is_empty() && h.new_lines.is_empty() }));
}

#[test]
fn tree_changes_with_worktree_includes_tracked_staged_and_unstaged_changes() {
    let r = TestRepo::new();
    common::commit(&r.path, "unstaged.txt", "before\n", "unstaged base");
    common::commit(&r.path, "staged.txt", "before\n", "staged base");
    let revision = r.git(&["rev-parse", "HEAD"]);

    r.write("unstaged.txt", "after\n");
    r.write("staged.txt", "after\n");
    r.git(&["add", "staged.txt"]);
    r.write("untracked.txt", "not part of git diff\n");

    let repo = r.open();
    let changes = repo
        .tree_changes_with_worktree(revision)
        .expect("tree changes with worktree");
    let paths: Vec<_> = changes.iter().map(|change| change.path.as_str()).collect();
    assert_eq!(paths, vec!["staged.txt", "unstaged.txt"]);
    assert!(changes.iter().all(|change| {
        change.kind == arbor_engine::TreeChangeKind::Modified && change.old_path.is_none()
    }));
}

#[test]
fn tree_changes_with_worktree_preserves_renames() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "same\n", "base");
    let revision = r.git(&["rev-parse", "HEAD"]);
    r.git(&["mv", "old.txt", "new.txt"]);

    let changes = r
        .open()
        .tree_changes_with_worktree(revision)
        .expect("rename diff");
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].kind, arbor_engine::TreeChangeKind::Renamed);
    assert_eq!(changes[0].old_path.as_deref(), Some("old.txt"));
    assert!(changes[0].is_pure_move);

    let diff = r
        .open()
        .diff_revision_path_with_worktree(
            r.git(&["rev-parse", "HEAD~0"]),
            "old.txt".into(),
            "new.txt".into(),
            false,
        )
        .expect("rename file diff");
    assert_eq!(diff.path, "new.txt");
    assert!(diff.hunks.is_empty(), "pure rename has identical content");
}

#[test]
fn revision_to_renamed_worktree_diff_uses_opt_in_textconv() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=upper\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attributes",
    );
    r.git(&["config", "diff.upper.textconv", "awk '{print toupper($0)}'"]);
    common::commit(&r.path, "old.txt", "one\n", "initial");
    let revision = r.git(&["rev-parse", "HEAD"]);

    r.git(&["mv", "old.txt", "new.txt"]);
    r.write("new.txt", "one\ntwo\n");

    let converted = r
        .open()
        .diff_revision_path_with_worktree_with_settings(
            revision,
            "old.txt".into(),
            "new.txt".into(),
            DiffSettings {
                use_external_textconv: true,
                ..Default::default()
            },
        )
        .expect("rename-aware revision to worktree textconv diff");
    assert_eq!(converted.path, "new.txt");
    assert!(converted
        .hunks
        .iter()
        .any(|hunk| hunk.new_lines.iter().any(|line| line.text == "TWO")));
    assert!(r
        .git(&["diff", "--cached", "--name-status"])
        .contains("old.txt\tnew.txt"));
}

#[test]
fn apply_selected_commit_changes_is_patch_based_and_reversible() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "f.txt", "before\n", "base");
    let changed = common::commit(&r.path, "f.txt", "after\n", "change");
    r.git(&["reset", "--hard", &base]);
    r.write("unrelated.txt", "local only\n");
    let repo = r.open();

    repo.apply_selected_commit_changes(changed.clone(), None, vec!["f.txt".into()], false)
        .expect("apply selected changes");
    assert_eq!(r.read("f.txt"), "after\n");
    assert_eq!(r.read("unrelated.txt"), "local only\n");
    assert!(
        r.git(&["diff", "--cached", "--name-only"]).is_empty(),
        "applying selected changes must not stage the file"
    );

    repo.apply_selected_commit_changes(changed, None, vec!["f.txt".into()], true)
        .expect("reverse selected changes");
    assert_eq!(r.read("f.txt"), "before\n");
    assert_eq!(r.read("unrelated.txt"), "local only\n");
    assert!(r.git(&["diff", "--cached", "--name-only"]).is_empty());
}

#[test]
fn apply_selected_commit_changes_conflict_is_restart_safe_and_completable() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "f.txt", "base\n", "base");
    let changed = common::commit(&r.path, "f.txt", "patch\n", "change");
    r.git(&["reset", "--hard", &base]);
    r.write("f.txt", "local\n");
    let repo = r.open();
    let name = format!("Log Apply {changed}");

    let error = repo
        .apply_selected_commit_changes(changed, None, vec!["f.txt".into()], false)
        .expect_err("overlapping local content must enter the conflict workbench");
    assert!(
        matches!(error, EngineError::ShelveApplyConflict { .. }),
        "unexpected apply error: {error:?}"
    );
    let restore = repo
        .shelve_restore_info()
        .expect("restore info")
        .expect("direct patch restore snapshot");
    assert_eq!(restore.name, name);
    assert!(restore.is_direct_patch);
    assert!(repo
        .conflict_workspace()
        .unwrap()
        .files
        .iter()
        .any(|file| file.path == "f.txt"));

    repo.accept_conflict("f.txt".into(), FilePick::Ours)
        .expect("accept local side");
    repo.apply_imported_patch_complete_restore(name)
        .expect("complete direct patch restore");
    assert_eq!(r.read("f.txt"), "local\n");
    assert!(repo.shelve_restore_info().unwrap().is_none());
}

#[test]
fn rename_and_binary_commit_diffs() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "same content\n", "init");
    r.git(&["mv", "old.txt", "new.txt"]);
    r.git(&["commit", "-q", "-m", "rename"]);
    let rename_id = r.git(&["rev-parse", "HEAD"]);
    std::fs::write(r.path.join("img.png"), b"\x00BIN\x00").unwrap();
    r.git(&["add", "img.png"]);
    r.git(&["commit", "-q", "-m", "add binary"]);
    let binary_id = r.git(&["rev-parse", "HEAD"]);
    r.write(
        "edited-old.txt",
        "line one\nline two\nline three\nline four\nline five\n",
    );
    r.git(&["add", "edited-old.txt"]);
    r.git(&["commit", "-q", "-m", "add editable rename source"]);
    r.git(&["mv", "edited-old.txt", "edited-new.txt"]);
    r.write(
        "edited-new.txt",
        "line one changed\nline two\nline three\nline four\nline five\n",
    );
    r.git(&["add", "edited-new.txt"]);
    r.git(&["commit", "-q", "-m", "rename with content change"]);
    let edited_rename_id = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    // rename:tree 层 Renamed
    let rename_diff = repo
        .commit_diff(rename_id.clone(), None)
        .expect("rename diff");
    assert!(
        rename_diff.changes.iter().any(|c| c.path == "new.txt"),
        "{:?}",
        rename_diff.changes
    );
    let rename = rename_diff
        .changes
        .iter()
        .find(|change| change.path == "new.txt")
        .expect("rename change");
    assert_eq!(rename.old_path.as_deref(), Some("old.txt"));
    assert!(rename.is_pure_move);
    // binary 文件出现在变更列表
    let binary_diff = repo.commit_diff(binary_id, None).expect("binary diff");
    assert!(binary_diff.changes.iter().any(|c| c.path == "img.png"));
    let edited_rename = repo
        .commit_diff(edited_rename_id, None)
        .expect("edited rename diff")
        .changes
        .into_iter()
        .find(|change| change.path == "edited-new.txt")
        .expect("edited rename change");
    assert_eq!(edited_rename.old_path.as_deref(), Some("edited-old.txt"));
    assert!(!edited_rename.is_pure_move);
}

#[test]
fn submodule_commit_diff_shows_old_and_new_gitlink_ids() {
    let submodule = TestRepo::new();
    let first_submodule_commit = common::commit(&submodule.path, "lib.txt", "v1\n", "sub v1");

    let outer = TestRepo::new();
    common::commit(&outer.path, "root.txt", "root\n", "outer base");
    let first_cacheinfo = format!("160000,{first_submodule_commit},vendor/lib");
    outer.git(&[
        "update-index",
        "--add",
        "--cacheinfo",
        first_cacheinfo.as_str(),
    ]);
    outer.git(&["commit", "-q", "-m", "add submodule"]);

    let second_submodule_commit = common::commit(&submodule.path, "lib.txt", "v2\n", "sub v2");
    let second_cacheinfo = format!("160000,{second_submodule_commit},vendor/lib");
    outer.git(&[
        "update-index",
        "--add",
        "--cacheinfo",
        second_cacheinfo.as_str(),
    ]);
    outer.git(&["commit", "-q", "-m", "update submodule"]);
    let target = outer.git(&["rev-parse", "HEAD"]);

    let diff = outer
        .open()
        .commit_file_diff(target, None, "vendor/lib".into(), false)
        .expect("submodule diff");
    let old_text = diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.old_lines.iter())
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>();
    let new_text = diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.new_lines.iter())
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>();
    assert!(old_text
        .iter()
        .any(|line| line.contains(&first_submodule_commit)));
    assert!(new_text
        .iter()
        .any(|line| line.contains(&second_submodule_commit)));
}

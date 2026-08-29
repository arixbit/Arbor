//! HISTORY-001：commit diff（root/merge parent 选择）、CommitInfo 扩展、
//! 签名状态、file history（--follow）、大仓库分页一致性。

mod common;

use arbor_engine::{SignatureStatus, TreeChangeKind};
use common::TestRepo;

#[test]
fn root_commit_diff_lists_all_files() {
    let r = TestRepo::new();
    // 第一个提交即 root(TestRepo 无初始提交)
    common::commit(&r.path, "a.txt", "a\n", "first");
    common::commit(&r.path, "b.txt", "b\n", "second");
    let root = r.git(&["rev-list", "--max-parents=0", "HEAD"]);
    let second = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let diff = repo.commit_diff(root.clone(), None).expect("root diff");
    assert!(diff.is_root, "root commit 标记");
    assert_eq!(diff.parent_count, 0);
    assert!(diff.parent_id.is_none());
    // root 与空 tree 比较:完整文件列表
    assert_eq!(diff.changes.len(), 1, "root 只有 a.txt: {:?}", diff.changes);
    assert_eq!(diff.changes[0].path, "a.txt");
    assert_eq!(diff.changes[0].kind, TreeChangeKind::Added);

    let file_diff = repo
        .commit_file_diff(root.clone(), None, "a.txt".into(), false)
        .expect("root file diff");
    assert!(!file_diff.binary);
    assert!(file_diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.new_lines.iter())
        .any(|line| line.text == "a"));

    // 普通提交与第一父比较
    let diff2 = repo.commit_diff(second.clone(), None).expect("second diff");
    assert!(!diff2.is_root);
    assert_eq!(diff2.parent_id.as_deref(), Some(root.as_str()));
    assert_eq!(diff2.changes.len(), 1);
    assert_eq!(diff2.changes[0].path, "b.txt");
    assert_eq!(diff2.changes[0].kind, TreeChangeKind::Added);
}

#[test]
fn merge_commit_parent_selection() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "b\n", "base");
    r.git(&["branch", "feature"]);
    r.write("main.txt", "m\n");
    r.git(&["add", "main.txt"]);
    r.git(&["commit", "-q", "-m", "main side"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("feat.txt", "f\n");
    r.git(&["add", "feat.txt"]);
    r.git(&["commit", "-q", "-m", "feature side"]);
    r.git(&["checkout", "-q", "main"]);
    common::git_allow_failure(
        &r.path,
        &["merge", "-q", "--no-ff", "feature", "-m", "merge feature"],
    );
    let merge = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let diff = repo.commit_diff(merge.clone(), None).expect("merge diff");
    assert_eq!(diff.parent_count, 2, "merge commit 双父");
    assert!(!diff.is_root);
    // 与第一父比较:merge 树相对 main 侧多出的正是 feature 侧文件
    assert_eq!(diff.changes.len(), 1, "与第一父比较: {:?}", diff.changes);
    assert_eq!(diff.changes[0].path, "feat.txt");

    // 与第二父比较:相对 feature 侧多出 main 侧文件
    let diff2 = repo
        .commit_diff(merge.clone(), Some(1))
        .expect("merge diff parent 1");
    assert_eq!(diff2.changes.len(), 1, "与第二父比较: {:?}", diff2.changes);
    assert_eq!(diff2.changes[0].path, "main.txt");

    // 越界 parent 回落第一父
    let diff3 = repo.commit_diff(merge, Some(9)).expect("merge diff oob");
    assert_eq!(diff3.changes[0].path, "feat.txt");
}

#[test]
fn commit_info_includes_body_committer_and_signature_flag() {
    let r = TestRepo::new();
    r.git(&["config", "user.name", "Committer Person"]);
    r.git(&["config", "user.email", "committer@example.com"]);
    common::commit(
        &r.path,
        "f.txt",
        "1\n",
        "title line\n\nbody paragraph\nsecond body line",
    );

    let repo = r.open();
    let log = repo.log(None, 5, false, None).expect("log");
    let entry = &log[0];
    assert_eq!(entry.summary, "title line");
    assert_eq!(entry.message_body, "body paragraph\nsecond body line");
    assert_eq!(entry.committer_name, "Committer Person");
    assert_eq!(entry.committer_email, "committer@example.com");
    let expected_path = r.path.to_string_lossy().into_owned();
    assert_eq!(
        entry.repository_path.as_deref(),
        Some(expected_path.as_str())
    );
    assert!(!entry.has_signature, "未签名提交");
}

#[test]
fn commit_info_loads_requested_revision_directly() {
    let r = TestRepo::new();
    common::commit(&r.path, "first.txt", "1\n", "first title");
    let first = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "second.txt", "2\n", "second title");

    let repo = r.open();
    let info = repo.commit_info(first.clone()).expect("direct commit info");
    assert_eq!(info.id, first);
    assert_eq!(info.summary, "first title");
    assert_eq!(info.parent_ids.len(), 0);
    assert!(!info.is_head, "older requested revision is not HEAD");
}

#[test]
fn signature_status_none_and_unknown() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "1\n", "signed?");

    let repo = r.open();
    let id = r.git(&["rev-parse", "HEAD"]);
    let status = repo.commit_signature_status(id).expect("status");
    assert_eq!(status, SignatureStatus::None, "无签名 -> None");
}

#[test]
fn signature_statuses_batch_preserves_requested_order_and_metadata_shape() {
    let r = TestRepo::new();
    common::commit(&r.path, "first.txt", "1\n", "first");
    let first = r.git(&["rev-parse", "HEAD"]);
    common::commit(&r.path, "second.txt", "2\n", "second");
    let second = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let statuses = repo
        .commit_signature_statuses(vec![second.clone(), first.clone()])
        .expect("batch signature statuses");
    assert_eq!(statuses.len(), 2);
    assert_eq!(statuses[0].commit_id, second);
    assert_eq!(statuses[1].commit_id, first);
    assert_eq!(statuses[0].status, SignatureStatus::None);
    assert!(statuses[0].signer.is_empty());
    assert!(statuses[0].fingerprint.is_empty());
    assert!(statuses[0].reason.is_empty());
}

#[test]
fn file_history_follows_renames() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "1\n2\n", "init");
    r.git(&["mv", "old.txt", "new.txt"]);
    r.git(&["commit", "-q", "-m", "rename"]);
    r.write("new.txt", "1\n2\n3\n");
    r.git(&["add", "new.txt"]);
    r.git(&["commit", "-q", "-m", "edit after rename"]);

    let repo = r.open();
    // follow=true:rename 前的新路径历史也纳入
    let followed = repo
        .log(Some("new.txt".into()), 10, true, None)
        .expect("follow");
    let subjects: Vec<&str> = followed.iter().map(|c| c.summary.as_str()).collect();
    assert_eq!(
        subjects,
        vec!["edit after rename", "rename", "init"],
        "follow 跨越 rename: {subjects:?}"
    );

    // follow=false:rename 提交里 new.txt 是新增路径,同样匹配(git log 语义)
    let plain = repo
        .log(Some("new.txt".into()), 10, false, None)
        .expect("plain");
    let subjects: Vec<&str> = plain.iter().map(|c| c.summary.as_str()).collect();
    assert_eq!(
        subjects,
        vec!["edit after rename", "rename"],
        "不 follow: {subjects:?}"
    );
}

#[test]
fn file_history_follows_renames_with_content_edits() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "one\ntwo\n", "init");
    r.git(&["mv", "old.txt", "new.txt"]);
    r.write("new.txt", "one\ntwo\nthree\n");
    r.git(&["add", "new.txt"]);
    r.git(&["commit", "-q", "-m", "rename and edit"]);
    common::commit(
        &r.path,
        "new.txt",
        "one\ntwo\nthree\nfour\n",
        "edit after rename",
    );

    let subjects: Vec<String> = r
        .open()
        .log(Some("new.txt".into()), 10, true, None)
        .expect("follow edited rename")
        .into_iter()
        .map(|commit| commit.summary)
        .collect();
    assert_eq!(
        subjects,
        vec!["edit after rename", "rename and edit", "init"],
        "edited rename must not truncate file history: {subjects:?}"
    );
}

#[test]
fn file_history_follows_renames_across_merge_parents() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "one\ntwo\n", "init");
    r.git(&["switch", "-q", "-c", "feature"]);
    r.git(&["mv", "old.txt", "new.txt"]);
    r.write("new.txt", "one\ntwo\nfeature\n");
    r.git(&["add", "new.txt"]);
    r.git(&["commit", "-q", "-m", "rename and edit"]);
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main\n", "main side change");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge feature"]);

    let subjects: Vec<String> = r
        .open()
        .log(Some("new.txt".into()), 10, true, None)
        .expect("follow merge rename")
        .into_iter()
        .map(|commit| commit.summary)
        .collect();
    assert_eq!(
        subjects,
        vec!["merge feature", "rename and edit", "init"],
        "merge parent rename paths must converge on the original file: {subjects:?}"
    );
}

#[test]
fn followed_file_history_pagination_replays_rename_state_before_cursor() {
    let r = TestRepo::new();
    common::commit(&r.path, "old.txt", "one\ntwo\n", "init");
    r.git(&["mv", "old.txt", "new.txt"]);
    r.write("new.txt", "one\ntwo\nthree\n");
    r.git(&["add", "new.txt"]);
    r.git(&["commit", "-q", "-m", "rename and edit"]);
    common::commit(&r.path, "new.txt", "one\ntwo\nthree\nfour\n", "tip");

    let repo = r.open();
    let first_page = repo
        .log(Some("new.txt".into()), 1, true, None)
        .expect("first followed page");
    let second_page = repo
        .log(
            Some("new.txt".into()),
            10,
            true,
            Some(first_page[0].id.clone()),
        )
        .expect("second followed page");
    let subjects: Vec<&str> = second_page
        .iter()
        .map(|commit| commit.summary.as_str())
        .collect();
    assert_eq!(
        subjects,
        vec!["rename and edit", "init"],
        "pagination must retain the pre-cursor rename path: {subjects:?}"
    );
}

#[test]
fn pagination_is_consistent_across_pages() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "0\n", "base");
    for i in 0..6 {
        r.write(&format!("f{i}.txt"), &format!("{i}\n"));
        r.git(&["add", "."]);
        r.git(&["commit", "-q", "-m", &format!("commit {i}")]);
    }

    let repo = r.open();
    // 第一页 3 条,after_id 翻页,两页拼接 == 全量
    let page1 = repo.log(None, 3, false, None).expect("p1");
    assert_eq!(page1.len(), 3);
    let page2 = repo
        .log(None, 3, false, Some(page1.last().unwrap().id.clone()))
        .expect("p2");
    assert_eq!(page2.len(), 3);
    let all = repo.log(None, 10, false, None).expect("all");
    assert_eq!(all.len(), 7);
    // 无重叠、顺序一致、首尾相接(分页语义:after_id 页从下一提交开始)
    let mut joined: Vec<String> = page1.iter().map(|c| c.id.clone()).collect();
    joined.extend(page2.iter().map(|c| c.id.clone()));
    let all_ids: Vec<String> = all.iter().map(|c| c.id.clone()).collect();
    assert_eq!(joined, all_ids[..6], "两页拼接 == 全量前 6 条,顺序一致");
    // 翻页续接:第三页从 page2 末尾继续,拿到最后一条
    let page3 = repo
        .log(None, 10, false, Some(page2.last().unwrap().id.clone()))
        .expect("p3");
    assert_eq!(page3.len(), 1);
    assert_eq!(page3[0].id, all_ids[6]);
}

#[test]
fn binary_file_in_commit_diff() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x\n", "init");
    std::fs::write(r.path.join("img.png"), b"\x00\x01BIN\x00").unwrap();
    r.git(&["add", "img.png"]);
    r.git(&["commit", "-q", "-m", "add binary"]);
    let id = r.git(&["rev-parse", "HEAD"]);

    let repo = r.open();
    let diff = repo.commit_diff(id, None).expect("diff");
    assert!(
        diff.changes.iter().any(|c| c.path == "img.png"),
        "{:?}",
        diff.changes
    );
}

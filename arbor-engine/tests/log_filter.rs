//! v0.4 日志过滤。

mod common;

use std::io::Write;
use std::process::{Command, Stdio};

use arbor_engine::LogGraphSortMode;
use common::TestRepo;

fn import_linear_history(repo: &TestRepo, count: usize) {
    let mut stream = String::new();
    for index in 1..=count {
        let timestamp = 1_000_000 + index as i64;
        let message = format!("commit {index}");
        stream.push_str(&format!(
            "commit refs/heads/main\nmark :{index}\nauthor Arbor Test <test@arbor.local> {timestamp} +0000\ncommitter Arbor Test <test@arbor.local> {timestamp} +0000\ndata {}\n{}\n",
            message.len(), message
        ));
        if index == 1 {
            stream.push_str("M 100644 inline file.txt\ndata 4\nbase\n");
        } else {
            stream.push_str(&format!("from :{}\n", index - 1));
        }
    }
    stream.push_str("done\n");

    let mut child = Command::new("git")
        .arg("fast-import")
        .current_dir(&repo.path)
        .stdin(Stdio::piped())
        .spawn()
        .expect("start fast-import");
    child
        .stdin
        .take()
        .expect("fast-import stdin")
        .write_all(stream.as_bytes())
        .expect("write fast-import stream");
    let status = child.wait().expect("wait for fast-import");
    assert!(status.success(), "fast-import failed: {status}");
}

#[test]
fn filters_by_author_since_and_start_revision() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    common::commit(&r.path, "one.txt", "one", "one");
    let tip = common::commit(&r.path, "tip.txt", "tip", "tip");
    let repo = r.open();

    let by_author = repo
        .log_filtered(None, 50, false, None, Some("arbor test".into()), None)
        .unwrap();
    assert_eq!(by_author.len(), 3);
    let no_author = repo
        .log_filtered(None, 50, false, None, Some("nobody".into()), None)
        .unwrap();
    assert!(no_author.is_empty());

    let tip_time = repo.log(None, 1, false, None).unwrap()[0].time;
    let too_new = repo
        .log_filtered(None, 50, false, None, None, Some(tip_time + 1))
        .unwrap();
    assert!(too_new.is_empty());

    let from_tip = repo
        .log_filtered(None, 50, false, Some(tip.clone()), None, None)
        .unwrap();
    assert_eq!(from_tip.last().unwrap().id, base);
    assert!(from_tip.iter().any(|c| c.id == tip));
}

#[test]
fn tree_changes_reports_full_revision_difference() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "a.txt", "a", "base");
    common::commit(&r.path, "a.txt", "a2", "modify");
    let tip = common::commit(&r.path, "b.txt", "b", "add");
    let changes = r.open().tree_changes(base, tip).unwrap();
    assert_eq!(changes.len(), 2);
    assert!(changes.iter().any(|c| c.path == "a.txt"));
    assert!(changes.iter().any(|c| c.path == "b.txt"));
}

#[test]
fn filters_by_full_commit_message_body_case_insensitively() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&[
        "commit",
        "--allow-empty",
        "-m",
        "Release candidate\n\nShip this safely",
    ]);
    common::commit(&r.path, "tip.txt", "tip", "unrelated");

    let matches = r
        .open()
        .log_filtered_with_message(None, 50, false, None, None, None, Some("ship this".into()))
        .unwrap();
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].summary, "Release candidate");
}

#[test]
fn text_filter_supports_regex_and_match_case_options() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["commit", "--allow-empty", "-m", "Release Candidate"]);
    r.git(&["commit", "--allow-empty", "-m", "release stable"]);
    let repo = r.open();

    let regex_matches = repo
        .log_filtered_with_message_and_options(
            None,
            50,
            false,
            None,
            None,
            None,
            Some(r"release\s+(candidate|stable)".into()),
            true,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("regex filter");
    assert_eq!(regex_matches.len(), 2);

    let case_sensitive_matches = repo
        .log_filtered_with_message_and_options(
            None,
            50,
            false,
            None,
            None,
            None,
            Some("Release".into()),
            false,
            true,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("case-sensitive filter");
    assert_eq!(case_sensitive_matches.len(), 1);
    assert_eq!(case_sensitive_matches[0].summary, "Release Candidate");

    let error = repo
        .log_filtered_with_message_and_options(
            None,
            50,
            false,
            None,
            None,
            None,
            Some("[unterminated".into()),
            true,
            true,
            LogGraphSortMode::ByCommitDate,
        )
        .expect_err("invalid regex must be rejected");
    assert!(error.to_string().contains("invalid log text filter regex"));

    let date_filter_error = repo
        .log_filtered_with_message_and_date_options(
            None,
            50,
            false,
            None,
            None,
            None,
            None,
            Some("[unterminated".into()),
            true,
            true,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect_err("permanent graph regex must be rejected");
    assert!(date_filter_error
        .to_string()
        .contains("invalid log text filter regex"));
}

#[test]
fn filtered_log_keeps_lanes_from_hidden_graph_context() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);

    let repo = r.open();
    let full = repo.log(None, 50, false, None).expect("full graph");
    let filtered = repo
        .log_filtered_with_message_and_options(
            None,
            50,
            false,
            None,
            None,
            None,
            Some("^(merge|feature|base)".into()),
            true,
            true,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("filtered graph");

    assert_eq!(
        filtered
            .iter()
            .map(|commit| commit.summary.as_str())
            .collect::<Vec<_>>(),
        vec!["merge", "feature", "base"]
    );
    for commit in &filtered {
        let expected = full
            .iter()
            .find(|candidate| candidate.id == commit.id)
            .expect("filtered commit exists in the full graph");
        assert_eq!(
            commit.lane, expected.lane,
            "lane changed at {}",
            commit.summary
        );
        assert_eq!(
            commit.parent_lanes, expected.parent_lanes,
            "parent lanes changed at {}",
            commit.summary
        );
    }

    let first_page = repo
        .log_filtered_with_message_and_options(
            None,
            2,
            false,
            None,
            None,
            None,
            Some("^(merge|feature|base)".into()),
            true,
            true,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("filtered first page");
    let continuation = repo
        .log_filtered_with_message_and_date_options_for_revisions_with_after_id(
            None,
            50,
            false,
            Vec::new(),
            None,
            None,
            None,
            Some("^(merge|feature|base)".into()),
            true,
            true,
            false,
            LogGraphSortMode::ByCommitDate,
            first_page.last().map(|commit| commit.id.clone()),
        )
        .expect("filtered continuation");
    assert_eq!(
        continuation
            .iter()
            .map(|commit| commit.summary.as_str())
            .collect::<Vec<_>>(),
        vec!["base"]
    );
    let expected_base = full
        .iter()
        .find(|commit| commit.summary == "base")
        .expect("base exists in the full graph");
    assert_eq!(continuation[0].lane, expected_base.lane);
    assert_eq!(continuation[0].parent_lanes, expected_base.parent_lanes);
}

#[test]
fn date_upper_bound_and_no_merges_match_vcs_log_filters() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);

    let repo = r.open();
    let all = repo.log(None, 50, false, None).expect("full log");
    let merge = all
        .iter()
        .find(|commit| commit.summary == "merge")
        .expect("merge commit");

    let before_merge = repo
        .log_filtered_with_message_and_date_options(
            None,
            50,
            false,
            None,
            None,
            None,
            Some(merge.time),
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("until filter");
    assert!(before_merge.iter().all(|commit| commit.time < merge.time));
    assert!(!before_merge.iter().any(|commit| commit.id == merge.id));

    let without_merges = repo
        .log_filtered_with_message_and_date_options(
            None,
            50,
            false,
            None,
            None,
            None,
            None,
            None,
            false,
            false,
            true,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("no merges filter");
    assert!(without_merges
        .iter()
        .all(|commit| commit.parent_ids.len() <= 1));
    assert!(!without_merges.iter().any(|commit| commit.id == merge.id));
}

#[test]
fn multiple_branch_heads_filter_to_their_reachable_history_union() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature only");
    r.git(&["switch", "-q", "main"]);
    let main = common::commit(&r.path, "main.txt", "main", "main only");
    r.git(&["switch", "-q", "-c", "other"]);
    let other = common::commit(&r.path, "other.txt", "other", "other only");

    let selected = r
        .open()
        .log_filtered_with_message_and_date_options_for_revisions(
            None,
            50,
            false,
            vec!["main".into(), "feature".into()],
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("multi-head log");

    let selected_ids: Vec<_> = selected.iter().map(|commit| commit.id.as_str()).collect();
    assert!(selected_ids.contains(&main.as_str()));
    assert!(selected_ids.contains(&feature.as_str()));
    assert!(!selected_ids.contains(&other.as_str()));
}

#[test]
fn selected_branch_rebuilds_visible_lanes_without_an_unselected_sibling() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature only");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main only");

    let repo = r.open();
    for sort_mode in [
        LogGraphSortMode::ByCommitDate,
        LogGraphSortMode::Topologically,
        LogGraphSortMode::LinearizeMerges,
    ] {
        let selected = repo
            .log_filtered_with_message_and_date_options_for_revisions(
                None,
                50,
                false,
                vec!["feature".into()],
                None,
                None,
                None,
                None,
                false,
                false,
                false,
                sort_mode,
            )
            .expect("selected branch log");

        assert_eq!(
            selected
                .iter()
                .map(|commit| commit.summary.as_str())
                .collect::<Vec<_>>(),
            vec!["feature only", "base"]
        );
        assert_eq!(selected[0].id, feature);
        assert_eq!(selected[0].lane, 0);
        assert_eq!(selected[0].parent_lanes, vec![0]);
        assert!(selected.iter().all(|commit| commit.lane == 0));
    }

    let first = repo
        .log_filtered_with_message_and_date_options_for_revisions(
            None,
            1,
            false,
            vec!["feature".into()],
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::Topologically,
        )
        .expect("selected branch first page");
    let continuation = repo
        .log_filtered_with_message_and_date_options_for_revisions_with_after_id(
            None,
            50,
            false,
            vec!["feature".into()],
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::Topologically,
            Some(first[0].id.clone()),
        )
        .expect("selected branch continuation");
    assert_eq!(
        continuation
            .iter()
            .map(|commit| commit.summary.as_str())
            .collect::<Vec<_>>(),
        vec!["base"]
    );
    assert_eq!(continuation[0].lane, 0);
    assert_eq!(continuation[0].parent_lanes, Vec::<u32>::new());
}

#[test]
fn first_parent_head_filter_excludes_the_merge_second_parent_line() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature only");
    r.git(&["switch", "-q", "main"]);
    let main = common::commit(&r.path, "main.txt", "main", "main only");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);

    let selected = r
        .open()
        .log_filtered_with_message_and_date_options_for_revisions(
            None,
            50,
            false,
            vec!["main".into()],
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::FirstParent,
        )
        .expect("first-parent head filter");

    let selected_ids: Vec<_> = selected.iter().map(|commit| commit.id.as_str()).collect();
    assert!(selected_ids.contains(&main.as_str()));
    assert!(selected.iter().any(|commit| commit.summary == "merge"));
    assert!(!selected_ids.contains(&feature.as_str()));
    assert!(selected.iter().all(|commit| commit.parent_ids.len() <= 2));
    let merge = selected
        .iter()
        .find(|commit| commit.summary == "merge")
        .expect("merge remains visible");
    assert_eq!(merge.parent_lanes.len(), 1);
}

#[test]
fn multiple_paths_filter_to_their_commit_union_in_engine_order() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let source = common::commit(&r.path, "Sources/App.swift", "source", "source");
    let docs = common::commit(&r.path, "Docs/README.md", "docs", "docs");
    let unrelated = common::commit(&r.path, "Other.txt", "other", "unrelated");

    let selected = r
        .open()
        .log_filtered_with_paths_with_message_and_date_options_for_revisions(
            vec!["Sources".into(), "Docs/README.md".into()],
            50,
            false,
            Vec::new(),
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("multi-path log");

    let selected_ids: Vec<_> = selected.iter().map(|commit| commit.id.as_str()).collect();
    assert!(selected_ids.contains(&source.as_str()));
    assert!(selected_ids.contains(&docs.as_str()));
    assert!(!selected_ids.contains(&unrelated.as_str()));
    assert!(selected
        .windows(2)
        .all(|window| window[0].time >= window[1].time));
}

#[test]
fn multiple_paths_log_cursor_continues_after_the_previous_visible_commit() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let source = common::commit(&r.path, "Sources/App.swift", "source", "source");
    let docs = common::commit(&r.path, "Docs/README.md", "docs", "docs");
    common::commit(&r.path, "Other.txt", "other", "unrelated");

    let repo = r.open();
    let all = repo
        .log_filtered_with_paths_with_message_and_date_options_for_revisions(
            vec!["Sources".into(), "Docs/README.md".into()],
            50,
            false,
            Vec::new(),
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("complete multi-path log");
    assert_eq!(
        all.iter().map(|commit| &commit.id).collect::<Vec<_>>(),
        vec![&docs, &source]
    );

    let first = repo
        .log_filtered_with_paths_with_message_and_date_options_for_revisions_with_after_id(
            vec!["Sources".into(), "Docs/README.md".into()],
            1,
            false,
            Vec::new(),
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
            None,
        )
        .expect("first multi-path page");
    let second = repo
        .log_filtered_with_paths_with_message_and_date_options_for_revisions_with_after_id(
            vec!["Sources".into(), "Docs/README.md".into()],
            50,
            false,
            Vec::new(),
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
            Some(first.last().expect("first page row").id.clone()),
        )
        .expect("second multi-path page");
    let paged_ids: Vec<_> = first
        .iter()
        .chain(second.iter())
        .map(|commit| commit.id.as_str())
        .collect();
    let all_ids: Vec<_> = all.iter().map(|commit| commit.id.as_str()).collect();
    assert_eq!(paged_ids, all_ids);
    assert!(paged_ids.contains(&docs.as_str()));
    assert!(paged_ids.contains(&source.as_str()));
}

#[test]
fn commit_children_resolves_all_direct_children_across_branches() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);

    let main_child = common::commit(&r.path, "main.txt", "main", "main child");
    r.git(&["switch", "-q", "feature"]);
    let feature_child = common::commit(&r.path, "feature.txt", "feature", "feature child");
    r.git(&["switch", "-q", "main"]);

    let children = r.open().commit_children(base).expect("direct children");
    let child_ids: std::collections::HashSet<_> =
        children.iter().map(|commit| commit.id.as_str()).collect();
    assert_eq!(children.len(), 2);
    assert!(child_ids.contains(main_child.as_str()));
    assert!(child_ids.contains(feature_child.as_str()));
}

#[test]
fn revision_range_filter_excludes_the_left_end() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    let middle = common::commit(&r.path, "middle.txt", "middle", "middle");
    let tip = common::commit(&r.path, "tip.txt", "tip", "tip");

    let selected = r
        .open()
        .log_filtered_with_message_and_date_options_for_revisions(
            None,
            50,
            false,
            vec![format!("{base}..{tip}")],
            None,
            None,
            None,
            None,
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("revision range log");

    let selected_ids: Vec<_> = selected.iter().map(|commit| commit.id.as_str()).collect();
    assert!(selected_ids.contains(&tip.as_str()));
    assert!(selected_ids.contains(&middle.as_str()));
    assert!(!selected_ids.contains(&base.as_str()));
}

#[test]
fn filtered_log_cursor_and_limit_are_not_capped_at_500_commits() {
    let r = TestRepo::new();
    import_linear_history(&r, 620);
    let repo = r.open();

    let all = repo
        .log_filtered_with_message_and_date_options_for_revisions(
            None,
            700,
            false,
            vec!["main".into()],
            None,
            None,
            None,
            Some("commit".into()),
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
        )
        .expect("unbounded filtered log");
    assert_eq!(all.len(), 620);

    let cursor = all[499].id.clone();
    let page = repo
        .log_filtered_with_message_and_date_options_for_revisions_with_after_id(
            None,
            200,
            false,
            vec!["main".into()],
            None,
            None,
            None,
            Some("commit".into()),
            false,
            false,
            false,
            LogGraphSortMode::ByCommitDate,
            Some(cursor),
        )
        .expect("cursor page");
    assert_eq!(page.len(), 120);
    assert_eq!(
        page.first().map(|commit| &commit.id),
        all.get(500).map(|commit| &commit.id)
    );
    assert!(page
        .iter()
        .all(|commit| !all[..=499].iter().any(|previous| previous.id == commit.id)));
}

#[test]
fn command_log_filter_uses_git_revision_and_path_semantics() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature only");
    let tip = common::commit(&r.path, "base.txt", "tip", "tip");
    let repo = r.open();

    let by_message = repo
        .log_with_command(vec!["--grep=feature".into()], 50)
        .expect("command message filter");
    assert_eq!(
        by_message
            .iter()
            .map(|commit| &commit.id)
            .collect::<Vec<_>>(),
        vec![&feature]
    );

    let by_path = repo
        .log_with_command(vec!["--".into(), "feature.txt".into()], 50)
        .expect("command path filter");
    assert_eq!(
        by_path.iter().map(|commit| &commit.id).collect::<Vec<_>>(),
        vec![&feature]
    );

    let by_range = repo
        .log_with_command(vec![format!("{base}..{tip}")], 1)
        .expect("command range filter");
    assert_eq!(by_range.len(), 1);
    assert_eq!(by_range[0].id, tip);
}

#[test]
fn command_log_filter_can_find_file_revision_on_another_ref_with_follow() {
    let r = TestRepo::new();
    common::commit(&r.path, "tracked.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    std::fs::rename(r.path.join("tracked.txt"), r.path.join("moved.txt")).unwrap();
    r.git(&["add", "-A"]);
    r.git(&["commit", "-q", "-m", "rename on feature"]);
    let feature_tip = r.git(&["rev-parse", "HEAD"]);
    r.git(&["switch", "-q", "main"]);

    let revision = r
        .open()
        .log_with_command(
            vec![
                "--all".into(),
                "--follow".into(),
                "-n1".into(),
                "--".into(),
                "moved.txt".into(),
            ],
            1,
        )
        .expect("find latest file revision across refs")
        .pop()
        .expect("feature revision");

    assert_eq!(revision.id, feature_tip);
    assert_eq!(revision.summary, "rename on feature");
}

#[test]
fn command_log_filter_supports_oldest_commit_in_a_rewrite_range() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    let first_changed = common::commit(&r.path, "first.txt", "first", "first changed");
    let tip = common::commit(&r.path, "tip.txt", "tip", "tip changed");
    let repo = r.open();

    let oldest = repo
        .log_with_command(vec!["--reverse".into(), format!("{base}..{tip}")], 1)
        .expect("oldest rewrite-range commit");

    assert_eq!(
        oldest.first().map(|commit| commit.id.as_str()),
        Some(first_changed.as_str())
    );
}

#[test]
fn command_log_filter_returns_empty_for_unborn_head() {
    let repo = TestRepo::new().open();
    assert!(repo.log_with_command(Vec::new(), 50).unwrap().is_empty());
}

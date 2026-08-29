//! v0.4 图数据：父提交必须携带下一行所属 lane。

mod common;

use arbor_engine::LogGraphSortMode;
use common::TestRepo;

#[test]
fn merge_graph_has_parent_lanes() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);

    let commits = r.open().log(None, 50, false, None).unwrap();
    assert!(commits.len() >= 4);
    for commit in &commits {
        assert_eq!(
            commit.parent_ids.len(),
            commit.parent_lanes.len(),
            "{} must have one lane per parent",
            commit.summary
        );
    }
    let merge = &commits[0];
    assert_eq!(merge.summary, "merge");
    assert_eq!(merge.parent_ids.len(), 2);
    assert_eq!(merge.parent_lanes[0], merge.lane);
    assert_ne!(merge.parent_lanes[0], merge.parent_lanes[1]);

    for (parent, lane) in merge.parent_ids.iter().zip(&merge.parent_lanes) {
        let parent_node = commits
            .iter()
            .find(|c| &c.id == parent)
            .expect("parent node must be in full graph");
        assert_eq!(parent_node.lane, *lane);
    }
    assert!(commits.iter().any(|c| c.id == base));
    assert!(commits.iter().any(|c| c.id == feature));
}

#[test]
fn log_includes_unmerged_local_branch() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature only");
    r.git(&["switch", "-q", "main"]);
    let main = common::commit(&r.path, "main.txt", "main", "main only");

    let commits = r.open().log(None, 50, false, None).expect("repository log");
    assert!(commits.iter().any(|commit| commit.id == main));
    let feature_commit = commits
        .iter()
        .find(|commit| commit.id == feature)
        .expect("unmerged local branch commit must be visible");
    assert!(feature_commit
        .refs
        .iter()
        .any(|reference| reference == "feature"));
}

#[test]
fn log_includes_tag_only_and_remote_tracking_tips() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "tag-only"]);
    let tagged = common::commit(&r.path, "tag.txt", "tag", "tag only");
    r.git(&["tag", "v-tag-only"]);
    r.git(&["switch", "-q", "main"]);
    r.git(&["branch", "-D", "tag-only"]);
    let main = common::commit(&r.path, "main.txt", "main", "main");

    r.git(&["switch", "-q", "-c", "remote-only"]);
    let remote = common::commit(&r.path, "remote.txt", "remote", "remote only");
    r.git(&["switch", "-q", "main"]);
    r.git(&["branch", "-D", "remote-only"]);
    r.git(&["update-ref", "refs/remotes/origin/remote-only", &remote]);

    let commits = r.open().log(None, 50, false, None).expect("repository log");
    let tagged_commit = commits
        .iter()
        .find(|commit| commit.id == tagged)
        .expect("tag-only commit must be visible");
    assert!(tagged_commit.tag_refs.iter().any(|tag| tag == "v-tag-only"));
    let remote_commit = commits
        .iter()
        .find(|commit| commit.id == remote)
        .expect("remote-tracking commit must be visible");
    assert!(remote_commit
        .remote_refs
        .iter()
        .any(|reference| reference == "origin/remote-only"));
    assert!(commits.iter().any(|commit| commit.id == main));
}

#[test]
fn paged_log_preserves_graph_lanes() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);

    let repo = r.open();
    let all = repo.log(None, 50, false, None).expect("full graph");
    assert!(all.len() >= 4);
    let cursor = all[1].id.clone();
    let page = repo
        .log(None, 50, false, Some(cursor))
        .expect("continuation page");
    assert_eq!(
        page.iter().map(|commit| &commit.id).collect::<Vec<_>>(),
        all[2..].iter().map(|commit| &commit.id).collect::<Vec<_>>(),
        "page continuation must preserve order"
    );

    // The page is rendered after the first page has already established the
    // graph lanes, so its lane coordinates must match the full graph.
    for (expected, actual) in all[2..].iter().zip(&page) {
        assert_eq!(
            actual.lane, expected.lane,
            "lane changed at {}",
            actual.summary
        );
        assert_eq!(
            actual.parent_lanes, expected.parent_lanes,
            "parent lanes changed at {}",
            actual.summary
        );
    }
}

#[test]
fn permanent_graph_pages_match_full_graph_across_small_batches() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    for index in 1..=4 {
        common::commit(
            &r.path,
            &format!("file-{index}.txt"),
            &format!("content-{index}"),
            &format!("commit {index}"),
        );
    }

    let repo = r.open();
    let full = repo.log(None, 50, false, None).expect("full graph");
    let mut paged = Vec::new();
    let mut cursor = None;
    loop {
        let page = repo
            .log(None, 2, false, cursor.clone())
            .expect("graph page");
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|commit| commit.id.clone());
        paged.extend(page);
    }

    assert_eq!(
        paged.iter().map(|commit| &commit.id).collect::<Vec<_>>(),
        full.iter().map(|commit| &commit.id).collect::<Vec<_>>()
    );
    assert_eq!(
        paged.iter().map(|commit| commit.lane).collect::<Vec<_>>(),
        full.iter().map(|commit| commit.lane).collect::<Vec<_>>()
    );
}

#[test]
fn permanent_graph_refreshes_when_a_ref_moves_on_same_repository_handle() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    let repo = r.open();
    let initial = repo.log(None, 50, false, None).expect("initial graph");
    assert_eq!(initial.len(), 1);

    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);

    let refreshed = repo.log(None, 50, false, None).expect("refreshed graph");
    assert!(
        refreshed.iter().any(|commit| commit.id == feature),
        "a moved/new ref must invalidate the repository graph cache"
    );
}

#[test]
fn permanent_graph_reports_containing_local_and_remote_branches() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["branch", "feature"]);
    let main_tip = common::commit(&r.path, "main.txt", "main", "main tip");
    r.git(&["switch", "-q", "feature"]);
    let feature_tip = common::commit(&r.path, "feature.txt", "feature", "feature tip");
    r.git(&["switch", "-q", "main"]);
    r.git(&["update-ref", "refs/remotes/origin/feature", &feature_tip]);

    let repo = r.open();
    let base_branches = repo
        .commit_containing_branches(base.clone())
        .expect("base containing branches");
    assert!(base_branches.iter().any(|branch| branch == "main"));
    assert!(base_branches.iter().any(|branch| branch == "feature"));
    assert!(base_branches
        .iter()
        .any(|branch| branch == "origin/feature"));

    let feature_branches = repo
        .commit_containing_branches(feature_tip)
        .expect("feature containing branches");
    assert!(feature_branches.iter().any(|branch| branch == "feature"));
    assert!(feature_branches
        .iter()
        .any(|branch| branch == "origin/feature"));
    assert!(!feature_branches.iter().any(|branch| branch == "main"));

    let main_branches = repo
        .commit_containing_branches(main_tip)
        .expect("main containing branches");
    assert_eq!(main_branches, vec!["main"]);
}

#[test]
fn graph_sort_modes_preserve_topology_and_linearize_incoming_lane() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);

    let topo = r
        .open()
        .log_with_sort(None, 50, false, None, LogGraphSortMode::Topologically)
        .expect("topological log");
    assert_eq!(topo[0].summary, "merge");
    assert_eq!(
        topo.iter()
            .map(|commit| commit.summary.as_str())
            .collect::<Vec<_>>(),
        vec!["merge", "feature", "main", "base"]
    );
    assert_all_parents_follow_children(&topo);
    let topo_page = r
        .open()
        .log_with_sort(
            None,
            50,
            false,
            Some(topo[1].id.clone()),
            LogGraphSortMode::Topologically,
        )
        .expect("topological continuation page");
    assert_eq!(
        topo_page
            .iter()
            .map(|commit| &commit.id)
            .collect::<Vec<_>>(),
        topo[2..]
            .iter()
            .map(|commit| &commit.id)
            .collect::<Vec<_>>()
    );
    for (expected, actual) in topo[2..].iter().zip(&topo_page) {
        assert_eq!(actual.lane, expected.lane);
        assert_eq!(actual.parent_lanes, expected.parent_lanes);
    }

    let linearized = r
        .open()
        .log_with_sort(None, 50, false, None, LogGraphSortMode::LinearizeMerges)
        .expect("linearized log");
    assert_eq!(linearized[0].summary, "merge");
    assert_all_parents_follow_children(&linearized);
    let merge = &linearized[0];
    assert_eq!(merge.parent_lanes[1], merge.lane);
    assert_ne!(merge.parent_lanes[0], merge.lane);

    let first_parent = r
        .open()
        .log_with_sort(None, 50, false, None, LogGraphSortMode::FirstParent)
        .expect("first-parent log");
    assert_eq!(first_parent[0].summary, "merge");
    assert_eq!(first_parent[0].parent_ids.len(), 2);
    assert_eq!(first_parent[0].parent_lanes, vec![first_parent[0].lane]);
    assert!(first_parent
        .iter()
        .all(|commit| commit.parent_lanes.len() <= 1));
    let first_parent_page = r
        .open()
        .log_with_sort(
            None,
            50,
            false,
            Some(first_parent[1].id.clone()),
            LogGraphSortMode::FirstParent,
        )
        .expect("first-parent continuation page");
    assert_eq!(
        first_parent_page
            .iter()
            .map(|commit| &commit.id)
            .collect::<Vec<_>>(),
        first_parent[2..]
            .iter()
            .map(|commit| &commit.id)
            .collect::<Vec<_>>()
    );
    for (expected, actual) in first_parent[2..].iter().zip(&first_parent_page) {
        assert_eq!(actual.lane, expected.lane);
        assert_eq!(actual.parent_lanes, expected.parent_lanes);
    }
}

fn assert_all_parents_follow_children(commits: &[arbor_engine::CommitInfo]) {
    for (index, commit) in commits.iter().enumerate() {
        for parent in &commit.parent_ids {
            let parent_index = commits
                .iter()
                .position(|candidate| &candidate.id == parent)
                .expect("parent is present in the graph");
            assert!(
                parent_index > index,
                "{} appears before its parent",
                commit.summary
            );
        }
    }
}

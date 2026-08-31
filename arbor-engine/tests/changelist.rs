//! IntelliJ local Changelist 归属与生命周期回归。

mod common;

use common::TestRepo;

#[test]
fn changelists_persist_members_without_touching_git_state() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    common::commit(&r.path, "b.txt", "b1\n", "add b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let repo = r.open();

    let before_a = r.read("a.txt");
    let before_b = r.read("b.txt");
    let initial = repo.changelist_list().expect("default list");
    assert_eq!(initial.len(), 1);
    assert!(initial[0].is_default);
    assert_eq!(initial[0].paths, vec!["a.txt", "b.txt"]);

    repo.changelist_create("UI".into()).expect("create list");
    repo.changelist_move_paths(vec!["b.txt".into()], "UI".into())
        .expect("move member");

    assert_eq!(r.read("a.txt"), before_a);
    assert_eq!(r.read("b.txt"), before_b);
    let lists = repo.changelist_list().expect("list members");
    assert_eq!(lists[0].name, "Default");
    assert_eq!(lists[0].paths, vec!["a.txt"]);
    assert_eq!(lists[1].name, "UI");
    assert_eq!(lists[1].paths, vec!["b.txt"]);

    // The file is metadata only and must survive a new Repository handle.
    let reopened = r.open();
    assert_eq!(reopened.changelist_list().unwrap(), lists);
}

#[test]
fn changelist_rename_activate_and_delete_preserve_order_and_reassign_members() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    common::commit(&r.path, "b.txt", "b1\n", "add b");
    common::commit(&r.path, "c.txt", "c1\n", "add c");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    r.write("c.txt", "c2\n");
    let repo = r.open();

    repo.changelist_create("Review".into()).unwrap();
    repo.changelist_create("Release".into()).unwrap();
    repo.changelist_move_paths(vec!["c.txt".into(), "a.txt".into()], "Review".into())
        .unwrap();
    repo.changelist_move_paths(vec!["b.txt".into()], "Release".into())
        .unwrap();
    repo.changelist_activate("Review".into()).unwrap();
    repo.changelist_rename("Review".into(), "UI Review".into())
        .unwrap();

    let lists = repo.changelist_list().unwrap();
    assert_eq!(lists[0].paths, Vec::<String>::new());
    assert_eq!(lists[1].name, "UI Review");
    assert_eq!(lists[1].paths, vec!["c.txt", "a.txt"]);
    assert!(lists[1].is_active);
    assert_eq!(lists[2].paths, vec!["b.txt"]);

    // Deleting a non-default list is non-destructive: its files return to
    // Default and the remaining list order is stable.
    repo.changelist_delete("UI Review".into()).unwrap();
    let after_delete = repo.changelist_list().unwrap();
    assert_eq!(after_delete.len(), 2);
    assert_eq!(after_delete[0].name, "Default");
    assert_eq!(after_delete[0].paths, vec!["c.txt", "a.txt"]);
    assert_eq!(after_delete[1].name, "Release");
    assert_eq!(after_delete[1].paths, vec!["b.txt"]);
    assert!(after_delete[0].is_active);
}

#[test]
fn changelist_rejects_duplicate_names_default_delete_and_clean_paths() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    let repo = r.open();
    repo.changelist_create("UI".into()).unwrap();
    assert!(repo.changelist_create("UI".into()).is_err());
    assert!(repo.changelist_delete("Default".into()).is_err());
    assert!(repo
        .changelist_move_paths(vec!["a.txt".into()], "UI".into())
        .is_err());
}

#[test]
fn changelist_ensure_is_idempotent_and_preserves_active_list() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    r.write("a.txt", "a2\n");
    let repo = r.open();

    repo.changelist_create("Active UI".into()).unwrap();
    repo.changelist_activate("Active UI".into()).unwrap();
    repo.changelist_ensure("Shelf Patch".into()).unwrap();
    repo.changelist_ensure("Shelf Patch".into()).unwrap();

    let lists = repo.changelist_list().unwrap();
    assert_eq!(
        lists
            .iter()
            .filter(|list| list.name == "Shelf Patch")
            .count(),
        1
    );
    assert!(lists
        .iter()
        .any(|list| list.name == "Active UI" && list.is_active));
    assert_eq!(r.read("a.txt"), "a2\n");
}

#[test]
fn changelist_reports_corrupt_metadata_instead_of_resetting_to_default() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    let repo = r.open();
    repo.changelist_create("UI".into()).unwrap();
    let metadata = r.path.join(".git").join("arbor-changelists");
    std::fs::write(&metadata, b"not-a-changelist\n").expect("corrupt metadata");

    let error = repo
        .changelist_list()
        .expect_err("corrupt metadata must fail");
    assert!(error.to_string().contains("unsupported metadata format"));
}

#[test]
fn changelist_list_for_paths_projects_from_an_existing_status_snapshot() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    common::commit(&r.path, "b.txt", "b1\n", "add b");
    r.write("a.txt", "a2\n");
    r.write("b.txt", "b2\n");
    let repo = r.open();

    repo.changelist_create("Review".into()).unwrap();
    repo.changelist_move_paths(vec!["b.txt".into()], "Review".into())
        .unwrap();

    let lists = repo
        .changelist_list_for_paths(vec!["b.txt".into()])
        .expect("project supplied status snapshot");
    assert_eq!(lists[0].paths, Vec::<String>::new());
    assert_eq!(lists[1].name, "Review");
    assert_eq!(lists[1].paths, vec!["b.txt"]);
}

#[test]
fn changelist_metadata_round_trips_and_active_assigns_only_new_paths() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    let repo = r.open();
    r.write("a.txt", "a2\n");
    // The first snapshot seeds the observation ledger and must not move an
    // existing change into a newly selected active list.
    repo.changelist_list().unwrap();
    repo.changelist_create("Review".into()).unwrap();
    repo.changelist_activate("Review".into()).unwrap();
    repo.changelist_set_metadata(
        "Review".into(),
        Some("Ready for review".into()),
        true,
        Some("task-42".into()),
    )
    .unwrap();

    common::commit(&r.path, "b.txt", "b1\n", "add b");
    r.write("b.txt", "b2\n");
    let lists = repo.changelist_list().unwrap();
    assert_eq!(lists[0].paths, vec!["a.txt"]);
    assert_eq!(lists[1].paths, vec!["b.txt"]);

    let metadata = repo.changelist_metadata().unwrap();
    let review = metadata.iter().find(|item| item.name == "Review").unwrap();
    assert_eq!(review.description.as_deref(), Some("Ready for review"));
    assert!(review.track_context);
    assert_eq!(review.task_identity.as_deref(), Some("task-42"));
    assert!(review.is_active);

    let reopened = r.open();
    let reopened_metadata = reopened.changelist_metadata().unwrap();
    assert_eq!(reopened_metadata, metadata);
}

#[test]
fn changelist_v1_metadata_migrates_without_losing_members() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a1\n", "init");
    r.write("a.txt", "a2\n");
    let repo = r.open();
    let metadata = r.path.join(".git").join("arbor-changelists");
    std::fs::write(
        &metadata,
        b"ARBOR_CHANGELISTS_V1\nL\t44656661756c74\t1\nL\t5549\t0\nA\t5549\nP\t612e747874\t5549\n",
    )
    .unwrap();
    let lists = repo.changelist_list().unwrap();
    assert_eq!(lists[1].name, "UI");
    assert_eq!(lists[1].paths, vec!["a.txt"]);
    assert!(std::fs::read_to_string(metadata)
        .unwrap()
        .starts_with("ARBOR_CHANGELISTS_V2\n"));
}

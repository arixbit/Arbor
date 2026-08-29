//! v0.6 HEAD reflog。

use std::io::Write;

mod common;

use common::TestRepo;

#[test]
fn reflog_returns_recent_operations() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a", "first");
    common::commit(&r.path, "b.txt", "b", "second");
    r.git(&["reset", "--hard", "HEAD^"]);
    let entries = r.open().reflog(20).unwrap();
    assert!(!entries.is_empty());
    assert_eq!(entries[0].ref_name, "HEAD");
    assert!(entries.iter().any(|e| e.message.contains("reset")));
    assert!(entries
        .iter()
        .all(|e| e.old_id.len() == 40 && e.new_id.len() == 40));
}

#[test]
fn reflog_page_uses_valid_record_offset_without_skipping_entries() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a", "first");
    common::commit(&r.path, "b.txt", "b", "second");
    common::commit(&r.path, "c.txt", "c", "third");

    let repo = r.open();
    let full = repo.reflog(50).unwrap();
    assert!(full.len() >= 3);

    let page = repo.reflog_page(2, 1).unwrap();
    assert_eq!(page.len(), 2);
    assert_eq!(page[0].new_id, full[1].new_id);
    assert_eq!(page[1].new_id, full[2].new_id);
    assert_eq!(page[0].message, full[1].message);
}

#[test]
fn reflog_page_ignores_malformed_lines_before_offset() {
    let r = TestRepo::new();
    common::commit(&r.path, "a.txt", "a", "first");
    common::commit(&r.path, "b.txt", "b", "second");
    let log_path = r.path.join(".git/logs/HEAD");
    std::fs::OpenOptions::new()
        .append(true)
        .open(&log_path)
        .unwrap()
        .write_all(b"malformed reflog line\n")
        .unwrap();

    let repo = r.open();
    let full = repo.reflog(20).unwrap();
    let page = repo.reflog_page(1, 1).unwrap();
    assert!(full.len() >= 2);
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].new_id, full[1].new_id);
}

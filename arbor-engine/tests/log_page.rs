//! v0.6 log after_id 分页。

mod common;

use common::TestRepo;

#[test]
fn log_after_id_continues_walk() {
    let r = TestRepo::new();
    for i in 0..6 {
        common::commit(
            &r.path,
            &format!("{i}.txt"),
            &i.to_string(),
            &format!("c{i}"),
        );
    }
    let repo = r.open();
    let first = repo.log(None, 2, false, None).unwrap();
    assert_eq!(first.len(), 2);
    let cursor = first.last().unwrap().id.clone();
    let second = repo.log(None, 2, false, Some(cursor)).unwrap();
    assert_eq!(second.len(), 2);
    assert!(first.iter().all(|a| second.iter().all(|b| a.id != b.id)));
    assert_eq!(second[0].summary, "c3");
    assert_eq!(second[1].summary, "c2");
}

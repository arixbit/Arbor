use std::fs;
use std::process::Command;

use arbor_engine::{git_executable, git_executable_version, set_git_executable};

mod common;

#[cfg(unix)]
#[test]
fn configured_git_executable_is_validated_and_used() {
    use std::os::unix::fs::PermissionsExt;

    let temp = tempfile::tempdir().unwrap();
    let real_git = String::from_utf8(
        Command::new("sh")
            .args(["-c", "command -v git"])
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap()
    .trim()
    .to_string();
    assert!(!real_git.is_empty());

    let marker = temp.path().join("argv.log");
    let wrapper = temp.path().join("git-wrapper");
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nexec '{}' \"$@\"\n",
        marker.display(),
        real_git
    );
    fs::write(&wrapper, script).unwrap();
    let mut permissions = fs::metadata(&wrapper).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&wrapper, permissions).unwrap();

    let selected = set_git_executable(wrapper.to_string_lossy().into_owned()).unwrap();
    assert_eq!(selected, wrapper.to_string_lossy());
    assert_eq!(git_executable(), wrapper.to_string_lossy());
    assert!(git_executable_version().unwrap().contains("git version"));
    assert!(fs::read_to_string(&marker).unwrap().contains("--version"));

    let repository = common::TestRepo::new();
    common::commit(&repository.path, "tracked.txt", "content", "init");
    let result = repository
        .open()
        .run_git_command("status".into(), Vec::new())
        .unwrap();
    assert_eq!(result.exit_code, 0);
    assert!(fs::read_to_string(&marker).unwrap().contains("status"));

    let invalid = set_git_executable(temp.path().join("missing-git").display().to_string());
    assert!(invalid.is_err());
    assert_eq!(git_executable(), wrapper.to_string_lossy());

    let selected = set_git_executable(String::new()).unwrap();
    assert_eq!(selected, "git");
    assert_eq!(git_executable(), "git");
    assert!(git_executable_version().unwrap().contains("git version"));
}

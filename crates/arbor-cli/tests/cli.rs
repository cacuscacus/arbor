use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;
use tempfile::tempdir;

#[test]
fn version_prints_package_version() {
    let mut cmd = Command::cargo_bin("arbor").unwrap();
    cmd.arg("version")
        .assert()
        .success()
        .stdout(predicate::str::contains(env!("CARGO_PKG_VERSION")));
}

#[test]
fn list_prints_entries_and_count() {
    let dir = tempdir().unwrap();
    fs::create_dir(dir.path().join("subdir")).unwrap();
    fs::write(dir.path().join("readme.txt"), b"hi").unwrap();
    fs::write(dir.path().join(".dot"), b"x").unwrap();

    let mut cmd = Command::cargo_bin("arbor").unwrap();
    cmd.args(["list", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicate::str::contains("subdir"))
        .stdout(predicate::str::contains("readme.txt"))
        .stdout(predicate::str::contains(".dot").not())
        .stderr(predicate::str::contains("2 entries"));
}

#[test]
fn list_all_includes_hidden() {
    let dir = tempdir().unwrap();
    fs::write(dir.path().join(".secret"), b"x").unwrap();

    let mut cmd = Command::cargo_bin("arbor").unwrap();
    cmd.args(["list", "--all", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicate::str::contains(".secret"));
}

#[test]
fn list_json_emits_array() {
    let dir = tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), b"x").unwrap();

    let mut cmd = Command::cargo_bin("arbor").unwrap();
    cmd.args(["list", "--json", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicate::str::starts_with("["))
        .stdout(predicate::str::contains("a.txt"));
}

#[test]
fn list_missing_path_fails() {
    let mut cmd = Command::cargo_bin("arbor").unwrap();
    cmd.args(["list", "/nonexistent/arbor/cli/path"])
        .assert()
        .failure();
}

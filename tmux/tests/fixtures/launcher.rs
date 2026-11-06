use std::{env, fs, process::Command};

fn main() {
    let arguments: Vec<_> = env::args().collect();
    assert_eq!(&arguments[1..3], &["launch", "claude"]);
    let model = arguments
        .iter()
        .position(|argument| argument == "--model")
        .unwrap();
    let separator = arguments
        .iter()
        .position(|argument| argument == "--")
        .unwrap();
    let mut child = Command::new(env::current_exe().unwrap().with_file_name("claude"))
        .args(["--model", &arguments[model + 1]])
        .args(&arguments[separator + 1..])
        .spawn()
        .unwrap();
    fs::write(env::var("TEST_CHILD_PID").unwrap(), child.id().to_string()).unwrap();
    assert!(child.wait().unwrap().success());
}

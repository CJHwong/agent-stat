use std::{env, fs, process::Command};

fn main() {
    let arguments: Vec<_> = env::args().collect();
    assert_eq!(arguments[1], "launch");
    assert!(matches!(arguments[2].as_str(), "claude" | "codex"));
    let model = arguments
        .iter()
        .position(|argument| argument == "--model")
        .unwrap();
    let forwarded = arguments
        .iter()
        .position(|argument| argument == "--")
        .map(|index| index + 1)
        .unwrap_or(arguments.len());
    let mut child = Command::new(env::current_exe().unwrap().with_file_name(&arguments[2]))
        .args(["--model", &arguments[model + 1]])
        .args(&arguments[forwarded..])
        .spawn()
        .unwrap();
    fs::write(env::var("TEST_CHILD_PID").unwrap(), child.id().to_string()).unwrap();
    assert!(child.wait().unwrap().success());
}

use std::{env, fs, thread, time::Duration};
fn main() {
    let arguments: Vec<_> = env::args().collect();
    let marker = env::var("TEST_WORKER_OUTPUT").unwrap_or_else(|_| arguments[1].clone());
    let mut contents = arguments.join("\0");
    contents.push('\0');
    contents.push_str(&env::current_dir().unwrap().to_string_lossy());
    contents.push('\0');
    contents.push_str(&env::var("CLAUDE_CONFIG_DIR").unwrap_or_default());
    fs::write(marker, contents).unwrap();
    thread::sleep(Duration::from_secs(120));
}

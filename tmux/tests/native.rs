use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_agent-stat-tmux")
}
fn success(output: Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("UTF-8 output")
        .trim_end_matches('\n')
        .to_owned()
}
struct Sandbox {
    root: PathBuf,
    socket: PathBuf,
}
impl Sandbox {
    fn new() -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "native-tmux-{}-{stamp}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&root).unwrap();
        let socket = root.join("socket");
        Self { root, socket }
    }
    fn tmux(&self, args: &[&str]) -> String {
        success(
            Command::new("tmux")
                .arg("-S")
                .arg(&self.socket)
                .current_dir(&self.root)
                .env("HOME", &self.root)
                .env("AGENT_STAT_DIR", self.root.join("events"))
                .env("TMUX_SIDEBAR_STATE_DIR", self.root.join("state"))
                .args(args)
                .output()
                .unwrap(),
        )
    }
    fn command(&self, session: &str, action: &str) -> Command {
        let mut command = Command::new(binary());
        command.args([
            "--socket",
            self.socket.to_str().unwrap(),
            "--session",
            session,
            action,
        ]);
        command
            .env("HOME", &self.root)
            .env("AGENT_STAT_DIR", self.root.join("events"))
            .env("TMUX_SIDEBAR_STATE_DIR", self.root.join("state"));
        command
    }
    fn start(&self, session: &str, command: &str) {
        self.tmux(&[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            session,
            "-x",
            "120",
            "-y",
            "40",
            command,
        ]);
        self.tmux(&["set-option", "-g", "default-shell", "/bin/sh"]);
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = Command::new("tmux")
            .arg("-S")
            .arg(&self.socket)
            .arg("kill-server")
            .output();
        if let Ok(files) = fs::read_dir(self.root.join("state")) {
            for file in files
                .flatten()
                .filter(|file| file.file_name().to_string_lossy().ends_with(".monitor.pid"))
            {
                if let Ok(pid) = fs::read_to_string(file.path())
                    .unwrap_or_default()
                    .parse::<i32>()
                {
                    unsafe { libc::kill(pid, libc::SIGTERM) };
                }
            }
        }
        std::thread::sleep(Duration::from_millis(150));
        if let Err(error) = fs::remove_dir_all(&self.root) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Remove isolated files: {error}");
            }
        }
    }
}

#[test]
fn installer_has_one_native_runtime_and_preserves_existing_configuration() {
    let sandbox = Sandbox::new();
    fs::write(
        sandbox.root.join(".tmux.conf"),
        "# Existing configuration\n",
    )
    .unwrap();
    for _ in 0..2 {
        success(
            Command::new(binary())
                .args([
                    "install",
                    "--home",
                    sandbox.root.to_str().unwrap(),
                    "--apply",
                ])
                .output()
                .unwrap(),
        );
    }
    let config = fs::read_to_string(sandbox.root.join(".config/tmux/window-sidebar.conf")).unwrap();
    assert!(!config.contains("python"));
    assert!(config.contains("agent-stat-tmux"));
    assert!(sandbox.root.join(".agents/tmux/agent-stat-tmux").is_file());
    let main = fs::read_to_string(sandbox.root.join(".tmux.conf")).unwrap();
    assert!(main.starts_with("# Existing configuration\n"));
    assert_eq!(main.matches("source-file").count(), 1);
}

#[test]
fn native_commands_keep_numeric_session_targets_and_content_processes() {
    let sandbox = Sandbox::new();
    sandbox.start("0", "sleep 120");
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "0", "#{pane_id}"]);
    let pid = sandbox.tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"]);
    success(sandbox.command("0", "enable").output().unwrap());
    for expected in [2, 3] {
        success(sandbox.command("0", "new").output().unwrap());
        assert_eq!(
            sandbox.tmux(&["list-windows", "-t", "0"]).lines().count(),
            expected
        );
        assert!(
            !sandbox
                .tmux(&[
                    "display-message",
                    "-p",
                    "-t",
                    "0",
                    "#{@window_sidebar_pane}"
                ])
                .is_empty()
        );
    }
    assert_eq!(
        sandbox.tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"]),
        pid
    );
}

#[test]
fn exited_shell_does_not_leave_a_sidebar_window() {
    let sandbox = Sandbox::new();
    success(
        Command::new(binary())
            .args([
                "install",
                "--home",
                sandbox.root.to_str().unwrap(),
                "--apply",
            ])
            .output()
            .unwrap(),
    );
    sandbox.start("0", "sleep 120");
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    success(sandbox.command("0", "enable").output().unwrap());
    let original = sandbox.tmux(&["display-message", "-p", "-t", "0", "#{window_id}"]);
    let original_content = sandbox.tmux(&["display-message", "-p", "-t", "0:", "#{pane_id}"]);
    let original_sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        "0",
        "#{@window_sidebar_pane}",
    ]);
    sandbox.tmux(&["select-pane", "-t", &original_sidebar]);
    let shell = sandbox.tmux(&[
        "new-window",
        "-P",
        "-F",
        "#{pane_id}",
        "-t",
        "0:",
        "-c",
        sandbox.root.to_str().unwrap(),
    ]);
    let window = sandbox.tmux(&["display-message", "-p", "-t", &shell, "#{window_id}"]);
    success(sandbox.command("0", "ensure").output().unwrap());
    sandbox.tmux(&["send-keys", "-t", &shell, "exit", "Enter"]);
    for _ in 0..100 {
        let remaining = sandbox.tmux(&["list-windows", "-t", "0", "-F", "#{window_id}"]);
        if !remaining.lines().any(|current| current == window) {
            assert_eq!(remaining, original);
            assert_eq!(
                sandbox.tmux(&["display-message", "-p", "-t", "0", "#{window_id}"]),
                original
            );
            assert_eq!(
                sandbox.tmux(&["display-message", "-p", "-t", "0:", "#{pane_id}"]),
                original_content
            );
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("The sidebar kept an exited shell's window alive");
}

#[test]
fn new_shell_starts_with_its_final_content_size() {
    let sandbox = Sandbox::new();
    sandbox.start("0", "sleep 120");
    success(sandbox.command("0", "enable").output().unwrap());
    let marker = sandbox.root.join("initial-shell-size");
    sandbox.tmux(&[
        "set-option",
        "-g",
        "default-command",
        &format!(
            "stty size > {}; exec /bin/sh",
            quote(marker.to_str().unwrap())
        ),
    ]);
    success(sandbox.command("0", "new").output().unwrap());
    wait_for_file(&marker);
    let actual = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        "0:",
        "#{pane_height} #{pane_width}",
    ]);
    assert_eq!(fs::read_to_string(marker).unwrap().trim(), actual);
}

fn worker(root: &Path) -> PathBuf {
    let output = root.join("worker");
    success(
        Command::new("rustc")
            .args([
                "--edition=2024",
                concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/worker.rs"),
                "-o",
                output.to_str().unwrap(),
            ])
            .output()
            .unwrap(),
    );
    output
}
fn wait_for_file(path: &Path) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    panic!("Missing worker output: {}", path.display());
}
fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[test]
fn exact_arguments_require_opt_in_and_legacy_snapshots_still_restore() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let marker = sandbox.root.join("worker-output");
    let arguments = vec![
        worker.to_string_lossy().into_owned(),
        marker.to_string_lossy().into_owned(),
        "two words".into(),
        "; touch nope".into(),
        String::new(),
    ];
    sandbox.start(
        "source",
        &arguments
            .iter()
            .map(|arg| quote(arg))
            .collect::<Vec<_>>()
            .join(" "),
    );
    sandbox.tmux(&["new-session", "-d", "-s", "keep", "sleep 120"]);
    wait_for_file(&marker);
    let snapshot: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("source", "snapshot").output().unwrap(),
    ))
    .unwrap();
    let pane = &snapshot["windows"][0]["panes"][0];
    assert_eq!(pane["command_argv"], serde_json::json!(arguments));
    let plan: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("source", "plan").output().unwrap(),
    ))
    .unwrap();
    assert_eq!(plan["commands"], serde_json::json!([]));
    sandbox.tmux(&["kill-session", "-t", "source"]);
    fs::remove_file(&marker).unwrap();
    success(sandbox.command("source", "restore").output().unwrap());
    assert!(!marker.exists());
    let mut restore = sandbox.command("source", "restore");
    restore.args(["--rerun", pane["pane_id"].as_str().unwrap()]);
    assert!(success(restore.output().unwrap()).contains("recovered-source"));
    wait_for_file(&marker);
    let restored = fs::read(&marker).unwrap();
    assert!(
        restored
            .windows(b"two words\0; touch nope\0\0".len())
            .any(|part| part == b"two words\0; touch nope\0\0")
    );
    assert!(!sandbox.root.join("nope").exists());
    assert_eq!(snapshot["version"], 1);
}

fn event_file(sandbox: &Sandbox) -> PathBuf {
    let host = success(Command::new("uname").arg("-n").output().unwrap())
        .trim()
        .trim_end_matches(".local")
        .to_owned();
    let directory = sandbox.root.join("events/hosts");
    fs::create_dir_all(&directory).unwrap();
    directory.join(format!("{host}-2026-11-04.jsonl"))
}
fn append_event(path: &Path, record: serde_json::Value) {
    use std::io::Write;
    writeln!(
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap(),
        "{record}"
    )
    .unwrap();
}
#[test]
fn shared_events_keep_unread_markers_and_unknown_rows_have_no_status() {
    let sandbox = Sandbox::new();
    sandbox.start("source", "sleep 120");
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{pane_id}"]);
    let window = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{window_id}"]);
    let pid: u32 = sandbox
        .tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
        .parse()
        .unwrap();
    sandbox.tmux(&["new-window", "-t", "source:", "sleep 120"]);
    let path = event_file(&sandbox);
    append_event(
        &path,
        serde_json::json!({"event":"Stop","session":"first","agent":"claude","agent_pid":pid,"tmux":pane,"ts":1}),
    );
    let dump = || {
        serde_json::from_str::<serde_json::Value>(&success(
            sandbox.command("source", "dump").output().unwrap(),
        ))
        .unwrap()
    };
    let initial = dump();
    assert_eq!(initial[0]["state"], "done");
    assert_eq!(initial[0]["unread"], true);
    assert_eq!(initial[1]["state"], "");
    sandbox.tmux(&["select-window", "-t", &window]);
    let viewed = dump();
    assert_eq!(viewed[0]["state"], "idle");
    assert_eq!(viewed[0]["unread"], false);
    sandbox.tmux(&["next-window", "-t", "source"]);
    append_event(
        &path,
        serde_json::json!({"event":"Stop","session":"first","agent":"claude","agent_pid":pid,"tmux":pane,"ts":1}),
    );
    assert_eq!(
        dump()[0]["unread"],
        true,
        "A new record at the same timestamp is a new completion"
    );
    append_event(
        &path,
        serde_json::json!({"event":"PermissionRequest","session":"first","agent_pid":pid,"tmux":pane,"ts":2}),
    );
    assert_eq!(dump()[0]["state"], "waiting");
    assert_eq!(dump()[0]["unread"], true);
    sandbox.tmux(&["select-window", "-t", &window]);
    let viewed = dump();
    assert_eq!(
        viewed[0]["state"], "waiting",
        "Viewing a request does not approve it"
    );
    assert_eq!(viewed[0]["unread"], false);
    sandbox.tmux(&["next-window", "-t", "source"]);
    assert_eq!(dump()[0]["unread"], false);
    append_event(
        &path,
        serde_json::json!({"event":"Notification","session":"first","agent_pid":pid,"tmux":pane,"ts":2}),
    );
    assert_eq!(
        dump()[0]["unread"],
        true,
        "A new notification needs attention again"
    );
}

#[test]
fn agent_recovery_preserves_profile_labels_and_split_proportions() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let bin = sandbox.root.join("bin");
    fs::create_dir(&bin).unwrap();
    fs::copy(worker, bin.join("claude")).unwrap();
    let marker = sandbox.root.join("resumed");
    let profile = sandbox.root.join("profile with spaces");
    fs::create_dir(&profile).unwrap();
    let command = format!(
        "env CLAUDE_CONFIG_DIR={} TEST_WORKER_OUTPUT={} {} --resume conversation-123",
        quote(profile.to_str().unwrap()),
        quote(marker.to_str().unwrap()),
        quote(bin.join("claude").to_str().unwrap())
    );
    sandbox.start("source", &command);
    sandbox.tmux(&["new-session", "-d", "-s", "keep", "sleep 120"]);
    wait_for_file(&marker);
    sandbox.tmux(&[
        "set-environment",
        "-g",
        "PATH",
        &format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
    ]);
    sandbox.tmux(&[
        "set-environment",
        "-g",
        "TEST_WORKER_OUTPUT",
        marker.to_str().unwrap(),
    ]);
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{pane_id}"]);
    let pid: u32 = sandbox
        .tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
        .parse()
        .unwrap();
    sandbox.tmux(&[
        "split-window",
        "-d",
        "-h",
        "-l",
        "30",
        "-t",
        &pane,
        "sleep 120",
    ]);
    sandbox.tmux(&[
        "set-option",
        "-p",
        "-t",
        &pane,
        "@window_sidebar_label",
        "Saved agent",
    ]);
    append_event(
        &event_file(&sandbox),
        serde_json::json!({"event":"Stop","session":"conversation-123","agent":"claude","agent_pid":pid,"tmux":pane,"cwd":sandbox.root,"ts":1}),
    );
    let snapshot: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("source", "snapshot").output().unwrap(),
    ))
    .unwrap();
    assert_eq!(
        snapshot["windows"][0]["panes"][0]["agent"]["profile"],
        profile.to_str().unwrap()
    );
    assert!(
        success(sandbox.command("source", "restore").output().unwrap())
            .contains("Nothing to restore")
    );
    let path = fs::read_dir(sandbox.root.join("state/snapshots"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    // A V1 snapshot from the retired implementation has no window label field.
    let mut legacy = snapshot;
    legacy["windows"][0]
        .as_object_mut()
        .unwrap()
        .remove("label");
    fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    sandbox.tmux(&["kill-session", "-t", "source"]);
    fs::remove_file(&marker).unwrap();
    let mut restore = sandbox.command("source", "restore");
    restore.env(
        "PATH",
        format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
    );
    let restored = success(restore.output().unwrap());
    assert!(restored.contains("recovered-source"), "{restored}");
    wait_for_file(&marker);
    let launched = String::from_utf8(fs::read(&marker).unwrap()).unwrap();
    assert!(launched.contains("--resume\0conversation-123\0"));
    assert!(launched.ends_with(profile.to_str().unwrap()));
    let panes = sandbox.tmux(&[
        "list-panes",
        "-t",
        "recovered-source",
        "-F",
        "#{@window_sidebar}\t#{pane_width}\t#{pane_height}\t#{@window_sidebar_label}",
    ]);
    let contents = panes
        .lines()
        .map(|line| line.split('\t').collect::<Vec<_>>())
        .filter(|fields| fields[0].is_empty())
        .collect::<Vec<_>>();
    assert_eq!(contents.len(), 2);
    assert!(contents[0][1].parse::<u16>().unwrap() > contents[1][1].parse::<u16>().unwrap());
    assert_eq!(contents[0][2], contents[1][2]);
    assert_eq!(contents[0][3], "Saved agent");
}

struct Client {
    child: std::process::Child,
    master: fs::File,
    slave: fs::File,
    width: u16,
}
impl Client {
    fn attach(sandbox: &Sandbox, session: &str) -> Self {
        use std::os::{
            fd::{AsRawFd, FromRawFd},
            unix::process::CommandExt,
        };
        let mut master = -1;
        let mut slave = -1;
        let mut dimensions = libc::winsize {
            ws_row: 40,
            ws_col: 120,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut dimensions,
                )
            },
            0
        );
        let master = unsafe { fs::File::from_raw_fd(master) };
        let slave = unsafe { fs::File::from_raw_fd(slave) };
        assert!(unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } >= 0);
        let mut command = Command::new("tmux");
        command
            .arg("-S")
            .arg(&sandbox.socket)
            .args(["attach-session", "-t", session])
            .env("TERM", "xterm-256color")
            .env_remove("TMUX")
            .stdin(slave.try_clone().unwrap())
            .stdout(slave.try_clone().unwrap())
            .stderr(slave.try_clone().unwrap());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        let child = command.spawn().unwrap();
        Self {
            child,
            master,
            slave,
            width: 120,
        }
    }
    fn send(&mut self, bytes: &[u8]) {
        use std::io::Write;
        let mut remaining = bytes;
        let started = std::time::Instant::now();
        while !remaining.is_empty() {
            match self.master.write(remaining) {
                Ok(0) => panic!("The terminal accepted no input"),
                Ok(count) => remaining = &remaining[count..],
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        started.elapsed() < Duration::from_secs(4),
                        "Terminal input stayed blocked"
                    );
                    std::thread::sleep(Duration::from_millis(2));
                }
                Err(error) => panic!("Terminal input: {error}"),
            }
        }
    }
    fn drain(&mut self, duration: Duration) -> Vec<u8> {
        use std::io::Read;
        let mut output = Vec::new();
        let end = std::time::Instant::now() + duration;
        while std::time::Instant::now() < end {
            let mut buffer = [0u8; 65536];
            match self.master.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => output.extend_from_slice(&buffer[..count]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(2))
                }
                Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
                Err(error) => panic!("PTY read: {error}"),
            }
        }
        let queries = regex::Regex::new(
            r"\x1b(?:\][^\x1b\x07]*(?:\x1b\\|\x07)|P[^\x1b]*\x1b\\|\[[0-?]*[ -/]*[@-~])",
        )
        .unwrap();
        // Answer terminal queries so tmux does not extend Escape while waiting for replies.
        for query in queries.find_iter(std::str::from_utf8(&output).unwrap_or_default()) {
            if query.as_str() == "\x1b[18t" {
                self.send(format!("\x1b[8;40;{}t", self.width).as_bytes());
                continue;
            }
            if query.as_str() == "\x1b[14t" {
                self.send(format!("\x1b[4;640;{}t", self.width as u32 * 8).as_bytes());
                continue;
            }
            if let Some(capabilities) = query
                .as_str()
                .strip_prefix("\x1bP+q")
                .and_then(|text| text.strip_suffix("\x1b\\"))
            {
                for capability in capabilities.split(';') {
                    self.send(format!("\x1bP0+r{capability}\x1b\\").as_bytes());
                }
            }
            if let Some(mode) = query
                .as_str()
                .strip_prefix("\x1b[")
                .and_then(|text| text.strip_suffix("$p"))
            {
                self.send(format!("\x1b[{mode};0$y").as_bytes());
            }
            let response = match query.as_str() {
                "\x1b[?u" => "\x1b[?0u",
                "\x1b[c" => "\x1b[?1;2c",
                "\x1b[>c" => "\x1b[>0;10;1c",
                "\x1b[>q" => "\x1bP>|native-test(1)\x1b\\",
                "\x1b[?996n" => "\x1b[?997;1n",
                "\x1b]10;?\x1b\\" => "\x1b]10;rgb:cccc/cccc/cccc\x1b\\",
                "\x1b]11;?\x1b\\" => "\x1b]11;rgb:0000/0000/0000\x1b\\",
                "\x1b[18t" => "\x1b[8;40;120t",
                "\x1b[14t" => "\x1b[4;640;960t",
                _ => "",
            };
            if !response.is_empty() {
                self.send(response.as_bytes());
            }
        }
        output
    }
    fn wait(&mut self, description: &str, mut predicate: impl FnMut() -> bool) {
        let end = std::time::Instant::now() + Duration::from_secs(4);
        while std::time::Instant::now() < end {
            if predicate() {
                return;
            }
            self.drain(Duration::from_millis(10));
        }
        panic!("Timed out: {description}");
    }
    fn expect(&mut self, text: &str) -> Duration {
        let started = std::time::Instant::now();
        let mut output = Vec::new();
        while started.elapsed() < Duration::from_secs(4) {
            output.extend(self.drain(Duration::from_millis(5)));
            if output
                .windows(text.len())
                .any(|part| part == text.as_bytes())
            {
                return started.elapsed();
            }
        }
        panic!("Missing terminal text: {text}");
    }
    fn click(&mut self, sandbox: &Sandbox, pane: &str, column: u16, row: u16, right: bool) {
        let top: u16 = sandbox
            .tmux(&["display-message", "-p", "-t", pane, "#{pane_top}"])
            .parse()
            .unwrap();
        let left: u16 = sandbox
            .tmux(&["display-message", "-p", "-t", pane, "#{pane_left}"])
            .parse()
            .unwrap();
        let button = if right { 2 } else { 0 };
        self.send(
            format!(
                "\x1b[<{button};{};{}M\x1b[<{button};{};{}m",
                left + column + 1,
                top + row + 1,
                left + column + 1,
                top + row + 1
            )
            .as_bytes(),
        );
    }
    fn resize(&mut self, width: u16) {
        self.width = width;
        use std::os::fd::AsRawFd;
        let size = libc::winsize {
            ws_row: 40,
            ws_col: width,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        assert_eq!(
            unsafe { libc::ioctl(self.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
            0
        );
        unsafe { libc::kill(self.child.id() as i32, libc::SIGWINCH) };
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        if let Err(error) = self.child.kill() {
            if error.kind() != std::io::ErrorKind::InvalidInput {
                eprintln!("Stop test client: {error}");
            }
        }
        self.child.wait().expect("reap test client");
    }
}

#[test]
fn monitor_uses_requested_session_instead_of_inherited_pane() {
    let sandbox = Sandbox::new();
    sandbox.start("requested", "sleep 120");
    let foreign = sandbox.tmux(&[
        "new-session",
        "-d",
        "-s",
        "foreign",
        "-P",
        "-F",
        "#{pane_id}",
        "sleep 120",
    ]);
    success(
        sandbox
            .command("requested", "enable")
            .env("TMUX_PANE", foreign)
            .output()
            .unwrap(),
    );
    let end = std::time::Instant::now() + Duration::from_secs(4);
    let mut monitors = Vec::new();
    while std::time::Instant::now() < end {
        monitors = fs::read_dir(sandbox.root.join("state"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.to_string_lossy().ends_with(".monitor.pid"))
            .collect();
        if !monitors.is_empty() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(monitors.len(), 1);
    assert!(
        monitors[0]
            .to_string_lossy()
            .ends_with("-session0.monitor.pid")
    );
}

#[test]
fn rename_prompts_keep_names_literal() {
    let sandbox = Sandbox::new();
    sandbox.start("rename", "sleep 120");
    sandbox.tmux(&["set-option", "-s", "escape-time", "20"]);
    sandbox.tmux(&["set-option", "-g", "status-keys", "emacs"]);
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "rename:", "#{pane_id}"]);
    let window = sandbox.tmux(&["display-message", "-p", "-t", &pane, "#{window_id}"]);
    let mut client = Client::attach(&sandbox, "rename");
    client.drain(Duration::from_millis(150));
    for route in ["rename", "pane-menu", "window-menu"] {
        for name in [
            "Matt's api",
            "Matt's api'; set-option -g @rename_injected yes; #",
            "quotes \"double\" \\ slash $HOME #{session_name}",
        ] {
            // Keep tmux's own window-name normalization separate from prompt quoting.
            sandbox.tmux(&["rename-window", "-t", &window, name]);
            let expected_window =
                sandbox.tmux(&["display-message", "-p", "-t", &window, "#{window_name}"]);
            sandbox.tmux(&["rename-window", "-t", &window, "Before rename"]);
            let action = if route == "rename" { "rename" } else { "menu" };
            let action = sandbox
                .command("rename", action)
                .arg("--pane")
                .arg(&pane)
                .spawn()
                .unwrap();
            if route != "rename" {
                client.expect("Rename window");
                client.send(if route == "pane-menu" { b"r" } else { b"R" });
            }
            client.expect(if route == "window-menu" {
                "Window name:"
            } else {
                "Pane name:"
            });
            client.send(b"\x15");
            client.send(name.as_bytes());
            client.send(b"\r");
            success(action.wait_with_output().unwrap());
            let format = if route == "window-menu" {
                "#{@window_sidebar_window_label}"
            } else {
                "#{@window_sidebar_label}"
            };
            client.wait(&format!("literal rename via {route}: {name:?}"), || {
                sandbox.tmux(&["display-message", "-p", "-t", &pane, format]) == name
            });
            if route == "window-menu" {
                assert_eq!(
                    sandbox.tmux(&["display-message", "-p", "-t", &window, "#{window_name}"]),
                    expected_window
                );
            }
            assert!(
                sandbox
                    .tmux(&["show-option", "-gqv", "@rename_injected"])
                    .is_empty()
            );
        }
    }
}

#[test]
fn native_terminal_checks_prefix_latency_new_windows_grouping_and_overlays() {
    let sandbox = Sandbox::new();
    success(
        Command::new(binary())
            .args([
                "install",
                "--home",
                sandbox.root.to_str().unwrap(),
                "--apply",
            ])
            .output()
            .unwrap(),
    );
    sandbox.start("0", "sleep 120");
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    let content = sandbox.tmux(&["display-message", "-p", "-t", "0", "#{pane_id}"]);
    let pid = sandbox.tmux(&["display-message", "-p", "-t", &content, "#{pane_pid}"]);
    let window = sandbox.tmux(&["display-message", "-p", "-t", "0", "#{window_id}"]);
    sandbox.tmux(&[
        "set-option",
        "-p",
        "-t",
        &content,
        "@window_sidebar_label",
        "Native controls",
    ]);
    success(sandbox.command("0", "enable").output().unwrap());
    let sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        "0",
        "#{@window_sidebar_pane}",
    ]);
    let mut client = Client::attach(&sandbox, "0");
    client.wait("sidebar first frame", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains("Native controls")
    });
    client.drain(Duration::from_millis(50));
    let mut timings = Vec::new();
    for _ in 0..3 {
        client.send(b"\x02");
        timings.push(client.expect("NEXT KEY"));
        client.send(b"\x02");
        client.wait("prefix release", || {
            sandbox
                .tmux(&["list-clients", "-t", "0", "-F", "#{client_prefix}"])
                .lines()
                .all(|line| line == "0")
        });
        client.drain(Duration::from_millis(60));
    }
    assert!(
        timings
            .iter()
            .all(|elapsed| *elapsed < Duration::from_millis(300)),
        "Prefix latency: {timings:?}"
    );
    println!("Native prefix latency: {timings:?}");
    for trigger in [b"/".as_slice(), b"\x02/".as_slice()] {
        sandbox.tmux(&["select-pane", "-t", &sidebar]);
        client.drain(Duration::from_millis(80));
        client.send(trigger);
        client.expect("Arrows: Select a pane");
        client.send(b"Native");
        client.expect("Native controls");
        client.send(b"\x1b");
        client.wait("search closes", || {
            let processes = success(
                Command::new("/bin/ps")
                    .args(["-axo", "command="])
                    .output()
                    .unwrap(),
            );
            !processes.lines().any(|line| {
                line.contains(sandbox.socket.to_str().unwrap()) && line.contains("search-ui")
            })
        });
        client.drain(Duration::from_millis(80));
    }
    for expected in [2, 3] {
        client.wait("new window sidebar", || {
            !sandbox
                .tmux(&[
                    "display-message",
                    "-p",
                    "-t",
                    "0",
                    "#{@window_sidebar_pane}",
                ])
                .is_empty()
        });
        let current = sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "0",
            "#{@window_sidebar_pane}",
        ]);
        client.wait("new window first frame", || {
            sandbox
                .tmux(&["capture-pane", "-p", "-t", &current])
                .contains("+ New")
        });
        client.click(&sandbox, &current, 4, 0, false);
        client.wait("New window", || {
            sandbox.tmux(&["list-windows", "-t", "0"]).lines().count() == expected
        });
        client.wait("prepared window is selected", || {
            sandbox.tmux(&["display-message", "-p", "-t", "0", "#{window_index}"])
                == (expected - 1).to_string()
        });
        let new_sidebar = sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "0:",
            "#{@window_sidebar_pane}",
        ]);
        client.wait("new sidebar first frame", || {
            sandbox
                .tmux(&["capture-pane", "-p", "-t", &new_sidebar])
                .contains("+ New")
        });
        client.click(&sandbox, &new_sidebar, 9, 2, false);
        client.wait("new sidebar accepts its first row click", || {
            sandbox.tmux(&["display-message", "-p", "-t", "0:", "#{window_id}"]) == window
        });
    }
    sandbox.tmux(&["select-window", "-t", &window]);
    sandbox.tmux(&["select-pane", "-t", &sidebar]);
    for zoom in ["1", "0"] {
        client.send(b"\x02");
        client.drain(Duration::from_millis(80));
        client.send(b"z");
        client.wait("content zoom", || {
            sandbox.tmux(&[
                "display-message",
                "-p",
                "-t",
                &content,
                "#{window_zoomed_flag}",
            ]) == zoom
        });
        client.drain(Duration::from_millis(150));
        assert_eq!(
            sandbox.tmux(&[
                "display-message",
                "-p",
                "-t",
                &content,
                "#{window_zoomed_flag}"
            ]),
            zoom
        );
    }
    client.send(b"\x02?");
    client.expect("TMUX SHORTCUTS");
    for _ in 0..100 {
        client.send(b"\x1b[<65;10;10M");
    }
    client.send(b"\x1b");
    let closing = std::time::Instant::now();
    client.wait("help closes after queued scrolling", || {
        let processes = success(
            Command::new("/bin/ps")
                .args(["-axo", "command="])
                .output()
                .unwrap(),
        );
        !processes
            .lines()
            .any(|line| line.contains(sandbox.socket.to_str().unwrap()) && line.contains("keys-ui"))
    });
    assert!(
        closing.elapsed() < Duration::from_millis(250),
        "Queued help scroll delayed Escape"
    );
    client.drain(Duration::from_millis(80));
    client.click(&sandbox, &sidebar, 9, 3, true);
    client.expect("Full title and command");
    client.send(b"q");
    client.drain(Duration::from_millis(80));
    client.resize(80);
    client.wait("rail", || {
        sandbox.tmux(&["display-message", "-p", "-t", &sidebar, "#{pane_width}"]) == "3"
    });
    client.wait("Unicode rail", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains('▶')
    });
    let rail = sandbox.tmux(&["capture-pane", "-p", "-t", &sidebar]);
    let height: usize = sandbox
        .tmux(&["display-message", "-p", "-t", &sidebar, "#{pane_height}"])
        .parse()
        .unwrap();
    let (row, arrow) = rail
        .lines()
        .enumerate()
        .find(|(_, line)| line.contains('▶'))
        .unwrap();
    assert_eq!(row, (height - 1) / 2);
    assert_eq!(arrow.chars().position(|letter| letter == '▶'), Some(1));
    let width = sandbox.tmux(&["display-message", "-p", "-t", &content, "#{pane_width}"]);
    client.click(&sandbox, &sidebar, 0, 1, false);
    client.expect("Esc: Close overlay");
    assert_eq!(
        sandbox.tmux(&["display-message", "-p", "-t", &content, "#{pane_width}"]),
        width
    );
    client.send(b"\x1b");
    client.wait("overlay closes", || {
        !sandbox
            .tmux(&["list-panes", "-t", &window, "-F", "#{@window_sidebar}"])
            .lines()
            .any(|role| role == "2")
    });
    client.click(&sandbox, &sidebar, 0, 1, false);
    client.expect("Esc: Close overlay");
    client.resize(120);
    client.wait("overlay docks", || {
        !sandbox
            .tmux(&["list-panes", "-t", &window, "-F", "#{@window_sidebar}"])
            .lines()
            .any(|role| role == "2")
    });
    client.wait("fixed width", || {
        sandbox.tmux(&["display-message", "-p", "-t", &sidebar, "#{pane_width}"]) == "28"
    });
    sandbox.tmux(&["split-window", "-d", "-h", "-t", &content, "sleep 120"]);
    client.wait("grouped panes", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains("2 panes")
    });
    sandbox.tmux(&["select-pane", "-t", &content]);
    client.drain(Duration::from_millis(80));
    client.send(b"\x1bOP");
    client.expect("Reset pane name");
    client.send(b"N");
    client.wait("manual pane label resets", || {
        sandbox
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                &content,
                "#{@window_sidebar_label}",
            ])
            .is_empty()
    });
    assert_eq!(
        sandbox.tmux(&["display-message", "-p", "-t", &content, "#{pane_pid}"]),
        pid
    );
}

#[test]
fn native_recovery_preview_cancels_fast_and_reruns_only_checked_commands() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let marker = sandbox.root.join("replayed");
    success(
        Command::new(binary())
            .args([
                "install",
                "--home",
                sandbox.root.to_str().unwrap(),
                "--apply",
            ])
            .output()
            .unwrap(),
    );
    sandbox.start(
        "source",
        &format!(
            "{} {} 'two words'",
            quote(worker.to_str().unwrap()),
            quote(marker.to_str().unwrap())
        ),
    );
    wait_for_file(&marker);
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    let content = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{pane_id}"]);
    success(sandbox.command("source", "enable").output().unwrap());
    let sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        "source",
        "#{@window_sidebar_pane}",
    ]);
    success(sandbox.command("source", "snapshot").output().unwrap());
    sandbox.tmux(&["respawn-pane", "-k", "-t", &content, "sleep 120"]);
    fs::remove_file(&marker).unwrap();
    let mut client = Client::attach(&sandbox, "source");
    client.wait("sidebar frame", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains("+ New")
    });
    // This PTY has no terminal emulator to answer tmux's startup capability queries.
    client.drain(Duration::from_millis(800));
    client.send(b"\x1bOP");
    client.expect("Recover saved sessions");
    client.send(b"u");
    client.expect("RECOVERY PREVIEW");
    assert!(!marker.exists());
    for _ in 0..100 {
        client.send(b"\x1b[<65;10;10M");
    }
    client.drain(Duration::from_millis(50));
    let recovery_running = || {
        let output = success(
            Command::new("/bin/ps")
                .args(["-axo", "command="])
                .output()
                .unwrap(),
        );
        output.lines().any(|line| {
            line.contains(sandbox.socket.to_str().unwrap()) && line.contains("recovery-ui")
        })
    };
    client.send(b"\x1b");
    let closing = std::time::Instant::now();
    client.wait("recovery closes", || !recovery_running());
    let escaped = closing.elapsed();
    client.drain(Duration::from_millis(40));
    assert!(
        escaped < Duration::from_millis(250),
        "Recovery Escape: {escaped:?}"
    );
    assert!(!marker.exists());
    client.send(b"r");
    client.drain(Duration::from_millis(80));
    assert!(!recovery_running());
    sandbox.tmux(&["select-pane", "-t", &sidebar]);
    client.drain(Duration::from_millis(80));
    client.send(b"\x02r");
    client.expect("RECOVERY PREVIEW");
    client.send(b"\x1b");
    client.wait("recovery shortcut closes", || !recovery_running());
    client.drain(Duration::from_millis(80));
    assert!(!marker.exists());
    client.send(b"\x02r");
    client.wait("recovery process starts", recovery_running);
    client.expect("Rerun saved command");
    client.send(b" r");
    client.wait("explicit saved command rerun", || marker.exists());
    let result = String::from_utf8(fs::read(&marker).unwrap()).unwrap();
    assert!(result.contains("two words\0"));
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &content,
            "#{pane_current_command}"
        ]),
        "sleep"
    );
}

#[test]
fn installed_upgrade_removes_legacy_files_and_restarts_only_the_sidebar() {
    let sandbox = Sandbox::new();
    let install = || {
        let mut command = Command::new(binary());
        command.args([
            "install",
            "--home",
            sandbox.root.to_str().unwrap(),
            "--apply",
        ]);
        command
    };
    success(install().output().unwrap());
    sandbox.start("0", "sleep 120");
    let installed = sandbox.root.join(".agents/tmux/agent-stat-tmux");
    let mut enable = Command::new(&installed);
    enable
        .args([
            "--socket",
            sandbox.socket.to_str().unwrap(),
            "--session",
            "0",
            "enable",
        ])
        .env("HOME", &sandbox.root)
        .env("AGENT_STAT_DIR", sandbox.root.join("events"))
        .env("TMUX_SIDEBAR_STATE_DIR", sandbox.root.join("state"));
    success(enable.output().unwrap());
    let content = sandbox
        .tmux(&[
            "list-panes",
            "-t",
            "0",
            "-F",
            "#{pane_id}\t#{pane_pid}\t#{@window_sidebar}",
        ])
        .lines()
        .find(|line| line.ends_with('\t'))
        .unwrap()
        .to_owned();
    fs::write(
        sandbox.root.join(".agents/tmux/window-sidebar.py"),
        "# Retired runtime\n",
    )
    .unwrap();
    let mut upgrade = install();
    upgrade.args(["--socket", sandbox.socket.to_str().unwrap(), "--restart"]);
    let output = success(upgrade.output().unwrap());
    assert!(output.contains("Preserved 1 content processes"));
    assert!(!sandbox.root.join(".agents/tmux/window-sidebar.py").exists());
    assert!(
        sandbox
            .tmux(&[
                "list-panes",
                "-t",
                "0",
                "-F",
                "#{pane_id}\t#{pane_pid}\t#{@window_sidebar}"
            ])
            .lines()
            .any(|line| line == content)
    );
    let hooks = sandbox.tmux(&["show-hooks", "-g"]);
    assert!(!hooks.contains("python"));
    assert!(!hooks.contains("prototype"));
}

#[test]
fn cached_hook_guards_are_empty_and_disappear_after_the_old_caller_exits() {
    let sandbox = Sandbox::new();
    sandbox.start("source", "sleep 120");
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{pane_id}"]);
    let pid: u32 = sandbox
        .tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
        .parse()
        .unwrap();
    for directory in [".agents/tmux", ".config/tmux", ".claude/sessions"] {
        fs::create_dir_all(sandbox.root.join(directory)).unwrap();
    }
    for directory in [".agents/tmux", ".config/tmux"] {
        fs::write(
            sandbox.root.join(directory).join("sidebar_agents.py"),
            "# Retired cached hook\n",
        )
        .unwrap();
    }
    fs::write(
        sandbox.root.join(".claude/sessions/old.json"),
        serde_json::to_vec(&serde_json::json!({"pid":pid})).unwrap(),
    )
    .unwrap();
    success(
        Command::new(binary())
            .args([
                "install",
                "--home",
                sandbox.root.to_str().unwrap(),
                "--socket",
                sandbox.socket.to_str().unwrap(),
                "--apply",
                "--restart",
            ])
            .output()
            .unwrap(),
    );
    for directory in [".agents/tmux", ".config/tmux"] {
        assert_eq!(
            fs::metadata(sandbox.root.join(directory).join("sidebar_agents.py"))
                .unwrap()
                .len(),
            0
        );
    }
    sandbox.tmux(&["respawn-pane", "-k", "-t", &pane, "sleep 120"]);
    success(sandbox.command("source", "snapshot").output().unwrap());
    for directory in [".agents/tmux", ".config/tmux"] {
        assert!(
            !sandbox
                .root
                .join(directory)
                .join("sidebar_agents.py")
                .exists()
        );
    }
}

#[test]
fn monitor_preserves_reboot_snapshots_and_records_deliberate_closures() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let marker = sandbox.root.join("worker-output");
    sandbox.start(
        "source",
        &format!(
            "{} {}",
            quote(worker.to_str().unwrap()),
            quote(marker.to_str().unwrap())
        ),
    );
    wait_for_file(&marker);
    success(sandbox.command("source", "snapshot").output().unwrap());
    let path = fs::read_dir(sandbox.root.join("state/snapshots"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let saved = fs::read(&path).unwrap();
    let mut monitor = sandbox
        .command("source", "monitor")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(250));
    sandbox.tmux(&["respawn-pane", "-k", "-t", "source", "/bin/sh"]);
    let deadline = std::time::Instant::now() + Duration::from_secs(12);
    let mut empty = false;
    while std::time::Instant::now() < deadline {
        let snapshot: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        if snapshot["windows"][0]["panes"][0]["command_argv"] == serde_json::json!([]) {
            empty = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(empty, "A running monitor records deliberate closures");
    unsafe { libc::kill(monitor.id() as i32, libc::SIGTERM) };
    monitor.wait().unwrap();
    fs::write(&path, &saved).unwrap();
    let mut fresh = sandbox
        .command("source", "monitor")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    for _ in 0..100 {
        if sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "source",
            "#{@window_sidebar_recovery}",
        ]) == "1"
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "source",
            "#{@window_sidebar_recovery}"
        ]),
        "1"
    );
    assert_eq!(
        fs::read(&path).unwrap(),
        saved,
        "A fresh empty shell must not erase the prior recovery snapshot"
    );
    unsafe { libc::kill(fresh.id() as i32, libc::SIGTERM) };
    fresh.wait().unwrap();
}

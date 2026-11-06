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
    fn geometry(&self, target: &str) -> String {
        self.tmux(&[
            "list-panes",
            "-t",
            target,
            "-F",
            "#{pane_id}:#{pane_left}:#{pane_top}:#{pane_width}:#{pane_height}",
        ])
    }
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
fn auto_zoom_dims_only_inactive_content_and_restores_brightness() {
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
    sandbox.start("dim", r"printf '\033[38;2;200;100;50mFIRST'; sleep 120");
    if sandbox.tmux(&["display-message", "-p", "#{>=:#{version},3.8}"]) != "1" {
        eprintln!("SKIP: pane color dimming requires tmux 3.8");
        return;
    }
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    sandbox.tmux(&["set-option", "-as", "terminal-features", ",xterm*:RGB"]);
    success(sandbox.command("dim", "enable").output().unwrap());
    let first = sandbox.tmux(&["display-message", "-p", "-t", "dim:", "#{pane_id}"]);
    let second = sandbox.tmux(&[
        "split-window",
        "-d",
        "-h",
        "-t",
        &first,
        "-P",
        "-F",
        "#{pane_id}",
        r"printf '\033[38;2;200;100;50mSECOND'; sleep 120",
    ]);
    let sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        &first,
        "#{@window_sidebar_pane}",
    ]);
    let mut client = Client::attach(&sandbox, "dim");
    client.expect("SECOND");
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &second,
            "#{?pane_active,#{E:window-active-style},#{E:window-style}}"
        ]),
        "dim=50"
    );
    for pane in [&first, &sidebar] {
        assert_eq!(
            sandbox.tmux(&[
                "display-message",
                "-p",
                "-t",
                pane,
                "#{?pane_active,#{E:window-active-style},#{E:window-style}}"
            ]),
            "default"
        );
    }
    client.drain(Duration::from_millis(30));
    sandbox.tmux(&["refresh-client"]);
    let rendered = String::from_utf8_lossy(&client.drain(Duration::from_millis(100))).into_owned();
    assert!(
        regex::Regex::new(r"38;2;100;50;25m(?:\x1b\[[0-9;]*[A-Za-z])*SECOND")
            .unwrap()
            .is_match(&rendered),
        "Inactive text must use dimmed colors"
    );
    assert!(
        regex::Regex::new(r"38;2;200;100;50m(?:\x1b\[[0-9;]*[A-Za-z])*FIRST")
            .unwrap()
            .is_match(&rendered),
        "Active text must use normal colors"
    );
    sandbox.tmux(&["select-pane", "-t", &second]);
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{?pane_active,#{E:window-active-style},#{E:window-style}}"
        ]),
        "dim=50"
    );
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &second,
            "#{?pane_active,#{E:window-active-style},#{E:window-style}}"
        ]),
        "default"
    );
    client.drain(Duration::from_millis(30));
    sandbox.tmux(&["refresh-client"]);
    let rendered = String::from_utf8_lossy(&client.drain(Duration::from_millis(100))).into_owned();
    assert!(
        regex::Regex::new(r"38;2;100;50;25m(?:\x1b\[[0-9;]*[A-Za-z])*FIRST")
            .unwrap()
            .is_match(&rendered),
        "The previous pane must dim after selection changes"
    );
    assert!(
        regex::Regex::new(r"38;2;200;100;50m(?:\x1b\[[0-9;]*[A-Za-z])*SECOND")
            .unwrap()
            .is_match(&rendered),
        "The selected pane must use normal colors"
    );
    success(
        sandbox
            .command("dim", "focus-toggle")
            .args(["--pane", &second])
            .output()
            .unwrap(),
    );
    for pane in [&first, &second, &sidebar] {
        assert_eq!(
            sandbox.tmux(&[
                "display-message",
                "-p",
                "-t",
                pane,
                "#{?pane_active,#{E:window-active-style},#{E:window-style}}"
            ]),
            "default"
        );
    }
    client.drain(Duration::from_millis(30));
    sandbox.tmux(&["refresh-client"]);
    let rendered = String::from_utf8_lossy(&client.drain(Duration::from_millis(100))).into_owned();
    assert!(!rendered.contains("38;2;100;50;25m"), "{rendered:?}");
    assert!(
        regex::Regex::new(r"38;2;200;100;50m(?:\x1b\[[0-9;]*[A-Za-z])*FIRST")
            .unwrap()
            .is_match(&rendered),
        "Active text must use normal colors"
    );
    sandbox.tmux(&[
        "set-option",
        "-w",
        "-t",
        &first,
        "@window_sidebar_focus_zoom",
        "1",
    ]);
    success(sandbox.command("dim", "toggle").output().unwrap());
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{?pane_active,#{E:window-active-style},#{E:window-style}}"
        ]),
        "default"
    );
}

#[test]
fn focus_zoom_preserves_each_window_layout_and_sidebar_width() {
    let sandbox = Sandbox::new();
    sandbox.start("focus", "sleep 120");
    let first = sandbox.tmux(&["display-message", "-p", "-t", "focus:", "#{pane_id}"]);
    success(sandbox.command("focus", "enable").output().unwrap());
    let sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        &first,
        "#{@window_sidebar_pane}",
    ]);
    let second = sandbox.tmux(&[
        "split-window",
        "-d",
        "-h",
        "-t",
        &first,
        "-P",
        "-F",
        "#{pane_id}",
        "sleep 120",
    ]);
    let original = sandbox.tmux(&["display-message", "-p", "-t", &first, "#{window_layout}"]);
    let original_geometry = sandbox.geometry(&first);
    success(
        sandbox
            .command("focus", "focus")
            .args(["--pane", &first])
            .output()
            .unwrap(),
    );
    assert_eq!(
        sandbox.tmux(&["display-message", "-p", "-t", &sidebar, "#{pane_width}"]),
        "28"
    );
    let width = |pane: &str| {
        sandbox
            .tmux(&["display-message", "-p", "-t", pane, "#{pane_width}"])
            .parse::<u16>()
            .unwrap()
    };
    assert_eq!(width(&first), 77);
    assert!(width(&second) > 0);
    sandbox.tmux(&["select-pane", "-t", &second]);
    success(
        sandbox
            .command("focus", "focus")
            .args(["--pane", &second])
            .output()
            .unwrap(),
    );
    assert_eq!(width(&second), 77);
    assert!(width(&first) > 0);
    let enlarged_snapshot: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("focus", "snapshot").output().unwrap(),
    ))
    .unwrap();
    assert_eq!(enlarged_snapshot["windows"][0]["layout"], original);
    success(
        sandbox
            .command("focus", "focus-toggle")
            .args(["--pane", &second])
            .output()
            .unwrap(),
    );
    assert_eq!(sandbox.geometry(&first), original_geometry);
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{@window_sidebar_focus_zoom}"
        ]),
        "0"
    );
    success(sandbox.command("focus", "new").output().unwrap());
    let fresh = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        "focus:",
        "#{@window_sidebar_focus_zoom}",
    ]);
    assert_ne!(fresh, "0");
    let snapshot: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("focus", "snapshot").output().unwrap(),
    ))
    .unwrap();
    assert_eq!(snapshot["windows"][0]["focus_zoom"], false);
    assert_eq!(snapshot["windows"][1]["focus_zoom"], true);
    sandbox.tmux(&["new-session", "-d", "-s", "keeper", "sleep 120"]);
    sandbox.tmux(&["kill-session", "-t", "focus"]);
    success(
        sandbox
            .command("focus", "restore")
            .args(["--rerun", &first])
            .output()
            .unwrap(),
    );
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "recovered-focus:0",
            "#{@window_sidebar_focus_zoom}"
        ]),
        "0"
    );
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "recovered-focus:1",
            "#{@window_sidebar_focus_zoom}"
        ]),
        "1"
    );
}

#[test]
fn focus_zoom_handles_stacked_and_nested_layouts_without_touching_the_sidebar() {
    for nested in [false, true] {
        let sandbox = Sandbox::new();
        sandbox.start("focus", "sleep 120");
        success(sandbox.command("focus", "enable").output().unwrap());
        let first = sandbox.tmux(&["display-message", "-p", "-t", "focus:", "#{pane_id}"]);
        let sidebar = sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{@window_sidebar_pane}",
        ]);
        sandbox.tmux(&[
            "split-window",
            "-d",
            if nested { "-h" } else { "-v" },
            "-t",
            &first,
            "sleep 120",
        ]);
        if nested {
            sandbox.tmux(&["split-window", "-d", "-v", "-t", &first, "sleep 120"]);
        }
        let original_geometry = sandbox.geometry(&first);
        success(
            sandbox
                .command("focus", "focus")
                .args(["--pane", &first])
                .output()
                .unwrap(),
        );
        assert_eq!(
            sandbox.tmux(&["display-message", "-p", "-t", &sidebar, "#{pane_width}"]),
            "28"
        );
        assert!(
            sandbox
                .tmux(&["display-message", "-p", "-t", &first, "#{pane_height}"])
                .parse::<u16>()
                .unwrap()
                >= 33
        );
        sandbox.tmux(&["resize-pane", "-Z", "-t", &first]);
        success(
            sandbox
                .command("focus", "focus-toggle")
                .args(["--pane", &first])
                .output()
                .unwrap(),
        );
        assert_eq!(
            sandbox.tmux(&[
                "display-message",
                "-p",
                "-t",
                &first,
                "#{window_zoomed_flag}"
            ]),
            "1"
        );
        sandbox.tmux(&["resize-pane", "-Z", "-t", &first]);
        success(
            sandbox
                .command("focus", "focus")
                .args(["--pane", &first])
                .output()
                .unwrap(),
        );
        assert_eq!(sandbox.geometry(&first), original_geometry);
        success(
            sandbox
                .command("focus", "focus-toggle")
                .args(["--pane", &first])
                .output()
                .unwrap(),
        );
        sandbox.tmux(&["resize-window", "-t", &first, "-x", "160"]);
        success(sandbox.command("focus", "ensure").output().unwrap());
        success(
            sandbox
                .command("focus", "focus-toggle")
                .args(["--pane", &first])
                .output()
                .unwrap(),
        );
        assert_eq!(
            sandbox.tmux(&["display-message", "-p", "-t", &sidebar, "#{pane_width}"]),
            "28"
        );
        assert_eq!(
            sandbox.tmux(&["display-message", "-p", "-t", &first, "#{window_width}"]),
            "160"
        );
    }
}

#[test]
fn focus_toggle_is_clickable_and_native_selection_enlarges_content() {
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
    sandbox.start("focus", "sleep 120");
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    sandbox.tmux(&[
        "set-option",
        "-w",
        "-t",
        "focus:",
        "@window_sidebar_focus_zoom",
        "0",
    ]);
    success(sandbox.command("focus", "enable").output().unwrap());
    let first = sandbox.tmux(&["display-message", "-p", "-t", "focus:", "#{pane_id}"]);
    let second = sandbox.tmux(&[
        "split-window",
        "-d",
        "-h",
        "-t",
        &first,
        "-P",
        "-F",
        "#{pane_id}",
        "sleep 120",
    ]);
    let original_geometry = sandbox.geometry(&first);
    let mut client = Client::attach(&sandbox, "focus");
    client.expect("Auto zoom: off");
    client.send(b"\x1b[<0;113;1M\x1b[<0;113;1m");
    client.wait("click enables focus zoom", || {
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{@window_sidebar_focus_zoom}",
        ]) == "1"
    });
    sandbox.tmux(&["select-pane", "-t", &first]);
    client.wait("left pane receives auto zoom", || {
        sandbox.tmux(&["display-message", "-p", "-t", &first, "#{pane_width}"]) == "77"
    });
    let clients = sandbox.tmux(&[
        "list-clients",
        "-t",
        "focus",
        "-F",
        "#{client_name}\t#{client_control_mode}",
    ]);
    let terminal = clients
        .lines()
        .find_map(|row| row.strip_suffix("\t0"))
        .unwrap();
    sandbox.tmux(&["refresh-client", "-t", terminal]);
    client.expect("Zoom:on");
    let mouse_started = std::time::Instant::now();
    client.click(&sandbox, &second, 5, 2, false);
    client.wait("mouse focus enlarges pane", || {
        sandbox
            .tmux(&["display-message", "-p", "-t", &second, "#{pane_width}"])
            .parse::<u16>()
            .unwrap()
            >= 75
    });
    let mouse_latency = mouse_started.elapsed();
    assert!(
        mouse_latency < Duration::from_millis(300),
        "Mouse focus latency: {mouse_latency:?}"
    );
    let started = std::time::Instant::now();
    sandbox.tmux(&["select-pane", "-t", &first]);
    client.wait("native focus enlarges pane", || {
        sandbox
            .tmux(&["display-message", "-p", "-t", &first, "#{pane_width}"])
            .parse::<u16>()
            .unwrap()
            >= 75
    });
    let native_latency = started.elapsed();
    assert!(
        native_latency < Duration::from_millis(300),
        "Focus zoom latency: {:?}",
        started.elapsed()
    );
    client.drain(Duration::from_millis(40));
    client.send(b"\x1b[<0;113;1M\x1b[<0;113;1m");
    client.wait("click restores baseline", || {
        sandbox.geometry(&first) == original_geometry
    });
    client.send(b"\x1b[<0;75;10M\x1b[<32;80;10M\x1b[<0;80;10m");
    client.wait("native border drag resizes panes", || {
        sandbox.tmux(&["display-message", "-p", "-t", &first, "#{pane_width}"]) != "45"
    });
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{@window_sidebar_focus_zoom}"
        ]),
        "0"
    );
    client.drain(Duration::from_millis(40));
    client.send(b"\x1bOP");
    client.expect("Explain status colors");
    client.send(b"a");
    client.wait("menu toggles focus zoom", || {
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &first,
            "#{@window_sidebar_focus_zoom}",
        ]) == "1"
    });
    println!("Mouse focus: {mouse_latency:?}; native selection: {native_latency:?}");
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
fn wrapped_agent_recovery_preserves_launcher_model_and_profile() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let bin = sandbox.root.join("bin");
    fs::create_dir(&bin).unwrap();
    fs::copy(worker, bin.join("claude")).unwrap();
    success(
        Command::new("rustc")
            .args(["--edition=2024", "tests/fixtures/launcher.rs", "-o"])
            .arg(bin.join("relay"))
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .output()
            .unwrap(),
    );
    let marker = sandbox.root.join("resumed-wrapper");
    let child_pid = sandbox.root.join("child-pid");
    let profile = sandbox.root.join("wrapped profile");
    fs::create_dir(&profile).unwrap();
    sandbox.start("source", &format!("env CLAUDE_CONFIG_DIR={} TEST_WORKER_OUTPUT={} TEST_CHILD_PID={} {} launch claude --model test-model -- --resume original-session --effort high", quote(profile.to_str().unwrap()), quote(marker.to_str().unwrap()), quote(child_pid.to_str().unwrap()), quote(bin.join("relay").to_str().unwrap())));
    sandbox.tmux(&["new-session", "-d", "-s", "keep", "sleep 120"]);
    wait_for_file(&marker);
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{pane_id}"]);
    wait_for_file(&child_pid);
    let pid: u32 = fs::read_to_string(&child_pid).unwrap().parse().unwrap();
    append_event(
        &event_file(&sandbox),
        serde_json::json!({"event":"Stop","session":"saved-wrapper","agent":"claude","agent_pid":pid,"tmux":pane,"ts":1}),
    );
    let snapshot: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("source", "snapshot").output().unwrap(),
    ))
    .unwrap();
    let agent = &snapshot["windows"][0]["panes"][0]["agent"];
    assert_eq!(
        agent["launch"]["launcher"][0],
        bin.join("relay").to_str().unwrap()
    );
    assert_eq!(agent["launch"]["model"], "test-model");
    assert_eq!(agent["profile"], profile.to_str().unwrap());
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
    sandbox.tmux(&[
        "set-environment",
        "-g",
        "TEST_CHILD_PID",
        child_pid.to_str().unwrap(),
    ]);
    let snapshot_path = fs::read_dir(sandbox.root.join("state/snapshots"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let mut legacy = snapshot;
    legacy["windows"][0]["panes"][0]["agent"]["launch"]
        .as_object_mut()
        .unwrap()
        .remove("launcher");
    fs::write(snapshot_path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    sandbox.tmux(&["kill-session", "-t", "source"]);
    fs::remove_file(&marker).unwrap();
    let mut restore = sandbox.command("source", "restore");
    restore.env(
        "PATH",
        format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
    );
    assert_eq!(success(restore.output().unwrap()), "recovered-source");
    wait_for_file(&marker);
    let launched = fs::read_to_string(marker).unwrap();
    assert!(launched.contains("--model\0test-model\0--resume\0saved-wrapper\0--effort\0high\0"));
    assert!(launched.ends_with(profile.to_str().unwrap()));
    assert!(!launched.contains("original-session"));
    assert_eq!(
        launched
            .split('\0')
            .filter(|argument| *argument == "--resume")
            .count(),
        1
    );
}

#[test]
fn codex_recovery_preserves_no_daemon() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let bin = sandbox.root.join("bin");
    fs::create_dir(&bin).unwrap();
    fs::copy(worker, bin.join("codex")).unwrap();
    let marker = sandbox.root.join("resumed-codex");
    sandbox.start(
        "source",
        &format!(
            "env TEST_WORKER_OUTPUT={} {} --no-daemon resume saved-codex",
            quote(marker.to_str().unwrap()),
            quote(bin.join("codex").to_str().unwrap())
        ),
    );
    sandbox.tmux(&["new-session", "-d", "-s", "keep", "sleep 120"]);
    wait_for_file(&marker);
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "source", "#{pane_id}"]);
    let pid: u32 = sandbox
        .tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
        .parse()
        .unwrap();
    append_event(
        &event_file(&sandbox),
        serde_json::json!({"event":"Stop","session":"saved-codex","agent":"codex","agent_pid":pid,"tmux":pane,"ts":1}),
    );
    let snapshot: serde_json::Value = serde_json::from_str(&success(
        sandbox.command("source", "snapshot").output().unwrap(),
    ))
    .unwrap();
    assert_eq!(
        snapshot["windows"][0]["panes"][0]["agent"]["launch"]["no_daemon"],
        true
    );
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
    sandbox.tmux(&["kill-session", "-t", "source"]);
    fs::remove_file(&marker).unwrap();
    let mut restore = sandbox.command("source", "restore");
    restore.env(
        "PATH",
        format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
    );
    assert_eq!(success(restore.output().unwrap()), "recovered-source");
    wait_for_file(&marker);
    let launched = fs::read_to_string(marker).unwrap();
    assert!(launched.contains("--no-daemon\0resume\0saved-codex\0"));
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
        "env CLAUDE_CONFIG_DIR={} TEST_WORKER_OUTPUT={} {} --resume conversation-123 --model test-model --effort high",
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
    assert_eq!(
        snapshot["windows"][0]["panes"][0]["agent"]["launch"]["model"],
        "test-model"
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
    assert!(launched.contains("--resume\0conversation-123\0--model\0test-model\0--effort\0high\0"));
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

#[test]
fn shared_sidebars_keep_mouse_keyboard_new_windows_and_service_recovery() {
    let sandbox = Sandbox::new();
    success(
        Command::new(binary())
            .args([
                "install",
                "--shared",
                "--home",
                sandbox.root.to_str().unwrap(),
                "--apply",
            ])
            .output()
            .unwrap(),
    );
    sandbox.start("shared", "sleep 120");
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    let first = sandbox.tmux(&["display-message", "-p", "-t", "shared:", "#{pane_id}"]);
    sandbox.tmux(&[
        "set-option",
        "-p",
        "-t",
        &first,
        "@window_sidebar_label",
        "First content",
    ]);
    success(sandbox.command("shared", "enable").output().unwrap());
    let second = sandbox.tmux(&[
        "new-window",
        "-d",
        "-t",
        "shared:",
        "-P",
        "-F",
        "#{pane_id}",
        "sleep 120",
    ]);
    sandbox.tmux(&[
        "set-option",
        "-p",
        "-t",
        &second,
        "@window_sidebar_label",
        "Second content",
    ]);
    let mut client = Client::attach(&sandbox, "shared");
    client.drain(Duration::from_millis(200));
    let sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        &first,
        "#{@window_sidebar_pane}",
    ]);
    client.wait("shared renderer draws both windows", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains("Second content")
    });
    let capture = sandbox.tmux(&["capture-pane", "-p", "-t", &sidebar]);
    let row = capture
        .lines()
        .position(|line| line.contains("Second content"))
        .unwrap() as u16;
    client.click(&sandbox, &sidebar, 5, row, false);
    client.wait("shared sidebar click selects another window", || {
        sandbox.tmux(&["display-message", "-p", "-t", "shared:", "#{pane_id}"]) == second
    });
    let next_sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        &second,
        "#{@window_sidebar_pane}",
    ]);
    assert_eq!(
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &next_sidebar,
            "#{@shared_sidebar}"
        ]),
        "1"
    );
    assert!(matches!(
        sandbox
            .tmux(&["display-message", "-p", "-t", &next_sidebar, "#{pane_pid}"])
            .as_str(),
        "" | "0"
    ));
    sandbox.tmux(&["select-pane", "-t", &next_sidebar]);
    client.send(b"\x1b[A\r");
    client.wait("shared sidebar keyboard selects first content", || {
        sandbox.tmux(&["display-message", "-p", "-t", "shared:", "#{pane_id}"]) == first
    });
    sandbox.tmux(&["select-pane", "-t", &sidebar]);
    client.click(&sandbox, &first, 5, 10, false);
    client.wait("ordinary content clicks keep their binding", || {
        sandbox.tmux(&["display-message", "-p", "-t", "shared:", "#{pane_id}"]) == first
    });
    let pid = sandbox.tmux(&["show-option", "-sqv", "@window_sidebar_service_pid"]);
    assert!(!pid.is_empty());
    unsafe {
        libc::kill(pid.parse().unwrap(), libc::SIGTERM);
    }
    std::thread::sleep(Duration::from_millis(100));
    success(sandbox.command("shared", "ensure").output().unwrap());
    client.wait("shared service restarts", || {
        let current = sandbox.tmux(&["show-option", "-sqv", "@window_sidebar_service_pid"]);
        !current.is_empty() && current != pid
    });
    client.wait("shared sidebar redraws after service restart", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains("Second content")
    });
    let service = sandbox.tmux(&["show-option", "-sqv", "@window_sidebar_service_pid"]);
    sandbox.tmux(&["new-session", "-d", "-s", "other", "sleep 120"]);
    success(sandbox.command("other", "enable").output().unwrap());
    let mut other = Client::attach(&sandbox, "other");
    let other_sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        "other:",
        "#{@window_sidebar_pane}",
    ]);
    other.wait("another session shares the service", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &other_sidebar])
            .contains("+ New")
    });
    assert_eq!(
        service,
        sandbox.tmux(&["show-option", "-sqv", "@window_sidebar_service_pid"])
    );
    assert!(
        !sandbox
            .tmux(&["capture-pane", "-p", "-t", &other_sidebar])
            .contains("First content")
    );
    for shared in [true, false] {
        let before = sandbox
            .tmux(&[
                "list-panes",
                "-a",
                "-F",
                "#{pane_id} #{pane_pid} #{@window_sidebar}",
            ])
            .lines()
            .filter(|line| line.ends_with(' '))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let mut installer = Command::new(binary());
        installer.args([
            "install",
            "--home",
            sandbox.root.to_str().unwrap(),
            "--apply",
            "--restart",
            "--socket",
            sandbox.socket.to_str().unwrap(),
        ]);
        installer
            .env("HOME", &sandbox.root)
            .env("TMUX_SIDEBAR_STATE_DIR", sandbox.root.join("state"))
            .env("AGENT_STAT_DIR", sandbox.root.join("events"));
        if shared {
            installer.arg("--shared");
        }
        success(installer.output().unwrap());
        let after = sandbox
            .tmux(&[
                "list-panes",
                "-a",
                "-F",
                "#{pane_id} #{pane_pid} #{@window_sidebar}",
            ])
            .lines()
            .filter(|line| line.ends_with(' '))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        assert_eq!(before, after);
        assert_eq!(
            sandbox.tmux(&["show-option", "-gqv", "@window_sidebar_shared"]),
            if shared { "1" } else { "0" }
        );
    }
}
impl Client {
    fn attach(sandbox: &Sandbox, session: &str) -> Self {
        Self::open(sandbox, &["attach-session", "-t", session])
    }
    fn open(sandbox: &Sandbox, arguments: &[&str]) -> Self {
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
            .args(arguments)
            .env("TERM", "xterm-256color")
            .env("HOME", &sandbox.root)
            .env("AGENT_STAT_DIR", sandbox.root.join("events"))
            .env("TMUX_SIDEBAR_STATE_DIR", sandbox.root.join("state"))
            .current_dir(&sandbox.root)
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
fn inactive_windows_resize_before_selection_with_fixed_sidebars() {
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
    sandbox.start("static", "sleep 120");
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    let second = sandbox.tmux(&[
        "new-window",
        "-d",
        "-t",
        "static:",
        "-P",
        "-F",
        "#{window_id}",
        "sleep 120",
    ]);
    success(sandbox.command("static", "enable").output().unwrap());
    let original = sandbox.tmux(&[
        "list-panes",
        "-s",
        "-t",
        "static",
        "-F",
        "#{pane_id}:#{pane_pid}",
    ]);
    let mut client = Client::attach(&sandbox, "static");
    client.drain(Duration::from_millis(150));
    client.resize(160);
    client.wait("inactive windows already match the attached client", || {
        sandbox
            .tmux(&["list-windows", "-t", "static", "-F", "#{window_width}"])
            .lines()
            .all(|width| width == "160")
    });
    client.wait("all sidebar widths settle before selection", || {
        sandbox
            .tmux(&[
                "list-panes",
                "-s",
                "-t",
                "static",
                "-F",
                "#{@window_sidebar}:#{pane_width}",
            ])
            .lines()
            .filter(|line| line.starts_with("1:"))
            .all(|line| line == "1:28")
    });
    let before = sandbox.tmux(&[
        "list-panes",
        "-t",
        &second,
        "-F",
        "#{pane_id}:#{pane_width}:#{pane_height}",
    ]);
    sandbox.tmux(&["select-window", "-t", &second]);
    assert_eq!(
        sandbox.tmux(&[
            "list-panes",
            "-t",
            &second,
            "-F",
            "#{pane_id}:#{pane_width}:#{pane_height}"
        ]),
        before
    );
    assert_eq!(
        sandbox.tmux(&[
            "list-panes",
            "-s",
            "-t",
            "static",
            "-F",
            "#{pane_id}:#{pane_pid}"
        ]),
        original
    );
}

#[test]
fn default_shell_starts_after_the_sidebar_layout_is_ready() {
    use std::os::unix::fs::PermissionsExt;
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
    let marker = sandbox.root.join("shell-size");
    let shell = sandbox.root.join("shell");
    fs::write(&shell, format!("#!/bin/sh\nif [ \"$1\" = -c ]; then exec /bin/sh \"$@\"; fi\nstty size > {}\nprintf 'ONE_PROMPT\\n'\nexec /bin/sh\n", quote(marker.to_str().unwrap()))).unwrap();
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
    let config = sandbox.root.join(".tmux.conf");
    let previous = fs::read_to_string(&config).unwrap();
    fs::write(
        &config,
        format!(
            "set-option -g default-shell {}\n{previous}",
            quote(shell.to_str().unwrap())
        ),
    )
    .unwrap();
    let mut client = Client::open(&sandbox, &["-f", config.to_str().unwrap()]);
    client.expect("ONE_PROMPT");
    wait_for_file(&marker);
    client.wait("sidebar startup layout", || {
        let output = Command::new("tmux")
            .arg("-S")
            .arg(&sandbox.socket)
            .args(["list-panes", "-t", "0:", "-F", "#{@window_sidebar}"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|role| role == "1")
    });
    assert_eq!(
        fs::read_to_string(&marker).unwrap().trim(),
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "0:",
            "#{pane_height} #{pane_width}"
        ])
    );
    fs::remove_file(&marker).unwrap();
    sandbox.tmux(&["new-window", "-t", "0:"]);
    client.wait("new shell records its initial size", || {
        fs::metadata(&marker).is_ok_and(|file| file.len() > 0)
    });
    assert_eq!(
        fs::read_to_string(&marker).unwrap().trim(),
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "0:",
            "#{pane_height} #{pane_width}"
        ])
    );
    fs::remove_file(&marker).unwrap();
    let split = sandbox.tmux(&["split-window", "-h", "-t", "0:", "-P", "-F", "#{pane_id}"]);
    client.wait("split shell records its initial size", || {
        fs::metadata(&marker).is_ok_and(|file| file.len() > 0)
    });
    client.drain(Duration::from_millis(120));
    assert_eq!(
        fs::read_to_string(&marker).unwrap().trim(),
        sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            &split,
            "#{pane_height} #{pane_width}"
        ])
    );
}

#[test]
fn custom_default_command_survives_sidebar_configuration() {
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
    sandbox.start("custom", "sleep 120");
    let command = "printf 'CUSTOM_COMMAND\\n'; sleep 120";
    sandbox.tmux(&["set-option", "-g", "default-command", command]);
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    assert_eq!(
        sandbox.tmux(&["show-option", "-gqv", "default-command"]),
        command
    );
    let pane = sandbox.tmux(&["new-window", "-t", "custom:", "-P", "-F", "#{pane_id}"]);
    let mut client = Client::attach(&sandbox, "custom");
    client.wait("custom default command runs", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &pane])
            .contains("CUSTOM_COMMAND")
    });
}

#[test]
fn plain_tmux_and_new_attached_sessions_open_one_sidebar() {
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
    let config = sandbox.root.join(".tmux.conf");
    let previous = fs::read_to_string(&config).unwrap();
    fs::write(
        &config,
        format!("set-option -g default-shell /bin/sh\n{previous}"),
    )
    .unwrap();
    let has_sidebar = |session: &str| {
        let output = Command::new("tmux")
            .arg("-S")
            .arg(&sandbox.socket)
            .args(["list-panes", "-t", session, "-F", "#{@window_sidebar}"])
            .output()
            .unwrap();
        output.status.success()
            && String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter(|role| *role == "1")
                .count()
                == 1
    };
    let mut first = Client::open(&sandbox, &["-f", config.to_str().unwrap()]);
    first.wait("sidebar after plain tmux starts its first server", || {
        has_sidebar("0:")
    });
    assert_eq!(
        sandbox.tmux(&["display-message", "-p", "-t", "0:", "#{@window_sidebar}"]),
        ""
    );
    drop(first);
    let mut next = Client::open(&sandbox, &["new-session", "-s", "fresh", "sleep 120"]);
    next.wait("sidebar after an attached new-session", || {
        has_sidebar("fresh:")
    });
    success(sandbox.command("fresh", "toggle").output().unwrap());
    drop(next);
    let mut reattached = Client::attach(&sandbox, "fresh");
    reattached.drain(Duration::from_millis(150));
    assert_eq!(
        sandbox.tmux(&["list-panes", "-t", "fresh:", "-F", "#{@window_sidebar}"]),
        ""
    );
    assert_eq!(
        sandbox.tmux(&[
            "show-option",
            "-v",
            "-t",
            "fresh",
            "@window_sidebar_enabled"
        ]),
        "0"
    );
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
                client.send(if route == "pane-menu" { b"p" } else { b"w" });
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
    terminal_controls(false);
}

#[test]
fn shared_terminal_keeps_menus_search_repeated_clicks_and_overlays() {
    terminal_controls(true);
}

fn terminal_controls(shared: bool) {
    let sandbox = Sandbox::new();
    let mut installer = Command::new(binary());
    installer.args([
        "install",
        "--home",
        sandbox.root.to_str().unwrap(),
        "--apply",
    ]);
    if shared {
        installer.arg("--shared");
    }
    success(installer.output().unwrap());
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
    let mut enable = sandbox.command("0", "enable");
    if shared {
        enable.env("TMUX", format!("{},1,0", sandbox.socket.display()));
        enable.env("TMUX_PANE", &content);
    }
    success(enable.output().unwrap());
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
    client.expect("View full command");
    client.send(b"\x1b");
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
    client.click(&sandbox, &sidebar, 1, row as u16, false);
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
    client.click(&sandbox, &sidebar, 1, row as u16, false);
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
    client.send(b"\x1b[H");
    for _ in 0..7 {
        client.send(b"\x1b[B");
    }
    client.send(b"\r");
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
fn recovery_preview_saves_and_refreshes_all_windows() {
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
    sandbox.start("source", "/bin/sh");
    sandbox.tmux(&["rename-window", "-t", "source:0", "first-saved-window"]);
    sandbox.tmux(&["set-option", "-g", "allow-rename", "off"]);
    sandbox.tmux(&["set-option", "-g", "automatic-rename", "off"]);
    sandbox.tmux(&[
        "source-file",
        sandbox
            .root
            .join(".config/tmux/window-sidebar.conf")
            .to_str()
            .unwrap(),
    ]);
    success(sandbox.command("source", "enable").output().unwrap());
    let mut client = Client::attach(&sandbox, "source");
    client.drain(Duration::from_millis(800));
    client.send(b"\x02r");
    client.expect("No saved recovery snapshot");
    client.send(b"\0");
    client.expect("Saving replaces the latest snapshot");
    client.send(b"s");
    client.expect("Snapshot saved.");
    client.send(b"\0");
    client.expect("Source session: source");
    client.send(b"\0");
    client.expect("Restore into: recovered-source");
    client.send(b"\0");
    client.expect("Window 0: first-saved-window");
    sandbox.tmux(&[
        "new-window",
        "-d",
        "-t",
        "source:1",
        "-n",
        "second-saved-window",
        "/bin/sh",
    ]);
    client.send(b"s");
    client.expect("Window 1: second-saved-window");
    let snapshot = fs::read_dir(sandbox.root.join("state/snapshots"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let saved: serde_json::Value = serde_json::from_slice(&fs::read(snapshot).unwrap()).unwrap();
    assert_eq!(saved["windows"].as_array().unwrap().len(), 2);
    assert_eq!(saved["windows"][1]["name"], "second-saved-window");
    assert_eq!(
        sandbox.tmux(&["list-sessions", "-F", "#{session_name}"]),
        "source"
    );
    client.send(b"\x1b");
}

#[test]
fn native_recovery_preview_cancels_fast_and_restores_all_commands() {
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let marker = sandbox.root.join("replayed");
    let second_marker = sandbox.root.join("replayed-second");
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
    let second = sandbox.tmux(&[
        "split-window",
        "-d",
        "-h",
        "-t",
        &content,
        "-P",
        "-F",
        "#{pane_id}",
        &format!(
            "{} {} 'second command'",
            quote(worker.to_str().unwrap()),
            quote(second_marker.to_str().unwrap())
        ),
    ]);
    wait_for_file(&second_marker);
    success(sandbox.command("source", "snapshot").output().unwrap());
    sandbox.tmux(&["respawn-pane", "-k", "-t", &content, "sleep 120"]);
    fs::remove_file(&marker).unwrap();
    sandbox.tmux(&["respawn-pane", "-k", "-t", &second, "sleep 120"]);
    fs::remove_file(&second_marker).unwrap();
    let mut client = Client::attach(&sandbox, "source");
    client.wait("sidebar frame", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains("+ New")
    });
    // This PTY has no terminal emulator to answer tmux's startup capability queries.
    client.drain(Duration::from_millis(800));
    client.send(b"\x1bOP");
    client.expect("Recover saved work");
    client.send(b"r");
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
    client.expect("[r] Restore all");
    assert!(!second_marker.exists());
    client.send(b"r");
    client.wait("all saved commands rerun", || {
        marker.exists() && second_marker.exists()
    });
    assert!(
        fs::read_to_string(&second_marker)
            .unwrap()
            .contains("second command\0")
    );
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
fn server_restart_keeps_recovery_while_the_startup_helper_runs() {
    use std::os::fd::AsRawFd;
    let sandbox = Sandbox::new();
    let worker = worker(&sandbox.root);
    let marker = sandbox.root.join("worker-output");
    sandbox.start(
        "restart",
        &format!(
            "{} {}",
            quote(worker.to_str().unwrap()),
            quote(marker.to_str().unwrap())
        ),
    );
    wait_for_file(&marker);
    success(sandbox.command("restart", "snapshot").output().unwrap());
    let snapshot = fs::read_dir(sandbox.root.join("state/snapshots"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let saved = fs::read(&snapshot).unwrap();
    sandbox.tmux(&["kill-server"]);
    sandbox.start("restart", "/bin/sh");
    sandbox.tmux(&["set-option", "-g", "@window_sidebar_enabled", "1"]);
    let lock = fs::File::create(sandbox.root.join("state/layout.lock")).unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "restart:", "#{pane_id}"]);
    let helper = format!(
        "{} --socket {} --session restart --pane {} shell",
        quote(binary()),
        quote(sandbox.socket.to_str().unwrap()),
        pane
    );
    sandbox.tmux(&["respawn-pane", "-k", "-t", &pane, &helper]);
    let mut monitor = sandbox
        .command("restart", "monitor")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(4);
    let mut available = String::new();
    while available.is_empty() && std::time::Instant::now() < deadline {
        available = sandbox.tmux(&[
            "display-message",
            "-p",
            "-t",
            "restart:",
            "#{@window_sidebar_recovery}",
        ]);
        std::thread::sleep(Duration::from_millis(20));
    }
    unsafe { libc::kill(monitor.id() as i32, libc::SIGTERM) };
    monitor.wait().unwrap();
    assert_eq!(
        fs::read(&snapshot).unwrap(),
        saved,
        "The startup helper must not replace saved work"
    );
    assert_eq!(available, "1");
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
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

#[test]
fn monitor_uses_control_connection_instead_of_idle_process_polls() {
    monitor_polling(true);
}

#[test]
fn monitor_retains_polling_if_the_control_observer_fails() {
    monitor_polling(false);
}

fn monitor_polling(control: bool) {
    use std::os::unix::fs::PermissionsExt;
    let sandbox = Sandbox::new();
    sandbox.start("monitor", "sleep 120");
    let real_tmux = success(Command::new("which").arg("tmux").output().unwrap());
    let bin = sandbox.root.join("bin");
    fs::create_dir(&bin).unwrap();
    let log = sandbox.root.join("polls");
    fs::write(&log, "").unwrap();
    let wrapper = bin.join("tmux");
    let fail_control = if control {
        ""
    } else {
        "if [ \"$3\" = -C ]; then exit 1; fi\n"
    };
    fs::write(&wrapper, format!("#!/bin/sh\n{fail_control}if [ \"$3\" = has-session ]; then printf 'poll\\n' >> {}; fi\nexec {} \"$@\"\n", quote(log.to_str().unwrap()), quote(&real_tmux))).unwrap();
    fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
    let mut monitor = sandbox
        .command("monitor", "monitor")
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(500));
    fs::write(&log, "").unwrap();
    std::thread::sleep(Duration::from_millis(1200));
    let polls = fs::read_to_string(&log).unwrap().lines().count();
    if control {
        assert!(polls <= 3, "Idle process polls: {polls}");
    } else {
        assert!(polls >= 3, "Missing fallback polls: {polls}");
    }
    sandbox.tmux(&["kill-session", "-t", "monitor"]);
    let deadline = std::time::Instant::now() + Duration::from_secs(1);
    while monitor.try_wait().unwrap().is_none() {
        assert!(
            std::time::Instant::now() < deadline,
            "Monitor did not exit after session closure"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn targeted_shared_scans_keep_status_identity_and_refresh_attention() {
    let sandbox = Sandbox::new();
    sandbox.start("status", "sleep 120");
    sandbox.tmux(&["set-option", "-g", "@window_sidebar_shared", "1"]);
    let pane = sandbox.tmux(&["display-message", "-p", "-t", "status:", "#{pane_id}"]);
    let pid: u32 = sandbox
        .tmux(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
        .parse()
        .unwrap();
    let started = success(
        Command::new("/bin/ps")
            .args(["-p", &pid.to_string(), "-o", "lstart="])
            .output()
            .unwrap(),
    );
    let path = event_file(&sandbox);
    append_event(
        &path,
        serde_json::json!({"event":"SessionStart","session":"identity","agent":"claude","agent_pid":pid,"agent_start":started,"tmux":pane,"ts":1}),
    );
    success(sandbox.command("status", "enable").output().unwrap());
    let sidebar = sandbox.tmux(&[
        "display-message",
        "-p",
        "-t",
        &pane,
        "#{@window_sidebar_pane}",
    ]);
    let mut client = Client::attach(&sandbox, "status");
    client.wait("targeted scan decorates the real process", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains('●')
    });
    append_event(
        &path,
        serde_json::json!({"event":"SessionStart","session":"identity","agent_pid":pid,"agent_start":"wrong identity","tmux":pane,"ts":2}),
    );
    client.wait("a stale process identity loses its status", || {
        !sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains('●')
    });
    sandbox.tmux(&["new-window", "-t", "status:", "sleep 120"]);
    append_event(
        &path,
        serde_json::json!({"event":"PermissionRequest","session":"identity","agent_pid":pid,"agent_start":started,"tmux":pane,"ts":3}),
    );
    client.wait("changed attention redraws an existing shared frame", || {
        sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains('*')
    });
    sandbox.tmux(&["respawn-pane", "-k", "-t", &pane, "sleep 120"]);
    client.wait("an exited process loses its status", || {
        !sandbox
            .tmux(&["capture-pane", "-p", "-t", &sidebar])
            .contains('●')
    });
}

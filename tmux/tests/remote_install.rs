use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output},
};

/// The other end of ssh runs here, in a home of its own and with no inherited
/// environment, the way a login on another machine starts. Its login profile
/// puts a fake tmux first on the path. A command that skips the login shell
/// misses it, which is the failure the remote install must avoid: a Mac with
/// Homebrew has no tmux on the plain ssh path.
const FAKE_SSH: &str = r#"#!/bin/sh
printf '%s\n' "$@" > "$FAKE_HOME/ssh-args"
exec env -i HOME="$FAKE_HOME" SHELL=/bin/zsh PATH=/usr/bin:/bin TMPDIR="$FAKE_HOME/tmp/" /bin/zsh -c "$3"
"#;

const FAKE_TMUX: &str = r#"#!/bin/sh
printf '%s\n' "$*" >> "$HOME/tmux-calls"
exit 1
"#;

struct Remote {
    root: PathBuf,
    home: PathBuf,
}

impl Remote {
    fn new(name: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("remote-install-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let home = root.join("home");
        for directory in [root.join("tools"), home.join("bin"), home.join("tmp")] {
            fs::create_dir_all(directory).unwrap();
        }
        script(&root.join("tools/ssh"), FAKE_SSH);
        script(&home.join("bin/tmux"), FAKE_TMUX);
        fs::write(home.join(".zprofile"), "export PATH=\"$HOME/bin:$PATH\"\n").unwrap();
        Self { root, home }
    }

    fn install(&self, arguments: &[&str]) -> Output {
        let path = format!(
            "{}:{}",
            self.root.join("tools").display(),
            std::env::var("PATH").unwrap()
        );
        Command::new(env!("CARGO_BIN_EXE_agent-stat-tmux"))
            .arg("install")
            .args(arguments)
            .env("PATH", path)
            .env("FAKE_HOME", &self.home)
            .output()
            .unwrap()
    }

    fn ssh_called(&self) -> bool {
        self.home.join("ssh-args").exists()
    }
}

impl Drop for Remote {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn script(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn stdout(output: &Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).into_owned()
}

#[test]
fn remote_dry_run_writes_nothing_there() {
    let remote = Remote::new("dry");
    let text = stdout(&remote.install(&["--remote", "peer", "--shared"]));
    assert!(text.contains("Dry run"), "{text}");
    let arguments = fs::read_to_string(remote.home.join("ssh-args")).unwrap();
    assert_eq!(
        arguments.lines().take(2).collect::<Vec<_>>(),
        ["-T", "peer"]
    );
    assert!(!remote.home.join(".agents").exists());
    assert_eq!(
        fs::read_dir(remote.home.join("tmp")).unwrap().count(),
        0,
        "the copy is removed"
    );
}

#[test]
fn remote_apply_installs_this_binary_through_the_login_shell() {
    let remote = Remote::new("apply");
    stdout(&remote.install(&["--remote", "peer", "--shared", "--apply"]));
    let installed = fs::read(remote.home.join(".agents/tmux/agent-stat-tmux")).unwrap();
    assert_eq!(
        installed,
        fs::read(env!("CARGO_BIN_EXE_agent-stat-tmux")).unwrap()
    );
    let config = fs::read_to_string(remote.home.join(".config/tmux/window-sidebar.conf")).unwrap();
    assert!(
        config.contains(
            &remote
                .home
                .join(".agents/tmux/agent-stat-tmux")
                .display()
                .to_string()
        )
    );
    let calls = fs::read_to_string(remote.home.join("tmux-calls")).unwrap_or_default();
    assert!(
        calls.contains("display-message"),
        "the installer found tmux on the login path: {calls:?}"
    );
    assert_eq!(
        fs::read_dir(remote.home.join("tmp")).unwrap().count(),
        0,
        "the copy is removed"
    );
}

#[test]
fn remote_refuses_an_option_for_a_host_and_local_paths() {
    let remote = Remote::new("refuse");
    assert!(
        !remote
            .install(&["--remote", "-oProxyCommand=true"])
            .status
            .success()
    );
    assert!(
        !remote
            .install(&["--remote", "peer", "--home", "/tmp"])
            .status
            .success()
    );
    assert!(!remote.install(&["--remote"]).status.success());
    assert!(!remote.ssh_called());
}

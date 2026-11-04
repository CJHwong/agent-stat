use crate::{Options, model};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub fn home() -> io::Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("HOME is unset"))
}
pub fn state_root() -> io::Result<PathBuf> {
    Ok(env::var_os("TMUX_SIDEBAR_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or(home()?.join(".local/state/tmux-sidebar")))
}
pub fn stamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}
pub fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}
pub fn shell(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|arg| quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}
pub fn command(options: &Options, action: &str, pane: Option<&str>) -> io::Result<String> {
    let mut args = vec![
        env::current_exe()?.to_string_lossy().into_owned(),
        "--socket".into(),
        options.socket.clone(),
        "--session".into(),
        options.session.clone(),
    ];
    if let Some(client) = &options.client {
        args.extend(["--client".into(), client.clone()]);
    }
    if let Some(pane) = pane {
        args.extend(["--pane".into(), pane.into()]);
    }
    args.push(action.into());
    Ok(shell(&args))
}
pub fn call(options: &Options, args: Vec<String>) -> io::Result<String> {
    model::tmux(
        &options.socket,
        &args.iter().map(String::as_str).collect::<Vec<_>>(),
    )
}
pub fn exists(options: &Options) -> bool {
    std::process::Command::new("tmux")
        .args(["-S", &options.socket, "has-session", "-t", &options.session])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}
pub fn canonical(options: &Options) -> io::Result<String> {
    if !options.session.starts_with('$') {
        return Ok(options.session.clone());
    }
    model::tmux(
        &options.socket,
        &[
            "display-message",
            "-p",
            "-t",
            &options.session,
            "#{session_name}",
        ],
    )
}
pub fn private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}
pub fn atomic_write(path: &Path, contents: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("Missing parent directory"))?;
    private_dir(parent)?;
    let temporary = parent.join(format!(".tmp-{}-{}", std::process::id(), stamp()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(contents)?;
    file.sync_all()?;
    fs::rename(temporary, path)
}
pub fn lock(path: &Path, nonblocking: bool) -> io::Result<Option<File>> {
    if let Some(parent) = path.parent() {
        private_dir(parent)?;
    }
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    let operation = libc::LOCK_EX | if nonblocking { libc::LOCK_NB } else { 0 };
    // The descriptor stays owned by File until the lock leaves scope.
    if unsafe { libc::flock(file.as_raw_fd(), operation) } == 0 {
        return Ok(Some(file));
    }
    let error = io::Error::last_os_error();
    if nonblocking && error.kind() == io::ErrorKind::WouldBlock {
        return Ok(None);
    }
    Err(error)
}

pub fn log(message: &str) {
    let result = (|| -> io::Result<()> {
        let root = state_root()?;
        private_dir(&root)?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(root.join("sidebar.log"))?;
        writeln!(file, "{} {message}", stamp())
    })();
    if let Err(error) = result {
        eprintln!("Cannot write sidebar log: {error}");
    }
}

pub fn client(options: &Options, window: &str) -> io::Result<String> {
    if let Some(client) = &options.client {
        return Ok(client.clone());
    }
    let rows = model::tmux(
        &options.socket,
        &[
            "list-clients",
            "-t",
            &options.session,
            "-F",
            "#{client_name}\t#{client_control_mode}\t#{window_id}",
        ],
    )?;
    let clients = rows
        .lines()
        .map(|line| line.split('\t').collect::<Vec<_>>())
        .filter(|fields| fields.len() == 3 && fields[1] == "0")
        .collect::<Vec<_>>();
    clients
        .iter()
        .find(|fields| fields[2] == window)
        .or(clients.first())
        .map(|fields| fields[0].into())
        .ok_or_else(|| io::Error::other("No attached terminal client"))
}

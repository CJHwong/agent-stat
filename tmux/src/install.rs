use crate::{Options, commands, model, runtime as rt};
use std::{
    collections::{HashMap, HashSet},
    env, fs, io,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Duration,
};

const LEGACY: &[&str] = &[
    "window-sidebar.py",
    "sidebar_agents.py",
    "agent_stat_reader.py",
    "sidebar_views.py",
    "process_commands.py",
    "switch_renderer.py",
    "agent-stat-tmux-prototype",
];
fn backup(home: &Path, path: &Path, root: &Path) -> io::Result<()> {
    if !path.is_file() {
        return Ok(());
    }
    let target = root.join(path.strip_prefix(home).map_err(io::Error::other)?);
    rt::private_dir(
        target
            .parent()
            .ok_or_else(|| io::Error::other("Missing backup parent"))?,
    )?;
    fs::copy(path, &target)?;
    fs::set_permissions(target, fs::Permissions::from_mode(0o600))
}
pub fn run() -> io::Result<()> {
    let mut home = rt::home()?;
    let mut apply = false;
    let mut reload = false;
    let mut restart = false;
    let mut shared = false;
    let mut socket = None;
    let mut arguments = env::args().skip(2);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--home" => {
                home = PathBuf::from(
                    arguments
                        .next()
                        .ok_or_else(|| io::Error::other("Missing home directory"))?,
                )
            }
            "--socket" => socket = arguments.next(),
            "--apply" => apply = true,
            "--reload" => reload = true,
            "--shared" => shared = true,
            "--restart" => {
                restart = true;
                reload = true;
            }
            _ => {
                return Err(io::Error::other(format!(
                    "Unknown install option: {argument}"
                )));
            }
        }
    }
    if !home.is_absolute() {
        home = env::current_dir()?.join(home);
    }
    let destination = home.join(".agents/tmux/agent-stat-tmux");
    let config = home.join(".config/tmux/window-sidebar.conf");
    let main = home.join(".tmux.conf");
    println!(
        "Install binary: {}\nWrite configuration: {}",
        destination.display(),
        config.display()
    );
    if !apply {
        println!("Dry run. Add --apply to install.");
        return Ok(());
    }
    let _install_lock = rt::lock(&home.join(".local/state/tmux-sidebar/install.lock"), false)?;
    let backup_root = home
        .join(".local/state/tmux-sidebar/backups")
        .join(format!("native-{}", rt::stamp()));
    rt::private_dir(&backup_root)?;
    for path in [&destination, &config, &main] {
        backup(&home, path, &backup_root)?;
    }
    for name in LEGACY {
        backup(&home, &home.join(".agents/tmux").join(name), &backup_root)?;
        backup(&home, &home.join(".config/tmux").join(name), &backup_root)?;
    }
    let staged = destination.with_extension(format!("next-{}", rt::stamp()));
    rt::atomic_write(&staged, &fs::read(env::current_exe()?)?)?;
    fs::set_permissions(&staged, fs::Permissions::from_mode(0o700))?;
    fs::rename(staged, &destination)?;
    let command = rt::quote(&destination.to_string_lossy())
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$");
    rt::atomic_write(
        &config,
        include_str!("../sidebar.conf.in")
            .replace("@SIDEBAR_COMMAND@", &command)
            .replace("@SHARED_DEFAULT@", if shared { "1" } else { "0" })
            .as_bytes(),
    )?;
    let existing = match fs::read_to_string(&main) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error),
    };
    let source = format!(
        "source-file \"{}\"",
        config
            .to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    );
    if !existing
        .lines()
        .any(|line| line == source || line == "source-file ~/.config/tmux/window-sidebar.conf")
    {
        rt::atomic_write(
            &main,
            format!("{}\n\n{source}\n", existing.trim_end()).as_bytes(),
        )?;
    }
    let mut probe = Command::new("tmux");
    if let Some(socket) = &socket {
        probe.args(["-S", socket]);
    }
    let server = probe
        .args(["display-message", "-p", "#{socket_path}"])
        .output()?;
    let live = server.status.success();
    let socket = String::from_utf8_lossy(&server.stdout).trim().to_owned();
    if live && reload {
        model::tmux(&socket, &["source-file", &config.to_string_lossy()])?;
    }
    if live && restart {
        replace(&home, &destination, &socket)?;
    }
    if !live || restart {
        cleanup(&home)?;
    } else {
        println!(
            "Existing terminal processes retain their code. Use --restart to replace them and remove legacy scripts."
        );
    }
    println!("Backup: {}", backup_root.display());
    Ok(())
}
fn cleanup(home: &Path) -> io::Result<()> {
    preserve_hook_guards(home)?;
    for name in LEGACY {
        let path = home.join(".agents/tmux").join(name);
        if path.is_file() && !(*name == "sidebar_agents.py" && guard_record(home).exists()) {
            fs::remove_file(&path)?;
        }
        let path = home.join(".config/tmux").join(name);
        if path.is_file() {
            let bytes = fs::read(&path)?;
            let text = String::from_utf8_lossy(&bytes);
            if text.contains(".agents/tmux")
                || text.contains("sidebar_agents")
                || text.contains("window_sidebar")
            {
                fs::remove_file(path)?;
            }
        }
    }
    for directory in [
        home.join(".agents/tmux/__pycache__"),
        home.join(".config/tmux/__pycache__"),
    ] {
        if !directory.is_dir() {
            continue;
        }
        for file in fs::read_dir(&directory)? {
            let path = file?.path();
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            if LEGACY
                .iter()
                .filter_map(|name| name.strip_suffix(".py"))
                .any(|stem| name.starts_with(&format!("{stem}.")))
            {
                fs::remove_file(path)?;
            }
        }
        if fs::read_dir(&directory)?.next().is_none() {
            fs::remove_dir(directory)?;
        }
    }
    Ok(())
}
fn replace(home: &Path, binary: &Path, socket: &str) -> io::Result<()> {
    let rows = model::tmux(
        socket,
        &[
            "list-panes",
            "-a",
            "-F",
            "#{pane_id}\t#{pane_pid}\t#{@window_sidebar}\t#{session_name}\t#{window_id}\t#{pane_in_mode}",
        ],
    )?;
    let panes = rows
        .lines()
        .map(|line| line.split('\t').collect::<Vec<_>>())
        .filter(|fields| fields.len() == 6)
        .collect::<Vec<_>>();
    let contents = panes
        .iter()
        .filter(|fields| fields[2].is_empty())
        .map(|fields| (fields[0].to_owned(), fields[1].to_owned()))
        .collect::<HashMap<_, _>>();
    stop_monitors(home, binary, &contents)?;
    let shared_options = Options {
        socket: socket.into(),
        ..Options::default()
    };
    crate::shared::stop(&shared_options)?;
    let shared = crate::shared::enabled(&shared_options)?;
    let mut sessions = HashSet::new();
    let mut count = 0;
    for pane in panes.iter().filter(|fields| fields[2] == "1") {
        let options = Options {
            socket: socket.into(),
            session: pane[3].into(),
            ..Options::default()
        };
        if pane[5] == "1" {
            model::tmux(socket, &["send-keys", "-X", "-t", pane[0], "cancel"])?;
        }
        let command = rt::shell(&[
            binary.to_string_lossy().into_owned(),
            "--socket".into(),
            socket.into(),
            "--session".into(),
            pane[3].into(),
            "render".into(),
        ]);
        if shared {
            crate::shared::replace_pane(&options, pane[0], pane[4])?;
        } else {
            model::tmux(socket, &["respawn-pane", "-k", "-t", pane[0], &command])?;
            model::tmux(
                socket,
                &["set-option", "-p", "-u", "-t", pane[0], "@shared_sidebar"],
            )?;
        }
        sessions.insert(options.session);
        count += 1;
    }
    for pane in panes.iter().filter(|fields| matches!(fields[2], "2" | "3")) {
        let result = Command::new("tmux")
            .args(["-S", socket, "kill-pane", "-t", pane[0]])
            .output()?;
        if !result.status.success()
            && !String::from_utf8_lossy(&result.stderr).contains("can't find pane:")
        {
            return Err(io::Error::other(
                String::from_utf8_lossy(&result.stderr).into_owned(),
            ));
        }
    }
    for session in sessions {
        let mut ensure = Command::new(binary);
        ensure
            .args(["--socket", socket, "--session", &session, "ensure"])
            .env("HOME", home);
        if env::var_os("TMUX_SIDEBAR_STATE_DIR").is_none() {
            ensure.env(
                "TMUX_SIDEBAR_STATE_DIR",
                home.join(".local/state/tmux-sidebar"),
            );
        }
        if env::var_os("AGENT_STAT_DIR").is_none() {
            ensure.env("AGENT_STAT_DIR", home.join(".local/state/agent-stat"));
        }
        let result = ensure.output()?;
        if !result.status.success() {
            return Err(io::Error::other(
                String::from_utf8_lossy(&result.stderr).into_owned(),
            ));
        }
    }
    let current = model::tmux(
        socket,
        &["list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}"],
    )?;
    let current = current
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .collect::<HashMap<_, _>>();
    if !contents
        .iter()
        .all(|(pane, pid)| current.get(pane.as_str()) == Some(&pid.as_str()))
    {
        return Err(io::Error::other(
            "Content process identities changed during installation",
        ));
    }
    println!(
        "Restarted {count} sidebar panes. Preserved {} content processes.",
        contents.len()
    );
    Ok(())
}
fn stop_monitors(home: &Path, binary: &Path, contents: &HashMap<String, String>) -> io::Result<()> {
    let processes = model::processes()?;
    let roots = contents
        .values()
        .filter_map(|pid| pid.parse::<u32>().ok())
        .collect::<Vec<_>>();
    let scripts = [
        home.join(".agents/tmux/sidebar_agents.py"),
        home.join(".config/tmux/sidebar_agents.py"),
        binary.to_path_buf(),
    ];
    let mut stopped = Vec::new();
    for (pid, process) in &processes {
        if *pid == std::process::id()
            || !process.command.contains("monitor")
            || roots
                .iter()
                .any(|root| model::belongs(*pid, *root, &processes))
        {
            continue;
        }
        let Ok(arguments) = commands::arguments(*pid) else {
            continue;
        };
        if !arguments.iter().any(|argument| argument == "monitor")
            || !arguments
                .iter()
                .any(|argument| scripts.iter().any(|script| Path::new(argument) == script))
        {
            continue;
        }
        // Only the deployed terminal monitor matches these complete argv paths.
        stopped.push(*pid as i32);
        if unsafe { libc::kill(*pid as i32, libc::SIGTERM) } != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while stopped
        .iter()
        .any(|pid| unsafe { libc::kill(*pid, 0) } == 0)
    {
        if std::time::Instant::now() >= deadline {
            return Err(io::Error::other("An old terminal monitor did not stop"));
        }
        thread::sleep(Duration::from_millis(25));
    }
    Ok(())
}

#[derive(serde::Deserialize, serde::Serialize)]
struct HookGuards {
    callers: Vec<(u32, String)>,
    agents: bool,
    config: bool,
}
fn guard_record(home: &Path) -> PathBuf {
    home.join(".local/state/tmux-sidebar/legacy-hook-guards.json")
}
fn preserve_hook_guards(home: &Path) -> io::Result<()> {
    let processes = model::processes()?;
    cleanup_hook_guards(home, &processes)?;
    if guard_record(home).exists() {
        return Ok(());
    }
    let agents = home.join(".agents/tmux/sidebar_agents.py").is_file();
    let config = home.join(".config/tmux/sidebar_agents.py").is_file();
    if !agents && !config {
        return Ok(());
    }
    let mut callers = registry_callers(home, &processes)?;
    for (pid, process) in &processes {
        if !process.command.contains("codex") {
            continue;
        }
        if home != rt::home()?.as_path()
            && !Path::new(&commands::profile(*pid, "codex")?).starts_with(home)
        {
            continue;
        }
        let arguments = commands::arguments(*pid).unwrap_or_default();
        if arguments.first().is_some_and(|argument| {
            Path::new(argument)
                .file_name()
                .is_some_and(|name| name == "codex")
        }) {
            callers.insert((*pid, process.started.clone()));
        }
    }
    if callers.is_empty() {
        return Ok(());
    }
    let guards = HookGuards {
        callers: callers.into_iter().collect(),
        agents,
        config,
    };
    rt::atomic_write(&guard_record(home), &serde_json::to_vec(&guards)?)?;
    for (enabled, path) in [
        (agents, home.join(".agents/tmux/sidebar_agents.py")),
        (config, home.join(".config/tmux/sidebar_agents.py")),
    ] {
        if enabled {
            rt::atomic_write(&path, b"")?;
        }
    }
    println!(
        "Empty compatibility guards protect cached hooks in {} running agent sessions. The monitor removes them after those sessions exit.",
        guards.callers.len()
    );
    Ok(())
}
pub fn cleanup_hook_guards(
    home: &Path,
    processes: &HashMap<u32, model::Process>,
) -> io::Result<()> {
    let record = guard_record(home);
    let bytes = match fs::read(&record) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let guards: HookGuards = serde_json::from_slice(&bytes)?;
    if guards.callers.iter().any(|(pid, start)| {
        processes
            .get(pid)
            .is_some_and(|process| &process.started == start)
    }) {
        return Ok(());
    }
    for (enabled, path) in [
        (guards.agents, home.join(".agents/tmux/sidebar_agents.py")),
        (guards.config, home.join(".config/tmux/sidebar_agents.py")),
    ] {
        if enabled && path.is_file() && fs::metadata(&path)?.len() == 0 {
            fs::remove_file(path)?;
        }
    }
    fs::remove_file(record)
}

fn registry_callers(
    home: &Path,
    processes: &HashMap<u32, model::Process>,
) -> io::Result<HashSet<(u32, String)>> {
    let files = match fs::read_dir(home.join(".claude/sessions")) {
        Ok(files) => files,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashSet::new()),
        Err(error) => return Err(error),
    };
    let mut callers = HashSet::new();
    for file in files {
        let path = file?.path();
        if path.extension().is_none_or(|extension| extension != "json") {
            continue;
        }
        let record = fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
        let Some(pid) = record
            .and_then(|record| record["pid"].as_u64())
            .map(|pid| pid as u32)
        else {
            continue;
        };
        let Some(process) = processes.get(&pid) else {
            continue;
        };
        callers.insert((pid, process.started.clone()));
    }
    Ok(callers)
}

use crate::{
    Options, actions,
    commands::{self, Capture},
    events::{Agent, Reader},
    model::{self, Entry, Process},
    runtime as rt,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs, io,
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Pane {
    pub pane_id: String,
    pub cwd: String,
    pub sidebar: bool,
    pub title: String,
    pub label: String,
    pub agent: Agent,
    #[serde(flatten)]
    pub command: Capture,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Window {
    pub index: u32,
    pub name: String,
    pub layout: String,
    pub label: String,
    #[serde(default = "focus_enabled")]
    pub focus_zoom: bool,
    pub panes: Vec<Pane>,
}
fn focus_enabled() -> bool {
    true
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Snapshot {
    pub version: u32,
    pub session: String,
    pub saved_at: f64,
    pub windows: Vec<Window>,
}
#[derive(Serialize)]
pub struct Plan {
    pub snapshot: Snapshot,
    pub active: HashSet<String>,
    pub eligible: Vec<String>,
    pub commands: Vec<String>,
}

pub fn namespace(options: &Options) -> io::Result<String> {
    let hash = format!("{:x}", Sha256::digest(options.socket.as_bytes()));
    let safe = rt::canonical(options)?
        .chars()
        .map(|letter| {
            if letter.is_ascii_alphanumeric() || matches!(letter, '_' | '-') {
                letter
            } else {
                '_'
            }
        })
        .collect::<String>();
    Ok(format!("{}-{safe}", &hash[..12]))
}
pub fn path(options: &Options) -> io::Result<PathBuf> {
    Ok(rt::state_root()?
        .join("snapshots")
        .join(format!("{}.json", namespace(options)?)))
}
pub fn monitor_lock(options: &Options) -> io::Result<PathBuf> {
    let session = if options.session.starts_with('$') {
        options.session.clone()
    } else {
        model::tmux(
            &options.socket,
            &[
                "display-message",
                "-p",
                "-t",
                &format!("{}:", options.session),
                "#{session_id}",
            ],
        )?
    };
    let hash = format!("{:x}", Sha256::digest(options.socket.as_bytes()));
    Ok(rt::state_root()?.join(format!(
        "{}-session{}.monitor.lock",
        &hash[..12],
        session.trim_start_matches('$')
    )))
}
fn registry(
    options: &Options,
    entries: &[Entry],
    processes: &HashMap<u32, Process>,
) -> io::Result<HashMap<String, Agent>> {
    let directory = rt::home()?.join(".claude/sessions");
    let files = match fs::read_dir(directory) {
        Ok(files) => files,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(error),
    };
    let session = rt::canonical(options)?;
    let mut result = HashMap::new();
    for file in files {
        let filename = file?.path();
        if filename
            .extension()
            .is_none_or(|extension| extension != "json")
        {
            continue;
        }
        let record = match fs::read(&filename).and_then(|bytes| {
            serde_json::from_slice::<serde_json::Value>(&bytes).map_err(io::Error::other)
        }) {
            Ok(record) => record,
            Err(_) => continue,
        };
        let locator = record["tmux"].as_str().unwrap_or_default();
        if !locator.starts_with(&format!("{session}:")) {
            continue;
        }
        let Some((_, suffix)) = locator.rsplit_once(".%") else {
            continue;
        };
        let pane = format!("%{suffix}");
        let pid = record["pid"].as_u64().unwrap_or(0) as u32;
        let Some(entry) = entries.iter().find(|entry| {
            entry.pane == pane
                && processes.contains_key(&pid)
                && model::belongs(pid, entry.root_pid, processes)
        }) else {
            continue;
        };
        result.insert(
            pane,
            Agent {
                agent: "claude".into(),
                session_id: record["sessionId"].as_str().unwrap_or_default().into(),
                pid,
                start: processes
                    .get(&pid)
                    .map(|process| process.started.clone())
                    .unwrap_or_default(),
                cwd: record["cwd"].as_str().unwrap_or(&entry.cwd).into(),
                updated: record["statusUpdatedAt"].as_f64().unwrap_or(0.) / 1000.,
                profile: commands::profile(pid, "claude")?,
                ..Agent::default()
            },
        );
    }
    Ok(result)
}
fn agents(
    options: &Options,
    reader: &mut Reader,
    entries: &[Entry],
    processes: &HashMap<u32, Process>,
) -> io::Result<HashMap<String, Agent>> {
    let mut result = registry(options, entries, processes)?;
    reader.refresh()?;
    for (pane, mut agent) in reader.agents(entries, processes) {
        agent.profile = commands::profile(agent.pid, &agent.agent)?;
        result.insert(pane, agent);
    }
    for agent in result.values_mut() {
        agent.launch = commands::launch(agent.pid, processes);
    }
    Ok(result)
}
pub fn capture(options: &Options, reader: &mut Reader) -> io::Result<Snapshot> {
    let processes = model::processes()?;
    crate::install::cleanup_hook_guards(&rt::home()?, &processes)?;
    let entries = model::entries(&options.socket, &options.session, &processes)?;
    let agents = agents(options, reader, &entries, &processes)?;
    let rows = model::tmux(
        &options.socket,
        &[
            "list-windows",
            "-t",
            &options.session,
            "-F",
            "#{window_id}\t#{window_index}\t#{window_name}\t#{window_layout}\t#{@window_sidebar_window_label}\t#{@window_sidebar_focus_zoom}\t#{@window_sidebar_focus_layout}\t#{@window_sidebar_focus_panes}",
        ],
    )?;
    let mut windows = Vec::new();
    for row in rows.lines() {
        let fields: Vec<_> = row.split('\t').collect();
        if fields.len() != 8 {
            continue;
        }
        let mut window = Window {
            index: fields[1].parse().map_err(io::Error::other)?,
            name: fields[2].into(),
            layout: fields[3].into(),
            label: fields[4].into(),
            focus_zoom: fields[5] != "0",
            panes: Vec::new(),
        };
        let panes = model::tmux(
            &options.socket,
            &[
                "list-panes",
                "-t",
                fields[0],
                "-F",
                "#{pane_id}\t#{pane_current_path}\t#{@window_sidebar}\t#{pane_title}\t#{@window_sidebar_label}\t#{pane_pid}",
            ],
        )?;
        for pane in panes
            .lines()
            .filter_map(|line| saved_pane(line, &agents, &processes))
        {
            window.panes.push(pane);
        }
        let mut identifiers = window
            .panes
            .iter()
            .map(|pane| pane.pane_id.as_str())
            .collect::<Vec<_>>();
        identifiers.sort_unstable();
        if !fields[6].is_empty() && identifiers.join(",") == fields[7] {
            // Recover the base layout so the first focused pane does not become the new baseline.
            window.layout = fields[6].into();
        }
        if !window.panes.is_empty() {
            windows.push(window);
        }
    }
    Ok(Snapshot {
        version: 1,
        session: rt::canonical(options)?,
        saved_at: rt::stamp() as f64 / 1e9,
        windows,
    })
}
fn saved_pane(
    line: &str,
    agents: &HashMap<String, Agent>,
    processes: &HashMap<u32, Process>,
) -> Option<Pane> {
    let fields: Vec<_> = line.split('\t').collect();
    if fields.len() != 6 || matches!(fields[2], "2" | "3") {
        return None;
    }
    let mut agent = agents.get(fields[0]).cloned().unwrap_or_default();
    if agent.state == "closed" {
        agent = Agent::default();
    }
    Some(Pane {
        pane_id: fields[0].into(),
        cwd: fields[1].into(),
        sidebar: fields[2] == "1",
        title: fields[3].into(),
        label: fields[4].into(),
        agent,
        command: if fields[2].is_empty() {
            commands::capture(fields[5].parse().unwrap_or(0), processes)
        } else {
            Capture::default()
        },
    })
}
fn recoverable(snapshot: &Snapshot) -> bool {
    snapshot
        .windows
        .iter()
        .flat_map(|window| &window.panes)
        .any(|pane| !pane.agent.session_id.is_empty() || can_replay(pane))
}
pub fn save(options: &Options, reader: &mut Reader, force: bool) -> io::Result<Snapshot> {
    let snapshot = capture(options, reader)?;
    if force || recoverable(&snapshot) {
        rt::atomic_write(&path(options)?, &serde_json::to_vec(&snapshot)?)?;
    }
    Ok(snapshot)
}
static RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
pub fn running() -> bool {
    RUNNING.load(std::sync::atomic::Ordering::Relaxed)
}
extern "C" fn stop(_: i32) {
    RUNNING.store(false, std::sync::atomic::Ordering::Relaxed);
}

pub fn monitor(options: &Options) -> io::Result<()> {
    let Some(_lock) = rt::lock(&monitor_lock(options)?, true)? else {
        return Ok(());
    };
    // The handler only changes a lock-free flag. Both monitor threads close normally.
    unsafe {
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let pidfile = monitor_lock(options)?.with_extension("pid");
    rt::atomic_write(&pidfile, std::process::id().to_string().as_bytes())?;
    let watch = options.clone();
    let observer = thread::spawn(move || {
        if let Err(error) = crate::prefix::watch(&watch) {
            rt::log(&format!("Shortcut observer: {error}"));
        }
    });
    let mut reader = Reader::new(options.event_root.clone(), options.host.clone());
    let mut seen = false;
    let mut availability = None;
    while running() && rt::exists(options) {
        if crate::shared::enabled(options)? {
            if let Err(error) = crate::shared::start(options) {
                rt::log(&format!("Shared service: {error}"));
            }
        }
        match save(options, &mut reader, seen) {
            Ok(snapshot) => seen |= recoverable(&snapshot),
            Err(error) => rt::log(&format!("Snapshot: {error}")),
        }
        if let Err(error) = publish_availability(options, &mut reader, &mut availability) {
            rt::log(&format!("Recovery availability: {error}"));
        }
        let next = Instant::now() + Duration::from_secs(10);
        // The control client detects session closure. Poll only after its observer exits.
        while Instant::now() < next && running() && (!observer.is_finished() || rt::exists(options))
        {
            thread::sleep(Duration::from_millis(100));
        }
    }
    RUNNING.store(false, std::sync::atomic::Ordering::Relaxed);
    if observer.join().is_err() {
        rt::log("Shortcut observer panicked");
    }
    fs::remove_file(pidfile)?;
    Ok(())
}
pub fn resume(agent: &Agent) -> Option<String> {
    if !matches!(agent.agent.as_str(), "claude" | "codex")
        || agent.session_id.is_empty()
        || !agent
            .session_id
            .bytes()
            .all(|letter| letter.is_ascii_alphanumeric() || matches!(letter, b'_' | b'-'))
    {
        return None;
    }
    let variable = if agent.agent == "claude" {
        "CLAUDE_CONFIG_DIR"
    } else {
        "CODEX_HOME"
    };
    let mut arguments = vec!["env".into()];
    if !agent.profile.is_empty() {
        arguments.push(format!("{variable}={}", agent.profile));
    }
    if agent.agent == "codex" {
        arguments.push("codex".into());
        if agent.launch.no_daemon {
            arguments.push("--no-daemon".into());
        }
        arguments.extend(["resume".into(), agent.session_id.clone()]);
        return Some(rt::shell(&arguments));
    }
    if agent.launch.ollama {
        arguments.extend(["ollama".into(), "launch".into(), "claude".into()]);
        if !agent.launch.model.is_empty() {
            arguments.extend(["--model".into(), agent.launch.model.clone()]);
        }
        arguments.push("--".into());
    } else {
        arguments.push("claude".into());
    }
    arguments.extend(["--resume".into(), agent.session_id.clone()]);
    if !agent.launch.ollama && !agent.launch.model.is_empty() {
        arguments.extend(["--model".into(), agent.launch.model.clone()]);
    }
    if !agent.launch.effort.is_empty() {
        arguments.extend(["--effort".into(), agent.launch.effort.clone()]);
    }
    Some(rt::shell(&arguments))
}
fn can_replay(pane: &Pane) -> bool {
    !pane.sidebar
        && pane.agent.session_id.is_empty()
        && pane.command.command_pid != 0
        && !pane.command.command_start.is_empty()
        && commands::replayable(&pane.command.command_argv)
}

pub fn plan(options: &Options) -> io::Result<Plan> {
    let mut reader = Reader::new(options.event_root.clone(), options.host.clone());
    plan_with_reader(options, &mut reader)
}
fn publish_availability(
    options: &Options,
    reader: &mut Reader,
    previous: &mut Option<bool>,
) -> io::Result<()> {
    let available = if path(options)?.is_file() {
        let plan = plan_with_reader(options, reader)?;
        !plan.eligible.is_empty() || !plan.commands.is_empty()
    } else {
        false
    };
    if *previous == Some(available) {
        return Ok(());
    }
    model::tmux(
        &options.socket,
        &[
            "set-option",
            "-t",
            &options.session,
            "@window_sidebar_recovery",
            if available { "1" } else { "0" },
        ],
    )?;
    *previous = Some(available);
    Ok(())
}
fn plan_with_reader(options: &Options, reader: &mut Reader) -> io::Result<Plan> {
    let snapshot: Snapshot =
        serde_json::from_slice(&fs::read(path(options)?).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                io::Error::other("No saved recovery snapshot exists for this session.")
            } else {
                error
            }
        })?)?;
    if snapshot.version != 1 || snapshot.windows.is_empty() {
        return Err(io::Error::other("Unsupported or empty recovery snapshot"));
    }
    let processes = model::processes()?;
    let entries = if rt::exists(options) {
        model::entries(&options.socket, &options.session, &processes)?
    } else {
        Vec::new()
    };
    let active = agents(options, reader, &entries, &processes)?
        .into_values()
        .filter(|agent| agent.state != "closed")
        .map(|agent| agent.session_id)
        .filter(|identifier| !identifier.is_empty())
        .collect::<HashSet<_>>();
    let panes = model::tmux(
        &options.socket,
        &["list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}"],
    )?;
    let roots = panes
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .map(|(pane, pid)| (pane, pid.parse::<u32>().unwrap_or(0)))
        .collect::<HashMap<_, _>>();
    let mut eligible = Vec::new();
    let mut commands = Vec::new();
    for pane in snapshot.windows.iter().flat_map(|window| &window.panes) {
        if !active.contains(&pane.agent.session_id) && resume(&pane.agent).is_some() {
            eligible.push(pane.pane_id.clone());
        }
        let running = processes
            .get(&pane.command.command_pid)
            .is_some_and(|process| {
                process.started == pane.command.command_start
                    && model::belongs(
                        pane.command.command_pid,
                        *roots.get(pane.pane_id.as_str()).unwrap_or(&0),
                        &processes,
                    )
            });
        if can_replay(pane) && !running {
            commands.push(pane.pane_id.clone());
        }
    }
    Ok(Plan {
        snapshot,
        active,
        eligible,
        commands,
    })
}
pub fn restore(options: &Options, selected: &HashSet<String>) -> io::Result<Option<String>> {
    let plan = plan(options)?;
    if !selected.iter().all(|pane| plan.commands.contains(pane)) {
        return Err(io::Error::other(
            "A selected command is unavailable or still running. Refresh the preview.",
        ));
    }
    if plan.eligible.is_empty() && selected.is_empty() {
        return Ok(None);
    }
    let recovered = format!("recovered-{}", plan.snapshot.session);
    let mut target = options.clone();
    target.session = recovered.clone();
    if rt::exists(&target) {
        return Err(io::Error::other(format!(
            "The recovery session already exists: {recovered}"
        )));
    }
    let cwd = &plan.snapshot.windows[0]
        .panes
        .first()
        .ok_or_else(|| io::Error::other("Empty saved window"))?
        .cwd;
    let first = model::tmux(
        &options.socket,
        &[
            "new-session",
            "-d",
            "-s",
            &recovered,
            "-c",
            cwd,
            "-P",
            "-F",
            "#{window_id}",
        ],
    )?;
    model::tmux(
        &options.socket,
        &[
            "set-option",
            "-t",
            &recovered,
            "@window_sidebar_enabled",
            "0",
        ],
    )?;
    let mut active = plan.active;
    for (index, window) in plan.snapshot.windows.iter().enumerate() {
        let window_id = if index == 0 {
            first.clone()
        } else {
            model::tmux(
                &options.socket,
                &[
                    "new-window",
                    "-d",
                    "-t",
                    &format!("{recovered}:"),
                    "-P",
                    "-F",
                    "#{window_id}",
                    "-c",
                    &window.panes[0].cwd,
                ],
            )?
        };
        restore_window(&target, &window_id, window, &mut active, selected)?;
    }
    actions::run(&target, "enable", None)?;
    let mut focused = target.clone();
    focused.pane = Some(format!("{recovered}:"));
    crate::focus::run(&focused, false)?;
    if let Some(client) = &options.client {
        model::tmux(
            &options.socket,
            &["switch-client", "-c", client, "-t", &recovered],
        )?;
    }
    Ok(Some(recovered))
}
fn restore_window(
    options: &Options,
    window_id: &str,
    window: &Window,
    active: &mut HashSet<String>,
    selected: &HashSet<String>,
) -> io::Result<()> {
    let first = model::tmux(
        &options.socket,
        &["display-message", "-p", "-t", window_id, "#{pane_id}"],
    )?;
    let mut panes = Vec::new();
    for (index, pane) in window.panes.iter().enumerate() {
        let pane_id = if index == 0 {
            first.clone()
        } else {
            model::tmux(
                &options.socket,
                &[
                    "split-window",
                    "-d",
                    "-h",
                    "-t",
                    window_id,
                    "-c",
                    &pane.cwd,
                    "-P",
                    "-F",
                    "#{pane_id}",
                ],
            )?
        };
        restore_pane(options, &pane_id, pane, active, selected)?;
        panes.push(pane_id);
        model::tmux(
            &options.socket,
            &["select-layout", "-t", window_id, "tiled"],
        )?;
    }
    model::tmux(
        &options.socket,
        &["rename-window", "-t", window_id, &window.name],
    )?;
    model::tmux(
        &options.socket,
        &[
            "set-option",
            "-w",
            "-t",
            window_id,
            "@window_sidebar_focus_zoom",
            if window.focus_zoom { "1" } else { "0" },
        ],
    )?;
    if !window.label.is_empty() {
        model::tmux(
            &options.socket,
            &[
                "set-option",
                "-w",
                "-t",
                window_id,
                "@window_sidebar_window_label",
                &window.label,
            ],
        )?;
    }
    model::tmux(
        &options.socket,
        &["select-layout", "-t", window_id, &window.layout],
    )?;
    if let Some(index) = window.panes.iter().position(|pane| !pane.sidebar) {
        model::tmux(&options.socket, &["select-pane", "-t", &panes[index]])?;
    }
    Ok(())
}
fn restore_pane(
    options: &Options,
    pane_id: &str,
    pane: &Pane,
    active: &mut HashSet<String>,
    selected: &HashSet<String>,
) -> io::Result<()> {
    if pane.sidebar {
        model::tmux(
            &options.socket,
            &["set-option", "-p", "-t", pane_id, "@window_sidebar", "1"],
        )?;
        model::tmux(
            &options.socket,
            &[
                "respawn-pane",
                "-k",
                "-t",
                pane_id,
                &rt::command(options, "render", None)?,
            ],
        )?;
        return Ok(());
    }
    if !pane.label.is_empty() {
        model::tmux(
            &options.socket,
            &[
                "set-option",
                "-p",
                "-t",
                pane_id,
                "@window_sidebar_label",
                &pane.label,
            ],
        )?;
    }
    let command = if let Some(command) =
        resume(&pane.agent).filter(|_| !active.contains(&pane.agent.session_id))
    {
        active.insert(pane.agent.session_id.clone());
        Some(command)
    } else if selected.contains(&pane.pane_id) && can_replay(pane) {
        Some(rt::shell(&pane.command.command_argv))
    } else {
        None
    };
    if let Some(command) = command {
        model::tmux(
            &options.socket,
            &[
                "respawn-pane",
                "-k",
                "-t",
                pane_id,
                "-c",
                &pane.cwd,
                &command,
            ],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resume_preserves_agent_launch_options() {
        let mut agent = Agent {
            agent: "codex".into(),
            session_id: "saved-session".into(),
            launch: commands::Launch {
                no_daemon: true,
                ..Default::default()
            },
            ..Default::default()
        };
        assert_eq!(
            resume(&agent).unwrap(),
            "'env' 'codex' '--no-daemon' 'resume' 'saved-session'"
        );
        agent.agent = "claude".into();
        agent.launch = commands::Launch {
            model: "local-model:latest".into(),
            effort: "high".into(),
            ..Default::default()
        };
        assert_eq!(
            resume(&agent).unwrap(),
            "'env' 'claude' '--resume' 'saved-session' '--model' 'local-model:latest' '--effort' 'high'"
        );
        agent.launch.ollama = true;
        assert_eq!(
            resume(&agent).unwrap(),
            "'env' 'ollama' 'launch' 'claude' '--model' 'local-model:latest' '--' '--resume' 'saved-session' '--effort' 'high'"
        );
    }
    #[test]
    fn old_snapshots_keep_their_original_resume_command() {
        let agent: Agent =
            serde_json::from_str(r#"{"agent":"codex","session_id":"saved-session"}"#).unwrap();
        assert_eq!(
            resume(&agent).unwrap(),
            "'env' 'codex' 'resume' 'saved-session'"
        );
    }
    #[test]
    fn commands_without_a_process_start_are_not_recovery_candidates() {
        let mut pane = Pane {
            command: Capture {
                command_pid: 42,
                command_argv: vec!["sleep".into(), "120".into()],
                ..Capture::default()
            },
            ..Pane::default()
        };
        assert!(!can_replay(&pane));
        pane.command.command_start = "Wed Nov 4 02:00:00 2026".into();
        assert!(can_replay(&pane));
    }
}

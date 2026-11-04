mod actions;
mod commands;
mod events;
mod focus;
mod install;
mod model;
mod prefix;
mod recovery;
mod recovery_ui;
mod runtime;
mod ui;

use std::{
    collections::HashSet,
    env, io,
    path::PathBuf,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Default)]
pub struct Options {
    socket: String,
    session: String,
    action: String,
    event_root: PathBuf,
    host: String,
    pane: Option<String>,
    client: Option<String>,
    owner_window: String,
    rerun: HashSet<String>,
}
fn options() -> io::Result<Options> {
    let mut result = Options {
        socket: env::var("TMUX")
            .unwrap_or_default()
            .split(',')
            .next()
            .unwrap_or_default()
            .into(),
        action: "render".into(),
        ..Options::default()
    };
    let mut arguments = env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--socket" | "--session" | "--pane" | "--client" | "--rerun" => {
                let value = arguments
                    .next()
                    .ok_or_else(|| io::Error::other(format!("Missing value for {argument}")))?;
                match argument.as_str() {
                    "--socket" => result.socket = value,
                    "--session" => result.session = value,
                    "--pane" => result.pane = Some(value),
                    "--client" => result.client = Some(value),
                    _ => {
                        result.rerun.insert(value);
                    }
                }
            }
            value if !value.starts_with('-') => result.action = value.into(),
            _ => return Err(io::Error::other(format!("Unknown argument: {argument}"))),
        }
    }
    if result.socket.is_empty() {
        return Err(io::Error::other("Run inside tmux or supply --socket PATH"));
    }
    if result.pane.is_none() {
        result.pane = env::var("TMUX_PANE").ok();
    }
    if result.session.is_empty() {
        result.session = model::tmux(
            &result.socket,
            &[
                "display-message",
                "-p",
                "-t",
                result.pane.as_deref().unwrap_or(""),
                "#{session_id}",
            ],
        )?;
    }
    result.event_root = env::var_os("AGENT_STAT_DIR")
        .map(PathBuf::from)
        .unwrap_or(runtime::home()?.join(".local/state/agent-stat"));
    let output = std::process::Command::new("uname").arg("-n").output()?;
    if !output.status.success() {
        return Err(io::Error::other("Cannot read host name"));
    }
    result.host = String::from_utf8_lossy(&output.stdout)
        .trim()
        .trim_end_matches(".local")
        .into();
    if matches!(result.action.as_str(), "render" | "overlay" | "monitor") {
        let session_target = format!("{}:", result.session);
        let identity = model::tmux(
            &result.socket,
            &[
                "display-message",
                "-p",
                "-t",
                if result.action == "monitor" {
                    &session_target
                } else {
                    result.pane.as_deref().unwrap_or(&session_target)
                },
                "#{session_id}\t#{window_id}",
            ],
        )?;
        let (session, window) = identity
            .split_once('\t')
            .ok_or_else(|| io::Error::other("Missing tmux session identity"))?;
        result.session = session.into();
        result.owner_window = window.into();
    }
    Ok(result)
}
fn snapshot(
    options: &Options,
    reader: &mut events::Reader,
    processes: &std::collections::HashMap<u32, model::Process>,
) -> io::Result<Vec<model::Entry>> {
    let mut entries = model::entries(&options.socket, &options.session, processes)?;
    reader.refresh()?;
    reader.decorate(&mut entries, processes);
    for entry in &mut entries {
        if entry.active && entry.unread {
            model::tmux(
                &options.socket,
                &[
                    "set-option",
                    "-p",
                    "-t",
                    &entry.pane,
                    "@window_sidebar_seen",
                    &entry.attention,
                ],
            )?;
            entry.unread = false;
            if entry.state == "done" {
                entry.state = "idle".into();
            }
            entry.seen = entry.attention.clone();
        }
    }
    Ok(entries)
}
fn render(options: &Options) -> io::Result<()> {
    let mut reader = events::Reader::new(options.event_root.clone(), options.host.clone());
    if options.action == "dump" {
        println!(
            "{}",
            serde_json::to_string(&snapshot(options, &mut reader, &model::processes()?)?)?
        );
        return Ok(());
    }
    let (sender, receiver) = mpsc::sync_channel(1);
    let (wake_sender, wake_receiver) = mpsc::channel();
    // Pane metadata makes the first frame interactive before the process scan finishes.
    let initial = model::entries(&options.socket, &options.session, &Default::default())
        .map_err(|error| error.to_string());
    sender
        .send(initial)
        .map_err(|error| io::Error::other(error.to_string()))?;
    let background = options.clone();
    thread::spawn(move || {
        let mut processes = std::collections::HashMap::new();
        let mut scanned = Instant::now() - Duration::from_secs(2);
        loop {
            if scanned.elapsed() >= Duration::from_secs(1) {
                match model::processes() {
                    Ok(current) => processes = current,
                    Err(error) => runtime::log(&error.to_string()),
                }
                scanned = Instant::now();
            }
            let result =
                snapshot(&background, &mut reader, &processes).map_err(|error| error.to_string());
            let active = result.as_ref().is_ok_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry.window_active && entry.window == background.owner_window)
            });
            if sender.send(result).is_err() {
                return;
            }
            if let Err(mpsc::RecvTimeoutError::Disconnected) = wake_receiver.recv_timeout(
                Duration::from_millis(if background.action == "render" && !active {
                    // Selecting the window wakes this worker through F12.
                    5000
                } else {
                    150
                }),
            ) {
                return;
            }
        }
    });
    ui::run(options, receiver, wake_sender)
}
fn run() -> io::Result<()> {
    if env::args().nth(1).as_deref() == Some("install") {
        return install::run();
    }
    if env::args().any(|argument| matches!(argument.as_str(), "--help" | "-h")) {
        println!(
            "agent-stat-tmux install [--home DIR] [--apply] [--reload] [--restart]\nagent-stat-tmux --socket PATH --session NAME [--pane ID] ACTION\nActions: render, search-ui, enable, toggle, menu, snapshot, plan, restore, recover\nrestore --rerun PANE explicitly reruns one saved command."
        );
        return Ok(());
    }
    let options = options()?;
    match options.action.as_str() {
        "render"|"overlay"|"search-ui"|"dump"=>render(&options),
        "prefix-help"=>prefix::render(&options),
        "shell"=>actions::shell(&options),
        "focus"|"focus-toggle"=>focus::run(&options,options.action=="focus-toggle"),
        "keys-ui"=>ui::pager("TMUX SHORTCUTS",prefix::shortcuts(&options)?),
        "legend-ui"=>ui::pager("STATUS COLORS","Green: Working\nRed: Request or response needs attention\nOrange: Failed\nBlue: Ready or acknowledged request/response\nPurple: Interrupted\nGray: Closed\nNo dot: No recorded agent status\n\n* Needs attention. Select its content pane to clear it.\nViewing a permission request does not approve it.".into()),
        "command-ui"=>{let processes=model::processes()?;let entry=actions::context_with_processes(&options,options.pane.as_deref(),&processes)?;let capture=commands::capture(entry.root_pid,&processes);ui::pager("FULL TITLE AND COMMAND",format!("Title: {}\nFolder: {}\n\nCommand:\n{}",entry.title,entry.cwd,capture.command))},
        "recovery-ui"=>recovery_ui::run(&options),
        "monitor"=>recovery::monitor(&options),
        "snapshot"=>{let mut reader=events::Reader::new(options.event_root.clone(),options.host.clone());println!("{}",serde_json::to_string(&recovery::save(&options,&mut reader,true)?)?);Ok(())}
        "plan"=>{println!("{}",serde_json::to_string(&recovery::plan(&options)?)?);Ok(())}
        "restore"=>{if let Some(name)=recovery::restore(&options,&options.rerun)?{println!("{name}");}else{println!("Nothing to restore (already running or no commands selected)");}Ok(())}
        action=>actions::run(&options,action,options.pane.as_deref()),
    }
}
fn main() {
    if let Err(error) = run() {
        runtime::log(&error.to_string());
        eprintln!("agent-stat-tmux: {error}");
        std::process::exit(1);
    }
}

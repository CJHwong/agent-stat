use crate::{
    Options,
    model::{self, Entry},
    runtime as rt,
};
use std::{
    env, io,
    process::{Command, Stdio},
};

fn field(options: &Options, target: &str, format: &str) -> io::Result<String> {
    model::tmux(
        &options.socket,
        &["display-message", "-p", "-t", target, format],
    )
}
pub fn context(options: &Options, pane: Option<&str>) -> io::Result<Entry> {
    let processes = model::processes()?;
    context_with_processes(options, pane, &processes)
}
pub(crate) fn context_with_processes(
    options: &Options,
    pane: Option<&str>,
    processes: &std::collections::HashMap<u32, model::Process>,
) -> io::Result<Entry> {
    let entries = model::entries(&options.socket, &options.session, processes)?;
    entries
        .iter()
        .find(|entry| Some(entry.pane.as_str()) == pane)
        .or_else(|| entries.iter().find(|entry| entry.active))
        .or(entries.first())
        .cloned()
        .ok_or_else(|| io::Error::other("No terminal panes are available"))
}
pub fn run(options: &Options, action: &str, pane: Option<&str>) -> io::Result<()> {
    with_entry(options, action, pane, None)
}
pub fn with_entry(
    options: &Options,
    action: &str,
    pane: Option<&str>,
    cached: Option<&Entry>,
) -> io::Result<()> {
    if matches!(action, "enable" | "ensure" | "attach" | "toggle") {
        return sidebars(options, action);
    }
    if action == "zoom" {
        return zoom(options, pane);
    }
    if matches!(action, "expand" | "help-overlay") {
        return overlay(options, action == "help-overlay");
    }
    let resolved;
    let entry = if let Some(entry) = cached {
        entry
    } else {
        // These controls need pane metadata, not every process's foreground command.
        resolved = if action == "rename" {
            context(options, pane)?
        } else {
            context_with_processes(options, pane, &Default::default())?
        };
        &resolved
    };
    match action {
        "new" => {
            let cwd = field(options, &entry.pane, "#{pane_current_path}")?;
            let boot = field(options, &entry.pane, "#{default-shell}\t#{default-command}")?;
            let (shell, command) = boot
                .split_once('\t')
                .ok_or_else(|| io::Error::other("Missing shell startup settings"))?;
            let arguments = if command.is_empty() {
                vec![shell.to_owned(), "-l".into()]
            } else {
                vec![shell.to_owned(), "-c".into(), command.to_owned()]
            };
            let token = format!("agent-stat-new-{}-{}", std::process::id(), rt::stamp());
            let wait = rt::shell(&[
                "tmux".into(),
                "-S".into(),
                options.socket.clone(),
                "wait-for".into(),
                token.clone(),
            ]);
            let startup = format!("{wait} && exec {}", rt::shell(&arguments));
            let created = model::tmux(
                &options.socket,
                &[
                    "new-window",
                    "-d",
                    "-P",
                    "-F",
                    "#{window_id}\t#{pane_id}",
                    "-t",
                    &format!("{}:", options.session),
                    "-c",
                    &cwd,
                    &startup,
                ],
            )?;
            let (window, pane) = created
                .split_once('\t')
                .ok_or_else(|| io::Error::other("Missing new window target"))?;
            let prepared = sidebars(options, "ensure");
            // Release startup even if layout preparation fails, so no shell stays blocked.
            let released = model::tmux(&options.socket, &["wait-for", "-S", &token]);
            prepared?;
            released?;
            model::select(
                &options.socket,
                &Entry {
                    window: window.into(),
                    pane: pane.into(),
                    ..Entry::default()
                },
            )?;
        }
        "rename" => {
            let prompt = format!(
                "set-option -p -t {} @window_sidebar_label \"%%%\"",
                entry.pane
            );
            model::tmux(
                &options.socket,
                &[
                    "command-prompt",
                    "-t",
                    &rt::client(options, &entry.window)?,
                    "-I",
                    &entry.title,
                    "-p",
                    "Pane name:",
                    &prompt,
                ],
            )?;
        }
        "menu" | "split" => menu(options, entry, action == "split")?,
        "search" => popup(options, entry, "search-ui", "Find window or pane")?,
        "recover" => popup(options, entry, "recovery-ui", "Recovery preview")?,
        "command" => popup(options, entry, "command-ui", "Full title and command")?,
        "legend" => popup(options, entry, "legend-ui", "Status colors")?,
        "keys" => popup(options, entry, "keys-ui", "TMUX SHORTCUTS")?,
        _ => return Err(io::Error::other(format!("Unknown action: {action}"))),
    }
    Ok(())
}
pub fn popup(options: &Options, entry: &Entry, action: &str, title: &str) -> io::Result<()> {
    let client = rt::client(options, &entry.window)?;
    let mut popup = options.clone();
    popup.client = Some(client.clone());
    model::tmux(
        &options.socket,
        &[
            "display-popup",
            "-c",
            &client,
            "-E",
            "-w",
            "85%",
            "-h",
            "75%",
            "-T",
            title,
            &rt::command(&popup, action, Some(&entry.pane))?,
        ],
    )?;
    Ok(())
}
fn item(items: &mut Vec<String>, label: &str, key: &str, command: String) {
    items.extend([label.into(), key.into(), command]);
}
fn menu(options: &Options, entry: &Entry, split_only: bool) -> io::Result<()> {
    let cwd = field(options, &entry.pane, "#{pane_current_path}")?;
    let pane = &entry.pane;
    let mut args = vec![
        "display-menu".into(),
        "-c".into(),
        rt::client(options, &entry.window)?,
        "-t".into(),
        pane.clone(),
        "-T".into(),
        "Window and pane controls".into(),
        "-x".into(),
        "C".into(),
        "-y".into(),
        "C".into(),
    ];
    item(
        &mut args,
        "Split left/right",
        "v",
        format!("split-window -h -t {pane} -c {}", rt::quote(&cwd)),
    );
    item(
        &mut args,
        "Split above/below",
        "h",
        format!("split-window -v -t {pane} -c {}", rt::quote(&cwd)),
    );
    if !split_only {
        append_menu(options, entry, &mut args)?;
    }
    rt::call(options, args)?;
    Ok(())
}
fn append_menu(options: &Options, entry: &Entry, args: &mut Vec<String>) -> io::Result<()> {
    let pane = &entry.pane;
    let window = &entry.window;
    for (label, key, action) in [
        ("Full title and command", "f", "command"),
        ("Status color legend", "s", "legend"),
        ("Find window or pane", "/", "search"),
        ("Recover saved sessions", "u", "recover"),
    ] {
        item(
            args,
            label,
            key,
            format!(
                "run-shell -b {}",
                rt::quote(&rt::command(options, action, Some(pane))?)
            ),
        );
    }
    for (label, key, command) in [
        (
            "New window",
            "c",
            format!(
                "run-shell -b {}",
                rt::quote(&rt::command(options, "new", Some(pane))?)
            ),
        ),
        (
            "Rename pane",
            "r",
            format!(
                "command-prompt -p 'Pane name:' {}",
                rt::quote(&format!(
                    "set-option -p -t {pane} @window_sidebar_label \"%%%\""
                ))
            ),
        ),
        (
            "Rename window",
            "R",
            format!(
                "command-prompt -p 'Window name:' {}",
                rt::quote(&format!(
                    "rename-window -t {window} \"%1%\"; set-option -w -t {window} @window_sidebar_window_label \"%1%\""
                ))
            ),
        ),
        (
            "Reset pane name",
            "N",
            format!("set-option -p -u -t {pane} @window_sidebar_label"),
        ),
        (
            "Zoom pane",
            "z",
            format!(
                "run-shell -b {}",
                rt::quote(&rt::command(options, "zoom", Some(pane))?)
            ),
        ),
        (
            "Close pane",
            "x",
            format!(
                "confirm-before -p 'Close this pane and its process? (y/n)' 'kill-pane -t {pane}'"
            ),
        ),
        (
            "Close window",
            "X",
            format!(
                "confirm-before -p 'Close this window and its processes? (y/n)' 'kill-window -t {window}'"
            ),
        ),
        ("Detach safely", "d", "detach-client".into()),
        ("Close menu", "q", String::new()),
    ] {
        item(args, label, key, command);
    }
    Ok(())
}
fn close_empty_window(options: &Options, window: &str) -> io::Result<()> {
    let current = field(options, window, "#{window_active} #{window_index}")?;
    let fields = current.split_whitespace().collect::<Vec<_>>();
    if fields.first() != Some(&"1") {
        model::tmux(&options.socket, &["kill-window", "-t", window])?;
        return Ok(());
    }
    let index = fields
        .get(1)
        .and_then(|index| index.parse::<u32>().ok())
        .ok_or_else(|| io::Error::other("Missing closing window index"))?;
    let entries = model::entries(&options.socket, &options.session, &Default::default())?;
    let adjacent = entries
        .iter()
        .filter(|entry| entry.index < index)
        .max_by_key(|entry| entry.index)
        .or_else(|| {
            entries
                .iter()
                .filter(|entry| entry.index > index)
                .min_by_key(|entry| entry.index)
        });
    let Some(adjacent) = adjacent else {
        model::tmux(&options.socket, &["kill-window", "-t", window])?;
        return Ok(());
    };
    let rows = model::tmux(
        &options.socket,
        &[
            "list-panes",
            "-t",
            &adjacent.window,
            "-F",
            "#{pane_id}\t#{@window_sidebar}\t#{pane_active}\t#{pane_last}",
        ],
    )?;
    let panes = rows
        .lines()
        .map(|row| row.split('\t').collect::<Vec<_>>())
        .filter(|fields| fields.len() == 4 && fields[1].is_empty())
        .collect::<Vec<_>>();
    let content = panes
        .iter()
        .find(|fields| fields[2] == "1")
        .or_else(|| panes.iter().find(|fields| fields[3] == "1"))
        .or(panes.first())
        .ok_or_else(|| io::Error::other("The adjacent window has no content pane"))?;
    // Set content focus before the destination becomes visible, then close the old window.
    model::tmux(
        &options.socket,
        &[
            "select-pane",
            "-t",
            content[0],
            ";",
            "select-window",
            "-t",
            &adjacent.window,
            ";",
            "kill-window",
            "-t",
            window,
        ],
    )?;
    Ok(())
}
pub fn ensure(options: &Options) -> io::Result<()> {
    if !rt::exists(options)
        || field(options, &options.session, "#{@window_sidebar_enabled}")? != "1"
    {
        return Ok(());
    }
    let existing = model::tmux(
        &options.socket,
        &[
            "list-panes",
            "-s",
            "-t",
            &options.session,
            "-F",
            "#{window_id}\t#{pane_id}\t#{@window_sidebar}",
        ],
    )?;
    let windows = model::tmux(
        &options.socket,
        &[
            "list-windows",
            "-t",
            &options.session,
            "-F",
            "#{window_id} #{window_width} #{window_zoomed_flag}",
        ],
    )?;
    for line in windows.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 3 {
            continue;
        }
        let window = fields[0];
        let roles = existing
            .lines()
            .filter_map(|row| {
                let values = row.split('\t').collect::<Vec<_>>();
                (values.len() == 3 && values[0] == window).then(|| values[2])
            })
            .collect::<Vec<_>>();
        if roles.contains(&"1") && !roles.contains(&"") {
            close_empty_window(options, window)?;
            continue;
        }
        if fields[2] == "1" {
            continue;
        }
        let width = if fields[1].parse::<u16>().unwrap_or(0) >= 100 {
            28
        } else {
            3
        };
        let found = existing.lines().find_map(|row| {
            let values: Vec<_> = row.split('\t').collect();
            (values.len() == 3 && values[0] == window && values[2] == "1")
                .then(|| values[1].to_owned())
        });
        let pane = if let Some(pane) = found {
            pane
        } else {
            let pane = model::tmux(
                &options.socket,
                &[
                    "split-window",
                    "-d",
                    "-b",
                    "-f",
                    "-h",
                    "-l",
                    &width.to_string(),
                    "-t",
                    window,
                    "-P",
                    "-F",
                    "#{pane_id}",
                    &rt::command(options, "render", None)?,
                ],
            )?;
            model::tmux(
                &options.socket,
                &["set-option", "-p", "-t", &pane, "@window_sidebar", "1"],
            )?;
            pane
        };
        model::tmux(
            &options.socket,
            &[
                "set-option",
                "-w",
                "-t",
                window,
                "@window_sidebar_pane",
                &pane,
            ],
        )?;
        let current = field(options, &pane, "#{pane_width}")?;
        if current != width.to_string() {
            model::tmux(
                &options.socket,
                &["resize-pane", "-t", &pane, "-x", &width.to_string()],
            )?;
        }
        model::tmux(
            &options.socket,
            &["set-option", "-p", "-t", &pane, "pane-border-format", ""],
        )?;
    }
    Ok(())
}
fn sidebars(options: &Options, action: &str) -> io::Result<()> {
    if !rt::exists(options) {
        return Ok(());
    }
    let _lock = rt::lock(&rt::state_root()?.join("layout.lock"), false)?;
    let enabled = field(options, &options.session, "#{@window_sidebar_enabled}")? == "1";
    if action == "toggle" && enabled {
        model::tmux(
            &options.socket,
            &[
                "set-option",
                "-t",
                &options.session,
                "@window_sidebar_enabled",
                "0",
            ],
        )?;
        let panes = model::tmux(
            &options.socket,
            &[
                "list-panes",
                "-s",
                "-t",
                &options.session,
                "-F",
                "#{pane_id} #{@window_sidebar}",
            ],
        )?;
        for line in panes.lines() {
            if let Some(pane) = line.strip_suffix(" 1") {
                model::tmux(&options.socket, &["kill-pane", "-t", pane])?;
            }
        }
        return Ok(());
    }
    let initialized = field(options, &options.session, "#{@window_sidebar_initialized}")?;
    if matches!(action, "enable" | "toggle") || (action == "attach" && initialized.is_empty()) {
        for (key, value) in [
            ("@window_sidebar_initialized", "1"),
            ("@window_sidebar_enabled", "1"),
        ] {
            model::tmux(
                &options.socket,
                &["set-option", "-t", &options.session, key, value],
            )?;
        }
    }
    if let Err(error) = ensure(options) {
        if matches!(action, "ensure" | "attach") {
            rt::log(&error.to_string());
            return Ok(());
        }
        return Err(error);
    }
    if rt::exists(options) && field(options, &options.session, "#{@window_sidebar_enabled}")? == "1"
    {
        start_monitor(options)?;
    }
    Ok(())
}
pub fn start_monitor(options: &Options) -> io::Result<()> {
    let path = crate::recovery::monitor_lock(options)?;
    let Some(lock) = rt::lock(&path, true)? else {
        return Ok(());
    };
    drop(lock);
    use std::os::unix::process::CommandExt;
    let mut command = Command::new(env::current_exe()?);
    command
        .args([
            "--socket",
            &options.socket,
            "--session",
            &rt::canonical(options)?,
            "monitor",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // A monitor must outlive the tmux command that starts it.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    command.spawn()?;
    Ok(())
}
pub fn overlay(options: &Options, help: bool) -> io::Result<()> {
    let pane = options
        .pane
        .clone()
        .or_else(|| env::var("TMUX_PANE").ok())
        .ok_or_else(|| io::Error::other("Missing target pane"))?;
    let _lock = rt::lock(&rt::state_root()?.join("help.lock"), false)?;
    if help
        && (!crate::prefix::armed(options)?
            || field(options, &pane, "#{window_zoomed_flag}")? == "1")
    {
        return Ok(());
    }
    if !help {
        let entry = context(options, None)?;
        model::tmux(
            &options.socket,
            &[
                "set-option",
                "-w",
                "-t",
                &pane,
                "@window_sidebar_target",
                &entry.pane,
            ],
        )?;
    }
    if help
        && model::tmux(
            &options.socket,
            &["list-panes", "-t", &pane, "-F", "#{@window_sidebar}"],
        )?
        .lines()
        .any(|role| role == "3")
    {
        return Ok(());
    }
    let dimensions = field(options, &pane, "#{window_width} #{window_height}")?;
    let fields: Vec<_> = dimensions.split_whitespace().collect();
    let window_width = fields[0].parse::<u16>().unwrap_or(80);
    let window_height = fields[1].parse::<u16>().unwrap_or(24);
    let width = window_width
        .saturating_sub(2)
        .min(if help { 44 } else { 28 })
        .max(1);
    let height = window_height
        .saturating_sub(2)
        .min(if help { 14 } else { u16::MAX })
        .max(1);
    let left = if help {
        window_width.saturating_sub(width) / 2
    } else {
        0
    };
    let top = if help {
        window_height.saturating_sub(height) / 2
    } else {
        0
    };
    let mut args = vec!["new-pane".into()];
    if help {
        args.push("-d".into());
    }
    args.extend([
        "-t".into(),
        pane,
        "-x".into(),
        width.to_string(),
        "-y".into(),
        height.to_string(),
        "-X".into(),
        left.to_string(),
        "-Y".into(),
        top.to_string(),
        "-P".into(),
        "-F".into(),
        "#{pane_id}".into(),
        rt::command(options, if help { "prefix-help" } else { "overlay" }, None)?,
    ]);
    let overlay = rt::call(options, args)?;
    model::tmux(
        &options.socket,
        &[
            "set-option",
            "-p",
            "-t",
            &overlay,
            "@window_sidebar",
            if help { "3" } else { "2" },
        ],
    )?;
    model::tmux(
        &options.socket,
        &["set-option", "-p", "-t", &overlay, "pane-border-format", ""],
    )?;
    Ok(())
}

fn zoom(options: &Options, pane: Option<&str>) -> io::Result<()> {
    let target = pane.or(options.pane.as_deref()).unwrap_or(&options.session);
    let window = field(options, target, "#{window_id}")?;
    let rows = model::tmux(
        &options.socket,
        &[
            "list-panes",
            "-t",
            &window,
            "-F",
            "#{pane_id}\t#{@window_sidebar}\t#{pane_active}\t#{pane_last}",
        ],
    )?;
    let panes = rows
        .lines()
        .map(|line| line.split('\t').collect::<Vec<_>>())
        .filter(|fields| fields.len() == 4 && fields[1].is_empty())
        .collect::<Vec<_>>();
    let chosen = panes
        .iter()
        .find(|fields| fields[0] == target)
        .or_else(|| {
            panes
                .iter()
                .max_by_key(|fields| (fields[2] == "1", fields[3] == "1"))
        })
        .ok_or_else(|| io::Error::other("No content pane to zoom"))?;
    let _lock = rt::lock(&rt::state_root()?.join("help.lock"), false)?;
    for fields in rows
        .lines()
        .map(|line| line.split('\t').collect::<Vec<_>>())
        .filter(|fields| fields.len() == 4 && fields[1] == "3")
    {
        let result = std::process::Command::new("tmux")
            .args(["-S", &options.socket, "kill-pane", "-t", fields[0]])
            .output()?;
        if !result.status.success()
            && !String::from_utf8_lossy(&result.stderr).contains("can't find pane:")
        {
            return Err(io::Error::other(
                String::from_utf8_lossy(&result.stderr).into_owned(),
            ));
        }
    }
    model::tmux(&options.socket, &["select-pane", "-Z", "-t", chosen[0]])?;
    model::tmux(&options.socket, &["resize-pane", "-Z", "-t", chosen[0]])?;
    drop(_lock);
    sidebars(options, "ensure")
}

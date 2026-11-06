use crate::{Options, model, runtime as rt};
use std::io;

struct Pane<'a> {
    id: &'a str,
    role: &'a str,
    active: bool,
    left: u16,
    top: u16,
    width: u16,
    height: u16,
}

fn panes(rows: &str) -> io::Result<Vec<Pane<'_>>> {
    rows.lines()
        .map(|row| {
            let fields = row.split('\t').collect::<Vec<_>>();
            if fields.len() != 7 {
                return Err(io::Error::other("Missing focus pane geometry"));
            }
            Ok(Pane {
                id: fields[0],
                role: fields[1],
                active: fields[2] == "1",
                left: fields[3].parse().map_err(io::Error::other)?,
                top: fields[4].parse().map_err(io::Error::other)?,
                width: fields[5].parse().map_err(io::Error::other)?,
                height: fields[6].parse().map_err(io::Error::other)?,
            })
        })
        .collect()
}

fn setting(arguments: &mut Vec<String>, window: &str, name: &str, value: &str) {
    if !arguments.is_empty() {
        arguments.push(";".into());
    }
    arguments.extend(["set-option", "-w", "-t", window, name, value].map(String::from));
}

pub fn refresh_styles(options: &Options) -> io::Result<()> {
    let style = model::tmux(&options.socket, &["show-option", "-gqv", "window-style"])?;
    // tmux caches formats in pane styles until a style option changes.
    model::tmux(
        &options.socket,
        &["set-option", "-g", "window-style", &style],
    )?;
    Ok(())
}

pub fn run(options: &Options, toggle: bool) -> io::Result<()> {
    let target = options.pane.as_deref().unwrap_or(&options.session);
    let _lock = rt::lock(&rt::state_root()?.join("layout.lock"), false)?;
    let header = model::tmux(
        &options.socket,
        &[
            "display-message",
            "-p",
            "-t",
            target,
            "#{window_id}\t#{window_zoomed_flag}\t#{@window_sidebar_enabled}\t#{@window_sidebar_focus_zoom}\t#{@window_sidebar_focus_layout}\t#{@window_sidebar_focus_panes}\t#{window_layout}",
        ],
    )?;
    let fields = header.split('\t').collect::<Vec<_>>();
    if fields.len() != 7 {
        return Err(io::Error::other("Missing focus window settings"));
    }
    if fields[2] != "1" {
        return Ok(());
    }
    let window = fields[0];
    let enabled = if toggle {
        fields[3] == "0"
    } else {
        fields[3] != "0"
    };
    let rows = model::tmux(
        &options.socket,
        &[
            "list-panes",
            "-t",
            window,
            "-F",
            "#{pane_id}\t#{@window_sidebar}\t#{pane_active}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}",
        ],
    )?;
    let panes = panes(&rows)?;
    let mut identifiers = panes
        .iter()
        .filter(|pane| pane.role.is_empty() || pane.role == "1")
        .map(|pane| pane.id)
        .collect::<Vec<_>>();
    identifiers.sort_unstable();
    let signature = identifiers.join(",");
    let mut arguments = Vec::new();
    if toggle {
        setting(
            &mut arguments,
            window,
            "@window_sidebar_focus_zoom",
            if enabled { "1" } else { "0" },
        );
    }
    if fields[1] == "1" {
        // Keep native full zoom intact. Restore the baseline after unzoom instead.
        if !arguments.is_empty() {
            rt::call(options, arguments)?;
        }
        if toggle {
            refresh_styles(options)?;
        }
        return Ok(());
    }
    if !enabled {
        let active = panes
            .iter()
            .find(|pane| pane.active && pane.role.is_empty())
            .map(|pane| pane.id);
        restore(
            &mut arguments,
            window,
            fields[4],
            fields[5] == signature,
            active,
        );
    } else {
        enlarge(
            &mut arguments,
            window,
            &panes,
            fields[4].is_empty() || fields[5] != signature,
            fields[6],
            &signature,
        );
    }
    if !arguments.is_empty() {
        keep_sidebar(&mut arguments, &panes);
        rt::call(options, arguments)?;
    }
    if toggle {
        refresh_styles(options)?;
    }
    Ok(())
}

fn keep_sidebar(arguments: &mut Vec<String>, panes: &[Pane<'_>]) {
    let Some(sidebar) = panes.iter().find(|pane| pane.role == "1") else {
        return;
    };
    arguments.extend([
        ";".into(),
        "if-shell".into(),
        "-F".into(),
        "-t".into(),
        sidebar.id.into(),
        format!("#{{!=:#{{pane_width}},{}}}", sidebar.width),
        format!("resize-pane -t {} -x {}", sidebar.id, sidebar.width),
    ]);
}

fn restore(
    arguments: &mut Vec<String>,
    window: &str,
    layout: &str,
    matching: bool,
    active: Option<&str>,
) {
    if layout.is_empty() {
        return;
    }
    if matching {
        if !arguments.is_empty() {
            arguments.push(";".into());
        }
        arguments.extend(["select-layout", "-t", window, layout].map(String::from));
        if let Some(pane) = active {
            arguments.extend([";", "select-pane", "-t", pane].map(String::from));
        }
    }
    setting(arguments, window, "@window_sidebar_focus_layout", "");
    setting(arguments, window, "@window_sidebar_focus_panes", "");
}

fn enlarge(
    arguments: &mut Vec<String>,
    window: &str,
    panes: &[Pane<'_>],
    save: bool,
    layout: &str,
    signature: &str,
) {
    let contents = panes
        .iter()
        .filter(|pane| pane.role.is_empty())
        .collect::<Vec<_>>();
    let Some(focused) = contents.iter().find(|pane| pane.active) else {
        return;
    };
    if contents.len() < 2 {
        return;
    }
    if save {
        setting(arguments, window, "@window_sidebar_focus_layout", layout);
        setting(arguments, window, "@window_sidebar_focus_panes", signature);
    }
    let left = contents.iter().map(|pane| pane.left).min().unwrap_or(0);
    let top = contents.iter().map(|pane| pane.top).min().unwrap_or(0);
    let right = contents
        .iter()
        .map(|pane| pane.left + pane.width)
        .max()
        .unwrap_or(0);
    let bottom = contents
        .iter()
        .map(|pane| pane.top + pane.height)
        .max()
        .unwrap_or(0);
    let horizontal = contents.iter().any(|pane| {
        pane.id != focused.id
            && pane.top < focused.top + focused.height
            && focused.top < pane.top + pane.height
    });
    let vertical = contents.iter().any(|pane| {
        pane.id != focused.id
            && pane.left < focused.left + focused.width
            && focused.left < pane.left + pane.width
    });
    for (resize, flag, size, current) in [
        (
            horizontal,
            "-x",
            (u32::from(right - left) * 85 / 100) as u16,
            focused.width,
        ),
        (
            vertical,
            "-y",
            (u32::from(bottom - top) * 85 / 100) as u16,
            focused.height,
        ),
    ] {
        if !resize || size == current {
            continue;
        }
        if !arguments.is_empty() {
            arguments.push(";".into());
        }
        arguments.extend(["resize-pane", "-t", focused.id, flag].map(String::from));
        arguments.push(size.max(1).to_string());
    }
}

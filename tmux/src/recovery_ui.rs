use crate::{
    Options,
    events::Reader,
    recovery::{self, Plan},
    ui,
};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, MouseButton, MouseEventKind};
use std::{io, time::Duration};

const RESTORE: &str = "[r] Restore all";
const SAVE: &str = "[s] Save snapshot";
const SAVE_WARNING: &str = "Saving adds a snapshot when the session changed. Five are kept.";
const PICK: &str = "1-5 or Left/Right: Snapshot";

fn detail(rows: &mut Vec<String>, text: &str, width: usize) {
    rows.extend(
        ui::wrapped_lines(text, width.saturating_sub(4).max(1))
            .into_iter()
            .map(|line| format!("    {line}")),
    );
}
fn count(amount: usize, noun: &str) -> String {
    format!("{amount} {noun}{}", if amount == 1 { "" } else { "s" })
}
fn age(saved_at: f64) -> String {
    let seconds = (crate::runtime::stamp() as f64 / 1e9 - saved_at).max(0.0) as u64;
    match seconds {
        0..60 => "just now".into(),
        60..3600 => format!("{} min ago", seconds / 60),
        3600..86400 => format!("{} h ago", seconds / 3600),
        _ => format!("{} d ago", seconds / 86400),
    }
}
fn lines(plan: &Plan, width: usize) -> Vec<String> {
    let mut rows = vec![
        format!(
            "Snapshot {} of {}, saved {}",
            plan.slot + 1,
            plan.slots,
            age(plan.snapshot.saved_at)
        ),
        format!("Source session: {}", plan.snapshot.session),
        format!("Restore into: {}", plan.destination),
        format!(
            "{} to restore ({} to resume, {} to rerun)",
            count(plan.snapshot.windows.len(), "window"),
            count(plan.eligible.len(), "conversation"),
            count(plan.commands.len(), "command")
        ),
    ];
    if !plan.commands.is_empty() {
        rows.push("Restore all runs the saved commands again.".into());
    }
    rows.extend([SAVE_WARNING.into(), String::new()]);
    for window in &plan.snapshot.windows {
        rows.push(format!("Window {}: {}", window.index, window.name));
        for pane in window.panes.iter().filter(|pane| !pane.sidebar) {
            pane_rows(&mut rows, pane, plan, width);
        }
        rows.push(String::new());
    }
    rows
}
fn pane_rows(rows: &mut Vec<String>, pane: &recovery::Pane, plan: &Plan, width: usize) {
    let title = if pane.label.is_empty() {
        &pane.title
    } else {
        &pane.label
    };
    let action = if plan.active.contains(&pane.agent.session_id)
        || plan.running_commands.contains(&pane.pane_id)
    {
        "Keep running".into()
    } else if pane.agent.session_id.is_empty()
        && crate::commands::is_codex_command(&pane.command.command)
    {
        "Cannot resume Codex (conversation ID missing)".into()
    } else if recovery::resume(&pane.agent).is_some() {
        let name = match pane.agent.agent.as_str() {
            "claude" => "Claude",
            "codex" => "Codex",
            name => name,
        };
        format!("Resume {name}")
    } else if plan.commands.contains(&pane.pane_id) {
        "Rerun command".into()
    } else {
        "Open shell".into()
    };
    rows.extend(
        ui::wrapped_lines(
            &format!("{action}: {title}"),
            width.saturating_sub(2).max(1),
        )
        .into_iter()
        .map(|line| format!("  {line}")),
    );
    if plan.commands.contains(&pane.pane_id) {
        detail(rows, &format!("Command: {}", pane.command.command), width);
    }
    if !pane.agent.launch.model.is_empty() {
        detail(rows, &format!("Model: {}", pane.agent.launch.model), width);
    }
    if !pane.agent.launch.launcher.is_empty() {
        detail(
            rows,
            &format!(
                "Launcher: {}",
                crate::commands::display(&pane.agent.launch.launcher)
            ),
            width,
        );
    }
    detail(rows, &format!("Folder: {}", pane.cwd), width);
}
fn load(options: &Options, sender: &std::sync::mpsc::Sender<io::Result<Plan>>, save: bool) {
    let background = options.clone();
    let sender = sender.clone();
    std::thread::spawn(move || {
        let result = (|| {
            if save {
                let mut reader =
                    Reader::new(background.event_root.clone(), background.host.clone());
                recovery::save(&background, &mut reader, true)?;
            }
            recovery::plan(&background)
        })();
        // Closing the preview cancels delivery, not the snapshot operation.
        let _ = sender.send(result);
    });
}
pub fn run(options: &Options) -> io::Result<()> {
    let mut options = options.clone();
    options.snapshot = 0;
    let options = &mut options;
    let (sender, receiver) = std::sync::mpsc::channel();
    load(options, &sender, false);
    let mut saving = false;
    let mut plan = Err(io::Error::other("Loading saved sessions..."));
    let mut loading = true;
    let _terminal = ui::Terminal::open()?;
    let mut offset = 0usize;
    let mut dirty = true;
    let mut notice = String::new();
    let mut rows = Vec::new();
    let mut rows_dirty = true;
    let mut wrapped_width = 0;
    let mut frame = std::time::Instant::now() - Duration::from_secs(1);
    loop {
        if let Ok(ready) = receiver.try_recv() {
            if saving && ready.is_ok() {
                notice = "Snapshot saved.".into();
                offset = 0;
            }
            match ready {
                Ok(ready) => plan = Ok(ready),
                Err(failure) if saving => notice = format!("Save failed: {failure}"),
                Err(failure) => plan = Err(failure),
            }
            loading = false;
            saving = false;
            rows_dirty = true;
            dirty = true;
        }
        let (width, height) = crossterm::terminal::size()?;
        let capacity = height.saturating_sub(2).max(1) as usize;
        if rows_dirty || wrapped_width != width {
            rows = match &plan {
                Ok(plan) => lines(plan, width as usize),
                Err(error) => vec![error.to_string(), SAVE_WARNING.into()],
            };
            if !notice.is_empty() {
                rows.insert(0, notice.clone());
            }
            rows_dirty = false;
            wrapped_width = width;
            dirty = true;
        }
        offset = offset.min(rows.len().saturating_sub(capacity));
        let available = plan
            .as_ref()
            .is_ok_and(|plan| !plan.eligible.is_empty() || !plan.commands.is_empty());
        let restore_label = if available {
            RESTORE
        } else {
            "Nothing to restore"
        };
        let save_column = restore_label.len() + 2;
        if dirty && (frame.elapsed() >= Duration::from_millis(16) || !event::poll(Duration::ZERO)?)
        {
            let footer = if saving {
                "Saving snapshot...  Esc: Close".into()
            } else if loading {
                "Loading saved sessions...  Esc: Close".into()
            } else {
                format!(
                    "{restore_label}  {SAVE}  {PICK}  Esc: Close  {}-{}/{}",
                    offset + 1,
                    (offset + capacity).min(rows.len()),
                    rows.len()
                )
            };
            ui::text_frame(
                "RECOVERY PREVIEW",
                &rows
                    .iter()
                    .skip(offset)
                    .take(capacity)
                    .cloned()
                    .collect::<Vec<_>>(),
                &footer,
            )?;
            dirty = false;
            frame = std::time::Instant::now();
        }
        if !event::poll(Duration::from_millis(20))? {
            continue;
        }
        let mut restore = false;
        let mut save = false;
        let mut pick = None;
        match event::read()? {
            Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Esc | KeyCode::Char('q') => return Ok(()),
                KeyCode::Down => offset = offset.saturating_add(1),
                KeyCode::Up => offset = offset.saturating_sub(1),
                KeyCode::PageDown => offset = offset.saturating_add(capacity),
                KeyCode::PageUp => offset = offset.saturating_sub(capacity),
                KeyCode::Char('r') => restore = available && !loading,
                KeyCode::Char('s') => save = !loading,
                KeyCode::Char(digit @ '1'..='5') => pick = Some(digit as usize - '1' as usize),
                KeyCode::Left => pick = options.snapshot.checked_sub(1),
                KeyCode::Right => pick = Some(options.snapshot + 1),
                _ => {}
            },
            Event::Mouse(mouse) => match mouse.kind {
                MouseEventKind::ScrollDown => offset = offset.saturating_add(3),
                MouseEventKind::ScrollUp => offset = offset.saturating_sub(3),
                MouseEventKind::Down(MouseButton::Left)
                    if mouse.row == height.saturating_sub(1) =>
                {
                    let column = mouse.column as usize;
                    save = !loading && (save_column..save_column + SAVE.len()).contains(&column);
                    restore = available && !loading && column < RESTORE.len();
                }
                _ => {}
            },
            _ => {}
        }
        let slots = plan.as_ref().map_or(0, |plan| plan.slots);
        if let Some(slot) =
            pick.filter(|slot| !loading && *slot < slots && *slot != options.snapshot)
        {
            options.snapshot = slot;
            loading = true;
            notice.clear();
            offset = 0;
            rows_dirty = true;
            load(options, &sender, false);
        }
        if save {
            options.snapshot = 0;
            loading = true;
            saving = true;
            notice.clear();
            rows_dirty = true;
            load(options, &sender, true);
        }
        if restore {
            rows_dirty = true;
            let commands = plan
                .as_ref()
                .map(|plan| plan.commands.iter().cloned().collect())
                .unwrap_or_default();
            let shown = plan.as_ref().ok().map(|plan| &plan.snapshot);
            match recovery::restore(options, &commands, shown) {
                Ok(Some(_)) => return Ok(()),
                Ok(None) => {
                    notice = "Nothing started; the saved programs are already running.".into()
                }
                Err(failure) => {
                    notice = failure.to_string();
                    loading = true;
                    load(options, &sender, false);
                }
            }
        }
        dirty = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        commands::Capture,
        events::Agent,
        recovery::{Pane, Snapshot, Window},
    };
    use std::collections::HashSet;

    #[test]
    fn preview_groups_clear_actions_under_the_saved_window() {
        let agent = Pane {
            pane_id: "%1".into(),
            label: "Review changes".into(),
            cwd: "/work/repo".into(),
            agent: Agent {
                agent: "claude".into(),
                session_id: "saved-conversation".into(),
                ..Default::default()
            },
            ..Default::default()
        };
        let command = Pane {
            pane_id: "%2".into(),
            label: "Development server".into(),
            command: Capture {
                command: "npm run dev".into(),
                ..Default::default()
            },
            ..Default::default()
        };
        let running = Pane {
            pane_id: "%3".into(),
            label: "Build".into(),
            ..Default::default()
        };
        let shell = Pane {
            pane_id: "%4".into(),
            label: "Terminal".into(),
            ..Default::default()
        };
        let plan = Plan {
            snapshot: Snapshot {
                session: "work".into(),
                windows: vec![Window {
                    index: 1,
                    name: "Project".into(),
                    panes: vec![agent, command, running, shell],
                    ..Default::default()
                }],
                ..Default::default()
            },
            slot: 1,
            slots: 3,
            active: HashSet::new(),
            eligible: vec!["%1".into()],
            commands: vec!["%2".into()],
            running_commands: HashSet::from(["%3".into()]),
            destination: "recovered-work".into(),
        };
        let preview = lines(&plan, 100).join("\n");
        assert!(
            preview.contains("1 window to restore (1 conversation to resume, 1 command to rerun)")
        );
        let heading = preview.find("Window 1: Project").unwrap();
        for action in [
            "Resume Claude: Review changes",
            "Rerun command: Development server",
            "Keep running: Build",
            "Open shell: Terminal",
        ] {
            assert!(preview.find(action).unwrap() > heading);
        }
        assert!(preview.contains("Snapshot 2 of 3, saved "));
        assert!(preview.contains("Command: npm run dev"));
        assert!(!preview.contains("saved-conversation"));
        assert!(!preview.contains("[ ]"));
    }
}

use crate::{
    Options,
    events::Reader,
    recovery::{self, Plan},
    ui,
};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, MouseButton, MouseEventKind};
use std::{collections::HashSet, io, time::Duration};

struct Row {
    text: String,
    command: Option<String>,
}
fn row(rows: &mut Vec<Row>, text: String) {
    rows.push(Row {
        text,
        command: None,
    });
}
fn lines(
    plan: &Plan,
    selected: &HashSet<String>,
    current: Option<&String>,
    width: usize,
) -> Vec<Row> {
    let mut rows = Vec::new();
    if plan.eligible.is_empty() && plan.commands.is_empty() {
        row(
            &mut rows,
            "No stopped conversations or saved commands are available.".into(),
        );
        row(
            &mut rows,
            "Running programs stay in their existing windows.".into(),
        );
    }
    row(
        &mut rows,
        format!("Source session: {}", plan.snapshot.session),
    );
    row(
        &mut rows,
        format!("Restore into: recovered-{}", plan.snapshot.session),
    );
    row(&mut rows, String::new());
    for window in &plan.snapshot.windows {
        row(
            &mut rows,
            format!("Window {}: {}", window.index, window.name),
        );
        for pane in window.panes.iter().filter(|pane| !pane.sidebar) {
            rows.extend(pane_rows(
                pane,
                window.index,
                plan,
                selected,
                current,
                width,
            ));
        }
    }
    rows
}
fn pane_rows(
    pane: &recovery::Pane,
    index: u32,
    plan: &Plan,
    selected: &HashSet<String>,
    current: Option<&String>,
    width: usize,
) -> Vec<Row> {
    let mut rows = Vec::new();
    let title = if pane.label.is_empty() {
        &pane.title
    } else {
        &pane.label
    };
    row(&mut rows, format!("{}  {title}", index));
    let action = if plan.active.contains(&pane.agent.session_id) {
        "Already running: keep the current conversation".into()
    } else if recovery::resume(&pane.agent).is_some() {
        format!("Resume {}: {}", pane.agent.agent, pane.agent.session_id)
    } else {
        "Open a terminal in the saved folder".into()
    };
    row(&mut rows, format!("   {action}"));
    if !pane.command.command.is_empty() {
        for text in ui::wrapped_lines(
            &format!("Saved command: {}", pane.command.command),
            width.saturating_sub(6).max(10),
        ) {
            row(&mut rows, format!("   {text}"));
        }
    }
    if plan.commands.contains(&pane.pane_id) {
        rows.push(Row {
            text: format!(
                " {} [{}] Rerun saved command",
                if current == Some(&pane.pane_id) {
                    "▸"
                } else {
                    " "
                },
                if selected.contains(&pane.pane_id) {
                    "x"
                } else {
                    " "
                }
            ),
            command: Some(pane.pane_id.clone()),
        });
    }
    row(&mut rows, format!("   Folder: {}", pane.cwd));
    row(&mut rows, String::new());
    rows
}
fn toggle(selected: &mut HashSet<String>, pane: &str) {
    if !selected.remove(pane) {
        selected.insert(pane.into());
    }
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
    let (sender, receiver) = std::sync::mpsc::channel();
    load(options, &sender, false);
    let mut saving = false;
    let mut plan = Err(io::Error::other("Loading saved sessions..."));
    let mut loading = true;
    let _terminal = ui::Terminal::open()?;
    let mut selected = HashSet::new();
    let mut current = 0;
    let mut offset = 0usize;
    let mut dirty = true;
    let mut error = String::new();
    let mut rows = Vec::new();
    let mut rows_dirty = true;
    let mut wrapped_width = 0;
    let mut frame = std::time::Instant::now() - Duration::from_secs(1);
    loop {
        if let Ok(ready) = receiver.try_recv() {
            if saving && ready.is_ok() {
                error = "Snapshot saved.".into();
                selected.clear();
                current = 0;
                offset = 0;
            }
            match ready {
                Ok(ready) => plan = Ok(ready),
                Err(failure) if saving => error = format!("Save failed: {failure}"),
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
                Ok(plan) => lines(plan, &selected, plan.commands.get(current), width as usize),
                Err(error) => vec![Row {
                    text: error.to_string(),
                    command: None,
                }],
            };
            rows.splice(
                0..0,
                [
                    Row {
                        text: "[s] Save current session".into(),
                        command: None,
                    },
                    Row {
                        text: "Saving replaces the latest snapshot for this session.".into(),
                        command: None,
                    },
                ],
            );
            if !error.is_empty() {
                rows.insert(
                    2,
                    Row {
                        text: error.clone(),
                        command: None,
                    },
                );
            }
            rows_dirty = false;
            wrapped_width = width;
            dirty = true;
        }
        offset = offset.min(rows.len().saturating_sub(capacity));
        let available = plan
            .as_ref()
            .is_ok_and(|plan| !plan.eligible.is_empty() || !selected.is_empty());
        if dirty && (frame.elapsed() >= Duration::from_millis(16) || !event::poll(Duration::ZERO)?)
        {
            let footer = if saving {
                "Saving snapshot...  Esc: Close".into()
            } else if loading {
                "Loading saved sessions...  Esc: Close".into()
            } else {
                format!(
                    "{}-{}/{}  {}  Space: Select  [c] Next command  Esc: Close",
                    offset + 1,
                    (offset + capacity).min(rows.len()),
                    rows.len(),
                    if available {
                        "r: Restore"
                    } else if plan.as_ref().is_ok_and(|plan| !plan.commands.is_empty()) {
                        "Select a saved command to enable Restore"
                    } else {
                        "Nothing to restore (already running)"
                    }
                )
            };
            ui::text_frame(
                "RECOVERY PREVIEW",
                &rows
                    .iter()
                    .skip(offset)
                    .take(capacity)
                    .map(|row| row.text.clone())
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
        match event::read()? {
            Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Esc | KeyCode::Char('q') => return Ok(()),
                KeyCode::Down => offset = offset.saturating_add(1),
                KeyCode::Up => offset = offset.saturating_sub(1),
                KeyCode::PageDown => offset = offset.saturating_add(capacity),
                KeyCode::PageUp => offset = offset.saturating_sub(capacity),
                KeyCode::Char('c') => {
                    rows_dirty = true;
                    if let Ok(plan) = &plan {
                        current = (current + 1) % plan.commands.len().max(1);
                        if let Some(index) = rows.iter().position(|row| {
                            row.command.as_ref() == plan.commands.get(current)
                                && row.command.is_some()
                        }) {
                            offset = index.saturating_sub(capacity / 2);
                        }
                    }
                }
                KeyCode::Char(' ') => {
                    if let Some(pane) = plan
                        .as_ref()
                        .ok()
                        .and_then(|plan| plan.commands.get(current))
                    {
                        toggle(&mut selected, pane);
                        rows_dirty = true;
                    }
                }
                KeyCode::Char('r') => restore = available && !loading,
                KeyCode::Char('s') => save = !loading,
                _ => {}
            },
            Event::Mouse(mouse) => match mouse.kind {
                MouseEventKind::ScrollDown => offset = offset.saturating_add(3),
                MouseEventKind::ScrollUp => offset = offset.saturating_sub(3),
                MouseEventKind::Down(MouseButton::Left)
                    if mouse.row == height.saturating_sub(1) =>
                {
                    restore = available && !loading
                }
                MouseEventKind::Down(MouseButton::Left) if mouse.row == 1 && offset == 0 => {
                    save = !loading;
                }
                MouseEventKind::Down(MouseButton::Left) if mouse.row > 0 => {
                    if let Some(pane) = rows
                        .get(offset + mouse.row as usize - 1)
                        .and_then(|row| row.command.as_ref())
                    {
                        toggle(&mut selected, pane);
                        rows_dirty = true;
                    }
                }
                _ => {}
            },
            _ => {}
        }
        if save {
            loading = true;
            saving = true;
            error.clear();
            rows_dirty = true;
            load(options, &sender, true);
        }
        if restore {
            rows_dirty = true;
            match recovery::restore(options, &selected) {
                Ok(Some(_)) => return Ok(()),
                Ok(None) => {
                    error = "Nothing started; the saved programs are already running.".into()
                }
                Err(failure) => error = failure.to_string(),
            }
        }
        dirty = true;
    }
}

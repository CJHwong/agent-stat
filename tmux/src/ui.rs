use crate::{
    Options,
    model::{self, Entry},
};
use crossterm::{
    cursor::{Hide, MoveTo, Show},
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
        MouseButton, MouseEventKind,
    },
    execute, queue,
    style::{
        Attribute, Color, Print, ResetColor, SetAttribute, SetBackgroundColor, SetForegroundColor,
    },
    terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::{
    io::{self, Write},
    sync::mpsc::{Receiver, Sender},
    time::Duration,
};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const PADDING: u16 = 2;

pub(crate) struct Terminal;
impl Terminal {
    pub(crate) fn open() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        let guard = Self;
        execute!(io::stdout(), EnterAlternateScreen, Hide, EnableMouseCapture)?;
        Ok(guard)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        if let Err(failure) = execute!(
            io::stdout(),
            ResetColor,
            SetAttribute(Attribute::Reset),
            DisableMouseCapture,
            Show,
            LeaveAlternateScreen
        ) {
            eprintln!("Cannot restore terminal display: {failure}");
        }
        if let Err(failure) = terminal::disable_raw_mode() {
            eprintln!("Cannot restore terminal input: {failure}");
        }
    }
}

#[derive(Default)]
struct View {
    entries: Vec<Entry>,
    query: String,
    selected: usize,
    search: bool,
    help: bool,
    details: bool,
    error: String,
    live: bool,
    overlay: bool,
}

impl View {
    fn can_recover(&self) -> bool {
        self.entries.iter().any(|entry| entry.recovery_available)
    }
    fn footer_rows(&self) -> u16 {
        3 + u16::from(self.can_recover())
    }
    fn list_start(&self) -> u16 {
        if self.live { 2 } else { 3 }
    }
    fn matches(&self) -> Vec<&Entry> {
        self.entries
            .iter()
            .filter(|entry| model::matches(entry, &self.query))
            .collect()
    }

    fn move_selection(&mut self, movement: i32) {
        let last = self.matches().len().saturating_sub(1);
        self.selected = self
            .selected
            .saturating_add_signed(movement as isize)
            .min(last);
    }

    fn update(&mut self, entries: Vec<Entry>) -> bool {
        // An exit hook selects adjacent content. Do not flash the first row meanwhile.
        if self.live && !self.entries.is_empty() && !entries.iter().any(|entry| entry.active) {
            return false;
        }
        let entries = if self.search {
            entries
        } else {
            model::grouped(entries)
        };
        if entries == self.entries {
            return false;
        }
        let previous_active = self
            .entries
            .iter()
            .find(|entry| entry.active && !entry.group)
            .map(|entry| entry.pane.clone());
        let new_active = entries
            .iter()
            .find(|entry| entry.active && !entry.group)
            .map(|entry| entry.pane.clone());
        let previous = self
            .matches()
            .get(self.selected)
            .map(|entry| entry.pane.clone());
        self.entries = entries;
        let matches = self.matches();
        let previous = if previous_active != new_active {
            new_active
        } else {
            previous
        };
        self.selected = previous
            .and_then(|pane| {
                matches
                    .iter()
                    .position(|entry| entry.pane == pane && !entry.group)
            })
            .unwrap_or_else(|| {
                matches
                    .iter()
                    .position(|entry| entry.active && !entry.group)
                    .unwrap_or(0)
            });
        true
    }
}

pub fn clip(text: &str, columns: usize) -> String {
    let mut width = 0;
    text.chars()
        .filter(|letter| !letter.is_control())
        .take_while(|letter| {
            width += letter.width().unwrap_or(0);
            width <= columns
        })
        .collect()
}

fn line(buffer: &mut Vec<u8>, row: u16, text: &str, width: u16) -> io::Result<()> {
    styled_line(buffer, row, text, width, Attribute::Reset)
}

fn styled_line(
    buffer: &mut Vec<u8>,
    row: u16,
    text: &str,
    width: u16,
    style: Attribute,
) -> io::Result<()> {
    queue!(
        buffer,
        MoveTo(PADDING, row),
        SetAttribute(Attribute::Reset),
        ResetColor,
        Clear(ClearType::CurrentLine),
        SetAttribute(style),
        Print(clip(text, width.saturating_sub(PADDING + 1) as usize))
    )
}

fn status_color(state: &str, unread: bool) -> Option<u8> {
    match state {
        "working" => Some(78),
        "waiting" if !unread => Some(75),
        "waiting" | "done" => Some(203),
        "failed" => Some(208),
        "idle" => Some(75),
        "interrupted" => Some(141),
        "closed" => Some(244),
        _ => None,
    }
}

fn draw_entry(
    buffer: &mut Vec<u8>,
    entry: &Entry,
    selected: bool,
    row: u16,
    width: u16,
) -> io::Result<()> {
    line(buffer, row, "", width)?;
    if selected {
        queue!(buffer, SetAttribute(Attribute::Reverse))?;
    }
    if entry.group {
        return styled_line(
            buffer,
            row,
            &format!("{}  {}", entry.index, entry.title),
            width,
            Attribute::Bold,
        );
    }
    let prefix = if entry.child {
        "    ".into()
    } else {
        format!("{}   ", entry.index)
    };
    let title = format!(
        "{prefix}{}{}",
        if entry.unread { "* " } else { "" },
        entry.title
    );
    let title = clip(&title, width.saturating_sub(PADDING + 1) as usize);
    queue!(
        buffer,
        Print(format!(
            "{}{}",
            title,
            " ".repeat((width.saturating_sub(PADDING + 1) as usize).saturating_sub(title.width()))
        ))
    )?;
    if let Some(color) = status_color(&entry.state, entry.unread) {
        queue!(
            buffer,
            MoveTo(
                PADDING
                    + if entry.child {
                        2
                    } else {
                        entry.index.to_string().len() as u16 + 1
                    },
                row
            )
        )?;
        if selected {
            queue!(
                buffer,
                SetForegroundColor(Color::Reset),
                SetBackgroundColor(Color::AnsiValue(color))
            )?;
        } else {
            queue!(buffer, SetForegroundColor(Color::AnsiValue(color)))?;
        }
        queue!(buffer, Print("●"))?;
    }
    styled_line(
        buffer,
        row + 1,
        &format!(
            "{}{}",
            " ".repeat(if entry.child {
                4
            } else {
                entry.index.to_string().len() + 3
            }),
            entry.folder
        ),
        width,
        Attribute::Dim,
    )
}

fn draw(view: &View) -> io::Result<()> {
    let (width, height) = terminal::size()?;
    let mut buffer = Vec::new();
    queue!(
        buffer,
        ResetColor,
        SetAttribute(Attribute::Reset),
        MoveTo(0, 0),
        Clear(ClearType::All)
    )?;
    if width < 7 || height < 8 {
        queue!(
            buffer,
            MoveTo(width.saturating_sub(1) / 2, height.saturating_sub(1) / 2),
            SetAttribute(Attribute::Bold),
            SetForegroundColor(Color::White),
            Print("▶")
        )?;
        queue!(buffer, ResetColor, SetAttribute(Attribute::Reset))?;
        io::stdout().write_all(&buffer)?;
        return io::stdout().flush();
    }
    let matches = view.matches();
    if view.live {
        styled_line(
            &mut buffer,
            0,
            "+ New  Split  Rename",
            width,
            Attribute::Dim,
        )?;
    } else {
        let heading = if view.search {
            format!("/ {}", view.query)
        } else {
            "FIND WINDOW OR PANE".into()
        };
        styled_line(&mut buffer, 0, &heading, width, Attribute::Bold)?;
        styled_line(
            &mut buffer,
            1,
            "Arrows: Select a pane",
            width,
            Attribute::Dim,
        )?;
    }
    let shown = visible(view, height);
    let (above, below) = overflow(&shown, matches.len());
    for (index, entry, row) in shown {
        draw_entry(&mut buffer, entry, index == view.selected, row, width)?;
    }
    if view.help {
        draw_help(&mut buffer, width, height)?;
    }
    if view.details {
        draw_details(
            &mut buffer,
            matches.get(view.selected).copied(),
            width,
            height,
        )?;
    }
    if view.live {
        if above {
            styled_line(&mut buffer, 1, "▲ More above", width, Attribute::Bold)?;
        }
        if below {
            styled_line(
                &mut buffer,
                height - view.footer_rows() - 1,
                "▼ More below",
                width,
                Attribute::Bold,
            )?;
        }
        if !view.error.is_empty() {
            line(
                &mut buffer,
                height - view.footer_rows() - 2,
                &view.error,
                width,
            )?;
        }
        if view.can_recover() {
            styled_line(&mut buffer, height - 4, "Recover", width, Attribute::Dim)?;
        }
        styled_line(
            &mut buffer,
            height - 3,
            "Search     Ctrl+b /",
            width,
            Attribute::Dim,
        )?;
        styled_line(
            &mut buffer,
            height - 2,
            "Actions    F1",
            width,
            Attribute::Dim,
        )?;
        styled_line(
            &mut buffer,
            height - 1,
            if view.overlay {
                "Esc: Close overlay"
            } else {
                "Shortcuts  Ctrl+b ?"
            },
            width,
            Attribute::Dim,
        )?;
    } else {
        line(&mut buffer, height - 2, &view.error, width)?;
        line(
            &mut buffer,
            height - 1,
            "F1: Help  /: Search  Enter: Select  Esc: Close",
            width,
        )?;
    }
    io::stdout().write_all(&buffer)?;
    io::stdout().flush()
}

fn draw_help(buffer: &mut Vec<u8>, width: u16, height: u16) -> io::Result<()> {
    let help = [
        "SHORTCUTS",
        "Arrows / wheel: Move",
        "Enter / click: Select pane",
        "/: Search title, folder, command",
        "f / right-click: Full details",
        "F1: Close this help",
        "Esc: Close view",
        "F1: Pane controls and full command",
    ];
    for (index, text) in help
        .iter()
        .take(height.saturating_sub(4) as usize)
        .enumerate()
    {
        line(buffer, index as u16 + 2, text, width)?;
    }
    Ok(())
}

fn draw_details(
    buffer: &mut Vec<u8>,
    entry: Option<&Entry>,
    width: u16,
    height: u16,
) -> io::Result<()> {
    let Some(entry) = entry else { return Ok(()) };
    let text = format!(
        "Title: {}\nFolder: {}\nCommand: {}",
        entry.title, entry.folder, entry.command
    );
    for (index, text) in text
        .lines()
        .take(height.saturating_sub(5) as usize)
        .enumerate()
    {
        line(buffer, index as u16 + 3, text, width)?;
    }
    Ok(())
}

fn invoke(options: &Options, action: &str, entry: Option<&Entry>) -> io::Result<()> {
    crate::actions::with_entry(
        options,
        action,
        entry.map(|entry| entry.pane.as_str()),
        entry,
    )
}

fn visible(view: &View, height: u16) -> Vec<(usize, &Entry, u16)> {
    let entries = view.matches();
    let limit = height.saturating_sub(if view.live {
        view.footer_rows() + 1 + u16::from(!view.error.is_empty())
    } else {
        2
    });
    let capacity = limit.saturating_sub(view.list_start()).max(1);
    let mut offset = view.selected.min(entries.len().saturating_sub(1));
    let mut used = entries
        .get(offset)
        .map(|entry| if entry.group { 1 } else { 3 })
        .unwrap_or(0);
    while offset > 0 && used + if entries[offset - 1].group { 1 } else { 3 } <= capacity {
        offset -= 1;
        used += if entries[offset].group { 1 } else { 3 };
    }
    let mut row = view.list_start();
    let mut result = Vec::new();
    for (index, entry) in entries.into_iter().enumerate().skip(offset) {
        let height = if entry.group { 1 } else { 3 };
        if row + height > limit {
            break;
        }
        result.push((index, entry, row));
        row += height;
    }
    result
}
fn overflow(shown: &[(usize, &Entry, u16)], total: usize) -> (bool, bool) {
    let above = shown.first().is_some_and(|(index, _, _)| *index > 0);
    let below = shown
        .last()
        .map_or(total > 0, |(index, _, _)| index + 1 < total);
    (above, below)
}

fn mouse(view: &mut View, options: &Options, event: event::MouseEvent) -> io::Result<bool> {
    // Tmux can forward repeated clicks as releases. Activate each left click once.
    let mut event = event;
    if event.kind == MouseEventKind::Down(MouseButton::Left) {
        return Ok(false);
    }
    if event.kind == MouseEventKind::Up(MouseButton::Left) {
        event.kind = MouseEventKind::Down(MouseButton::Left);
    }
    let (width, height) = terminal::size()?;
    let active = view
        .entries
        .iter()
        .find(|entry| entry.active && !entry.group);
    let column = event.column.saturating_sub(PADDING);
    if view.live && matches!(event.kind, MouseEventKind::Down(MouseButton::Left)) {
        let action = if width < 7 {
            Some("expand")
        } else if event.row == 0 {
            Some(if column < 7 {
                "new"
            } else if column < 14 {
                "split"
            } else {
                "rename"
            })
        } else if view.can_recover() && event.row == height - 4 {
            Some("recover")
        } else if event.row == height - 3 {
            Some("search")
        } else if event.row == height - 2 {
            Some("menu")
        } else if event.row == height - 1 && !view.overlay {
            Some("keys")
        } else {
            None
        };
        if let Some(action) = action {
            invoke(options, action, active)?;
            return Ok(false);
        }
    }
    match event.kind {
        MouseEventKind::ScrollDown => view.move_selection(3),
        MouseEventKind::ScrollUp => view.move_selection(-3),
        MouseEventKind::Down(button)
            if event.row >= view.list_start()
                && event.row < height.saturating_sub(if view.live { 4 } else { 2 }) =>
        {
            if let Some((index, _, _)) =
                visible(view, height).into_iter().find(|(_, entry, row)| {
                    event.row >= *row && event.row < *row + if entry.group { 1 } else { 2 }
                })
            {
                view.selected = index;
            } else {
                return Ok(false);
            }
            if button == MouseButton::Right {
                if view.live {
                    invoke(options, "menu", view.matches().get(view.selected).copied())?;
                } else {
                    view.details = true;
                }
                return Ok(false);
            }
            if button == MouseButton::Left {
                return choose(view, options);
            }
        }
        _ => {}
    }
    Ok(false)
}

fn choose(view: &mut View, options: &Options) -> io::Result<bool> {
    if let Some(entry) = view.matches().get(view.selected) {
        model::select(&options.socket, entry)?;
        return Ok(options.action == "search-ui" || options.action == "overlay");
    }
    Ok(false)
}

fn key(view: &mut View, options: &Options, key: event::KeyEvent) -> io::Result<bool> {
    if key.kind == KeyEventKind::Release {
        return Ok(false);
    }
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') if view.overlay => {
            if let Some(entry) = view
                .entries
                .iter()
                .find(|entry| entry.active && !entry.group)
            {
                model::select(&options.socket, entry)?;
            }
            return Ok(true);
        }
        KeyCode::Esc if view.live => {
            if let Some(entry) = view
                .entries
                .iter()
                .find(|entry| entry.active && !entry.group)
            {
                model::select(&options.socket, entry)?;
            }
        }
        KeyCode::Esc => return Ok(true),
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => return Ok(true),
        KeyCode::F(1) if view.live => invoke(
            options,
            "menu",
            view.entries
                .iter()
                .find(|entry| entry.active && !entry.group),
        )?,
        KeyCode::F(1) => view.help = !view.help,
        KeyCode::Down => view.move_selection(1),
        KeyCode::Up => view.move_selection(-1),
        KeyCode::Enter => return choose(view, options),
        KeyCode::Backspace if view.search => {
            view.query.pop();
            view.selected = 0;
        }
        KeyCode::Char('/') if view.live => invoke(
            options,
            "search",
            view.entries
                .iter()
                .find(|entry| entry.active && !entry.group),
        )?,
        KeyCode::Char('/') if !view.search => {
            view.search = true;
            view.selected = 0;
        }
        KeyCode::Char(letter) if view.search => {
            view.query.push(letter);
            view.selected = 0;
        }
        KeyCode::Char('f') => view.details = !view.details,
        _ => {}
    }
    Ok(false)
}

pub fn run(
    options: &Options,
    receiver: Receiver<Result<Vec<Entry>, String>>,
    wake: Sender<()>,
) -> io::Result<()> {
    let _terminal = Terminal::open()?;
    let mut view = View {
        search: options.action == "search-ui",
        live: options.action != "search-ui",
        overlay: options.action == "overlay",
        ..View::default()
    };
    if let Ok(initial) = receiver.try_recv() {
        match initial {
            Ok(entries) => {
                view.update(entries);
            }
            Err(error) => view.error = error,
        }
    }
    draw(&view)?;
    let mut docking = std::time::Instant::now();
    let mut dirty = false;
    let mut frame = std::time::Instant::now();
    loop {
        if view.overlay && docking.elapsed() >= Duration::from_millis(150) {
            docking = std::time::Instant::now();
            let width = model::tmux(
                &options.socket,
                &[
                    "display-message",
                    "-p",
                    "-t",
                    options.pane.as_deref().unwrap_or(&options.session),
                    "#{window_width}",
                ],
            )?;
            if width.parse::<u16>().unwrap_or(0) >= 100 {
                if let Some(entry) = view
                    .entries
                    .iter()
                    .find(|entry| entry.active && !entry.group)
                {
                    model::select(&options.socket, entry)?;
                }
                return Ok(());
            }
        }
        let mut changed = false;
        while let Ok(result) = receiver.try_recv() {
            match result {
                Ok(entries) => {
                    changed |= view.update(entries);
                }
                Err(failure) => {
                    view.error = failure;
                    changed = true;
                }
            }
        }
        if event::poll(Duration::from_millis(10))? {
            let outcome = match event::read()? {
                Event::Key(event) if matches!(event.code, KeyCode::F(12) | KeyCode::F(24)) => {
                    if wake.send(()).is_err() {
                        return Err(io::Error::other("Sidebar refresh worker exited"));
                    }
                    Ok(false)
                }
                Event::Key(event) => key(&mut view, options, event),
                Event::Mouse(event) => mouse(&mut view, options, event),
                _ => Ok(false),
            };
            let exit = match outcome {
                Ok(exit) => exit,
                Err(failure) => {
                    view.error = failure.to_string();
                    false
                }
            };
            if exit {
                return Ok(());
            }
            changed = true;
        }
        dirty |= changed;
        if dirty && (frame.elapsed() >= Duration::from_millis(16) || !event::poll(Duration::ZERO)?)
        {
            draw(&view)?;
            dirty = false;
            frame = std::time::Instant::now();
        }
    }
}

pub fn text_frame(heading: &str, lines: &[String], footer: &str) -> io::Result<()> {
    let (width, height) = terminal::size()?;
    let mut buffer = Vec::new();
    queue!(buffer, MoveTo(0, 0), Clear(ClearType::All))?;
    styled_line(&mut buffer, 0, heading, width, Attribute::Bold)?;
    for (index, text) in lines
        .iter()
        .take(height.saturating_sub(2) as usize)
        .enumerate()
    {
        line(&mut buffer, index as u16 + 1, text, width)?;
    }
    if height > 1 {
        styled_line(&mut buffer, height - 1, footer, width, Attribute::Dim)?;
    }
    io::stdout().write_all(&buffer)?;
    io::stdout().flush()
}

pub fn pager(heading: &str, text: String) -> io::Result<()> {
    let _terminal = Terminal::open()?;
    let mut offset = 0usize;
    let mut dirty = true;
    let mut wrapped_width = 0;
    let mut lines = Vec::new();
    let mut frame = std::time::Instant::now() - Duration::from_secs(1);
    loop {
        let (width, height) = terminal::size()?;
        let capacity = height.saturating_sub(2).max(1) as usize;
        if wrapped_width != width {
            lines = wrapped_lines(&text, width.saturating_sub(4).max(1) as usize);
            wrapped_width = width;
            dirty = true;
        }
        offset = offset.min(lines.len().saturating_sub(capacity));
        if dirty && (frame.elapsed() >= Duration::from_millis(16) || !event::poll(Duration::ZERO)?)
        {
            text_frame(
                heading,
                &lines
                    .iter()
                    .skip(offset)
                    .take(capacity)
                    .cloned()
                    .collect::<Vec<_>>(),
                &format!(
                    "{}-{}/{}  Arrows/wheel: Scroll  Esc/q: Close",
                    offset + 1,
                    (offset + capacity).min(lines.len()),
                    lines.len()
                ),
            )?;
            dirty = false;
            frame = std::time::Instant::now();
        }
        if !event::poll(Duration::from_millis(20))? {
            continue;
        }
        match event::read()? {
            Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Esc | KeyCode::Char('q') => return Ok(()),
                KeyCode::Down => offset = offset.saturating_add(1),
                KeyCode::Up => offset = offset.saturating_sub(1),
                KeyCode::PageDown => offset = offset.saturating_add(capacity),
                KeyCode::PageUp => offset = offset.saturating_sub(capacity),
                _ => {}
            },
            Event::Mouse(mouse) => match mouse.kind {
                MouseEventKind::ScrollDown => offset = offset.saturating_add(3),
                MouseEventKind::ScrollUp => offset = offset.saturating_sub(3),
                _ => {}
            },
            _ => {}
        }
        dirty = true;
    }
}

pub fn wrapped_lines(text: &str, width: usize) -> Vec<String> {
    text.lines()
        .flat_map(|line| wrapped_line(line, width))
        .collect()
}
fn wrapped_line(text: &str, width: usize) -> Vec<String> {
    let clean: String = text.chars().filter(|letter| !letter.is_control()).collect();
    if clean.is_empty() {
        return vec![String::new()];
    }
    let mut result = Vec::new();
    let mut remaining = clean.as_str();
    while !remaining.is_empty() {
        let part = clip(remaining, width.max(1));
        if part.is_empty() {
            break;
        }
        let length = part.len();
        result.push(part);
        remaining = &remaining[length..];
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recover_row_uses_only_published_availability() {
        let mut view = View {
            live: true,
            entries: vec![Entry::default()],
            ..View::default()
        };
        assert!(!view.can_recover());
        assert_eq!(view.footer_rows(), 3);
        view.entries[0].recovery_available = true;
        assert!(view.can_recover());
        assert_eq!(view.footer_rows(), 4);
    }
    #[test]
    fn overflow_indicators_follow_scroll_and_resize() {
        let entries = (0..6)
            .map(|index| Entry {
                index,
                window: format!("@{index}"),
                pane: format!("%{index}"),
                ..Entry::default()
            })
            .collect();
        let mut view = View {
            live: true,
            entries,
            ..View::default()
        };
        assert_eq!(overflow(&visible(&view, 17), 6), (false, true));
        view.selected = 3;
        assert_eq!(overflow(&visible(&view, 17), 6), (true, true));
        view.selected = 5;
        assert_eq!(overflow(&visible(&view, 17), 6), (true, false));
        assert_eq!(overflow(&visible(&view, 40), 6), (false, false));
        view.entries.clear();
        assert_eq!(overflow(&visible(&view, 17), 0), (false, false));
    }
    #[test]
    fn sidebar_selection_waits_for_the_next_content_window() {
        let first = Entry {
            window: "@0".into(),
            pane: "%0".into(),
            index: 0,
            ..Entry::default()
        };
        let second = Entry {
            window: "@1".into(),
            pane: "%1".into(),
            index: 1,
            ..Entry::default()
        };
        let third = Entry {
            window: "@2".into(),
            pane: "%2".into(),
            index: 2,
            active: true,
            ..Entry::default()
        };
        let mut view = View {
            live: true,
            ..View::default()
        };
        view.update(vec![first.clone(), second.clone(), third]);
        assert_eq!(view.selected, 2);
        assert!(!view.update(vec![first.clone(), second.clone()]));
        assert_eq!(view.selected, 2);
        let next = Entry {
            active: true,
            ..second
        };
        assert!(view.update(vec![first, next]));
        assert_eq!(view.selected, 1);
    }
    #[test]
    fn unchanged_grouped_windows_do_not_request_a_redraw() {
        let first = Entry {
            window: "@0".into(),
            pane: "%0".into(),
            active: true,
            ..Entry::default()
        };
        let second = Entry {
            pane: "%1".into(),
            ..first.clone()
        };
        let mut view = View {
            live: true,
            ..View::default()
        };
        assert!(view.update(vec![first.clone(), second.clone()]));
        assert!(!view.update(vec![first, second]));
    }
    #[test]
    fn clips_wide_text_by_terminal_columns() {
        assert_eq!(clip("台灣abc", 5), "台灣a");
        assert_eq!(clip("abc", 2), "ab");
    }
    #[test]
    fn unknown_status_has_no_indicator() {
        assert_eq!(status_color("", false), None);
        assert_eq!(status_color("idle", false), Some(75));
        assert_eq!(status_color("waiting", true), Some(203));
        assert_eq!(status_color("waiting", false), Some(75));
    }
}

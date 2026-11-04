use crate::{Options, model, runtime as rt, shared};
use crossterm::event::{
    Event, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, env, io, os::unix::net::UnixDatagram, time::Duration};

#[derive(Serialize, Deserialize)]
pub(crate) struct Request {
    pub pane: String,
    pub client: Option<String>,
    pub input: String,
}

pub fn send(options: &Options) -> io::Result<()> {
    let request = Request {
        pane: options
            .pane
            .clone()
            .ok_or_else(|| io::Error::other("Missing input pane"))?,
        client: options.client.clone(),
        input: options
            .input
            .clone()
            .ok_or_else(|| io::Error::other("Missing input event"))?,
    };
    let path = shared::endpoint(options)?;
    let socket = UnixDatagram::unbound()?;
    let bytes = serde_json::to_vec(&request)?;
    if socket.send_to(&bytes, &path).is_ok() {
        return Ok(());
    }
    shared::start(options)?;
    for _ in 0..20 {
        std::thread::sleep(Duration::from_millis(25));
        match socket.send_to(&bytes, &path) {
            Ok(_) => return Ok(()),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                ) => {}
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::other("Shared service is unavailable"))
}

pub(crate) fn event(input: &str) -> io::Result<Event> {
    let fields = input.split(':').collect::<Vec<_>>();
    if fields.len() == 3 {
        let kind = match fields[0] {
            // The existing mouse handler activates left clicks on release.
            "mouse-left" => MouseEventKind::Up(MouseButton::Left),
            "mouse-right" => MouseEventKind::Down(MouseButton::Right),
            "wheel-up" => MouseEventKind::ScrollUp,
            "wheel-down" => MouseEventKind::ScrollDown,
            _ => return Err(io::Error::other("Unknown mouse event")),
        };
        let column = fields[1].parse::<u16>().map_err(io::Error::other)?;
        let row = fields[2].parse::<u16>().map_err(io::Error::other)?;
        return Ok(Event::Mouse(MouseEvent {
            kind,
            column,
            row,
            modifiers: KeyModifiers::NONE,
        }));
    }
    let code = match input {
        "Up" => KeyCode::Up,
        "Down" => KeyCode::Down,
        "Enter" => KeyCode::Enter,
        "Escape" => KeyCode::Esc,
        "F1" => KeyCode::F(1),
        "/" => KeyCode::Char('/'),
        _ => return Err(io::Error::other("Unknown sidebar key")),
    };
    Ok(Event::Key(KeyEvent::new(code, KeyModifiers::NONE)))
}

fn current_bindings(options: &Options) -> io::Result<HashMap<String, String>> {
    let lines = model::tmux(&options.socket, &["list-keys", "-T", "root"])?;
    Ok(lines
        .lines()
        .filter_map(|line| {
            let (_, binding) = line.split_once("root ")?;
            let (key, command) = binding.trim_start().split_once(char::is_whitespace)?;
            Some((key.to_owned(), command.trim_start().to_owned()))
        })
        .collect())
}

fn branch_commands(commands: &str) -> String {
    let mut result = String::new();
    let mut quoted = None;
    let mut letters = commands.chars().peekable();
    while let Some(letter) = letters.next() {
        if letter == '\\' {
            let next = letters.next();
            if next != Some(';') || quoted.is_some() {
                result.push(letter);
            }
            result.extend(next);
            continue;
        }
        if Some(letter) == quoted {
            quoted = None;
        } else if quoted.is_none() && matches!(letter, '\'' | '"') {
            quoted = Some(letter);
        }
        result.push(letter);
    }
    result
}

pub fn install(options: &Options) -> io::Result<()> {
    let _lock = rt::lock(
        &shared::endpoint(options)?.with_extension("bindings.lock"),
        false,
    )?;
    let current = current_bindings(options)?;
    let saved = model::tmux(
        &options.socket,
        &["show-option", "-sqv", "@shared_original_bindings"],
    )?;
    let mut originals: HashMap<String, String> = if saved.is_empty() {
        HashMap::new()
    } else {
        serde_json::from_str(&saved)?
    };
    let binary = env::current_exe()?.to_string_lossy().into_owned();
    for (key, input) in [
        ("MouseDown1Pane", "mouse-left"),
        ("DoubleClick1Pane", "mouse-left"),
        ("TripleClick1Pane", "mouse-left"),
        ("MouseDown3Pane", "mouse-right"),
        ("WheelUpPane", "wheel-up"),
        ("WheelDownPane", "wheel-down"),
        ("Up", "Up"),
        ("Down", "Down"),
        ("Enter", "Enter"),
        ("Escape", "Escape"),
        ("F1", "F1"),
        ("/", "/"),
    ] {
        install_binding(options, &binary, &current, &mut originals, key, input)?;
    }
    model::tmux(
        &options.socket,
        &[
            "set-option",
            "-s",
            "@shared_original_bindings",
            &serde_json::to_string(&originals)?,
        ],
    )?;
    Ok(())
}

fn install_binding(
    options: &Options,
    binary: &str,
    current: &HashMap<String, String>,
    originals: &mut HashMap<String, String>,
    key: &str,
    input: &str,
) -> io::Result<()> {
    let existing = current.get(key);
    if existing.is_some_and(|command| command.contains("shared-input") && command.contains(binary))
    {
        return Ok(());
    }
    if let Some(command) = existing.filter(|command| !command.contains("shared-input")) {
        originals.insert(key.into(), command.clone());
    }
    let mouse = key.contains("Pane");
    let fallback = originals.get(key).cloned().unwrap_or_else(|| {
        if mouse {
            "send-keys -M".into()
        } else {
            format!("send-keys {}", rt::quote(key))
        }
    });
    let fallback = branch_commands(&fallback);
    let pane = if mouse { "#{mouse_pane}" } else { "#{pane_id}" };
    let input = if mouse {
        format!("{input}:#{{mouse_x}}:#{{mouse_y}}")
    } else {
        input.into()
    };
    let command = format!(
        "{} --socket '#{{socket_path}}' --session '#{{session_id}}' --pane '{}' --client '#{{client_name}}' --input '{}' shared-input",
        rt::quote(binary),
        pane,
        input
    );
    let quoted = command
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$");
    // The client queue must retain key order while each helper sends its event.
    let branch = format!("run-shell \"{quoted}\"");
    let mut args = vec!["bind-key", "-T", "root", key, "if-shell", "-F"];
    if mouse {
        args.extend(["-t", "="]);
    }
    args.extend(["#{@shared_sidebar}", &branch, &fallback]);
    model::tmux(&options.socket, &args)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fallback_branches_keep_literal_semicolons() {
        assert_eq!(
            branch_commands("select-pane -t = \\; send-keys -M"),
            "select-pane -t = ; send-keys -M"
        );
        assert_eq!(
            branch_commands("send-keys 'literal \\; text'"),
            "send-keys 'literal \\; text'"
        );
    }
    #[test]
    fn mouse_coordinates_remain_relative_to_the_pane() {
        let Event::Mouse(mouse) = event("mouse-left:5:6").unwrap() else {
            panic!("mouse event expected")
        };
        assert_eq!((mouse.column, mouse.row), (5, 6));
        assert_eq!(mouse.kind, MouseEventKind::Up(MouseButton::Left));
        assert!(event("mouse-left:invalid:11").is_err());
        assert!(event("unknown").is_err());
    }
}

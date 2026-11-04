use regex::Regex;
use serde::Serialize;
use std::{collections::HashMap, io, path::Path, process::Command, sync::LazyLock};

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Entry {
    pub window: String,
    pub pane: String,
    pub index: u32,
    pub title: String,
    pub folder: String,
    pub command: String,
    pub active: bool,
    pub window_active: bool,
    pub root_pid: u32,
    pub state: String,
    pub cwd: String,
    pub seen: String,
    pub completion: String,
    pub attention: String,
    pub unread: bool,
    pub group: bool,
    pub child: bool,
    pub window_label: String,
    pub recovery_available: bool,
}

#[derive(Clone, Debug)]
pub struct Process {
    pub parent: u32,
    pub group: u32,
    pub foreground: u32,
    pub started: String,
    pub command: String,
}

pub fn tmux(socket: &str, arguments: &[&str]) -> io::Result<String> {
    let output = Command::new("tmux")
        .args(["-S", socket])
        .args(arguments)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end_matches('\n')
        .to_owned())
}

pub fn processes() -> io::Result<HashMap<u32, Process>> {
    let output = Command::new("/bin/ps")
        .args(["-axo", "pid=,ppid=,pgid=,tpgid=,lstart=,command="])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("Cannot read process list"));
    }
    let mut result = HashMap::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 10 {
            continue;
        }
        let Ok(pid) = fields[0].parse() else { continue };
        result.insert(
            pid,
            Process {
                parent: fields[1].parse().unwrap_or(0),
                group: fields[2].parse().unwrap_or(0),
                foreground: fields[3].parse().unwrap_or(0),
                started: fields[4..9].join(" "),
                command: redact(&fields[9..].join(" ")),
            },
        );
    }
    Ok(result)
}

pub fn belongs(pid: u32, root: u32, processes: &HashMap<u32, Process>) -> bool {
    let mut current = pid;
    for _ in 0..128 {
        if current == root {
            return true;
        }
        let Some(process) = processes.get(&current) else {
            return false;
        };
        if current == process.parent {
            return false;
        }
        current = process.parent;
    }
    false
}

static SECRETS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
    r#"(?i)(--?(?:password|passwd|token|api[-_]?key|secret|authorization)(?:=|\s+))('[^']*'|"[^"]*"|\S+)"#
).expect("constant credential pattern")
});
static ENV_SECRETS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY)[A-Z0-9_]*=)('[^']*'|"[^"]*"|\S+)"#,
    )
    .expect("constant environment pattern")
});
static URL_SECRETS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"https?://[^/\s]+:[^/\s]+@").expect("constant URL pattern"));

pub fn redact(command: &str) -> String {
    let clean: String = command
        .chars()
        .filter(|letter| !letter.is_control())
        .collect();
    let flags = SECRETS.replace_all(&clean, "${1}[hidden]");
    let environment = ENV_SECRETS.replace_all(&flags, "${1}[hidden]");
    URL_SECRETS
        .replace_all(&environment, "https://[hidden]@")
        .into_owned()
}

pub fn entries(
    socket: &str,
    session: &str,
    processes: &HashMap<u32, Process>,
) -> io::Result<Vec<Entry>> {
    let format = "#{window_id}\t#{window_index}\t#{window_active}\t#{pane_id}\t#{pane_current_path}\t#{@window_sidebar}\t#{pane_title}\t#{pane_active}\t#{host}\t#{pane_current_command}\t#{pane_pid}\t#{@window_sidebar_label}\t#{pane_last}\t#{@window_sidebar_seen}\t#{@window_sidebar_window_label}\t#{@window_sidebar_target}\t#{@window_sidebar_recovery}";
    let text = tmux(socket, &["list-panes", "-s", "-t", session, "-F", format])?;
    let mut result = Vec::new();
    for line in text.lines() {
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() != 17 || !fields[5].is_empty() {
            continue;
        }
        result.push(entry(&fields, processes));
    }
    for entry in &mut result {
        if !entry.window_active {
            entry.active = false;
        }
    }
    let active_content = text.lines().find_map(|line| {
        let fields: Vec<_> = line.split('\t').collect();
        (fields.len() == 17 && fields[2] == "1" && fields[7] == "1" && fields[5].is_empty())
            .then(|| fields[3])
    });
    if let Some(pane) = active_content {
        for entry in &mut result {
            entry.active = entry.window_active && entry.pane == pane;
        }
    }
    if !result.iter().any(|entry| entry.active) {
        if let Some(entry) = result.iter_mut().find(|entry| entry.window_active) {
            entry.active = true;
        }
    }
    result.sort_by_key(|entry| entry.index);
    Ok(result)
}

fn entry(fields: &[&str], processes: &HashMap<u32, Process>) -> Entry {
    let root_pid = fields[10].parse().unwrap_or(0);
    let foreground = processes.get(&crate::commands::foreground(root_pid, processes));
    let mut command = foreground
        .map(|process| process.command.clone())
        .or_else(|| {
            processes
                .get(&root_pid)
                .map(|process| process.command.clone())
        })
        .unwrap_or_else(|| fields[9].to_owned());
    if command.contains("agent-stat-new-") {
        command = processes
            .get(&root_pid)
            .and_then(|process| process.command.split_whitespace().next())
            .and_then(|program| Path::new(program).file_name())
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "shell".into());
    }
    let folder = Path::new(fields[4])
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let title = fields[6]
        .trim()
        .trim_start_matches(['✳', '✶', '✻', '✽', '✢', '*', ' ']);
    let title = if !fields[11].is_empty() {
        fields[11]
    } else if title.is_empty()
        || title == fields[8]
        || title == fields[8].split('.').next().unwrap_or_default()
        || title == fields[4]
        || title == folder
    {
        &command
    } else {
        title
    };
    Entry {
        window: fields[0].into(),
        pane: fields[3].into(),
        index: fields[1].parse().unwrap_or(0),
        title: title
            .chars()
            .filter(|letter| !letter.is_control())
            .collect(),
        folder,
        command,
        active: fields[2] == "1"
            && (fields[7] == "1" || fields[12] == "1" || fields[3] == fields[15]),
        window_active: fields[2] == "1",
        root_pid,
        state: String::new(),
        cwd: fields[4].into(),
        seen: fields[13].into(),
        window_label: fields[14].into(),
        recovery_available: fields[16] == "1",
        ..Entry::default()
    }
}

pub fn grouped(entries: Vec<Entry>) -> Vec<Entry> {
    let mut windows: Vec<Vec<Entry>> = Vec::new();
    for entry in entries {
        if let Some(window) = windows
            .last_mut()
            .filter(|window| window[0].window == entry.window)
        {
            window.push(entry);
        } else {
            windows.push(vec![entry]);
        }
    }
    let mut result = Vec::new();
    for mut window in windows {
        if window.len() == 1 {
            result.append(&mut window);
            continue;
        }
        let chosen = window
            .iter()
            .find(|entry| entry.active)
            .unwrap_or(&window[0]);
        let title = if chosen.window_label.is_empty() {
            format!("{} panes: {}", window.len(), chosen.folder)
        } else {
            chosen.window_label.clone()
        };
        result.push(Entry {
            title,
            folder: String::new(),
            group: true,
            active: chosen.window_active,
            ..chosen.clone()
        });
        for mut entry in window {
            entry.child = true;
            result.push(entry);
        }
    }
    result
}

pub fn matches(entry: &Entry, query: &str) -> bool {
    let haystack = format!(
        "{} {} {} {}",
        entry.index, entry.title, entry.folder, entry.command
    )
    .to_lowercase();
    query
        .to_lowercase()
        .split_whitespace()
        .all(|term| haystack.contains(term))
}

pub fn select(socket: &str, entry: &Entry) -> io::Result<()> {
    tmux(
        socket,
        &[
            "select-pane",
            "-t",
            &entry.pane,
            ";",
            "select-window",
            "-t",
            &entry.window,
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn redacts_credentials_and_control_sequences() {
        assert_eq!(
            redact("tool --token 'sample value' --name example"),
            "tool --token [hidden] --name example"
        );
        assert!(!redact("tool https://name:sample@example.test").contains("sample"));
        assert!(!redact("SAMPLE_TOKEN=sample tool").contains("=sample"));
    }
    #[test]
    fn process_identity_requires_ancestry() {
        let processes = HashMap::from([(
            12,
            Process {
                parent: 11,
                group: 12,
                foreground: 12,
                started: String::new(),
                command: String::new(),
            },
        )]);
        assert!(belongs(12, 11, &processes));
        assert!(!belongs(12, 99, &processes));
    }
}

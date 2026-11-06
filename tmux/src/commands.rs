use crate::{
    model::{self, Process},
    runtime as rt,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, io, path::Path};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Capture {
    pub command: String,
    pub command_argv: Vec<String>,
    pub command_pid: u32,
    pub command_start: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Launch {
    pub no_daemon: bool,
    pub launcher: Vec<String>,
    pub model: String,
    pub effort: String,
}
fn option(arguments: &[String], name: &str) -> String {
    let prefix = format!("{name}=");
    for (index, argument) in arguments.iter().enumerate() {
        if let Some(value) = argument.strip_prefix(&prefix) {
            return value.into();
        }
        if argument == name {
            return arguments.get(index + 1).cloned().unwrap_or_default();
        }
    }
    String::new()
}
fn codex_identifier(value: &str) -> Option<String> {
    static IDENTIFIER: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(
            r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        )
        .expect("Codex identifier pattern")
    });
    IDENTIFIER
        .is_match(value)
        .then(|| value.to_ascii_lowercase())
}
pub fn codex_resume_identifier(arguments: &[String]) -> Option<String> {
    if arguments
        .first()
        .and_then(|argument| Path::new(argument).file_name())
        != Some(std::ffi::OsStr::new("codex"))
        || arguments.iter().any(|argument| {
            matches!(
                argument.as_str(),
                "exec" | "app-server" | "debug" | "review"
            )
        })
    {
        return None;
    }
    arguments.windows(2).find_map(|pair| {
        (pair[0] == "resume")
            .then(|| codex_identifier(&pair[1]))
            .flatten()
    })
}
pub fn saved_codex_identifier(command: &str) -> Option<String> {
    static RESUME: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^(?:codex|[A-Za-z0-9_./+-]+/codex|'[^'\n]*/codex')(?: --no-daemon)? resume ([^ ]+)(?: |$)").expect("Saved Codex resume pattern")
    });
    codex_identifier(RESUME.captures(command)?.get(1)?.as_str())
}
pub fn is_codex_command(command: &str) -> bool {
    static COMMAND: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^(?:codex|[A-Za-z0-9_./+-]+/codex|'[^'\n]*/codex')(?: |$)")
            .expect("Codex command pattern")
    });
    COMMAND.is_match(command)
}
pub fn launcher_prefix(arguments: &[String], agent: &str) -> Option<Vec<String>> {
    let agent_index = arguments
        .iter()
        .enumerate()
        .skip(1)
        .find_map(|(index, argument)| {
            let previous = &arguments[index - 1];
            let option_value = previous != "--" && previous.starts_with('-');
            (!option_value && Path::new(argument).file_name() == Some(std::ffi::OsStr::new(agent)))
                .then_some(index)
        })?;
    let start = arguments
        .iter()
        .enumerate()
        .skip(agent_index + 1)
        .find_map(|(index, argument)| (argument == "--").then_some(index + 1))
        .unwrap_or(agent_index + 1);
    let prefix = arguments[..start].to_vec();
    replayable(&prefix).then_some(prefix)
}
pub fn launch(pid: u32, root: u32, agent: &str, processes: &HashMap<u32, Process>) -> Launch {
    let arguments = arguments(pid).unwrap_or_default();
    let mut launch = Launch {
        no_daemon: arguments.iter().any(|argument| argument == "--no-daemon"),
        model: option(&arguments, "--model"),
        effort: option(&arguments, "--effort"),
        ..Launch::default()
    };
    let mut parent = pid;
    for _ in 0..128 {
        if parent == root {
            break;
        }
        let Some(process) = processes.get(&parent) else {
            break;
        };
        parent = process.parent;
        let arguments = self::arguments(parent).unwrap_or_default();
        if let Some(prefix) = launcher_prefix(&arguments, agent) {
            launch.launcher = prefix;
        }
    }
    launch
}

pub fn foreground(root: u32, processes: &HashMap<u32, Process>) -> u32 {
    processes
        .iter()
        .find(|(pid, process)| {
            **pid == process.group
                && process.group == process.foreground
                && model::belongs(**pid, root, processes)
        })
        .map(|(pid, _)| *pid)
        .unwrap_or(root)
}
fn display_quote(argument: &str) -> String {
    if !argument.is_empty()
        && argument
            .bytes()
            .all(|letter| letter.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&letter))
    {
        argument.into()
    } else {
        rt::quote(argument)
    }
}
pub fn display(arguments: &[String]) -> String {
    model::redact(
        &arguments
            .iter()
            .map(|argument| display_quote(argument))
            .collect::<Vec<_>>()
            .join(" "),
    )
}
pub fn replayable(arguments: &[String]) -> bool {
    let Some(first) = arguments.first() else {
        return false;
    };
    let name = Path::new(first)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy();
    if name == "tmux"
        && arguments
            .iter()
            .any(|argument| argument.starts_with("agent-stat-new-"))
    {
        return false;
    }
    if matches!(
        name.trim_start_matches('-'),
        "bash" | "zsh" | "sh" | "fish" | "dash" | "claude" | "codex" | "agent-stat-tmux"
    ) {
        return false;
    }
    let raw = arguments
        .iter()
        .map(|argument| display_quote(argument))
        .collect::<Vec<_>>()
        .join(" ");
    model::redact(&raw) == raw
}

#[cfg(target_os = "macos")]
fn procargs(pid: u32) -> io::Result<Vec<u8>> {
    let mut query = [libc::CTL_KERN, 49, pid as i32];
    let mut length = 0;
    // KERN_PROCARGS2 preserves argv boundaries. The fixed query reads one process.
    if unsafe {
        libc::sysctl(
            query.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut contents = vec![0u8; length];
    if unsafe {
        libc::sysctl(
            query.as_mut_ptr(),
            3,
            contents.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    contents.truncate(length);
    Ok(contents)
}
#[cfg(target_os = "macos")]
fn parse(contents: &[u8]) -> io::Result<(Vec<String>, usize)> {
    let bytes: [u8; 4] = contents
        .get(..4)
        .ok_or_else(|| io::Error::other("Incomplete process arguments"))?
        .try_into()
        .map_err(io::Error::other)?;
    let count = i32::from_ne_bytes(bytes);
    if !(1..=4096).contains(&count) {
        return Err(io::Error::other("Invalid process argument count"));
    }
    let mut offset = contents[4..]
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| io::Error::other("Missing executable path"))?
        + 5;
    while contents.get(offset) == Some(&0) {
        offset += 1;
    }
    let mut arguments = Vec::new();
    for _ in 0..count {
        let length = contents
            .get(offset..)
            .and_then(|rest| rest.iter().position(|byte| *byte == 0))
            .ok_or_else(|| io::Error::other("Incomplete argv"))?;
        arguments.push(
            String::from_utf8(contents[offset..offset + length].to_vec())
                .map_err(io::Error::other)?,
        );
        offset += length + 1;
    }
    Ok((arguments, offset))
}
pub fn arguments(pid: u32) -> io::Result<Vec<String>> {
    #[cfg(target_os = "macos")]
    {
        parse(&procargs(pid)?).map(|(arguments, _)| arguments)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let bytes = std::fs::read(format!("/proc/{pid}/cmdline"))?;
        let text = String::from_utf8(bytes).map_err(io::Error::other)?;
        Ok(text
            .trim_end_matches('\0')
            .split('\0')
            .map(String::from)
            .collect())
    }
}
pub fn profile(pid: u32, agent: &str) -> io::Result<String> {
    let variable = if agent == "claude" {
        "CLAUDE_CONFIG_DIR"
    } else {
        "CODEX_HOME"
    };
    #[cfg(target_os = "macos")]
    let environment = procargs(pid)
        .and_then(|contents| parse(&contents).map(|(_, offset)| contents[offset..].to_vec()));
    #[cfg(not(target_os = "macos"))]
    let environment = std::fs::read(format!("/proc/{pid}/environ"));
    if let Ok(environment) = environment {
        let prefix = format!("{variable}=");
        if let Some(value) = environment
            .split(|byte| *byte == 0)
            .find_map(|part| std::str::from_utf8(part).ok()?.strip_prefix(&prefix))
        {
            return Ok(value.into());
        }
    }
    Ok(rt::home()?
        .join(if agent == "claude" {
            ".claude"
        } else {
            ".codex"
        })
        .to_string_lossy()
        .into_owned())
}
pub fn capture(root: u32, processes: &HashMap<u32, Process>) -> Capture {
    let pid = foreground(root, processes);
    let process = processes.get(&pid);
    let arguments = arguments(pid).unwrap_or_default();
    let command = if arguments.is_empty() {
        process
            .map(|process| process.command.clone())
            .unwrap_or_else(|| "[process exited]".into())
    } else {
        display(&arguments)
    };
    Capture {
        command,
        command_argv: if replayable(&arguments) {
            arguments
        } else {
            Vec::new()
        },
        command_pid: pid,
        command_start: process
            .map(|process| process.started.clone())
            .unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_codex_resume_requires_a_native_identifier() {
        let identity = "00000000-0000-7000-8000-000000000001";
        let arguments = ["/opt/bin/codex", "resume", identity].map(String::from);
        assert_eq!(
            codex_resume_identifier(&arguments).as_deref(),
            Some(identity)
        );
        assert_eq!(
            saved_codex_identifier(&format!("/opt/bin/codex resume {identity}")).as_deref(),
            Some(identity)
        );
        for arguments in [
            vec!["codex", "resume", "--last"],
            vec!["codex", "exec", "resume", identity],
            vec!["other", "resume", identity],
        ] {
            assert!(
                codex_resume_identifier(
                    &arguments.into_iter().map(String::from).collect::<Vec<_>>()
                )
                .is_none()
            );
        }
        assert!(saved_codex_identifier(&format!("echo codex resume {identity}")).is_none());
        assert!(saved_codex_identifier("codex resume not-a-conversation-id").is_none());
        assert!(!is_codex_command("rg codex"));
    }
    #[test]
    fn generic_launchers_drop_existing_resume_arguments() {
        let arguments = [
            "relay",
            "launch",
            "claude",
            "--model=local-model",
            "--",
            "--resume",
            "old-session",
            "--effort",
            "high",
        ]
        .map(String::from);
        assert_eq!(
            launcher_prefix(&arguments, "claude").unwrap(),
            arguments[..5]
        );
        let arguments = ["relay", "claude", "--resume", "old-session"].map(String::from);
        assert_eq!(
            launcher_prefix(&arguments, "claude").unwrap(),
            arguments[..2]
        );
        let arguments = [
            "relay",
            "--profile",
            "claude",
            "--",
            "claude",
            "--resume",
            "old-session",
        ]
        .map(String::from);
        assert_eq!(
            launcher_prefix(&arguments, "claude").unwrap(),
            arguments[..5]
        );
        let shell = ["zsh", "-c", "relay claude --resume old-session"].map(String::from);
        assert!(launcher_prefix(&shell, "claude").is_none());
        let secret = ["relay", "--token", "private", "claude"].map(String::from);
        assert!(launcher_prefix(&secret, "claude").is_none());
    }
    #[test]
    fn internal_startup_barriers_are_not_replayed() {
        let arguments = ["tmux", "wait-for", "agent-stat-new-1-2"]
            .into_iter()
            .map(String::from)
            .collect::<Vec<_>>();
        assert!(!replayable(&arguments));
    }
    #[test]
    fn sidebar_startup_helpers_are_not_replayed() {
        for executable in [
            "agent-stat-tmux",
            "/home/example/.agents/tmux/agent-stat-tmux",
        ] {
            let arguments = [executable, "--session", "0", "shell"]
                .into_iter()
                .map(String::from)
                .collect::<Vec<_>>();
            assert!(!replayable(&arguments));
        }
    }
    #[test]
    fn exact_arguments_keep_spaces_empty_values_and_shell_punctuation() {
        let arguments = vec![
            "worker".into(),
            "two words".into(),
            "; touch nope".into(),
            String::new(),
        ];
        assert!(replayable(&arguments));
        assert_eq!(display(&arguments), "worker 'two words' '; touch nope' ''");
    }
    #[test]
    fn credentials_never_become_replay_candidates() {
        for arguments in [
            vec!["worker", "--token", "private value"],
            vec!["worker", "--api-key=private"],
            vec!["worker", "PASSWORD=private"],
            vec!["worker", "https://name:private@example.test"],
        ] {
            assert!(!replayable(
                &arguments.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn kernel_arguments_exclude_the_environment() {
        let mut contents = 3i32.to_ne_bytes().to_vec();
        contents.extend_from_slice(b"/bin/tool\0\0tool\0two words\0\0SECRET=private\0");
        let (arguments, offset) = parse(&contents).expect("parse argv");
        assert_eq!(arguments, ["tool", "two words", ""]);
        assert!(contents[offset..].starts_with(b"SECRET="));
    }
}

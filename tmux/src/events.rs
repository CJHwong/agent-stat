use crate::model::{Entry, Process, belongs};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File},
    io::{self, BufRead, BufReader, Seek, SeekFrom},
    os::unix::fs::MetadataExt,
    path::PathBuf,
};

#[derive(Default, Deserialize)]
pub struct Record {
    #[serde(default)]
    pub event: String,
    pub session: Option<String>,
    pub agent_id: Option<String>,
    pub agent: Option<String>,
    pub agent_pid: Option<u32>,
    pub agent_start: Option<String>,
    pub tmux: Option<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub ts: f64,
    #[serde(skip)]
    pub position: String,
}

#[derive(Default)]
struct Session {
    pane: String,
    agent: String,
    pid: u32,
    started: String,
    state: String,
    children: HashSet<String>,
    sequence: u64,
    cwd: String,
    updated: f64,
    completion: String,
    attention: String,
}

impl Session {
    fn child(&mut self, event: &str, child: String, completion: &str) {
        if event == "SubagentStart" {
            self.children.insert(child);
            return;
        }
        if event != "SubagentStop" {
            return;
        }
        self.children.remove(&child);
        if self.children.is_empty() && self.state == "done" {
            self.completion = completion.into();
            self.attention = completion.into();
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Agent {
    pub agent: String,
    pub session_id: String,
    pub pid: u32,
    pub start: String,
    pub state: String,
    pub updated: f64,
    pub cwd: String,
    pub profile: String,
    pub completion: String,
}

pub struct Reader {
    root: PathBuf,
    host: String,
    cursors: HashMap<PathBuf, (u64, u64)>,
    sessions: HashMap<String, Session>,
    sequence: u64,
}

impl Reader {
    pub fn new(root: PathBuf, host: String) -> Self {
        Self {
            root,
            host,
            cursors: HashMap::new(),
            sessions: HashMap::new(),
            sequence: 0,
        }
    }

    pub fn refresh(&mut self) -> io::Result<()> {
        let directory = match fs::read_dir(self.root.join("hosts")) {
            Ok(directory) => directory,
            Err(failure) if failure.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(failure) => return Err(failure),
        };
        let mut files = Vec::new();
        for entry in directory {
            let path = entry?.path();
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            if name.starts_with(&format!("{}-", self.host))
                && name.ends_with(".jsonl")
                && name.len() == self.host.len() + 17
            {
                files.push(path);
            }
        }
        files.sort();
        for path in files {
            if self.read_file(path)? {
                return self.refresh();
            }
        }
        Ok(())
    }

    fn read_file(&mut self, path: PathBuf) -> io::Result<bool> {
        let mut file = File::open(&path)?;
        let metadata = file.metadata()?;
        let (inode, mut offset) = self
            .cursors
            .get(&path)
            .copied()
            .unwrap_or((metadata.ino(), 0));
        if inode != metadata.ino() || metadata.len() < offset {
            self.cursors.clear();
            self.sessions.clear();
            return Ok(true);
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut reader = BufReader::new(file);
        let mut line = Vec::new();
        loop {
            line.clear();
            let count = reader.read_until(b'\n', &mut line)?;
            if count == 0 || line.last() != Some(&b'\n') {
                break;
            }
            offset += count as u64;
            if let Ok(mut record) = serde_json::from_slice::<Record>(&line) {
                record.position = format!(
                    "{}:{offset}",
                    path.file_name().unwrap_or_default().to_string_lossy()
                );
                self.apply(record);
            }
        }
        self.cursors.insert(path, (metadata.ino(), offset));
        Ok(false)
    }

    pub fn apply(&mut self, record: Record) {
        let Some(identifier) = record.session else {
            return;
        };
        self.sequence += 1;
        let session = self.sessions.entry(identifier).or_default();
        session.sequence = self.sequence;
        if let Some(child) = record.agent_id {
            session.child(&record.event, child, &record.position);
            return;
        }
        session.attention = record.position.clone();
        session.updated = session.updated.max(record.ts);
        if let Some(cwd) = record.cwd {
            session.cwd = cwd;
        }
        if record.event == "Stop" {
            session.completion = record.position;
        }
        if let Some(agent) = record.agent {
            session.agent = agent;
        }
        if let Some(pane) = record.tmux {
            session.pane = pane;
        }
        if let Some(pid) = record.agent_pid {
            session.pid = pid;
        }
        if let Some(started) = record.agent_start {
            session.started = started.split_whitespace().collect::<Vec<_>>().join(" ");
        }
        let state = match record.event.as_str() {
            "SessionStart" => "idle",
            "UserPromptSubmit" | "PreToolUse" => "working",
            "PostToolUse" if session.state == "waiting" => "working",
            "PermissionRequest" => "waiting",
            "Stop" => "done",
            "StopFailure" => "failed",
            "Interrupt" => "interrupted",
            "SessionEnd" | "RunEnd"
                if session.agent == "codex"
                    && matches!(session.state.as_str(), "working" | "waiting") =>
            {
                "failed"
            }
            "SessionEnd" | "RunEnd" if session.state != "failed" => "closed",
            _ => return,
        };
        session.state = state.into();
    }

    pub fn agents(
        &self,
        entries: &[Entry],
        processes: &HashMap<u32, Process>,
    ) -> HashMap<String, Agent> {
        let mut agents = HashMap::new();
        for entry in entries {
            let record = self
                .sessions
                .iter()
                .filter(|(_, record)| {
                    record.pane == entry.pane && valid(record, entry.root_pid, processes)
                })
                .max_by_key(|(_, record)| record.sequence);
            if let Some((identifier, record)) = record {
                agents.insert(
                    entry.pane.clone(),
                    Agent {
                        agent: record.agent.clone(),
                        session_id: identifier.clone(),
                        pid: record.pid,
                        start: record.started.clone(),
                        state: state(record, false).into(),
                        updated: record.updated,
                        cwd: record.cwd.clone(),
                        profile: String::new(),
                        completion: record.completion.clone(),
                    },
                );
            }
        }
        agents
    }

    pub fn decorate(&self, entries: &mut [Entry], processes: &HashMap<u32, Process>) {
        for entry in entries {
            let record = self
                .sessions
                .values()
                .filter(|record| {
                    record.pane == entry.pane && valid(record, entry.root_pid, processes)
                })
                .max_by_key(|record| record.sequence);
            if let Some(record) = record {
                entry.state = state(record, false).into();
                entry.completion = record.completion.clone();
                entry.attention = record.attention.clone();
                entry.unread = matches!(entry.state.as_str(), "done" | "waiting")
                    && !record.attention.is_empty()
                    && entry.seen != record.attention;
                if entry.state == "done" && !entry.unread {
                    entry.state = "idle".into();
                }
            }
        }
    }
}

fn valid(record: &Session, root: u32, processes: &HashMap<u32, Process>) -> bool {
    let Some(process) = processes.get(&record.pid) else {
        return false;
    };
    (record.started.is_empty() || record.started == process.started)
        && belongs(record.pid, root, processes)
}

fn state(record: &Session, active: bool) -> &str {
    match record.state.as_str() {
        "done" if !record.children.is_empty() => "working",
        "done" if active => "idle",
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn history_is_incremental_handles_partial_lines_and_excludes_other_hosts() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("agent-stat-rust-{}-{stamp}", std::process::id()));
        fs::create_dir_all(root.join("hosts")).expect("test directory");
        let path = root.join("hosts/test-2026-11-03.jsonl");
        fs::write(&path, b"{\"session\":\"s\",\"event\":\"UserPromptSubmit\"}\n{broken}\n{\"session\":\"s\",\"event\":").expect("test history");
        fs::write(
            root.join("hosts/test-other-2026-11-03.jsonl"),
            b"{\"session\":\"foreign\",\"event\":\"Stop\"}\n",
        )
        .expect("foreign history");
        let mut reader = Reader::new(root.clone(), "test".into());
        reader.refresh().expect("initial read");
        assert_eq!(reader.sessions.len(), 1);
        assert_eq!(reader.sessions["s"].state, "working");
        let previous = reader.sequence;
        reader.refresh().expect("unchanged read");
        assert_eq!(reader.sequence, previous);
        fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("history file")
            .write_all(b"\"Stop\"}\n")
            .expect("complete line");
        reader.refresh().expect("incremental read");
        assert_eq!(reader.sessions["s"].state, "done");
        fs::write(
            &path,
            b"{\"session\":\"replacement\",\"event\":\"SessionStart\"}\n",
        )
        .expect("rotation");
        reader.refresh().expect("rotated read");
        assert!(!reader.sessions.contains_key("s"));
        assert_eq!(reader.sessions["replacement"].state, "idle");
        fs::remove_dir_all(root).expect("test cleanup");
    }

    #[test]
    fn stale_process_and_codex_failure_are_not_reported_as_working() {
        let process = Process {
            parent: 11,
            group: 12,
            foreground: 12,
            started: "new".into(),
            command: String::new(),
        };
        let processes = HashMap::from([(12, process)]);
        let record = Session {
            pid: 12,
            started: "old".into(),
            ..Session::default()
        };
        assert!(!valid(&record, 11, &processes));
        let mut reader = Reader::new(PathBuf::new(), "test".into());
        for event in ["UserPromptSubmit", "SessionEnd"] {
            reader.apply(Record {
                event: event.into(),
                agent: Some("codex".into()),
                session: Some("s".into()),
                ..Record::default()
            });
        }
        assert_eq!(reader.sessions["s"].state, "failed");
    }
    #[test]
    fn finished_parent_stays_working_until_children_stop() {
        let mut reader = Reader::new(PathBuf::new(), "test".into());
        for event in ["SubagentStart", "Stop"] {
            let record = Record {
                event: event.into(),
                session: Some("parent".into()),
                agent_id: (event == "SubagentStart").then(|| "child".into()),
                ..Record::default()
            };
            reader.apply(record);
        }
        assert_eq!(state(&reader.sessions["parent"], false), "working");
        reader.apply(Record {
            event: "SubagentStop".into(),
            session: Some("parent".into()),
            agent_id: Some("child".into()),
            ..Record::default()
        });
        assert_eq!(state(&reader.sessions["parent"], false), "done");
        assert_eq!(state(&reader.sessions["parent"], true), "idle");
    }
}

use crate::{Options, events, model, runtime as rt, shared_input, ui};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{self, Write},
    os::unix::{net::UnixDatagram, process::CommandExt},
    path::PathBuf,
    process::{Command, Stdio},
    sync::Arc,
    time::{Duration, Instant},
};

pub(crate) fn endpoint(options: &Options) -> io::Result<PathBuf> {
    let socket = fs::canonicalize(&options.socket)?;
    let hash = format!(
        "{:x}",
        Sha256::digest(socket.as_os_str().as_encoded_bytes())
    );
    // macOS limits Unix socket paths to 104 bytes. Workspace paths can exceed that.
    let root = PathBuf::from(format!("/tmp/agent-stat-tmux-{}", unsafe {
        libc::geteuid()
    }));
    rt::private_dir(&root)?;
    Ok(root.join(format!("shared-{}.sock", &hash[..16])))
}

pub fn enabled(options: &Options) -> io::Result<bool> {
    Ok(model::tmux(
        &options.socket,
        &["show-option", "-gqv", "@window_sidebar_shared"],
    )? == "1")
}

pub fn start(options: &Options) -> io::Result<()> {
    let roles = model::tmux(
        &options.socket,
        &["list-panes", "-a", "-F", "#{@shared_sidebar}"],
    )?;
    if !roles.lines().any(|role| role == "1") {
        return Ok(());
    }
    shared_input::install(options)?;
    let path = endpoint(options)?;
    let Some(lock) = rt::lock(&path.with_extension("lock"), true)? else {
        return Ok(());
    };
    drop(lock);
    let mut command = Command::new(env::current_exe()?);
    command
        .args([
            "--socket",
            &options.socket,
            "--session",
            &options.session,
            "shared-serve",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
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

pub fn stop(options: &Options) -> io::Result<()> {
    let path = endpoint(options)?;
    let text = match fs::read_to_string(path.with_extension("pid")) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let pid = text.trim().parse::<u32>().map_err(io::Error::other)?;
    let arguments = match crate::commands::arguments(pid) {
        Ok(arguments) => arguments,
        Err(_) => return Ok(()),
    };
    if !arguments.iter().any(|argument| argument == "shared-serve")
        || !arguments
            .windows(2)
            .any(|pair| pair == ["--socket", &options.socket])
    {
        return Ok(());
    }
    if unsafe { libc::kill(pid as i32, libc::SIGTERM) } != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Err(error);
        }
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    while rt::lock(&path.with_extension("lock"), true)?.is_none() {
        if Instant::now() >= deadline {
            return Err(io::Error::other("Shared service did not stop"));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Ok(())
}

#[derive(Clone)]
struct Pane {
    id: String,
    session: String,
    window: String,
    width: u16,
    height: u16,
}

fn parse_pane(fields: &[&str]) -> io::Result<Option<Pane>> {
    if fields.len() != 8 || fields[5] != "1" {
        return Ok(None);
    }
    Ok(Some(Pane {
        id: fields[0].into(),
        session: fields[1].into(),
        window: fields[2].into(),
        width: fields[3].parse().map_err(io::Error::other)?,
        height: fields[4].parse().map_err(io::Error::other)?,
    }))
}

fn panes(options: &Options) -> io::Result<(Vec<Pane>, HashSet<u32>)> {
    let rows = model::tmux(
        &options.socket,
        &[
            "list-panes",
            "-a",
            "-F",
            "#{pane_id}\t#{session_id}\t#{window_id}\t#{pane_width}\t#{pane_height}\t#{@shared_sidebar}\t#{pane_pid}\t#{@window_sidebar}",
        ],
    )?;
    let mut panes = Vec::new();
    let mut roots = HashSet::new();
    for row in rows.lines() {
        let fields = row.split('\t').collect::<Vec<_>>();
        if fields.len() != 8 {
            continue;
        }
        let root = fields[6]
            .parse::<u32>()
            .ok()
            .filter(|pid| *pid > 0 && fields[7].is_empty());
        if let Some(pid) = root {
            roots.insert(pid);
        }
        if let Some(pane) = parse_pane(&fields)? {
            panes.push(pane);
        }
    }
    Ok((panes, roots))
}

pub(crate) fn publish(options: &Options, pane: &str, frame: &[u8]) -> io::Result<()> {
    let mut child = Command::new("tmux")
        .args(["-S", &options.socket, "display-message", "-I", "-t", pane])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    let written = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("Missing frame input"))?
        .write_all(frame);
    let output = child.wait_with_output()?;
    written?;
    if !output.status.success() {
        return Err(io::Error::other(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ));
    }
    Ok(())
}

struct Sidebar {
    pane: Pane,
    view: ui::SharedView,
    frame: Vec<u8>,
    entries: Arc<Vec<model::Entry>>,
}

impl Sidebar {
    fn input_dimensions(&self, options: &Options, input: &str) -> io::Result<(u16, u16)> {
        if !input.starts_with("mouse-left:") {
            return Ok((self.pane.width, self.pane.height));
        }
        // Layout hooks can resize a rail between its frame and the next pane discovery.
        let dimensions = model::tmux(
            &options.socket,
            &[
                "display-message",
                "-p",
                "-t",
                &self.pane.id,
                "#{pane_width}\t#{pane_height}",
            ],
        )?;
        let (width, height) = dimensions
            .split_once('\t')
            .ok_or_else(|| io::Error::other("Missing pane dimensions"))?;
        Ok((
            width.parse().map_err(io::Error::other)?,
            height.parse().map_err(io::Error::other)?,
        ))
    }

    fn refresh(&mut self, pane: Pane, entries: Arc<Vec<model::Entry>>) -> bool {
        let resized = self.pane.width != pane.width || self.pane.height != pane.height;
        let changed = self.frame.is_empty() || !Arc::ptr_eq(&self.entries, &entries);
        self.pane = pane;
        if changed {
            self.view.refresh(entries.as_ref().clone());
            self.entries = entries;
        }
        resized || changed
    }

    fn draw(&mut self, options: &Options) -> io::Result<()> {
        let frame = self.view.frame(self.pane.width, self.pane.height)?;
        if frame != self.frame {
            publish(options, &self.pane.id, &frame)?;
            self.frame = frame;
        }
        Ok(())
    }

    fn input(&mut self, options: &Options, request: shared_input::Request) -> io::Result<()> {
        let mut target = options.clone();
        target.session = self.pane.session.clone();
        target.owner_window = self.pane.window.clone();
        target.pane = Some(self.pane.id.clone());
        target.client = request.client;
        target.detached_actions = true;
        let event = shared_input::event(&request.input)?;
        let dimensions = self.input_dimensions(&target, &request.input)?;
        self.pane.width = dimensions.0;
        self.pane.height = dimensions.1;
        self.view.input(&target, event, dimensions)?;
        self.draw(options)
    }
}

struct Service {
    reader: events::Reader,
    processes: HashMap<u32, model::Process>,
    scanned: Instant,
    sidebars: HashMap<String, Sidebar>,
    entries: HashMap<String, Arc<Vec<model::Entry>>>,
}

fn reuse_rows(
    previous: Option<&Arc<Vec<model::Entry>>>,
    rows: Vec<model::Entry>,
) -> Arc<Vec<model::Entry>> {
    match previous.filter(|previous| previous.as_ref() == &rows) {
        Some(previous) => Arc::clone(previous),
        None => Arc::new(rows),
    }
}

impl Service {
    fn refresh(&mut self, options: &Options) -> io::Result<bool> {
        let (panes, roots) = panes(options)?;
        if panes.is_empty() {
            return Ok(false);
        }
        if self.scanned.elapsed() >= Duration::from_secs(1) {
            self.processes = model::processes_for_roots(&roots)?;
            self.scanned = Instant::now();
        }
        let sessions = panes
            .iter()
            .map(|pane| pane.session.clone())
            .collect::<HashSet<_>>();
        let mut entries = HashMap::new();
        for session in sessions {
            let target = Options {
                session: session.clone(),
                ..options.clone()
            };
            match crate::snapshot(&target, &mut self.reader, &self.processes) {
                Ok(rows) => {
                    let rows = reuse_rows(self.entries.get(&session), rows);
                    entries.insert(session, rows);
                }
                Err(error) => rt::log(&format!("Shared session: {error}")),
            }
        }
        let live = panes
            .iter()
            .map(|pane| pane.id.clone())
            .collect::<HashSet<_>>();
        self.sidebars.retain(|pane, _| live.contains(pane));
        for pane in panes {
            if let Some(rows) = entries.get(&pane.session) {
                self.refresh_pane(options, pane, Arc::clone(rows));
            }
        }
        self.entries = entries;
        Ok(true)
    }

    fn refresh_pane(&mut self, options: &Options, pane: Pane, entries: Arc<Vec<model::Entry>>) {
        let id = pane.id.clone();
        let sidebar = self.sidebars.entry(id).or_insert_with(|| Sidebar {
            pane: pane.clone(),
            view: ui::SharedView::new(),
            frame: Vec::new(),
            entries: Arc::clone(&entries),
        });
        if !sidebar.refresh(pane, entries) {
            return;
        }
        // A pane can close between discovery and output. Other sidebars must continue.
        if let Err(error) = sidebar.draw(options) {
            rt::log(&format!("Shared frame: {error}"));
        }
    }

    fn receive(&mut self, options: &Options, socket: &UnixDatagram) -> io::Result<()> {
        let mut buffer = [0u8; 4096];
        match socket.recv(&mut buffer) {
            Ok(length) => {
                let request: shared_input::Request = serde_json::from_slice(&buffer[..length])?;
                if let Some(sidebar) = self.sidebars.get_mut(&request.pane) {
                    sidebar.input(options, request)?;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(error) => return Err(error),
        }
        Ok(())
    }
}

pub fn run(options: &Options) -> io::Result<()> {
    let path = endpoint(options)?;
    let Some(_lock) = rt::lock(&path.with_extension("lock"), true)? else {
        return Ok(());
    };
    match fs::remove_file(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let socket = UnixDatagram::bind(&path)?;
    rt::atomic_write(
        &path.with_extension("pid"),
        std::process::id().to_string().as_bytes(),
    )?;
    model::tmux(
        &options.socket,
        &[
            "set-option",
            "-s",
            "@window_sidebar_service_pid",
            &std::process::id().to_string(),
        ],
    )?;
    let mut service = Service {
        reader: events::Reader::new(options.event_root.clone(), options.host.clone()),
        processes: HashMap::new(),
        scanned: Instant::now() - Duration::from_secs(1),
        sidebars: HashMap::new(),
        entries: HashMap::new(),
    };
    let mut refreshed = Instant::now() - Duration::from_secs(1);
    loop {
        if refreshed.elapsed() >= Duration::from_millis(150) {
            if !service.refresh(options)? {
                break;
            }
            refreshed = Instant::now();
        }
        socket.set_read_timeout(Some(
            Duration::from_millis(150)
                .saturating_sub(refreshed.elapsed())
                .max(Duration::from_millis(1)),
        ))?;
        if let Err(error) = service.receive(options, &socket) {
            rt::log(&format!("Shared input: {error}"));
        }
    }
    fs::remove_file(path)?;
    Ok(())
}

pub fn replace_pane(options: &Options, pane: &str, window: &str) -> io::Result<String> {
    let stage = format!("agent-stat-upgrade-{}", std::process::id());
    model::tmux(
        &options.socket,
        &["new-session", "-d", "-s", &stage, "sleep 60"],
    )?;
    let converted = (|| -> io::Result<String> {
        model::tmux(
            &options.socket,
            &["set-option", "-t", &stage, "@window_sidebar_enabled", "0"],
        )?;
        let empty = model::tmux(
            &options.socket,
            &[
                "split-window",
                "-d",
                "-h",
                "-t",
                &format!("{stage}:"),
                "-P",
                "-F",
                "#{pane_id}",
                "",
            ],
        )?;
        for (key, value) in [
            ("@window_sidebar", "1"),
            ("@shared_sidebar", "1"),
            ("pane-border-format", ""),
        ] {
            model::tmux(
                &options.socket,
                &["set-option", "-p", "-t", &empty, key, value],
            )?;
        }
        model::tmux(
            &options.socket,
            &["swap-pane", "-d", "-s", &empty, "-t", pane],
        )?;
        model::tmux(
            &options.socket,
            &[
                "set-option",
                "-w",
                "-t",
                window,
                "@window_sidebar_pane",
                &empty,
            ],
        )?;
        model::tmux(&options.socket, &["kill-pane", "-t", pane])?;
        Ok(empty)
    })();
    let cleanup = model::tmux(&options.socket, &["kill-session", "-t", &stage]);
    let pane = converted?;
    cleanup?;
    Ok(pane)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane() -> Pane {
        Pane {
            id: "%1".into(),
            session: "$0".into(),
            window: "@0".into(),
            width: 28,
            height: 40,
        }
    }

    fn entries() -> Arc<Vec<model::Entry>> {
        Arc::new(vec![model::Entry {
            window: "@0".into(),
            pane: "%0".into(),
            title: "First".into(),
            active: true,
            ..model::Entry::default()
        }])
    }

    #[test]
    fn left_click_uses_current_dimensions_after_a_resize() {
        let socket = format!("/tmp/shared-input-size-{}", std::process::id());
        let output = Command::new("tmux")
            .args([
                "-S",
                &socket,
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "40",
                "sleep 20",
            ])
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .output();
        let output = match output {
            Ok(output) => output,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                eprintln!("SKIP: resize input check requires tmux");
                return;
            }
            Err(error) => panic!("Start resize input server: {error}"),
        };
        assert!(output.status.success());
        let id = model::tmux(
            &socket,
            &[
                "split-window",
                "-h",
                "-l",
                "3",
                "-P",
                "-F",
                "#{pane_id}",
                "sleep 20",
            ],
        )
        .unwrap();
        let options = Options {
            socket: socket.clone(),
            ..Options::default()
        };
        let sidebar = Sidebar {
            pane: Pane {
                id,
                width: 8,
                ..pane()
            },
            view: ui::SharedView::new(),
            frame: Vec::new(),
            entries: entries(),
        };
        let clicked = sidebar.input_dimensions(&options, "mouse-left:1:19");
        let scrolled = sidebar.input_dimensions(&options, "wheel-down:1:19");
        model::tmux(&socket, &["kill-server"]).unwrap();
        assert_eq!(clicked.unwrap(), (3, 40));
        assert_eq!(scrolled.unwrap(), (8, 40));
    }

    #[test]
    fn unchanged_rows_skip_frames_but_resizes_and_titles_refresh() {
        let rows = entries();
        let mut sidebar = Sidebar {
            pane: pane(),
            view: ui::SharedView::new(),
            frame: Vec::new(),
            entries: Arc::clone(&rows),
        };
        assert!(sidebar.refresh(pane(), Arc::clone(&rows)));
        sidebar.frame = sidebar.view.frame(28, 40).unwrap();
        assert!(!sidebar.refresh(pane(), Arc::clone(&rows)));
        let narrow = Pane { width: 3, ..pane() };
        assert!(sidebar.refresh(narrow, Arc::clone(&rows)));
        assert!(
            String::from_utf8(sidebar.view.frame(3, 40).unwrap())
                .unwrap()
                .contains('▶')
        );
        let updated = Arc::new(vec![model::Entry {
            title: "Renamed".into(),
            ..rows[0].clone()
        }]);
        assert!(sidebar.refresh(pane(), updated));
        assert!(
            String::from_utf8(sidebar.view.frame(28, 40).unwrap())
                .unwrap()
                .contains("Renamed")
        );
    }

    #[test]
    fn repeated_snapshots_reuse_session_rows() {
        let rows = entries();
        assert!(Arc::ptr_eq(
            &rows,
            &reuse_rows(Some(&rows), rows.as_ref().clone())
        ));
        let renamed = vec![model::Entry {
            title: "Renamed".into(),
            ..rows[0].clone()
        }];
        assert!(!Arc::ptr_eq(&rows, &reuse_rows(Some(&rows), renamed)));
    }
}

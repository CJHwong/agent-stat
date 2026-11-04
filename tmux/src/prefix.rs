use crate::{Options, actions, model, runtime as rt, ui};
use std::{
    collections::HashSet,
    io::{self, BufRead, BufReader, Write},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    thread,
    time::Duration,
};

struct Control {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}
impl Control {
    fn open(options: &Options) -> io::Result<Self> {
        let mut child = Command::new("tmux")
            .args([
                "-S",
                &options.socket,
                "-C",
                "attach-session",
                "-f",
                "ignore-size,no-output",
                "-t",
                &options.session,
            ])
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let input = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("Missing control input"))?;
        let output = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("Missing control output"))?,
        );
        let mut control = Self {
            child,
            input,
            output,
        };
        control.reply()?;
        Ok(control)
    }
    fn reply(&mut self) -> io::Result<Vec<String>> {
        let mut inside = false;
        let mut reply = Vec::new();
        loop {
            let mut line = String::new();
            if self.output.read_line(&mut line)? == 0 {
                return Err(io::Error::other("Tmux control connection closed"));
            }
            let line = line.trim_end_matches('\n');
            if line.starts_with("%begin ") {
                inside = true;
                continue;
            }
            if line.starts_with("%end ") {
                return Ok(reply);
            }
            if line.starts_with("%error ") {
                return Err(io::Error::other(reply.join("\n")));
            }
            if inside && !line.starts_with('%') {
                reply.push(line.into());
            }
        }
    }
    fn clients(&mut self, session: &str) -> io::Result<Vec<String>> {
        writeln!(
            self.input,
            "list-clients -t {} -F '#{{client_name}}\t#{{client_prefix}}\t#{{client_key_table}}\t#{{pane_id}}\t#{{client_control_mode}}'",
            rt::quote(session)
        )?;
        self.input.flush()?;
        self.reply()
    }
}
impl Drop for Control {
    fn drop(&mut self) {
        if let Err(error) = self.child.kill() {
            if error.kind() != io::ErrorKind::InvalidInput {
                rt::log(&format!("Stop control client: {error}"));
            }
        }
        if let Err(error) = self.child.wait() {
            rt::log(&format!("Wait for control client: {error}"));
        }
    }
}
pub fn watch(options: &Options) -> io::Result<()> {
    let mut control = Control::open(options)?;
    let mut previous = HashSet::new();
    while crate::recovery::running() {
        let mut current = HashSet::new();
        for line in control.clients(&options.session)? {
            let fields: Vec<_> = line.split('\t').collect();
            if fields.len() != 5 || fields[4] == "1" || !(fields[1] == "1" || fields[2] == "prefix")
            {
                continue;
            }
            current.insert(fields[0].to_owned());
            if previous.contains(fields[0]) {
                continue;
            }
            let mut target = options.clone();
            target.pane = Some(fields[3].into());
            target.client = Some(fields[0].into());
            if let Err(error) = actions::overlay(&target, true) {
                rt::log(&format!("Open shortcut sheet: {error}"));
            }
        }
        previous = current;
        thread::sleep(Duration::from_millis(15));
    }
    Ok(())
}
pub fn armed(options: &Options) -> io::Result<bool> {
    let rows = model::tmux(
        &options.socket,
        &[
            "list-clients",
            "-t",
            &options.session,
            "-F",
            "#{client_name}\t#{client_prefix}\t#{client_key_table}",
        ],
    )?;
    Ok(rows.lines().any(|line| {
        let fields: Vec<_> = line.split('\t').collect();
        fields.len() == 3
            && options
                .client
                .as_ref()
                .is_none_or(|client| client == fields[0])
            && (fields[1] == "1" || fields[2] == "prefix")
    }))
}
pub fn render(options: &Options) -> io::Result<()> {
    let _terminal = ui::Terminal::open()?;
    while armed(options)? {
        ui::text_frame(
            "NEXT KEY",
            &[
                "c       New window",
                "%       Split left/right",
                "\"       Split above/below",
                "h j k l Move to pane",
                "z       Zoom pane",
                "d       Detach safely",
                "Tab     Toggle sidebar",
                "/       Find pane",
                "r       Recover sessions",
                "?       All shortcuts",
                "Esc     Cancel",
            ]
            .map(String::from),
            "",
        )?;
        thread::sleep(Duration::from_millis(30));
    }
    Ok(())
}

pub fn shortcuts(options: &Options) -> io::Result<String> {
    let bindings = model::tmux(&options.socket, &["list-keys", "-Na", "-T", "prefix"])?;
    Ok(format!(
        "Press Ctrl+b, release it, then press a key.\n\nCommon default keys:\nc           New window\n%           Split left/right\n\"           Split above/below\nArrow keys  Move to pane\n[           Scrollback and copy mode\n]           Paste latest copied text\nw           Choose window\ns           Choose session\nd           Detach safely\n\nHide the sidebar with Ctrl+b Tab before native layouts or pane swaps.\nSpace       Next pane layout\n{{ or }}      Swap pane positions\n\nYour current bindings:\n{bindings}"
    ))
}

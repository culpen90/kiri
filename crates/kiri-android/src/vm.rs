use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::cli::{DISK_SIZE, Host};

const GREETING: &[u8; 6] = b"KIRI1\n";
const STARTUP_ERROR: &[u8; 6] = b"KIRI!\n";
const FRAME_MAX: usize = 8192;
const OUTPUT_MAX: usize = 256 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(25);
static INTERRUPTED: AtomicI32 = AtomicI32::new(0);

fn command(host: &Host, path: &Path, format: bool) -> Command {
    let mut cmd = Command::new(&host.qemu);
    cmd.env_clear().current_dir(path).env("TMPDIR", path);
    if let Some(prefix) = &host.prefix {
        // Some Termux packages depend on libraries under its private prefix.
        cmd.env("LD_LIBRARY_PATH", prefix.join("lib"));
    }
    // Only these devices are exposed. In particular there is no monitor,
    // user-mode NIC, 9p/virtiofs, host port forwarding or listen socket.
    cmd.args([
        "-no-user-config",
        "-nodefaults",
        "-machine",
        "virt",
        "-accel",
        "tcg",
        "-cpu",
        "cortex-a57",
        "-smp",
        "1",
        "-m",
        "256M",
        "-display",
        "none",
        "-monitor",
        "none",
        "-serial",
        "null",
        "-nic",
        "none",
        "-no-reboot",
    ]);
    cmd.arg("-kernel").arg(host.assets.join("Image"));
    cmd.arg("-initrd")
        .arg(host.assets.join("initramfs.cpio.gz"));
    let boot_args = "rdinit=/init console=ttyAMA0 quiet panic=-1";
    cmd.arg("-append").arg(if format {
        format!("{boot_args} kiri.format=1")
    } else {
        boot_args.into()
    });
    // Fixed raw format and basename. A guest cannot point this at a host
    // path or create a backing filename that the next boot would follow.
    cmd.args([
        "-drive",
        "if=none,id=workspace,format=raw,file=workspace.raw",
        "-device",
        "virtio-blk-pci,drive=workspace",
        "-chardev",
        "stdio,id=kiri,signal=off",
        "-device",
        "virtio-serial-pci",
        "-device",
        "virtserialport,chardev=kiri,name=org.kiri.agent",
    ]);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);

    #[cfg(any(target_os = "android", target_os = "linux"))]
    {
        // SAFETY: these calls have no pointer arguments. The pre-exec
        // closure does not allocate and invokes only async-signal-safe syscalls.
        unsafe {
            let parent = libc::getpid();
            cmd.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    libc::_exit(125);
                }
                Ok(())
            });
        }
    }
    cmd
}

pub(super) fn run(
    host: &Host,
    path: &Path,
    script: Vec<u8>,
    timeout: Duration,
) -> io::Result<(u8, Value)> {
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: the handler only stores the signal number in an atomic.
        if unsafe { libc::signal(signal, interrupt as *const () as libc::sighandler_t) }
            == libc::SIG_ERR
        {
            return Err(io::Error::last_os_error());
        }
    }
    let deadline = Instant::now() + timeout;
    let pending = path.join(".unformatted");
    let pending = match fs::symlink_metadata(&pending) {
        Ok(m) if m.is_file() && m.len() == 0 => {
            // A prior boot interrupted during mkfs may have left a partial
            // filesystem. No script has been allowed to touch this disk yet.
            let disk = OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(path.join("workspace.raw"))?;
            disk.set_len(0)?;
            disk.set_len(DISK_SIZE)?;
            Some(pending)
        }
        Ok(_) => return Err(io::Error::other("invalid workspace format marker")),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e),
    };
    let mut child = Reap(command(host, path, pending.is_some()).spawn()?);
    let stdin = child.0.stdin.take().expect("QEMU stdin is piped");
    let stdout = child.0.stdout.take().expect("QEMU stdout is piped");
    let mut stderr = child.0.stderr.take().expect("QEMU stderr is piped");
    let log_worker = thread::spawn(move || {
        let mut log = Vec::new();
        let _ = (&mut stderr).take(FRAME_MAX as u64).read_to_end(&mut log);
        let _ = io::copy(&mut stderr, &mut io::sink());
        log
    });
    let (tx, rx) = mpsc::sync_channel(8);
    let protocol_worker = thread::spawn(move || {
        if let Err(error) = talk(stdin, stdout, &script, pending, &tx) {
            let _ = tx.send(Event::Error(error.to_string()));
        }
    });

    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut outcome = loop {
        if let Some(ended) = stop_requested(deadline) {
            break ended;
        }
        match rx.recv_timeout(POLL_INTERVAL) {
            Ok(Event::Output(kind, bytes)) => {
                let remaining = OUTPUT_MAX - out.len() - err.len();
                let target = if kind == 0 { &mut out } else { &mut err };
                target.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
                if bytes.len() > remaining {
                    break Outcome::OutputLimit;
                }
            }
            Ok(Event::Exit(code)) => break wait_for_shutdown(&mut child.0, code, deadline),
            Ok(Event::Error(message)) => break Outcome::Error(message),
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => {
                break Outcome::Error("no exit status from Linux guest".into());
            }
        }
    };
    drop(rx);
    drop(child); // Close QEMU's pipe ends before joining the workers.
    let _ = protocol_worker.join();
    let qemu_log = log_worker.join().unwrap_or_default();
    if let Outcome::Error(message) = &mut outcome {
        let log = String::from_utf8_lossy(&qemu_log);
        let log = log.trim();
        if !log.is_empty() {
            message.push_str("; QEMU: ");
            message.push_str(log);
        }
    }
    let mut result =
        json!({"stdout": String::from_utf8_lossy(&out), "stderr": String::from_utf8_lossy(&err)});
    let (status, code) = match outcome {
        Outcome::Exited(n) => {
            result["exit_code"] = json!(n);
            ("exited", n)
        }
        Outcome::Timeout => ("timeout", 124),
        Outcome::OutputLimit => ("output_limit", 125),
        Outcome::Error(message) => {
            result["message"] = json!(message);
            ("error", 125)
        }
        Outcome::Interrupted(signal) => {
            result["message"] = json!(format!("interrupted by signal {signal}"));
            ("error", (128 + signal) as u8)
        }
    };
    result["status"] = json!(status);
    Ok((code, result))
}

extern "C" fn interrupt(signal: libc::c_int) {
    INTERRUPTED.store(signal, Ordering::Relaxed);
}

enum Outcome {
    Exited(u8),
    Timeout,
    OutputLimit,
    Error(String),
    Interrupted(i32),
}

fn stop_requested(deadline: Instant) -> Option<Outcome> {
    let signal = INTERRUPTED.load(Ordering::Relaxed);
    if signal != 0 {
        Some(Outcome::Interrupted(signal))
    } else if Instant::now() >= deadline {
        Some(Outcome::Timeout)
    } else {
        None
    }
}

fn wait_for_shutdown(child: &mut Child, code: u8, deadline: Instant) -> Outcome {
    loop {
        if let Some(ended) = stop_requested(deadline) {
            return ended;
        }
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Outcome::Exited(code),
            Ok(Some(status)) => return Outcome::Error(format!("QEMU stopped with {status}")),
            Ok(None) => thread::sleep(POLL_INTERVAL),
            Err(e) => return Outcome::Error(format!("waiting for QEMU shutdown: {e}")),
        }
    }
}

struct Reap(Child);

impl Drop for Reap {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

enum Event {
    Output(u8, Vec<u8>),
    Exit(u8),
    Error(String),
}

fn talk(
    mut input: ChildStdin,
    mut output: ChildStdout,
    script: &[u8],
    pending: Option<PathBuf>,
    tx: &SyncSender<Event>,
) -> io::Result<()> {
    let mut hello = [0; GREETING.len()];
    output
        .read_exact(&mut hello)
        .map_err(|e| io::Error::other(format!("Linux guest did not send its greeting: {e}")))?;
    if &hello == STARTUP_ERROR {
        let (kind, body) = read_frame(&mut output)?;
        if kind != 3 {
            return Err(io::Error::other("unrecognized Linux guest startup error"));
        }
        return Err(io::Error::other(
            String::from_utf8_lossy(&body).into_owned(),
        ));
    }
    if &hello != GREETING {
        return Err(io::Error::other(
            "unrecognized Linux guest protocol greeting",
        ));
    }
    if let Some(marker) = pending {
        // The guest formatted and mounted the disk. Clear the one-use flag
        // *before* handing over work; later boots must never format it again.
        fs::remove_file(&marker)?;
        File::open(marker.parent().expect("format marker has a parent"))?.sync_all()?;
    }
    input.write_all(&(script.len() as u32).to_le_bytes())?;
    input.write_all(script)?;
    loop {
        let (kind, body) = read_frame(&mut output).map_err(|e| {
            io::Error::other(format!("Linux guest ended before completing the job: {e}"))
        })?;
        let (event, final_event) = match kind {
            kind @ (0 | 1) => (Event::Output(kind, body), false),
            2 if body.len() == 1 => (Event::Exit(body[0]), true),
            3 => (
                Event::Error(String::from_utf8_lossy(&body).into_owned()),
                true,
            ),
            _ => return Err(io::Error::other("unrecognized Linux guest frame type")),
        };
        if tx.send(event).is_err() || final_event {
            return Ok(());
        }
    }
}

fn read_frame(output: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0; 5];
    output.read_exact(&mut header)?;
    let size = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
    if !(1..=FRAME_MAX).contains(&size) {
        return Err(io::Error::other("invalid Linux guest frame length"));
    }
    let mut body = vec![0; size];
    output.read_exact(&mut body)?;
    Ok((header[0], body))
}

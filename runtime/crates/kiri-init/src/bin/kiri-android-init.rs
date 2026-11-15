//! PID 1 for Stowlark's offline Linux environments on Android.

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("stowlark-android-init runs in the Linux guest");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() {
    guest::run();
}

#[cfg(target_os = "linux")]
mod guest {
    use std::ffi::CStr;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::{
        fs::PermissionsExt,
        process::{CommandExt, ExitStatusExt},
    };
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    const WORKER: u32 = 1000;
    const SCRIPT_LIMIT: usize = 65_536;
    const FRAME_LIMIT: usize = 8192;
    const DISK_BYTES: usize = 64 * 1024 * 1024;
    const WORKSPACE: &str = "/workspace";
    const DISK: &str = "/dev/vda";
    const CONTROL_NAME: &str = "org.kiri.agent";
    const READY: &[u8] = b"KIRI1\n";

    pub fn run() -> ! {
        let result = connect().and_then(|mut control| {
            if let Err(error) = prepare_workspace() {
                control.write_all(b"KIRI!\n")?;
                return error_frame(&mut control, &error);
            }
            control.write_all(READY)?;
            match run_job(&mut control) {
                Ok(code) => frame(&mut control, 2, &[code]),
                Err(error) => error_frame(&mut control, &error),
            }
        });
        if let Err(error) = result {
            eprintln!("stowlark-android-init: {error}");
        }
        // SAFETY: PID 1 owns this guest. Neither syscall touches host state.
        unsafe {
            libc::sync();
            libc::reboot(libc::LINUX_REBOOT_CMD_POWER_OFF);
            loop {
                libc::pause();
            }
        }
    }

    fn connect() -> io::Result<File> {
        mount(
            c"devtmpfs",
            c"/dev",
            c"devtmpfs",
            libc::MS_NOSUID | libc::MS_NOEXEC,
            None,
        )?;
        let safe = libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC;
        mount(c"sysfs", c"/sys", c"sysfs", safe | libc::MS_RDONLY, None)?;
        let started = Instant::now();
        loop {
            let port = find_control_port();
            match port.and_then(|path| {
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
                OpenOptions::new().read(true).write(true).open(path)
            }) {
                Ok(control) => {
                    return Ok(control);
                }
                Err(error)
                    if error.kind() == io::ErrorKind::NotFound
                        && started.elapsed() < Duration::from_secs(5) =>
                {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => {
                    return Err(io::Error::other(format!(
                        "opening virtio control port: {error}"
                    )));
                }
            }
        }
    }

    fn find_control_port() -> io::Result<PathBuf> {
        for port in fs::read_dir("/sys/class/virtio-ports")? {
            let port = port?;
            if fs::read_to_string(port.path().join("name"))
                .is_ok_and(|name| name.trim() == CONTROL_NAME)
            {
                return Ok(Path::new("/dev").join(port.file_name()));
            }
        }
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "missing named virtio port",
        ))
    }

    fn run_job(control: &mut File) -> io::Result<u8> {
        let mut length = [0; 4];
        control.read_exact(&mut length)?;
        let length = u32::from_le_bytes(length) as usize;
        if length == 0 || length > SCRIPT_LIMIT {
            return Err(io::Error::other(
                "script exceeds the guest protocol's size limit or is empty",
            ));
        }
        let mut script = vec![0; length];
        control.read_exact(&mut script)?;
        let script =
            std::str::from_utf8(&script).map_err(|_| io::Error::other("script must be UTF-8"))?;
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", script])
            .env_clear()
            .env("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", WORKSPACE)
            .env("USER", "agent")
            .env("LANG", "C.UTF-8")
            .env("TMPDIR", "/tmp")
            .current_dir(WORKSPACE)
            .uid(WORKER)
            .gid(WORKER)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // SAFETY: only async-signal-safe syscalls in the child before exec.
        unsafe {
            command.pre_exec(limit_worker);
        }
        let mut child = command.spawn()?;
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let output = Mutex::new(&mut *control);
        let status = std::thread::scope(|scope| -> io::Result<_> {
            let stdout = scope.spawn(|| forward(stdout, &output, 0));
            let stderr = scope.spawn(|| forward(stderr, &output, 1));
            let status = child.wait();
            reap_remaining();
            stdout
                .join()
                .map_err(|_| io::Error::other("stdout forwarding failed"))??;
            stderr
                .join()
                .map_err(|_| io::Error::other("stderr forwarding failed"))??;
            status
        });
        sync_workspace()?;
        let status = status?;
        Ok(status
            .code()
            .unwrap_or_else(|| 128 + status.signal().unwrap_or(1)) as u8)
    }

    fn prepare_workspace() -> io::Result<()> {
        let safe = libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC;
        mount(c"proc", c"/proc", c"proc", safe, None)?;
        mount(
            c"tmpfs",
            c"/tmp",
            c"tmpfs",
            libc::MS_NOSUID | libc::MS_NODEV,
            Some(c"size=32M,mode=1777"),
        )?;
        for name in ["virtio_blk", "crc16", "mbcache", "jbd2", "ext4"] {
            let module = File::open(format!("/lib/stowlark-modules/{name}.ko"))?;
            // SAFETY: the exact matching module is bundled in the read-only boot input.
            check(unsafe {
                libc::syscall(libc::SYS_finit_module, module.as_raw_fd(), c"".as_ptr(), 0)
                    as libc::c_int
            })
            .map_err(|err| io::Error::other(format!("loading guest module {name}: {err}")))?;
        }
        fs::set_permissions(DISK, fs::Permissions::from_mode(0o600))?;
        let can_format = fs::read_to_string("/proc/cmdline")?
            .split_ascii_whitespace()
            .any(|arg| arg == "kiri.format=1");
        if let Err(error) = mount_workspace() {
            if !can_format {
                return Err(error);
            }
            format_blank_disk()?;
            mount_workspace()?;
        }
        // SAFETY: /workspace itself is the filesystem's mount point.
        check(unsafe { libc::chown(c"/workspace".as_ptr(), WORKER, WORKER) })?;
        fs::set_permissions(WORKSPACE, fs::Permissions::from_mode(0o700))?;
        sync_workspace()
    }

    fn mount_workspace() -> io::Result<()> {
        mount(
            c"/dev/vda",
            c"/workspace",
            c"ext4",
            libc::MS_NODEV | libc::MS_NOSUID,
            None,
        )
        .map_err(|err| io::Error::other(format!("mounting the workspace: {err}")))
    }

    fn sync_workspace() -> io::Result<()> {
        let workspace = File::open(WORKSPACE)?;
        // SAFETY: syncfs writes pending changes for the guest's workspace disk.
        check(unsafe { libc::syncfs(workspace.as_raw_fd()) })
    }

    fn format_blank_disk() -> io::Result<()> {
        let mut disk = File::open(DISK)?;
        let mut buffer = [0; 16 * 1024];
        for _ in 0..DISK_BYTES / buffer.len() {
            disk.read_exact(&mut buffer)?;
            if buffer.iter().any(|byte| *byte != 0) {
                return Err(io::Error::other(
                    "workspace format requested for a disk containing data",
                ));
            }
        }
        if disk.read(&mut buffer[..1])? != 0 {
            return Err(io::Error::other("workspace disk must be exactly 64 MiB"));
        }
        let status = Command::new("/sbin/mke2fs")
            .args([
                "-q",
                "-t",
                "ext4",
                "-F",
                "-E",
                "nodiscard,lazy_itable_init=0,lazy_journal_init=0",
                DISK,
            ])
            .env_clear()
            .stdin(Stdio::null())
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "formatting workspace failed: {status}"
            )))
        }
    }

    fn limit_worker() -> io::Result<()> {
        // SAFETY: syscall arguments consist of primitive values and local rlimits.
        unsafe {
            check(libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))?;
            libc::umask(0o077);
            for (resource, max) in [
                (libc::RLIMIT_CORE, 0),
                (libc::RLIMIT_NPROC, 64),
                (libc::RLIMIT_NOFILE, 256),
            ] {
                let limit = libc::rlimit {
                    rlim_cur: max,
                    rlim_max: max,
                };
                check(libc::setrlimit(resource, &limit))?;
            }
        }
        Ok(())
    }

    fn reap_remaining() {
        // SAFETY: this is PID 1 inside a dedicated guest and all other processes
        // are part of this one job. This also stops descendants that called setsid.
        unsafe {
            libc::kill(-1, libc::SIGKILL);
            loop {
                if libc::waitpid(-1, std::ptr::null_mut(), 0) < 0
                    && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
                {
                    break;
                }
            }
        }
    }

    fn forward(mut source: impl Read, control: &Mutex<&mut File>, kind: u8) -> io::Result<()> {
        let mut data = [0; FRAME_LIMIT];
        loop {
            let count = source.read(&mut data)?;
            if count == 0 {
                return Ok(());
            }
            let mut output = control
                .lock()
                .map_err(|_| io::Error::other("guest control lock failed"))?;
            frame(&mut output, kind, &data[..count])?;
        }
    }

    fn frame(control: &mut File, kind: u8, data: &[u8]) -> io::Result<()> {
        let mut header = [kind; 5];
        header[1..].copy_from_slice(&(data.len() as u32).to_le_bytes());
        control.write_all(&header)?;
        control.write_all(data)
    }

    fn error_frame(control: &mut File, error: &io::Error) -> io::Result<()> {
        let message = error.to_string();
        frame(
            control,
            3,
            &message.as_bytes()[..message.len().min(FRAME_LIMIT)],
        )
    }

    fn mount(
        src: &CStr,
        target: &CStr,
        fs: &CStr,
        flags: libc::c_ulong,
        data: Option<&CStr>,
    ) -> io::Result<()> {
        let data = data.map_or(std::ptr::null(), |s| s.as_ptr().cast());
        // SAFETY: mount receives valid C strings and optional mount data.
        check(unsafe { libc::mount(src.as_ptr(), target.as_ptr(), fs.as_ptr(), flags, data) })
    }

    fn check(value: libc::c_int) -> io::Result<()> {
        if value < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

use std::env;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use serde_json::{Value, json};

use crate::vm;

const USAGE: &str = "\
Usage: stowlark-android doctor | list | create NAME | delete NAME
       stowlark-android run [NAME] [--timeout SECONDS] < script.sh

Without NAME, run uses a temporary Linux workspace. A named workspace
keeps /workspace between runs. Other VM state resets on each boot.
No guest network, host mounts, or listening socket. Results are JSON.";
pub(super) const DISK_SIZE: u64 = 64 * 1024 * 1024;
const MAX_SCRIPT: usize = 64 * 1024;
const DEFAULT_TIMEOUT: u64 = 90;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn main() -> ExitCode {
    let args = env::args_os()
        .skip(1)
        .map(|s| s.into_string().map_err(|_| "arguments must be UTF-8"));
    let reply = args
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(Into::into)
        .and_then(dispatch);
    match reply {
        Ok((code, Some(value))) => {
            let mut out = io::stdout().lock();
            if writeln!(out, "{value}").is_err() || out.flush().is_err() {
                return ExitCode::from(125);
            }
            ExitCode::from(code)
        }
        Ok((code, None)) => ExitCode::from(code),
        Err(error) => {
            let _ = writeln!(
                io::stdout().lock(),
                "{}",
                json!({"status": "error", "message": error.to_string()})
            );
            ExitCode::from(125)
        }
    }
}

fn dispatch(args: Vec<String>) -> Result<(u8, Option<Value>)> {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let args = args.as_slice();
    let result = match args {
        [] | ["--help" | "-h"] => {
            println!("{USAGE}");
            return Ok((0, None));
        }
        ["--version"] => {
            println!("stowlark-android {}", env!("CARGO_PKG_VERSION"));
            return Ok((0, None));
        }
        ["doctor"] => {
            let host = Host::locate()?;
            let state = State::open(&host)?;
            json!({"status": "ready", "api_version": 1, "guest_arch": "aarch64", "memory_mib": 256,
                   "workspace_mib": DISK_SIZE / 1024 / 1024, "network": false, "host_mounts": false,
                   "backend": "qemu-tcg", "trusted_workloads_only": true, "qemu": host.qemu, "state_dir": state.root})
        }
        ["list"] => {
            let state = State::open(&Host::locate_state()?)?;
            json!({"workspaces": state.list()?})
        }
        ["create", name] => {
            let name = checked_name(name)?;
            let state = State::open(&Host::locate_state()?)?;
            state.create(name)?;
            json!({"status": "created", "name": name})
        }
        ["delete", name] => {
            let name = checked_name(name)?;
            let state = State::open(&Host::locate_state()?)?;
            let workspace = state.root.join(name);
            if !fs::symlink_metadata(&workspace).is_ok_and(|m| m.is_dir()) {
                return Err(format!("workspace {name} does not exist").into());
            }
            fs::remove_dir_all(workspace)?;
            json!({"status": "deleted", "name": name})
        }
        ["run", run_args @ ..] => {
            let (name, timeout) = match run_args {
                [] => (None, DEFAULT_TIMEOUT),
                ["--timeout", seconds] => (None, parse_timeout(seconds)?),
                [name] => (Some(checked_name(name)?), DEFAULT_TIMEOUT),
                [name, "--timeout", seconds] => {
                    (Some(checked_name(name)?), parse_timeout(seconds)?)
                }
                _ => {
                    return Err(
                        "usage: stowlark-android run [NAME] [--timeout SECONDS] < script.sh".into(),
                    );
                }
            };
            let mut script = Vec::new();
            io::stdin()
                .take(MAX_SCRIPT as u64 + 1)
                .read_to_end(&mut script)?;
            if script.is_empty()
                || script.len() > MAX_SCRIPT
                || script.contains(&0)
                || std::str::from_utf8(&script).is_err()
            {
                return Err(
                    "stdin must contain a UTF-8 shell script of 1 to 65536 bytes with no NUL bytes"
                        .into(),
                );
            }
            let host = Host::locate()?;
            let state = State::open(&host)?;
            let mut ephemeral = None;
            let path = if let Some(name) = name {
                state.existing(name)?
            } else {
                let path = state.root.join(".ephemeral");
                clear_temporary(&path)?;
                state.create(".ephemeral")?;
                ephemeral = Some(RemoveOnDrop(path.clone()));
                path
            };
            let result = vm::run(&host, &path, script, Duration::from_secs(timeout));
            drop(ephemeral);
            let (code, value) = result?;
            return Ok((code, Some(value)));
        }
        _ => return Err("invalid arguments; see stowlark-android --help".into()),
    };
    Ok((0, Some(result)))
}

fn parse_timeout(value: &str) -> Result<u64> {
    match value.parse::<u64>() {
        Ok(seconds @ 1..=300) => Ok(seconds),
        _ => Err("timeout must be an integer from 1 to 300 seconds".into()),
    }
}

fn checked_name(name: &str) -> Result<&str> {
    if (1..=32).contains(&name.len())
        && name
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        Ok(name)
    } else {
        Err("workspace name must be 1 to 32 lowercase ASCII letters, digits or hyphens, starting with a letter or digit".into())
    }
}

#[derive(Debug)]
pub(super) struct Host {
    pub qemu: PathBuf,
    pub assets: PathBuf,
    pub prefix: Option<PathBuf>,
    state: PathBuf,
}

impl Host {
    fn locate_state() -> Result<Self> {
        #[cfg(not(target_os = "android"))]
        if let Some(state) = env::var_os("STOWLARK_ANDROID_STATE_DIR") {
            return Ok(Self {
                qemu: PathBuf::new(),
                assets: PathBuf::new(),
                prefix: None,
                state: state.into(),
            });
        }
        let home = fs::canonicalize(PathBuf::from(env::var_os("HOME").ok_or("HOME is not set")?))?;
        #[cfg(target_os = "android")]
        let prefix = {
            let prefix = home
                .parent()
                .ok_or("Termux home is not in app-private storage")?
                .join("usr");
            let uid = effective_uid();
            if uid < 10000
                || !home.starts_with("/data")
                || !home.ends_with("files/home")
                || fs::metadata(&home)?.uid() != uid
            {
                return Err(
                    "use a regular Termux session with its app-private HOME, without root".into(),
                );
            }
            Some(prefix)
        };
        #[cfg(not(target_os = "android"))]
        let prefix = None;
        Ok(Self {
            qemu: PathBuf::new(),
            assets: PathBuf::new(),
            prefix,
            state: home.join(".stowlark-android"),
        })
    }

    fn locate() -> Result<Self> {
        let mut host = Self::locate_state()?;
        let exe = env::current_exe()?.canonicalize()?;
        let installed_assets = exe
            .parent()
            .and_then(Path::parent)
            .ok_or("invalid Stowlark bundle layout")?
            .join("share/stowlark-android");
        #[cfg(target_os = "android")]
        {
            let home = host.state.parent().ok_or("invalid Termux home")?;
            if !exe.starts_with(home) {
                return Err(
                    "install the verified Stowlark bundle inside the Termux home directory".into(),
                );
            }
            host.qemu = host
                .prefix
                .as_ref()
                .ok_or("missing Termux prefix")?
                .join("bin/qemu-system-aarch64");
            host.assets = installed_assets;
        }
        #[cfg(not(target_os = "android"))]
        {
            host.qemu = env::split_paths(&env::var_os("PATH").unwrap_or_default())
                .filter(|p| p.is_absolute())
                .map(|dir| dir.join("qemu-system-aarch64"))
                .find(|p| is_executable(p))
                .ok_or("qemu-system-aarch64 is missing from PATH")?;
            host.assets = env::var_os("STOWLARK_ANDROID_ASSETS")
                .map(PathBuf::from)
                .unwrap_or(installed_assets);
        }
        if !is_executable(&host.qemu) {
            return Err(
                "install QEMU with `pkg install qemu-system-aarch64-headless` in Termux".into(),
            );
        }
        let assets = fs::canonicalize(&host.assets)
            .map_err(|e| format!("Stowlark guest assets at {}: {e}", host.assets.display()))?;
        #[cfg(target_os = "android")]
        if !assets.starts_with(host.state.parent().ok_or("invalid Termux home")?) {
            return Err("Stowlark guest assets must be inside the Termux home directory".into());
        }
        for name in ["Image", "initramfs.cpio.gz"] {
            let m = fs::symlink_metadata(assets.join(name))
                .map_err(|e| format!("Stowlark guest asset {name}: {e}"))?;
            if !m.is_file() || m.len() == 0 {
                return Err(
                    format!("Stowlark guest asset {name} must be a nonempty regular file").into(),
                );
            }
        }
        host.assets = assets;
        Ok(host)
    }
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|m| m.is_file() && m.mode() & 0o111 != 0)
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

struct State {
    root: PathBuf,
    _lock: File,
}

impl State {
    fn open(host: &Host) -> Result<Self> {
        let root = &host.state;
        match DirBuilder::new().mode(0o700).create(root) {
            Ok(()) => (),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
            Err(e) => {
                return Err(
                    format!("cannot create private state at {}: {e}", root.display()).into(),
                );
            }
        }
        let m = fs::symlink_metadata(root)?;
        if !m.is_dir() || m.mode() & 0o077 != 0 || m.uid() != effective_uid() {
            return Err(
                "Stowlark state must be a private directory (mode 0700) owned by this user".into(),
            );
        }
        let root = root.canonicalize()?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(root.join(".lock"))?;
        if !lock.metadata()?.is_file() {
            return Err("Stowlark state lock must be a regular file".into());
        }
        // SAFETY: lock is a valid owned fd kept open until State is dropped.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                return Err("Stowlark is busy; wait for the active workspace command to finish".into());
            }
            return Err(error.into());
        }
        Ok(Self { root, _lock: lock })
    }

    fn create(&self, name: &str) -> Result<()> {
        let dir = self.root.join(name);
        match fs::symlink_metadata(&dir) {
            Ok(_) => return Err(format!("workspace {name} already exists").into()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
        let staging = self.root.join(".staging");
        clear_temporary(&staging)?;
        DirBuilder::new()
            .mode(0o700)
            .create(&staging)
            .map_err(|e| format!("cannot create workspace {name}: {e}"))?;
        let _cleanup = RemoveOnDrop(staging.clone());
        let disk = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(staging.join("workspace.raw"))?;
        disk.set_len(DISK_SIZE)?;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(staging.join(".unformatted"))?;
        fs::rename(staging, dir)?;
        Ok(())
    }

    fn existing(&self, name: &str) -> Result<PathBuf> {
        let dir = self.root.join(name);
        if !fs::symlink_metadata(&dir).is_ok_and(|m| m.is_dir())
            || !fs::symlink_metadata(dir.join("workspace.raw"))
                .is_ok_and(|m| m.is_file() && m.len() == DISK_SIZE)
        {
            return Err(format!("workspace {name} does not exist or its disk is invalid").into());
        }
        Ok(dir)
    }

    fn list(&self) -> Result<Vec<String>> {
        let mut names = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if let Ok(name) = entry.file_name().into_string()
                && checked_name(&name).is_ok()
                && self.existing(&name).is_ok()
            {
                names.push(name);
            }
        }
        names.sort_unstable();
        Ok(names)
    }
}

fn clear_temporary(path: &Path) -> io::Result<()> {
    match fs::remove_dir_all(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

struct RemoveOnDrop(PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = clear_temporary(&self.0);
    }
}

#[cfg(unix)]
mod cli;
#[cfg(unix)]
mod vm;

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    cli::main()
}

#[cfg(not(unix))]
fn main() -> std::process::ExitCode {
    eprintln!("stowlark-android runs on ARM64 Android in Termux (or Unix for development)");
    std::process::ExitCode::FAILURE
}

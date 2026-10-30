use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// `EPERM` is a live process of a different user, for example root. A PID that does not fit in
/// `pid_t` is not a process: a negative `pid_t` names a process group.
pub fn process_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    match unsafe { libc::kill(pid, 0) } {
        0 => true,
        _ => std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM),
    }
}

/// A maintenance wake during system sleep has no Graphics capability.
pub async fn full_wake() -> bool {
    let output = tokio::process::Command::new("pmset")
        .args(["-g", "systemstate"])
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await;
    output.is_ok_and(|output| String::from_utf8_lossy(&output.stdout).contains("Graphics"))
}

/// No host is a local remote.
pub async fn online(host: Option<&str>) -> bool {
    if !full_wake().await {
        return false;
    }
    let Some(host) = host else { return true };
    let status = tokio::process::Command::new("nc")
        .args(["-z", "-G", "5", host, "443"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .status()
        .await;
    status.is_ok_and(|status| status.success())
}

/// A new session, so that a stop of the process group of the caller does not stop the program.
pub fn spawn_detached(program: &Path, args: &[&str], log: &Path) -> std::io::Result<()> {
    let output = std::fs::OpenOptions::new().create(true).append(true).open(log)?;
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(output.try_clone()?)
        .stderr(output);
    // SAFETY: setsid is async-signal-safe.
    unsafe {
        command.pre_exec(|| match libc::setsid() {
            -1 => Err(std::io::Error::last_os_error()),
            _ => Ok(()),
        });
    }
    command.spawn().map(|_| ())
}

/// Must give the same 12 hex digits of the SHA-1 as the keys of the state files on disk.
pub fn shasum12(text: &str) -> Result<String, String> {
    let mut child = Command::new("shasum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| format!("shasum: {error}"))?;
    child
        .stdin
        .take()
        .expect("stdin is piped")
        .write_all(text.as_bytes())
        .map_err(|error| format!("shasum: {error}"))?;
    let output = child.wait_with_output().map_err(|error| format!("shasum: {error}"))?;
    let digest = String::from_utf8_lossy(&output.stdout);
    match digest.get(..12) {
        Some(prefix) if output.status.success() => Ok(prefix.to_string()),
        _ => Err(format!("shasum failed for {text}")),
    }
}

pub fn now_seconds() -> i64 {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    now.map_or(0, |duration| duration.as_secs() as i64)
}

/// The civil-from-days algorithm of Howard Hinnant.
fn utc_civil(seconds: i64) -> (i64, i64, i64) {
    let days = seconds.div_euclid(86400) + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    (year_of_era + era * 400 + i64::from(month <= 2), month, day)
}

pub fn utc_date(seconds: i64) -> String {
    let (year, month, day) = utc_civil(seconds);
    format!("{year:04}-{month:02}-{day:02}")
}

pub fn utc_timestamp(seconds: i64) -> String {
    let second_of_day = seconds.rem_euclid(86400);
    format!(
        "{}T{:02}:{:02}:{:02}Z",
        utc_date(seconds),
        second_of_day / 3600,
        second_of_day / 60 % 60,
        second_of_day % 60
    )
}

pub fn local_time(seconds: i64) -> (i32, i32, i32) {
    let time: libc::time_t = seconds;
    // SAFETY: localtime_r writes only to `parts`.
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&time, &mut parts) };
    (parts.tm_hour, parts.tm_min, parts.tm_sec)
}

/// The column count of the terminal of stdout.
pub fn terminal_columns() -> Option<usize> {
    // SAFETY: TIOCGWINSZ writes only to `size`.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    let result = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) };
    match result == 0 && size.ws_col > 0 {
        true => Some(usize::from(size.ws_col)),
        false => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_date_and_timestamp_of_unix_times() {
        assert_eq!(utc_date(0), "1970-01-01");
        assert_eq!(utc_date(951_782_400), "2000-02-29");
        assert_eq!(utc_timestamp(1_793_000_000), "2026-10-26T07:33:20Z");
    }

    #[test]
    fn process_alive_is_true_for_a_process_of_root_and_false_for_an_ended_process() {
        let mut child = Command::new("true").spawn().unwrap();
        let ended = child.id();
        child.wait().unwrap();

        assert!(process_alive(std::process::id()));
        assert!(process_alive(1));
        assert!(!process_alive(ended));
        assert!(!process_alive(u32::MAX));
    }
}

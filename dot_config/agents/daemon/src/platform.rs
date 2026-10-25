use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// `ps`, not `kill(pid, 0)`: `kill` fails on processes of root.
pub fn process_alive(pid: u32) -> bool {
    Command::new("ps")
        .args(["-p", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn ps_field(field: &str, pid: u32) -> Option<String> {
    let output = Command::new("ps")
        .args(["-o", &format!("{field}="), "-p", &pid.to_string()])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    match output.status.success() && !text.is_empty() {
        true => Some(text),
        false => None,
    }
}

fn parent_of(pid: u32) -> Option<u32> {
    ps_field("ppid", pid)?.parse().ok()
}

/// The ancestors of this process, from the parent up to the child of PID 1.
pub fn ancestors() -> Vec<u32> {
    let mut pids = Vec::new();
    let mut pid = std::os::unix::process::parent_id();
    while pid > 1 {
        pids.push(pid);
        match parent_of(pid) {
            Some(parent) => pid = parent,
            None => break,
        }
    }
    pids
}

/// The Claude Code process that runs the caller. Its life is the life of the subscription. With
/// no `claude` process above, the parent, and a log message.
pub fn session_pid() -> (u32, Option<String>) {
    if let Some(pid) = std::env::var("WATCH_SESSION_PID").ok().and_then(|pid| pid.parse().ok()) {
        return (pid, None);
    }
    let parent = std::os::unix::process::parent_id();
    for pid in ancestors() {
        let command = ps_field("comm", pid).unwrap_or_default();
        if command.rsplit('/').next() == Some("claude") {
            return (pid, None);
        }
    }
    // The parent dies with the client. Thus the subscription ends soon after each client.
    let message = format!("no claude process above PID {parent}: the session is PID {parent}");
    (parent, Some(message))
}

/// True during full wake. A maintenance wake during system sleep has no Graphics capability.
pub async fn full_wake() -> bool {
    let output = tokio::process::Command::new("pmset")
        .args(["-g", "systemstate"])
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await;
    output.is_ok_and(|output| String::from_utf8_lossy(&output.stdout).contains("Graphics"))
}

/// One try: full wake, and the host accepts a connection on port 443. No host is a local remote.
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

/// Starts PROGRAM in a new session, so that a stop of the process group of the caller does not
/// stop it. launchd becomes its parent when the caller exits.
pub fn spawn_detached(program: &Path, args: &[&str], log: &Path) -> std::io::Result<()> {
    let output = std::fs::OpenOptions::new().create(true).append(true).open(log)?;
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(output.try_clone()?).stderr(output);
    // SAFETY: setsid is async-signal-safe.
    unsafe {
        command.pre_exec(|| match libc::setsid() {
            -1 => Err(std::io::Error::last_os_error()),
            _ => Ok(()),
        });
    }
    command.spawn().map(|_| ())
}

/// The first 12 hex digits of the SHA-1 of `text`, as `printf %s TEXT | shasum | cut -c1-12`.
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

/// Year, month, and day of a Unix time in UTC, by the civil-from-days algorithm of Howard Hinnant.
fn utc_civil(seconds: i64) -> (i64, i64, i64) {
    let days = seconds.div_euclid(86400) + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    (year_of_era + era * 400 + i64::from(month <= 2), month, day)
}

/// `YYYY-MM-DD` in UTC.
pub fn utc_date(seconds: i64) -> String {
    let (year, month, day) = utc_civil(seconds);
    format!("{year:04}-{month:02}-{day:02}")
}

/// `YYYY-MM-DDTHH:MM:SSZ`, as `date -u +%Y-%m-%dT%H:%M:%SZ`.
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

/// Hour, minute, and second of a Unix time in the local time zone.
pub fn local_time(seconds: i64) -> (i32, i32, i32) {
    let time: libc::time_t = seconds;
    // SAFETY: localtime_r writes only to `parts`.
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&time, &mut parts) };
    (parts.tm_hour, parts.tm_min, parts.tm_sec)
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
}

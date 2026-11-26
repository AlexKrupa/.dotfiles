use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// `EPERM` is a live process of a different user, for example root. A PID of 0 or a PID that does
/// not fit in `pid_t` is not a process: `kill` reads 0 and a negative `pid_t` as a process group.
pub fn process_alive(pid: u32) -> bool {
    let Some(pid) = libc::pid_t::try_from(pid).ok().filter(|pid| *pid > 0) else {
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
pub fn spawn_detached(program: &Path, args: &[&str]) -> std::io::Result<()> {
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe.
    unsafe {
        command.pre_exec(|| match libc::setsid() {
            -1 => Err(std::io::Error::last_os_error()),
            _ => Ok(()),
        });
    }
    command.spawn().map(|_| ())
}

/// Points stdout and stderr at the file. The descriptors change, so that the child processes that
/// inherit them also write to the file.
pub fn redirect_output(file: &std::fs::File) -> std::io::Result<()> {
    for fd in [libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        // SAFETY: dup2 on an open descriptor.
        if unsafe { libc::dup2(file.as_raw_fd(), fd) } == -1 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Must give the same 12 hex digits of the SHA-1 as `shasum`, the hash of the keys of the state
/// files on disk.
pub fn shasum12(text: &str) -> String {
    let mut digest = sha1_smol::Sha1::from(text).digest().to_string();
    digest.truncate(12);
    digest
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

/// The days-from-civil algorithm of Howard Hinnant.
fn days_of(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let month_index = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// The Unix time of an ISO 8601 time stamp such as `2026-10-26T07:33:20.123Z` or one with a
/// `+02:00` offset.
pub fn utc_seconds(text: &str) -> Option<i64> {
    let number = |range: std::ops::Range<usize>| text.get(range)?.parse::<i64>().ok();
    let separators = [(4, b'-'), (7, b'-'), (10, b'T'), (13, b':'), (16, b':')];
    if !separators
        .iter()
        .all(|(index, byte)| text.as_bytes().get(*index) == Some(byte))
    {
        return None;
    }
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    let zone = text[19..].trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    let offset = match zone.as_bytes().first() {
        Some(b'Z') => 0,
        Some(sign @ (b'+' | b'-')) => {
            let hours: i64 = zone.get(1..3)?.parse().ok()?;
            let minutes: i64 = zone.get(4..6)?.parse().ok()?;
            let size = hours * 3600 + minutes * 60;
            if *sign == b'+' { size } else { -size }
        }
        _ => return None,
    };
    Some(days_of(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset)
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
    fn utc_seconds_reads_gitlab_time_stamps() {
        assert_eq!(utc_seconds("2026-10-26T07:33:20Z"), Some(1_793_000_000));
        assert_eq!(utc_seconds("2026-10-26T07:33:20.123Z"), Some(1_793_000_000));
        assert_eq!(utc_seconds("2026-10-26T09:33:20.123+02:00"), Some(1_793_000_000));
        assert_eq!(utc_seconds("2000-02-29T00:00:00Z"), Some(951_782_400));
        assert_eq!(utc_seconds("yesterday"), None);
    }

    #[test]
    fn process_alive_is_true_for_a_process_of_root_and_false_for_an_ended_process_or_a_group() {
        let mut child = Command::new("true").spawn().unwrap();
        let ended = child.id();
        child.wait().unwrap();

        assert!(process_alive(std::process::id()));
        assert!(process_alive(1));
        assert!(!process_alive(ended));
        assert!(!process_alive(0));
        assert!(!process_alive(u32::MAX));
    }
}

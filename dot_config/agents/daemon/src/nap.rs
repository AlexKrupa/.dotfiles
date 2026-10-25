const NETWORK_ERRORS: &[&str] = &[
    "no such host",
    "dial tcp",
    "i/o timeout",
    "TLS handshake timeout",
    "Could not resolve host",
    "Failed to connect",
    "Connection refused",
    "connection refused",
    "connection reset",
    "timed out",
    "Network is unreachable",
    "network is unreachable",
    "HTTP 502",
    "HTTP 503",
    "HTTP 504",
];

pub fn is_network_error(stderr: &str) -> bool {
    NETWORK_ERRORS.iter().any(|pattern| stderr.contains(pattern))
}

#[derive(Debug, PartialEq, Eq)]
pub enum NapEnd {
    Done,
    /// A poke or a stop.
    Interrupted,
    /// A system sleep, or no full wake: the caller waits for the network.
    Asleep,
}

/// `sleep` gives `(woken, awake)`: true for a wake-up, and false for no full wake after the step.
pub async fn nap<Now, Sleep, SleepFuture>(seconds: u64, max_step: u64, now: Now, mut sleep: Sleep) -> NapEnd
where
    Now: Fn() -> i64,
    Sleep: FnMut(u64) -> SleepFuture,
    SleepFuture: std::future::Future<Output = (bool, bool)>,
{
    let mut left = seconds;
    while left > 0 {
        let step = left.min(max_step);
        let start = now();
        let (woken, awake) = sleep(step).await;
        if now() - start > step as i64 + 30 || !awake {
            return NapEnd::Asleep;
        }
        left -= step;
        if woken {
            return NapEnd::Interrupted;
        }
    }
    NapEnd::Done
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::cell::Cell;

    fn run(nap_future: impl std::future::Future<Output = NapEnd>) -> NapEnd {
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        runtime.block_on(nap_future)
    }

    #[test]
    fn clock_jump_longer_than_step_plus_30_seconds_is_a_sleep() {
        let clock = Cell::new(0_i64);
        let end = run(nap(
            60,
            10,
            || clock.get(),
            |step| {
                clock.set(clock.get() + step as i64 + 31);
                async { (false, true) }
            },
        ));
        assert_eq!(end, NapEnd::Asleep);
        assert_eq!(clock.get(), 41);
    }

    #[test]
    fn nap_waits_in_steps_and_ends_early_on_a_wake_up() {
        let clock = Cell::new(0_i64);
        let steps = Cell::new(0);
        let end = run(nap(
            25,
            10,
            || clock.get(),
            |step| {
                clock.set(clock.get() + step as i64);
                steps.set(steps.get() + 1);
                async { (false, true) }
            },
        ));
        assert_eq!((end, clock.get(), steps.get()), (NapEnd::Done, 25, 3));
        let woken = run(nap(25, 10, || 0, |_| async { (true, true) }));
        assert_eq!(woken, NapEnd::Interrupted);
        let dark = run(nap(25, 10, || 0, |_| async { (false, false) }));
        assert_eq!(dark, NapEnd::Asleep);
    }

    #[test]
    fn network_error_matches_the_bash_patterns() {
        assert!(is_network_error("dial tcp: i/o timeout"));
        assert!(is_network_error("HTTP 503"));
        assert!(!is_network_error("HTTP 404 Not Found"));
    }
}

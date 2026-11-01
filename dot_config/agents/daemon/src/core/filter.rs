//! The event kinds, the conditions, and the needs of each MR mode. The engine sends one event set
//! for each MR. After each check, the daemon keeps the events of the mode of the key. The hub has
//! no entry: its events do not go through the filter.

use crate::core::subs::Mode;
use crate::engine::event::{Event, EventKind};
use crate::engine::state::Need;

const AUTHOR_KINDS: &[EventKind] = &[
    EventKind::Reaction,
    EventKind::Pipeline,
    EventKind::Comment,
    EventKind::OwnComment,
    EventKind::Approved,
    EventKind::Unapproved,
    EventKind::Draft,
    EventKind::Ready,
    EventKind::Title,
    EventKind::Description,
    EventKind::Labels,
    EventKind::Conflict,
    EventKind::Mergeable,
    EventKind::Merged,
    EventKind::Closed,
    EventKind::Unaddressed,
    EventKind::Pushed,
];

const REVIEW_KINDS: &[EventKind] = &[
    EventKind::Reaction,
    EventKind::Pipeline,
    EventKind::Comment,
    EventKind::OwnComment,
    EventKind::Approved,
    EventKind::Unapproved,
    EventKind::Draft,
    EventKind::Ready,
    EventKind::Title,
    EventKind::Description,
    EventKind::Labels,
    EventKind::Conflict,
    EventKind::Mergeable,
    EventKind::Merged,
    EventKind::Closed,
    EventKind::Unaddressed,
    EventKind::Pushed,
    EventKind::Resolved,
];

const AUTHOR_NEEDS: &[Need] = &[
    Need::Failed,
    Need::Conflict,
    Need::Reply,
    Need::RequestedChanges,
    Need::Ready,
    Need::Draft,
];

const REVIEW_NEEDS: &[Need] = &[Need::ReplyMine, Need::Commits];

pub fn kinds(mode: Mode) -> &'static [EventKind] {
    match mode {
        Mode::Hub => &[],
        Mode::Author => AUTHOR_KINDS,
        Mode::Review => REVIEW_KINDS,
    }
}

fn holds(mode: Mode, event: &Event) -> bool {
    match mode {
        Mode::Hub => true,
        Mode::Author => event.kind != EventKind::Pushed || event.local != Some(true),
        Mode::Review => event.kind != EventKind::Unaddressed || event.mine == Some(true),
    }
}

/// An empty `chosen` means all kinds of the mode. The item of an event that fails a condition of
/// the mode does not open from a different event either, for example from a comment in the thread.
pub fn filter(mode: Mode, chosen: &[EventKind], events: Vec<Event>) -> Vec<Event> {
    let allowed = match mode {
        Mode::Hub => return events,
        Mode::Author | Mode::Review => kinds(mode),
    };
    let dropped: Vec<String> = events
        .iter()
        .filter(|event| !holds(mode, event))
        .filter_map(|event| event.item.clone())
        .collect();
    events
        .into_iter()
        .filter(|event| allowed.contains(&event.kind))
        .filter(|event| chosen.is_empty() || chosen.contains(&event.kind))
        .filter(|event| holds(mode, event))
        .map(
            |event| match event.item.as_ref().is_some_and(|item| dropped.contains(item)) {
                true => Event { item: None, ..event },
                false => event,
            },
        )
        .collect()
}

/// The needs of the mode in `present`, in the order of the mode.
pub fn needs(mode: Mode, present: &[Need]) -> Vec<Need> {
    let order = match mode {
        Mode::Hub => return present.to_vec(),
        Mode::Author => AUTHOR_NEEDS,
        Mode::Review => REVIEW_NEEDS,
    };
    order.iter().copied().filter(|need| present.contains(need)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: EventKind) -> Event {
        Event::new(kind, Some(5), Some("T"), "u", "anna", "", "b")
    }

    fn unaddressed(mine: bool) -> Event {
        Event {
            mine: Some(mine),
            ..event(EventKind::Unaddressed)
        }
    }

    fn kinds_of(events: &[Event]) -> Vec<EventKind> {
        events.iter().map(|event| event.kind).collect()
    }

    #[test]
    fn author_drops_resolved() {
        let events = filter(
            Mode::Author,
            &[],
            vec![event(EventKind::Resolved), event(EventKind::Comment)],
        );
        assert_eq!(kinds_of(&events), vec![EventKind::Comment]);
    }

    #[test]
    fn author_keeps_only_pushes_from_elsewhere() {
        let local = Event {
            local: Some(true),
            ..event(EventKind::Pushed)
        };
        let events = filter(Mode::Author, &[], vec![local, event(EventKind::Pushed)]);
        assert_eq!(events, vec![event(EventKind::Pushed)]);
    }

    #[test]
    fn review_keeps_pushed_and_resolved() {
        let events = filter(
            Mode::Review,
            &[],
            vec![event(EventKind::Pushed), event(EventKind::Resolved)],
        );
        assert_eq!(kinds_of(&events), vec![EventKind::Pushed, EventKind::Resolved]);
    }

    #[test]
    fn review_drops_unaddressed_of_others() {
        let both = || vec![unaddressed(false), unaddressed(true)];
        assert_eq!(filter(Mode::Review, &[], both()), vec![unaddressed(true)]);
        assert_eq!(filter(Mode::Author, &[], both()), both());
    }

    #[test]
    fn review_drops_the_thread_item_of_others() {
        let item = |event: Event, id: &str| Event {
            item: Some(format!("thread:{id}")),
            ..event
        };
        let events = vec![
            item(event(EventKind::Comment), "d1"),
            item(event(EventKind::Comment), "d2"),
            item(unaddressed(false), "d1"),
            item(unaddressed(true), "d2"),
        ];

        let kept = filter(Mode::Review, &[], events);

        assert_eq!(
            kept,
            vec![
                event(EventKind::Comment),
                item(event(EventKind::Comment), "d2"),
                item(unaddressed(true), "d2"),
            ]
        );
    }

    #[test]
    fn chosen_narrows_the_mode_list() {
        let events = filter(
            Mode::Review,
            &[EventKind::Pushed],
            vec![event(EventKind::Pushed), event(EventKind::Comment)],
        );
        assert_eq!(kinds_of(&events), vec![EventKind::Pushed]);
    }

    #[test]
    fn needs_follow_the_mode_order() {
        let present = [Need::Draft, Need::ReplyMine, Need::Reply, Need::Failed, Need::Commits];
        assert_eq!(
            needs(Mode::Author, &present),
            vec![Need::Failed, Need::Reply, Need::Draft]
        );
        assert_eq!(needs(Mode::Review, &present), vec![Need::ReplyMine, Need::Commits]);
    }

    #[test]
    fn hub_events_pass() {
        assert_eq!(
            kinds_of(&filter(Mode::Hub, &[], vec![event(EventKind::Todo)])),
            vec![EventKind::Todo]
        );
    }
}

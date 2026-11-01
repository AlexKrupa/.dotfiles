//! The engine sends one event set for each MR, and this table gives the part of it for each mode.

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

const REVIEW_NEEDS: &[Need] = &[Need::ReplyToYou, Need::Commits];

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
        Mode::Review => event.kind != EventKind::Unaddressed || event.you_commented == Some(true),
    }
}

/// An empty `chosen` means all kinds of the mode. `merged` and `closed` always pass, because they
/// end the watch. The item of a dropped event does not open from a comment in the same thread.
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
        .filter(|event| {
            chosen.is_empty()
                || chosen.contains(&event.kind)
                || matches!(event.kind, EventKind::Merged | EventKind::Closed)
        })
        .filter(|event| holds(mode, event))
        .map(
            |event| match event.item.as_ref().is_some_and(|item| dropped.contains(item)) {
                true => Event { item: None, ..event },
                false => event,
            },
        )
        .collect()
}

/// The worktree state has one reply value for all modes.
pub fn needs(mode: Mode, present: &[Need]) -> Vec<Need> {
    let order = match mode {
        Mode::Hub => return present.to_vec(),
        Mode::Author => AUTHOR_NEEDS,
        Mode::Review => REVIEW_NEEDS,
    };
    order
        .iter()
        .copied()
        .filter(|need| present.contains(need))
        .map(|need| match need {
            Need::ReplyToYou => Need::Reply,
            other => other,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: EventKind) -> Event {
        Event::new(kind, Some(5), Some("T"), "u", "anna", "", "b")
    }

    fn unaddressed(you_commented: bool) -> Event {
        Event {
            you_commented: Some(you_commented),
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
    fn chosen_keeps_the_end_of_the_mr() {
        let events = filter(
            Mode::Review,
            &[EventKind::Pushed],
            vec![event(EventKind::Merged), event(EventKind::Closed)],
        );
        assert_eq!(kinds_of(&events), vec![EventKind::Merged, EventKind::Closed]);
    }

    #[test]
    fn needs_follow_the_mode_order() {
        let present = [Need::Draft, Need::ReplyToYou, Need::Reply, Need::Failed, Need::Commits];
        assert_eq!(
            needs(Mode::Author, &present),
            vec![Need::Failed, Need::Reply, Need::Draft]
        );
        assert_eq!(needs(Mode::Review, &present), vec![Need::Reply, Need::Commits]);
    }

    #[test]
    fn hub_events_pass() {
        assert_eq!(
            kinds_of(&filter(Mode::Hub, &[], vec![event(EventKind::Todo)])),
            vec![EventKind::Todo]
        );
    }
}

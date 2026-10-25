use serde::{Deserialize, Serialize};

pub use super::subs::Mode;
use crate::engine::event::{Event, EventKind};

/// The open items of a subscription, `items/<key>.json`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Items {
    pub next: u64,
    pub items: Vec<Item>,
}

impl Default for Items {
    fn default() -> Items {
        Items { next: 1, items: Vec::new() }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub n: u64,
    pub item: String,
    pub owner: Owner,
    pub iid: Option<u64>,
    pub title: Option<String>,
    pub url: Option<String>,
    pub what: Option<String>,
    pub result: Option<String>,
    pub since: Option<i64>,
    pub event: Option<Event>,
}

/// The daemon closes its items by the present list of the engine. The model closes its items in a
/// report.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Owner {
    Daemon,
    Model,
}

/// An event with `row`: the number of its open item, or a new number.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RoutedEvent {
    #[serde(flatten)]
    pub event: Event,
    pub row: u64,
}

/// An event with a new item key opens a new item. An event with no item key gets a new number. An
/// unaddressed line keeps the event of its item: the item shows the comment that opened it.
pub fn assign_rows(items: &mut Items, events: Vec<Event>, now: i64) -> Vec<RoutedEvent> {
    let mut routed = Vec::new();
    for event in events {
        let Some(key) = event.item.clone() else {
            routed.push(RoutedEvent { event, row: items.next });
            items.next += 1;
            continue;
        };
        match items.items.iter_mut().find(|item| item.item == key) {
            Some(item) => {
                let row = item.n;
                match event.kind {
                    EventKind::Unaddressed => {}
                    _ => item.event = Some(event.clone()),
                }
                routed.push(RoutedEvent { event, row });
            }
            None => {
                let row = items.next;
                items.items.push(Item {
                    n: row,
                    item: key,
                    owner: Owner::Daemon,
                    iid: event.iid,
                    title: event.title.clone(),
                    url: Some(event.url.clone()),
                    what: None,
                    result: None,
                    since: Some(now),
                    event: Some(event.clone()),
                });
                items.next += 1;
                routed.push(RoutedEvent { event, row });
            }
        }
    }
    routed
}

/// The item keys of the hub. A review key takes the hub items of its MR.
fn is_hub_item(key: &str) -> bool {
    ["todo:", "note:", "main-failed:"].iter().any(|prefix| key.starts_with(prefix))
}

/// After a check: removes each daemon item whose key is not in the present list of the engine. A
/// hub item of a review or stack key uses the present list of the hub, and stays if there is none.
pub fn prune_items(items: &mut Items, present: &[String], hub_present: Option<&[String]>, mode: Mode) {
    items.items.retain(|item| {
        let other_mode = match mode {
            Mode::Hub => false,
            Mode::Stack | Mode::Review => true,
        };
        match item.owner {
            Owner::Model => true,
            Owner::Daemon if other_mode && is_hub_item(&item.item) => {
                hub_present.is_none_or(|hub| hub.contains(&item.item))
            }
            Owner::Daemon => present.contains(&item.item),
        }
    });
}

/// Moves the items of `source`, or only the items of the MR `iid`, to `target`, with new numbers of
/// the target. Gives the number of moved items.
pub fn move_items(source: &mut Items, target: &mut Items, iid: Option<u64>) -> usize {
    let (moved, kept): (Vec<Item>, Vec<Item>) = std::mem::take(&mut source.items)
        .into_iter()
        .partition(|item| iid.is_none() || item.iid == iid);
    source.items = kept;
    let count = moved.len();
    for item in moved {
        target.items.push(Item { n: target.next, ..item });
        target.next += 1;
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: EventKind, item: Option<&str>) -> Event {
        Event {
            item: item.map(str::to_string),
            ..Event::new(kind, Some(5), Some("T"), "u", "anna", "d", "b")
        }
    }

    fn rows(routed: &[RoutedEvent]) -> Vec<u64> {
        routed.iter().map(|event| event.row).collect()
    }

    #[test]
    fn assign_rows_reuses_the_number_of_an_open_item() {
        let mut items = Items::default();
        assign_rows(&mut items, vec![event(EventKind::Conflict, Some("conflict:5"))], 100);
        let routed = assign_rows(&mut items, vec![event(EventKind::Conflict, Some("conflict:5"))], 200);
        assert_eq!(rows(&routed), vec![1]);
        assert_eq!(items.next, 2);
        assert_eq!(items.items.len(), 1);
        assert_eq!(items.items[0].since, Some(100));
        assert_eq!(items.items[0].owner, Owner::Daemon);
    }

    #[test]
    fn assign_rows_keeps_the_event_of_an_item_for_an_unaddressed_line() {
        let mut items = Items::default();
        let comment = Event { detail: "Why?".to_string(), ..event(EventKind::Comment, Some("thread:d1")) };
        assign_rows(&mut items, vec![comment, event(EventKind::Unaddressed, Some("thread:d1"))], 100);
        let routed = assign_rows(&mut items, vec![event(EventKind::Unaddressed, Some("thread:d1"))], 200);
        assert_eq!(rows(&routed), vec![1]);
        assert_eq!(items.items[0].event.as_ref().map(|event| event.kind), Some(EventKind::Comment));
        assert_eq!(serde_json::to_string(&routed[0]).unwrap(), r#"{"kind":"unaddressed","iid":5,"title":"T","url":"u","actor":"anna","detail":"d","branch":"b","item":"thread:d1","row":1}"#);
    }

    #[test]
    fn event_without_item_gets_a_new_number_and_opens_nothing() {
        let mut items = Items::default();
        let routed = assign_rows(&mut items, vec![event(EventKind::Approved, None), event(EventKind::Approved, None)], 100);
        assert_eq!(rows(&routed), vec![1, 2]);
        assert_eq!(items.next, 3);
        assert!(items.items.is_empty());
    }

    #[test]
    fn prune_keeps_model_items_and_uses_the_hub_present_list_for_review_hub_items() {
        let item = |n: u64, key: &str, owner: Owner| Item {
            n,
            item: key.to_string(),
            owner,
            iid: Some(5),
            title: None,
            url: None,
            what: None,
            result: None,
            since: None,
            event: None,
        };
        let mut items = Items {
            next: 5,
            items: vec![
                item(1, "model:1", Owner::Model),
                item(2, "todo:11", Owner::Daemon),
                item(3, "note:12", Owner::Daemon),
                item(4, "thread:d1", Owner::Daemon),
            ],
        };
        let hub = vec!["todo:11".to_string()];
        prune_items(&mut items, &["note:12".to_string()], Some(&hub), Mode::Review);
        let left: Vec<u64> = items.items.iter().map(|item| item.n).collect();
        assert_eq!(left, vec![1, 2]);

        let mut no_hub = Items { next: 3, items: vec![item(1, "todo:11", Owner::Daemon), item(2, "thread:d1", Owner::Daemon)] };
        prune_items(&mut no_hub, &[], None, Mode::Review);
        assert_eq!(no_hub.items.len(), 1);
        let mut hub_mode = Items { next: 2, items: vec![item(1, "todo:11", Owner::Daemon)] };
        prune_items(&mut hub_mode, &[], None, Mode::Hub);
        assert!(hub_mode.items.is_empty());
    }

    #[test]
    fn move_items_renumbers_in_the_target() {
        let mut source = Items::default();
        assign_rows(&mut source, vec![event(EventKind::Todo, Some("todo:1"))], 1);
        let other = Event { iid: Some(6), ..event(EventKind::Todo, Some("todo:2")) };
        assign_rows(&mut source, vec![other], 1);
        let mut target = Items { next: 7, items: Vec::new() };
        assert_eq!(move_items(&mut source, &mut target, Some(5)), 1);
        assert_eq!(target.next, 8);
        assert_eq!(target.items[0].n, 7);
        assert_eq!(target.items[0].item, "todo:1");
        assert_eq!(source.items.len(), 1);
        assert_eq!(move_items(&mut source, &mut target, None), 1);
        assert!(source.items.is_empty());
        assert_eq!(target.items[1].n, 8);
    }
}

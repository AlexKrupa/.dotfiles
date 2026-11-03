//! The report of `watchd board`: one group for each MR, with the title, the status line, and the MR
//! URL, then the rows of the MR, wrapped to the width of the pane. A URL is plain text.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::engine::event::{Event, EventKind};
use crate::engine::state::MrState;
use crate::report::{ReportData, RowSection, one_line, what};

#[derive(Debug, Default, PartialEq, Deserialize, Serialize)]
pub struct Board {
    pub time: String,
    pub rows: Vec<BoardRow>,
}

#[derive(Debug, PartialEq, Deserialize, Serialize)]
pub struct BoardRow {
    pub n: u64,
    pub section: RowSection,
    pub iid: Option<u64>,
    pub title: Option<String>,
    pub url: Option<String>,
    /// The MR URL with no `#` anchor.
    #[serde(default)]
    pub mr_url: Option<String>,
    pub what: String,
    pub result: String,
}

/// The MR data of the state files, which the board file does not have.
#[derive(Debug, Default)]
pub struct Status {
    /// Work pane: the MRs of the worktree, in order. Hub: empty.
    pub mrs: Vec<u64>,
    pub known: BTreeMap<u64, MrStatus>,
}

#[derive(Debug, Default)]
pub struct MrStatus {
    pub title: Option<String>,
    pub url: Option<String>,
    pub line: Option<String>,
}

const RESET: &str = "\x1b[0m";
const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const CYAN: &str = "\x1b[36m";

/// The columns left of a section heading and of a row.
const SECTION_INDENT: usize = 2;

/// The columns left of the row text, after the section indent. The row number is in them.
const INDENT: usize = 3;

/// The approvers that the status line names. It counts the others.
const SHOWN_APPROVERS: usize = 3;

const SECTIONS: [RowSection; 3] = [RowSection::NeedsYou, RowSection::Agent, RowSection::Info];

/// The parts of the MR state, joined with ` - `. A merged or closed MR has no other part.
pub fn status_line(mr: &MrState, local_conflict: bool) -> Option<String> {
    if let Some(state) = mr
        .state
        .as_deref()
        .filter(|state| matches!(*state, "merged" | "closed"))
    {
        return Some(state.to_string());
    }
    let approvers = mr.approved_by.as_deref().unwrap_or_default();
    let approvals = match approvers.len() {
        0 => None,
        count if count > SHOWN_APPROVERS => Some(format!(
            "approved by {} +{}",
            approvers[..SHOWN_APPROVERS].join(", "),
            count - SHOWN_APPROVERS
        )),
        _ => Some(format!("approved by {}", approvers.join(", "))),
    };
    let parts: Vec<String> = [
        (mr.draft == Some(true)).then(|| "draft".to_string()),
        (mr.merge_status.as_deref() == Some("mergeable")).then(|| "ready to merge".to_string()),
        approvals,
        local_conflict.then(|| "local conflict".to_string()),
    ]
    .into_iter()
    .flatten()
    .collect();
    match parts.is_empty() {
        true => None,
        false => Some(parts.join(" - ")),
    }
}

/// The rows of one MR, or of no MR for `iid` `None`.
struct Group<'a> {
    iid: Option<u64>,
    rows: Vec<&'a BoardRow>,
}

impl Board {
    pub fn of(time: &str, data: &ReportData) -> Board {
        let rows = data
            .rows
            .iter()
            .filter(|row| !row.event.as_ref().is_some_and(is_state_change))
            .map(|row| BoardRow {
                n: row.n,
                section: row.section,
                iid: row.iid,
                title: row.title.clone(),
                url: row
                    .url
                    .clone()
                    .or_else(|| row.iid.and_then(|iid| data.known.get(&iid)?.url.clone()))
                    .filter(|url| !url.is_empty()),
                mr_url: row
                    .iid
                    .and_then(|iid| data.known.get(&iid)?.url.as_deref())
                    .map(|url| url.split('#').next().unwrap_or(url).to_string())
                    .filter(|url| !url.is_empty()),
                what: one_line(&what(row)),
                result: one_line(&row.result),
            })
            .collect();
        Board {
            time: time.to_string(),
            rows,
        }
    }

    /// The text with ANSI colors.
    pub fn draw(&self, columns: usize, status: &Status) -> String {
        let mut lines = vec![match self.time.is_empty() {
            true => "No report yet.".to_string(),
            false => format!("{DIM}{}{RESET}", self.time),
        }];
        for group in self.groups(status) {
            lines.extend(group.draw(columns, status));
        }
        lines.join("\n")
    }

    /// The MRs of the status first, then the MR with the most urgent row, then the rows with no MR.
    fn groups(&self, status: &Status) -> Vec<Group<'_>> {
        let mut groups: Vec<Group> = status
            .mrs
            .iter()
            .map(|iid| Group {
                iid: Some(*iid),
                rows: Vec::new(),
            })
            .collect();
        let mut others: Vec<Group> = Vec::new();
        for row in &self.rows {
            match groups
                .iter_mut()
                .chain(others.iter_mut())
                .find(|group| group.iid == row.iid)
            {
                Some(group) => group.rows.push(row),
                None => others.push(Group {
                    iid: row.iid,
                    rows: vec![row],
                }),
            }
        }
        others.sort_by_key(|group| {
            let most_urgent = group.rows.iter().map(|row| (urgency(row.section), row.n)).min();
            (group.iid.is_none(), most_urgent)
        });
        groups.extend(others);
        groups
    }
}

impl Group<'_> {
    /// Two empty lines, the header, then each section with rows.
    fn draw(&self, columns: usize, status: &Status) -> Vec<String> {
        let known = self.iid.and_then(|iid| status.known.get(&iid));
        let mr_url = known
            .and_then(|known| known.url.as_deref())
            .or_else(|| self.rows.iter().find_map(|row| row.mr_url.as_deref()));
        let mut lines = vec![String::new(), String::new()];
        match self.iid {
            Some(iid) => {
                let title = known
                    .and_then(|known| known.title.as_deref())
                    .or_else(|| self.rows.iter().find_map(|row| row.title.as_deref()));
                let mr = format!("!{iid}");
                let header = [Some(mr.as_str()), title]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>()
                    .join(" ");
                let mut header_lines = wrap(&header, columns.max(10));
                header_lines[0] = format!("{CYAN}{mr}{RESET}{BOLD}") + &header_lines[0][mr.len()..];
                lines.extend(header_lines.iter().map(|line| format!("{BOLD}{line}{RESET}")));
            }
            None => lines.push(format!("{BOLD}Project{RESET}")),
        }
        if let Some(line) = known.and_then(|known| known.line.as_deref()) {
            lines.extend(wrap(line, columns.max(10)));
        }
        // A URL with no line break stays one URL for the terminal, also when the terminal wraps it.
        if let Some(url) = mr_url {
            lines.push(format!("{DIM}{url}{RESET}"));
        }
        let section_indent = " ".repeat(SECTION_INDENT);
        for section in SECTIONS {
            let rows: Vec<&BoardRow> = self.rows.iter().copied().filter(|row| row.section == section).collect();
            if rows.is_empty() {
                continue;
            }
            lines.push(String::new());
            lines.push(format!(
                "{section_indent}{BOLD}{}{}{RESET}",
                color(section),
                section.label().to_uppercase()
            ));
            for row in rows {
                lines.push(String::new());
                lines.extend(draw_row(row, mr_url, columns));
            }
        }
        lines
    }
}

/// The number, the text, the `->` result, and the URL if it is not the MR URL.
fn draw_row(row: &BoardRow, mr_url: Option<&str>, columns: usize) -> Vec<String> {
    let width = columns.saturating_sub(SECTION_INDENT + INDENT).max(10);
    let indent = " ".repeat(SECTION_INDENT + INDENT);
    let section_indent = " ".repeat(SECTION_INDENT);
    let mut lines: Vec<String> = heading(row.n, &wrap(&row.what, width))
        .into_iter()
        .map(|line| format!("{section_indent}{line}"))
        .collect();
    for (index, line) in wrap(&row.result, width - 3).iter().enumerate() {
        let arrow = match index {
            0 => "-> ",
            _ => "   ",
        };
        lines.push(format!("{indent}{arrow}{line}"));
    }
    if let Some(url) = row.url.as_deref().filter(|url| Some(*url) != mr_url) {
        lines.push(format!("{indent}{DIM}{url}{RESET}"));
    }
    lines
}

/// The lower value is the more urgent section.
fn urgency(section: RowSection) -> u8 {
    match section {
        RowSection::NeedsYou => 0,
        RowSection::Agent => 1,
        RowSection::Info => 2,
    }
}

/// An event that the status line of its MR shows. A failed pipeline has jobs.
fn is_state_change(event: &Event) -> bool {
    match event.kind {
        EventKind::Approved
        | EventKind::Unapproved
        | EventKind::Draft
        | EventKind::Ready
        | EventKind::Merged
        | EventKind::Closed
        | EventKind::Mergeable => true,
        EventKind::Pipeline => event.jobs.is_none(),
        EventKind::Todo
        | EventKind::Opened
        | EventKind::Note
        | EventKind::Reaction
        | EventKind::DefaultFailed
        | EventKind::Comment
        | EventKind::OwnComment
        | EventKind::Title
        | EventKind::Description
        | EventKind::Labels
        | EventKind::Conflict
        | EventKind::Unaddressed
        | EventKind::Pushed
        | EventKind::Resolved
        | EventKind::PullBlocked => false,
    }
}

fn color(section: RowSection) -> &'static str {
    match section {
        RowSection::NeedsYou => "\x1b[31m",
        RowSection::Agent => "\x1b[33m",
        RowSection::Info => "\x1b[90m",
    }
}

/// The row number before the first line.
fn heading(n: u64, lines: &[String]) -> Vec<String> {
    let number = format!("{n:<width$}", width = INDENT - 1);
    let indent = " ".repeat(INDENT);
    match lines.split_first() {
        Some((first, rest)) => std::iter::once(format!("{BOLD}{number}{RESET} {first}"))
            .chain(rest.iter().map(|line| format!("{indent}{line}")))
            .collect(),
        None => vec![format!("{BOLD}{number}{RESET}")],
    }
}

/// Breaks the text at spaces, and a word longer than the width in the word.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let words = text.split_whitespace().flat_map(|word| {
        let chars: Vec<char> = word.chars().collect();
        chars
            .chunks(width)
            .map(|chunk| chunk.iter().collect::<String>())
            .collect::<Vec<_>>()
    });
    let mut lines = Vec::new();
    let mut line = String::new();
    let mut line_chars = 0;
    for word in words {
        let word_chars = word.chars().count();
        if line_chars > 0 && line_chars + 1 + word_chars > width {
            lines.push(std::mem::take(&mut line));
            line_chars = 0;
        }
        if line_chars > 0 {
            line.push(' ');
            line_chars += 1;
        }
        line.push_str(&word);
        line_chars += word_chars;
    }
    if line_chars > 0 {
        lines.push(line);
    }
    lines
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::engine::state::MrState;
    use crate::report::{Known, Row};

    const URL: &str = "https://gitlab.example.com/app/-/merge_requests/12";

    fn plain(text: &str) -> String {
        let mut out = String::new();
        let mut rest = text;
        while let Some(start) = rest.find('\x1b') {
            out.push_str(&rest[..start]);
            let end = rest[start..].find('m').map_or(rest.len(), |end| start + end + 1);
            rest = &rest[end..];
        }
        out + rest
    }

    fn row(n: u64, section: RowSection, iid: Option<u64>, title: &str, what: &str, result: &str) -> BoardRow {
        BoardRow {
            n,
            section,
            iid,
            title: Some(title.to_string()),
            url: Some(URL.to_string()),
            mr_url: Some(URL.to_string()),
            what: what.to_string(),
            result: result.to_string(),
        }
    }

    fn names(names: &[&str]) -> Option<Vec<String>> {
        Some(names.iter().map(|name| name.to_string()).collect())
    }

    fn known(iid: u64, status: MrStatus) -> Status {
        Status {
            mrs: Vec::new(),
            known: BTreeMap::from([(iid, status)]),
        }
    }

    fn board(rows: Vec<BoardRow>) -> Board {
        Board {
            time: "10:00".to_string(),
            rows,
        }
    }

    #[test]
    fn status_line_parts() {
        let merged = MrState {
            state: Some("merged".to_string()),
            approved_by: names(&["bob"]),
            ..MrState::default()
        };
        let draft = MrState {
            state: Some("opened".to_string()),
            draft: Some(true),
            merge_status: Some("mergeable".to_string()),
            approved_by: names(&["bob", "carol"]),
            ..MrState::default()
        };
        let five = MrState {
            approved_by: names(&["a", "b", "c", "d", "e"]),
            ..MrState::default()
        };

        assert_eq!(status_line(&merged, true).as_deref(), Some("merged"));
        assert_eq!(
            status_line(&draft, false).as_deref(),
            Some("draft - ready to merge - approved by bob, carol")
        );
        assert_eq!(status_line(&five, false).as_deref(), Some("approved by a, b, c +2"));
        assert_eq!(
            status_line(&MrState::default(), true).as_deref(),
            Some("local conflict")
        );
        assert_eq!(status_line(&MrState::default(), false), None);
    }

    #[test]
    fn groups_by_mr_with_most_urgent_first() {
        let project = BoardRow {
            title: None,
            url: None,
            mr_url: None,
            ..row(3, RowSection::Agent, None, "", "main: job unit passed", "")
        };
        let board = board(vec![
            row(1, RowSection::Info, Some(1), "One", "a", ""),
            row(2, RowSection::NeedsYou, Some(2), "Two", "b", ""),
            project,
        ]);

        let text = plain(&board.draw(80, &Status::default()));

        let lines: Vec<&str> = text.lines().collect();
        let at = |line: &str| lines.iter().position(|found| *found == line).unwrap();
        assert!(at("!2 Two") < at("!1 One"), "{text}");
        assert!(at("!1 One") < at("Project"), "{text}");
    }

    #[test]
    fn header_has_title_status_and_url() {
        let status = known(
            42,
            MrStatus {
                title: Some("Add login retry".to_string()),
                url: None,
                line: Some("draft - approved by bob, carol".to_string()),
            },
        );
        let board = board(vec![row(1, RowSection::NeedsYou, Some(42), "Old title", "a", "")]);

        let text = board.draw(80, &status);

        let lines: Vec<String> = plain(&text).lines().map(str::to_string).collect();
        assert_eq!(
            lines[3..6],
            ["!42 Add login retry", "draft - approved by bob, carol", URL]
        );
        assert!(text.contains(&format!("{DIM}{URL}{RESET}")), "{text:?}");
    }

    #[test]
    fn row_url_shows_only_when_it_differs() {
        let comment = BoardRow {
            url: Some(format!("{URL}#note_7")),
            ..row(1, RowSection::NeedsYou, Some(12), "Add foo", "a comment", "")
        };
        let board = board(vec![
            comment,
            row(2, RowSection::NeedsYou, Some(12), "Add foo", "b", ""),
        ]);

        let text = plain(&board.draw(80, &Status::default()));

        let urls: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|line| line.starts_with("https://"))
            .collect();
        assert_eq!(urls, [URL.to_string(), format!("{URL}#note_7")], "{text}");
    }

    #[test]
    fn work_pane_draws_with_no_report_and_no_state() {
        let status = Status {
            mrs: vec![42, 43],
            ..Status::default()
        };

        let text = plain(&Board::default().draw(80, &status));

        assert_eq!(text, "No report yet.\n\n\n!42\n\n\n!43");
    }

    #[test]
    fn hub_mr_of_another_person_has_no_status_line() {
        let comment = BoardRow {
            url: Some(format!("{URL}#note_88")),
            ..row(
                1,
                RowSection::NeedsYou,
                Some(12),
                "Cache warmup",
                "@dave commented",
                "Reply",
            )
        };

        let text = plain(&board(vec![comment]).draw(80, &Status::default()));

        assert_eq!(
            text,
            [
                "10:00",
                "",
                "",
                "!12 Cache warmup",
                URL,
                "",
                "  NEEDS YOU",
                "",
                "  1  @dave commented",
                "     -> Reply",
                &format!("     {URL}#note_88"),
            ]
            .join("\n")
        );
    }

    #[test]
    fn empty_lines_between_parts() {
        let status = Status {
            mrs: vec![12, 14],
            known: BTreeMap::from([(
                14,
                MrStatus {
                    title: Some("Fix login".to_string()),
                    url: None,
                    line: Some("merged".to_string()),
                },
            )]),
        };
        let board = board(vec![
            row(1, RowSection::NeedsYou, Some(12), "Add foo", "a", "Do a"),
            row(2, RowSection::NeedsYou, Some(12), "Add foo", "b", ""),
            row(3, RowSection::Info, Some(12), "Add foo", "c", ""),
        ]);

        let text = plain(&board.draw(80, &status));

        assert_eq!(
            text,
            [
                "10:00",
                "",
                "",
                "!12 Add foo",
                URL,
                "",
                "  NEEDS YOU",
                "",
                "  1  a",
                "     -> Do a",
                "",
                "  2  b",
                "",
                "  INFO",
                "",
                "  3  c",
                "",
                "",
                "!14 Fix login",
                "merged",
            ]
            .join("\n")
        );
    }

    #[test]
    fn wraps_at_a_narrow_width() {
        let status = known(
            12,
            MrStatus {
                title: None,
                url: None,
                line: Some("draft - ready to merge - approved by bob, carol, dave +2".to_string()),
            },
        );
        let long = "word ".repeat(30);
        let board = board(vec![row(1, RowSection::NeedsYou, Some(12), &long, &long, &long)]);

        let text = plain(&board.draw(30, &status));

        let long_lines: Vec<&str> = text
            .lines()
            .filter(|line| !line.trim().starts_with("https://"))
            .filter(|line| line.chars().count() > 30)
            .collect();
        assert!(long_lines.is_empty(), "{text}");
        assert!(text.lines().count() > 10, "{text}");
    }

    #[test]
    fn takes_the_mr_url_for_a_row_with_no_url() {
        let known = BTreeMap::from([(
            12,
            Known {
                title: Some("Add foo".to_string()),
                url: Some(URL.to_string()),
            },
        )]);
        let data = ReportData {
            known,
            rows: vec![Row {
                n: 1,
                section: RowSection::Info,
                iid: Some(12),
                title: Some("Add foo".to_string()),
                url: None,
                event: None,
                what: Some("Merged".to_string()),
                result: String::new(),
                since: None,
            }],
            links: Vec::new(),
        };

        let board = Board::of("10:00", &data);

        assert_eq!(board.rows[0].url.as_deref(), Some(URL));
    }

    fn data_row(n: u64, event: Option<Event>, what: &str) -> Row {
        Row {
            n,
            section: RowSection::Info,
            iid: Some(12),
            title: Some("Add foo".to_string()),
            url: None,
            event,
            what: Some(what.to_string()),
            result: String::new(),
            since: None,
        }
    }

    fn data(known_url: &str, rows: Vec<Row>) -> ReportData {
        let known = BTreeMap::from([(
            12,
            Known {
                title: Some("Add foo".to_string()),
                url: Some(known_url.to_string()),
            },
        )]);
        ReportData {
            known,
            rows,
            links: Vec::new(),
        }
    }

    fn event(kind: EventKind, jobs: Option<Vec<String>>) -> Event {
        Event {
            jobs,
            ..Event::new(kind, Some(12), Some("Add foo"), URL, "", "", "b")
        }
    }

    #[test]
    fn drops_state_change_rows_and_keeps_numbers() {
        let rows = vec![
            data_row(1, Some(event(EventKind::Comment, None)), "a comment"),
            data_row(2, Some(event(EventKind::Approved, None)), "approved"),
            data_row(3, Some(event(EventKind::Pipeline, None)), "passed"),
            data_row(
                4,
                Some(event(EventKind::Pipeline, Some(vec!["unit".to_string()]))),
                "failed",
            ),
        ];

        let board = Board::of("10:00", &data(URL, rows));

        let numbers: Vec<u64> = board.rows.iter().map(|row| row.n).collect();
        assert_eq!(numbers, [1, 4]);
    }

    #[test]
    fn keeps_the_full_row_text() {
        let long = "x".repeat(250);

        let board = Board::of("10:00", &data(URL, vec![data_row(1, None, &long)]));

        assert_eq!(board.rows[0].what.chars().count(), 250);
    }

    #[test]
    fn sets_the_mr_url_without_anchor() {
        let board = Board::of("10:00", &data("https://x/mr/12#note_5", vec![data_row(1, None, "a")]));

        assert_eq!(board.rows[0].mr_url.as_deref(), Some("https://x/mr/12"));
    }

    #[test]
    fn old_board_file_reads_with_no_mr_url() {
        let text = r#"{"time": "10:00", "rows": [{"n": 1, "section": "Info", "iid": 12, "title": "T",
            "url": null, "what": "w", "result": ""}]}"#;

        let board: Board = serde_json::from_str(text).unwrap();

        assert_eq!(board.rows[0].mr_url, None);
    }

    #[test]
    fn breaks_a_word_that_is_longer_than_the_width() {
        assert_eq!(wrap("a 0123456789abc", 10), ["a", "0123456789", "abc"]);
    }
}

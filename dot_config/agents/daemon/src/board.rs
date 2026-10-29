//! The hub report of `watchd board`: one block for each row, wrapped to the width of the pane, with the
//! URL of the comment or of the MR as plain text.

use serde::{Deserialize, Serialize};

use crate::report::{ReportData, RowSection, short, what};

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
    pub what: String,
    pub result: String,
}

const RESET: &str = "\x1b[0m";
const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const CYAN: &str = "\x1b[36m";

/// The columns left of the row text. The row number is in them.
const INDENT: usize = 3;

impl Board {
    pub fn of(time: &str, data: &ReportData) -> Board {
        let rows = data
            .rows
            .iter()
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
                what: short(&what(row)),
                result: short(&row.result),
            })
            .collect();
        Board {
            time: time.to_string(),
            rows,
        }
    }

    /// The text with ANSI colors.
    pub fn draw(&self, columns: usize) -> String {
        let width = columns.saturating_sub(INDENT).max(10);
        let indent = " ".repeat(INDENT);
        let mut lines = vec![format!("{DIM}{}{RESET}", self.time)];
        let mut section = None;
        for row in &self.rows {
            if section != Some(row.section) {
                lines.push(String::new());
                lines.push(format!(
                    "{BOLD}{}{}{RESET}",
                    color(row.section),
                    row.section.label().to_uppercase()
                ));
                section = Some(row.section);
            }
            let mr = row.iid.map(|iid| format!("!{iid}"));
            let title = [mr.as_deref(), row.title.as_deref()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" ");
            match title.is_empty() {
                true => lines.extend(heading(row.n, &wrap(&row.what, width))),
                false => {
                    let mut title_lines = wrap(&title, width);
                    if let Some(mr) = &mr {
                        title_lines[0] = format!("{CYAN}{mr}{RESET}") + &title_lines[0][mr.len()..];
                    }
                    lines.extend(heading(row.n, &title_lines));
                    lines.extend(wrap(&row.what, width).into_iter().map(|line| format!("{indent}{line}")));
                }
            }
            for (index, line) in wrap(&row.result, width - 3).iter().enumerate() {
                let arrow = match index {
                    0 => "-> ",
                    _ => "   ",
                };
                lines.push(format!("{indent}{arrow}{line}"));
            }
            // A URL with no line break stays one URL for the terminal, also when the terminal wraps it.
            if let Some(url) = &row.url {
                lines.push(format!("{indent}{DIM}{url}{RESET}"));
            }
        }
        lines.join("\n")
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
            what: what.to_string(),
            result: result.to_string(),
        }
    }

    #[test]
    fn draws_one_heading_per_section_and_wraps_to_the_width() {
        let untitled = BoardRow {
            title: None,
            url: None,
            ..row(3, RowSection::Agent, None, "", "main: job unit passed after retry", "")
        };
        let board = Board {
            time: "10:00".to_string(),
            rows: vec![
                row(
                    1,
                    RowSection::NeedsYou,
                    Some(12),
                    "Add foo",
                    "@anna: \"Please split this\"",
                    "",
                ),
                row(
                    2,
                    RowSection::NeedsYou,
                    Some(14),
                    "Fix login",
                    "Pipeline failed: unit",
                    "Retried the job once",
                ),
                untitled,
            ],
        };

        let text = plain(&board.draw(24));

        assert_eq!(
            text,
            [
                "10:00",
                "",
                "NEEDS YOU",
                "1  !12 Add foo",
                "   @anna: \"Please split",
                "   this\"",
                &format!("   {URL}"),
                "2  !14 Fix login",
                "   Pipeline failed: unit",
                "   -> Retried the job",
                "      once",
                &format!("   {URL}"),
                "",
                "AGENT",
                "3  main: job unit passed",
                "   after retry",
            ]
            .join("\n")
        );
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

    #[test]
    fn breaks_a_word_that_is_longer_than_the_width() {
        assert_eq!(wrap("a 0123456789abc", 10), ["a", "0123456789", "abc"]);
    }
}

//! The drawing half of the TUI. Pure: it reads `App` and paints; it never
//! sends anything.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

use causewaybay_hacker_cli::render;

use super::{App, Pane};

const GOLD: Color = Color::Rgb(0xE8, 0xC4, 0x70);
const DIM: Color = Color::Rgb(0x7A, 0x82, 0x8C);
const INK: Color = Color::Rgb(0xE6, 0xE8, 0xEA);

pub fn draw(frame: &mut Frame, app: &App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(6),
            Constraint::Length(1),
        ])
        .split(frame.area());

    header(frame, app, rows[0]);

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(38), Constraint::Percentage(62)])
        .split(rows[1]);

    map_pane(frame, app, columns[0]);

    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(45), Constraint::Percentage(55)])
        .split(columns[1]);
    quest_pane(frame, app, right[0]);
    output_pane(frame, app, right[1]);

    footer(frame, app, rows[2]);

    if app.help {
        help(frame, frame.area());
    }
}

fn header(frame: &mut Frame, app: &App, area: Rect) {
    let link = if app.connected {
        Span::styled("●", Style::default().fg(Color::Green))
    } else {
        // Never a silent failure: a dropped socket is visible before the
        // player wonders why nothing responds.
        Span::styled("● reconnecting", Style::default().fg(Color::Yellow))
    };
    let line = Line::from(vec![
        Span::styled(
            " CAUSEWAYBAY HACKER ",
            Style::default().fg(GOLD).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(
                "{}/{}  ",
                app.land.to_uppercase(),
                app.category.to_uppercase()
            ),
            Style::default().fg(INK),
        ),
        Span::styled(format!("{}  ", app.user), Style::default().fg(DIM)),
        Span::styled(format!("{}  ", app.server), Style::default().fg(DIM)),
        link,
    ]);
    frame.render_widget(Paragraph::new(line), area);
}

fn map_pane(frame: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = app
        .nodes
        .iter()
        .map(|node| {
            let cleared = node.state == "cleared";
            let mark = if cleared { "✓" } else { "·" };
            let style = if cleared {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(INK)
            };
            ListItem::new(Line::from(vec![
                Span::styled(format!(" {mark} {:>2} ", node.node), style),
                Span::styled(
                    format!("{:<24}", truncate(&node.title, 24)),
                    Style::default().fg(INK),
                ),
                Span::styled(render::stars(node.stars), Style::default().fg(GOLD)),
                if node.kind == "boss" {
                    Span::styled(" BOSS", Style::default().fg(Color::Red))
                } else {
                    Span::raw("")
                },
            ]))
        })
        .collect();

    let mut state = ListState::default();
    state.select(Some(app.selected));
    let list = List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" OVERWORLD ")
                .border_style(Style::default().fg(if app.focus == Pane::Map { GOLD } else { DIM })),
        )
        .highlight_style(
            Style::default()
                .bg(Color::Rgb(0x2A, 0x30, 0x3A))
                .add_modifier(Modifier::BOLD),
        );
    frame.render_stateful_widget(list, area, &mut state);
}

fn quest_pane(frame: &mut Frame, app: &App, area: Rect) {
    let mut lines: Vec<Line> = Vec::new();
    match &app.quest {
        None => {
            lines.push(Line::from(Span::styled(
                " Enter on a node reads its brief. ? for keys.",
                Style::default().fg(DIM),
            )));
        }
        Some(quest) => {
            lines.push(Line::from(vec![
                Span::styled(
                    format!(" {} ", quest.title),
                    Style::default().fg(GOLD).add_modifier(Modifier::BOLD),
                ),
                Span::styled(quest.id.clone(), Style::default().fg(DIM)),
            ]));
            let mut facts = vec![
                format!("{}", quest.state),
                render::stars(quest.stars),
                render::difficulty(quest.difficulty),
                format!(
                    "{} visible / {} hidden",
                    quest.tests.visible.len(),
                    quest.tests.hidden_count
                ),
            ];
            if quest.hints_total > 0 {
                facts.push(format!("hints {}/{}", quest.hints_used, quest.hints_total));
            }
            lines.push(Line::from(Span::styled(
                format!(" {}", facts.join("   ")),
                Style::default().fg(DIM),
            )));
            // §4.8b: the server's clock, shown because `quest.get` started it.
            if let Some(deadline) = &quest.deadline_at {
                let left = chrono::DateTime::parse_from_rfc3339(deadline)
                    .ok()
                    .map(|d| d.with_timezone(&chrono::Utc) - chrono::Utc::now());
                let text = match left {
                    Some(left) if left.num_seconds() > 0 => format!(
                        " ⏱ {:02}:{:02} left",
                        left.num_seconds() / 60,
                        left.num_seconds() % 60
                    ),
                    _ => " ⏱ the clock ran out — still open, still judged".to_string(),
                };
                lines.push(Line::from(Span::styled(
                    text,
                    Style::default().fg(Color::Yellow),
                )));
            }
            lines.push(Line::from(""));
            for line in quest.brief.trim().lines() {
                lines.push(Line::from(Span::styled(
                    format!(" {line}"),
                    Style::default().fg(INK),
                )));
            }
        }
    }

    let paragraph = Paragraph::new(Text::from(lines))
        .wrap(Wrap { trim: false })
        .scroll((app.brief_scroll, 0))
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" QUEST ")
                .border_style(Style::default().fg(DIM)),
        );
    frame.render_widget(paragraph, area);
}

fn output_pane(frame: &mut Frame, app: &App, area: Rect) {
    let height = area.height.saturating_sub(2) as usize;
    let total = app.output.len();
    // `u16::MAX` means "stay at the bottom", which is what a live stream wants.
    let scroll = if app.out_scroll == u16::MAX {
        total.saturating_sub(height) as u16
    } else {
        app.out_scroll.min(total.saturating_sub(height) as u16)
    };

    let lines: Vec<Line> = app
        .output
        .iter()
        .map(|line| {
            let style = if line.starts_with("error") || line.contains("✗") {
                Style::default().fg(Color::Rgb(0xE0, 0x6C, 0x75))
            } else if line.contains("CLEARED") || line.contains('✓') || line.contains('✦') {
                Style::default().fg(Color::Green)
            } else if line.starts_with("warning") || line.starts_with("  (a chunk") {
                Style::default().fg(Color::Yellow)
            } else if line.starts_with("  ") && line.contains("ms  ") {
                Style::default().fg(DIM)
            } else {
                Style::default().fg(INK)
            };
            Line::from(Span::styled(line.clone(), style))
        })
        .collect();

    let title = match &app.busy {
        Some(what) => format!(" OUTPUT — {what} "),
        None => " OUTPUT ".to_string(),
    };
    let paragraph = Paragraph::new(Text::from(lines)).scroll((scroll, 0)).block(
        Block::default()
            .borders(Borders::ALL)
            .title(title)
            .border_style(Style::default().fg(if app.focus == Pane::Output { GOLD } else { DIM })),
    );
    frame.render_widget(paragraph, area);
}

fn footer(frame: &mut Frame, app: &App, area: Rect) {
    let keys = " ↑↓ move   ⏎ read   e edit   r run   s submit   f format   h hint   [ ] map   ⇥ pane   c clear   ? keys   q quit";
    let line = if app.status.is_empty() {
        Line::from(Span::styled(keys, Style::default().fg(DIM)))
    } else {
        Line::from(vec![
            Span::styled(" ", Style::default()),
            Span::styled(
                truncate(&app.status, area.width.saturating_sub(2) as usize),
                Style::default().fg(GOLD),
            ),
        ])
    };
    frame.render_widget(Paragraph::new(line), area);
}

fn help(frame: &mut Frame, area: Rect) {
    let width = 56u16.min(area.width.saturating_sub(4));
    let height = 18u16.min(area.height.saturating_sub(4));
    let box_area = Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    };
    let text = Text::from(vec![
        Line::from(""),
        Line::from("  ↑ ↓ / j k     walk the overworld, or scroll the output"),
        Line::from("  ⏎             read the quest at this node"),
        Line::from("  e             open $EDITOR on your file, and wait"),
        Line::from("  r             run — visible cases only, nothing cleared"),
        Line::from("  s             submit — every case, for the record"),
        Line::from("  f             rustfmt / gofmt / clang-format your file"),
        Line::from("  h             take a hint (this costs stars)"),
        Line::from("  [ ]           previous / next land and category"),
        Line::from("  ⇥             move focus between the map and the output"),
        Line::from("  R R           put the starter back — twice, it overwrites"),
        Line::from("  c             clear the output"),
        Line::from("  q / esc       leave"),
        Line::from(""),
        Line::from("  Every node is playable. The paths are advice."),
        Line::from("  Your source lives in ~/.causewaybayhackercli/work/."),
    ]);
    frame.render_widget(Clear, box_area);
    frame.render_widget(
        Paragraph::new(text).block(
            Block::default()
                .borders(Borders::ALL)
                .title(" KEYS ")
                .border_style(Style::default().fg(GOLD)),
        ),
        box_area,
    );
}

fn truncate(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    text.chars()
        .take(width.saturating_sub(1))
        .collect::<String>()
        + "…"
}

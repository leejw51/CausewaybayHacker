//! Interview mode (PROTOCOL §4.9e): a live coding screen, simulated.
//!
//! Everything else in this game teaches a topic. This rehearses the hour — and
//! the hour is not only typing. A live screen is: read a statement under time
//! pressure, **say what you are going to do and why before you do it**, write
//! it while somebody watches, and answer for the result. The half that is not
//! typing is the half that fails most candidates, and it is the half nothing
//! here rehearsed until now.
//!
//! Three rules hold the whole thing up:
//!
//! * **No hints and no reference answer, for the session.** Absent, not
//!   rate-limited. A screen does not come with hints, and one that did would
//!   rehearse the wrong hour.
//! * **The approach is written first and is never graded.** It is kept and
//!   handed back at the end beside what the reference does, so the player can
//!   see whether they said the thing they then wrote. Scoring it would be
//!   inventing a judgement the server cannot make.
//! * **The clock records; it does not stop you.** Running out is information.
//!   A trainer that locks you out at the buzzer teaches panic rather than
//!   finishing.

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::error::{bad_request, not_found, Result};
use crate::{attempts, ids, mistakes, progress, quests, time};

#[derive(Debug, Clone, Serialize)]
pub struct Session {
    pub id: String,
    pub quest_id: String,
    pub opened_at: String,
    pub deadline_at: Option<String>,
    pub approach: Option<String>,
    pub approach_at: Option<String>,
    pub finished_at: Option<String>,
}

/// A few sentences, not an essay. Long enough to say what you will do and what
/// it costs; short enough that writing it is a habit rather than a chore.
pub const MAX_APPROACH_CHARS: usize = 4_000;

fn row_to_session(row: &rusqlite::Row<'_>, time_limit_s: Option<i64>) -> rusqlite::Result<Session> {
    let opened_at: String = row.get(2)?;
    Ok(Session {
        deadline_at: progress::deadline(Some(&opened_at), time_limit_s),
        id: row.get(0)?,
        quest_id: row.get(1)?,
        opened_at,
        approach: row.get(3)?,
        approach_at: row.get(4)?,
        finished_at: row.get(5)?,
    })
}

const COLUMNS: &str = "id, quest_id, opened_at, approach, approach_at, finished_at";

pub fn get(conn: &Connection, address: &str, session_id: &str) -> Result<Session> {
    let quest_id: Option<String> = conn
        .query_row(
            "SELECT quest_id FROM interviews WHERE id = ?1 AND address = ?2",
            params![session_id, address],
            |r| r.get(0),
        )
        .optional()?;
    let quest_id = quest_id.ok_or_else(|| not_found("no such interview"))?;
    let limit = quests::get(conn, &quest_id)?.time_limit_s;
    conn.query_row(
        &format!("SELECT {COLUMNS} FROM interviews WHERE id = ?1 AND address = ?2"),
        params![session_id, address],
        |r| row_to_session(r, limit),
    )
    .optional()?
    .ok_or_else(|| not_found("no such interview"))
}

/// The player's live session, if they have one. Used by `quest.get` and
/// `quest.hint` to know what to withhold.
pub fn live(conn: &Connection, address: &str) -> Result<Option<Session>> {
    let id: Option<String> = conn
        .query_row(
            "SELECT id FROM interviews WHERE address = ?1 AND finished_at IS NULL
              ORDER BY created_at DESC LIMIT 1",
            params![address],
            |r| r.get(0),
        )
        .optional()?;
    match id {
        Some(id) => Ok(Some(get(conn, address, &id)?)),
        None => Ok(None),
    }
}

/// Start one. One live session per player: starting another finishes the
/// first, because walking out of an interview is a thing that happened and
/// should be reported rather than erased.
pub fn start(
    conn: &Connection,
    address: &str,
    land: &str,
    category: Option<&str>,
) -> Result<Session> {
    if !matches!(land, "rust" | "go") {
        return Err(bad_request(format!("unknown land '{land}'")));
    }
    if let Some(open) = live(conn, address)? {
        finish(conn, address, &open.id)?;
    }
    let quest_id = pick(conn, address, land, category)?;
    let now = time::now_stamp();
    let id = ids::interview_id();
    conn.execute(
        "INSERT INTO interviews (id, address, quest_id, opened_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?4)",
        params![id, address, quest_id, now],
    )?;
    // The quest's own clock starts too, so a submit carries `within_limit`
    // exactly as it would outside an interview (§4.8b).
    progress::open_clock(conn, address, &quest_id)?;
    get(conn, address, &id)
}

/// A quest the player has **not cleared**, in the land they asked for.
///
/// Timed quests first: a `hacker` quest carries `time_limit_s`, and a screen
/// with a clock on it is the thing being rehearsed. Randomised among equals so
/// the same interview does not come round twice in an afternoon.
fn pick(conn: &Connection, address: &str, land: &str, category: Option<&str>) -> Result<String> {
    let mut stmt = conn.prepare(
        "SELECT q.id FROM quests q
           LEFT JOIN progress p ON p.quest_id = q.id AND p.address = ?1
          WHERE q.land = ?2 AND (?3 IS NULL OR q.category = ?3)
            AND (p.state IS NULL OR p.state <> 'cleared')
          ORDER BY (q.time_limit_s IS NULL), q.category, q.node",
    )?;
    let candidates: Vec<String> = stmt
        .query_map(params![address, land, category], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if candidates.is_empty() {
        return Err(not_found(match category {
            Some(category) => format!("you have cleared every {land} {category} quest"),
            None => format!("you have cleared every {land} quest"),
        }));
    }
    // Only shuffle within the first tier — the timed ones, if there are any.
    let timed: Vec<&String> = candidates
        .iter()
        .filter(|id| {
            quests::get(conn, id)
                .map(|q| q.time_limit_s.is_some())
                .unwrap_or(false)
        })
        .collect();
    let pool: Vec<&String> = if timed.is_empty() {
        candidates.iter().collect()
    } else {
        timed
    };
    let mut seed = [0u8; 8];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut seed);
    let index = (u64::from_le_bytes(seed) % pool.len() as u64) as usize;
    Ok(pool[index].clone())
}

/// The approach, written before the editor unlocks. Kept verbatim, **never
/// graded**, and returned at the end beside what the reference does.
pub fn set_approach(
    conn: &Connection,
    address: &str,
    session_id: &str,
    text: &str,
) -> Result<Session> {
    let session = get(conn, address, session_id)?;
    if session.finished_at.is_some() {
        return Err(bad_request("that interview is over"));
    }
    let text = text.trim();
    if text.is_empty() {
        return Err(bad_request(
            "say what you are going to do and what it costs — that is the exercise",
        ));
    }
    let text: String = text.chars().take(MAX_APPROACH_CHARS).collect();
    // The first one stamps the clock that unlocks the editor; a later edit
    // refines the words without pretending it was written then.
    conn.execute(
        "UPDATE interviews SET approach = ?3, approach_at = COALESCE(approach_at, ?4)
          WHERE id = ?1 AND address = ?2",
        params![session_id, address, text, time::now_stamp()],
    )?;
    get(conn, address, session_id)
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub session_id: String,
    pub quest_id: String,
    pub cleared: bool,
    pub within_limit: Option<bool>,
    pub took_ms: i64,
    pub limit_ms: Option<i64>,
    pub approach: Option<String>,
    /// What the reference answer does. **Derived, never generated**: the
    /// solution's own leading comment if the author wrote one, plus its size
    /// and the ideas the quest is filed under. The server does not have an
    /// opinion about code and should not pretend to.
    pub reference_summary: String,
    pub attempts: Vec<attempts::AttemptBrief>,
    pub mistakes: Vec<ReportedMistake>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReportedMistake {
    pub kind: String,
    pub label: String,
    pub count: i64,
}

/// The only way to end a session, and the product of the whole feature: time
/// against the limit, the sentence they wrote, what the reference does, what
/// they actually submitted, and what went wrong on the way.
pub fn finish(conn: &Connection, address: &str, session_id: &str) -> Result<Report> {
    let session = get(conn, address, session_id)?;
    let now = time::now_stamp();
    if session.finished_at.is_none() {
        conn.execute(
            "UPDATE interviews SET finished_at = ?3 WHERE id = ?1 AND address = ?2",
            params![session_id, address, now],
        )?;
    }
    let ended = session.finished_at.clone().unwrap_or(now);
    let quest = quests::get(conn, &session.quest_id)?;

    let took_ms = match (time::parse(&session.opened_at), time::parse(&ended)) {
        (Some(start), Some(end)) => (end - start).num_milliseconds().max(0),
        _ => 0,
    };

    // Only what happened during the session, on the quest it was about.
    let mut stmt = conn.prepare(
        "SELECT id, quest_id, verdict, tests_passed, tests_total, created_at, mode
           FROM attempts
          WHERE address = ?1 AND quest_id = ?2 AND created_at >= ?3 AND created_at <= ?4
          ORDER BY created_at DESC, rowid DESC",
    )?;
    let mut during: Vec<attempts::AttemptBrief> = stmt
        .query_map(
            params![address, session.quest_id, session.opened_at, ended],
            |r| {
                Ok(attempts::AttemptBrief {
                    id: r.get(0)?,
                    quest_id: r.get(1)?,
                    verdict: r.get(2)?,
                    tests_passed: r.get(3)?,
                    tests_total: r.get(4)?,
                    created_at: r.get(5)?,
                    mode: r.get(6)?,
                    kinds: Vec::new(),
                })
            },
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    for brief in &mut during {
        let mut stmt =
            conn.prepare("SELECT DISTINCT kind FROM mistakes WHERE attempt_id = ?1 ORDER BY kind")?;
        brief.kinds = stmt
            .query_map(params![brief.id], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
    }

    let cleared = during
        .iter()
        .any(|a| a.verdict == "accepted" && a.mode == "submit");
    let within_limit: Option<bool> = conn
        .query_row(
            "SELECT within_limit FROM attempts
              WHERE address = ?1 AND quest_id = ?2 AND mode = 'submit'
                AND verdict = 'accepted' AND created_at >= ?3 AND created_at <= ?4
              ORDER BY created_at DESC LIMIT 1",
            params![address, session.quest_id, session.opened_at, ended],
            |r| r.get(0),
        )
        .optional()?
        .flatten();

    let mut stmt = conn.prepare(
        "SELECT m.kind, count(*) FROM mistakes m
          WHERE m.address = ?1 AND m.quest_id = ?2
            AND m.created_at >= ?3 AND m.created_at <= ?4
          GROUP BY m.kind ORDER BY count(*) DESC, m.kind",
    )?;
    let made: Vec<ReportedMistake> = stmt
        .query_map(
            params![address, session.quest_id, session.opened_at, ended],
            |r| {
                let kind: String = r.get(0)?;
                Ok(ReportedMistake {
                    label: mistakes::label(&kind).to_string(),
                    kind,
                    count: r.get(1)?,
                })
            },
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);

    Ok(Report {
        session_id: session.id,
        quest_id: session.quest_id,
        cleared,
        within_limit,
        took_ms,
        limit_ms: quest.time_limit_s.map(|s| s * 1000),
        approach: session.approach,
        reference_summary: reference_summary(&quest),
        attempts: during,
        mistakes: made,
    })
}

/// Derived from the reference answer, never written about it.
///
/// If the content author put a leading comment on the solution, that is the
/// best description of the approach that exists and it is theirs. Otherwise
/// the honest thing to say is how big it is and what it is about — which is
/// still enough for a player to hold their own sentence up against.
fn reference_summary(quest: &quests::Quest) -> String {
    let leading: Vec<&str> = quest
        .solution
        .lines()
        .map(str::trim)
        .skip_while(|l| l.is_empty())
        .take_while(|l| l.starts_with("//"))
        .map(|l| l.trim_start_matches('/').trim())
        .filter(|l| !l.is_empty())
        .collect();
    let lines = quest
        .solution
        .lines()
        .filter(|l| !l.trim().is_empty())
        .count();
    let concepts = if quest.concepts.is_empty() {
        String::new()
    } else {
        format!(" and turns on {}", quest.concepts.join(", "))
    };
    let shape = format!("The reference answer is {lines} lines{concepts}.");
    if leading.is_empty() {
        shape
    } else {
        format!("{} {shape}", leading.join(" "))
    }
}

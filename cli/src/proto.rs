//! The envelope and the shared shapes — PROTOCOL §2 and §5.
//!
//! Nothing here talks to a socket; it is the contract expressed in Rust types,
//! so a command reads `attempt.verdict` rather than
//! `value["attempt"]["verdict"]` and a typo becomes a compile error.

use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;

/// §2: *"Every frame in both directions is an object with exactly these four
/// keys."*
///
/// `id` is `Option<String>` and deliberately **not** `skip_serializing_if`:
/// a server-initiated event carries `id: null`, and §2 answers a frame with a
/// missing key the same way it answers one with an extra key. Four keys, every
/// time, in both directions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Frame {
    pub v: u32,
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    pub payload: serde_json::Value,
}

impl Frame {
    pub fn request(
        id: impl Into<String>,
        kind: impl Into<String>,
        payload: serde_json::Value,
    ) -> Frame {
        Frame {
            v: VERSION,
            id: Some(id.into()),
            kind: kind.into(),
            // §2: payload is *always an object*, never a bare value, never
            // absent. A caller that passes `Value::Null` gets `{}`.
            payload: if payload.is_object() {
                payload
            } else {
                serde_json::json!({})
            },
        }
    }

    /// The request type a reply belongs to: `quest.submit.ok` -> `quest.submit`.
    pub fn base_type(&self) -> &str {
        self.kind
            .strip_suffix(".ok")
            .or_else(|| self.kind.strip_suffix(".err"))
            .unwrap_or(&self.kind)
    }

    pub fn is_ok(&self) -> bool {
        self.kind.ends_with(".ok")
    }
    pub fn is_err(&self) -> bool {
        self.kind.ends_with(".err")
    }
    /// §2.3: a server-initiated event has no suffix and `id: null`.
    pub fn is_event(&self) -> bool {
        self.id.is_none()
    }
}

/// §3.3's error payload: always exactly these three keys.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireError {
    pub code: String,
    pub message: String,
    #[serde(default = "empty_object")]
    pub detail: serde_json::Value,
}

fn empty_object() -> serde_json::Value {
    serde_json::json!({})
}

// ---------------------------------------------------------------- §5 shapes

#[derive(Debug, Clone, Deserialize)]
pub struct User {
    pub address: String,
    pub name: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub last_seen_at: String,
    #[serde(default)]
    pub level: i64,
    #[serde(default)]
    pub xp: i64,
    #[serde(default = "empty_object")]
    pub settings: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthOk {
    pub token: String,
    pub user: User,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Challenge {
    pub nonce: String,
    /// §4.2: sign this byte-for-byte. Never rebuild it from the parts.
    pub message: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CategoryProgress {
    pub category: String,
    pub total: i64,
    pub cleared: i64,
    pub stars: i64,
    #[serde(default)]
    pub open: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Land {
    pub land: String,
    pub categories: Vec<CategoryProgress>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Lands {
    pub lands: Vec<Land>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MapNode {
    pub quest_id: String,
    pub node: i64,
    pub title: String,
    pub difficulty: i64,
    /// §4.7: `"open" | "cleared"` — never `"locked"`.
    pub state: String,
    pub stars: i64,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub attempts: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorldMap {
    pub land: String,
    pub category: String,
    pub nodes: Vec<MapNode>,
    #[serde(default)]
    pub edges: Vec<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TestCase {
    pub name: String,
    #[serde(default)]
    pub stdin: String,
    #[serde(default)]
    pub expect: String,
}

/// §4.8: there is **no `tests.cases`** on the wire. `visible` carries the
/// cases the player may see; `hidden_count` is a count and nothing else.
#[derive(Debug, Clone, Deserialize)]
pub struct Tests {
    #[serde(default)]
    pub r#match: String,
    #[serde(default)]
    pub timeout_ms: i64,
    #[serde(default)]
    pub visible: Vec<TestCase>,
    #[serde(default)]
    pub hidden_count: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Quest {
    pub id: String,
    pub land: String,
    pub category: String,
    pub node: i64,
    pub title: String,
    #[serde(default)]
    pub brief: String,
    #[serde(default)]
    pub story: String,
    pub difficulty: i64,
    /// §4.8b — the player's clock. `null` when untimed.
    #[serde(default)]
    pub time_limit_s: Option<i64>,
    #[serde(default)]
    pub opened_at: Option<String>,
    #[serde(default)]
    pub deadline_at: Option<String>,
    pub starter: String,
    #[serde(default)]
    pub concepts: Vec<String>,
    #[serde(default)]
    pub hints_total: i64,
    #[serde(default)]
    pub hints_used: i64,
    pub state: String,
    pub stars: i64,
    pub tests: Tests,
    /// §4.8: omitted entirely unless the player has cleared it.
    #[serde(default)]
    pub solution: Option<String>,
}

impl Quest {
    /// The `lang` a submit must carry. §4.9: it *must match the quest's land*,
    /// and a disagreement is `bad_request` — so it is derived from the quest,
    /// never from a file extension or a flag.
    pub fn lang(&self) -> &str {
        &self.land
    }

    pub fn file_extension(&self) -> &str {
        match self.land.as_str() {
            "go" => "go",
            _ => "rs",
        }
    }
}

/// `quest.get`'s payload is `{ "quest": Quest }` — the quest is inside a named
/// key, not the payload itself.
#[derive(Debug, Clone, Deserialize)]
pub struct QuestReply {
    pub quest: Quest,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CaseResult {
    pub name: String,
    pub passed: bool,
    #[serde(default)]
    pub visible: bool,
    #[serde(default)]
    pub stdin: Option<String>,
    #[serde(default)]
    pub expect: Option<String>,
    #[serde(default)]
    pub got: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Mistake {
    pub kind: String,
    #[serde(default)]
    pub code: Option<String>,
    pub message: String,
    #[serde(default)]
    pub line: Option<i64>,
    #[serde(default)]
    pub col: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Attempt {
    pub id: String,
    pub quest_id: String,
    /// §4.9b: `"run"` never clears a node.
    pub mode: String,
    pub verdict: String,
    pub tests_passed: i64,
    pub tests_total: i64,
    #[serde(default)]
    pub compile_ms: i64,
    #[serde(default)]
    pub run_ms: i64,
    #[serde(default)]
    pub exit_code: Option<i64>,
    #[serde(default)]
    pub stderr: String,
    #[serde(default)]
    pub cases: Vec<CaseResult>,
    /// §4.8b: `null` when untimed.
    #[serde(default)]
    pub within_limit: Option<bool>,
    #[serde(default)]
    pub mistakes: Vec<Mistake>,
    pub stars: i64,
    /// §5.4: "did *this* submission just clear the node", not "is it cleared".
    pub cleared: bool,
    #[serde(default)]
    pub created_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AttemptReply {
    pub attempt: Attempt,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FormatReply {
    pub source: String,
    pub changed: bool,
    /// §4.9d: present when the source did not parse. The reply is still `.ok`
    /// and `source` comes back untouched.
    #[serde(default)]
    pub problem: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Hint {
    pub hint: String,
    pub index: i64,
    pub total: i64,
    pub hints_used: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Reset {
    pub starter: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LandStat {
    pub land: String,
    pub cleared: i64,
    pub total: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Summary {
    pub cleared: i64,
    pub total: i64,
    pub attempts: i64,
    pub accuracy: f64,
    #[serde(default)]
    pub streak_days: i64,
    #[serde(default)]
    pub stars: i64,
    #[serde(default)]
    pub by_land: Vec<LandStat>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MistakeStat {
    pub kind: String,
    pub label: String,
    pub count: i64,
    #[serde(default)]
    pub last_at: String,
    #[serde(default)]
    pub cleared_since: i64,
    #[serde(default)]
    pub example_quest_id: Option<String>,
    #[serde(default)]
    pub concepts: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Mistakes {
    pub mistakes: Vec<MistakeStat>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Award {
    pub kind: String,
    pub id: String,
    pub title: String,
    #[serde(default = "empty_object")]
    pub detail: serde_json::Value,
    #[serde(default)]
    pub created_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Awards {
    pub awards: Vec<Award>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AttemptBrief {
    pub id: String,
    pub quest_id: String,
    pub verdict: String,
    pub tests_passed: i64,
    pub tests_total: i64,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub kinds: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct History {
    pub attempts: Vec<AttemptBrief>,
}

/// §4.17. `stage` ∈ queued | compiling | running | judging, strictly ordered,
/// each sent once.
#[derive(Debug, Clone, Deserialize)]
pub struct RunStage {
    pub attempt_id: String,
    pub stage: String,
    #[serde(default)]
    pub queued: i64,
    #[serde(default)]
    pub elapsed_ms: i64,
}

/// §4.18. `seq` counts from 0 **per stream** per attempt, and chunks may split
/// anywhere — including mid-line.
#[derive(Debug, Clone, Deserialize)]
pub struct RunLog {
    pub attempt_id: String,
    pub stream: String,
    pub chunk: String,
    pub seq: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProgressUpdate {
    pub quest_id: String,
    pub state: String,
    #[serde(default)]
    pub stars: i64,
    #[serde(default)]
    pub cleared_total: i64,
    #[serde(default)]
    pub unlocked: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Bye {
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlaygroundRun {
    pub attempt_id: String,
    pub lang: String,
    pub outcome: String,
    #[serde(default)]
    pub compile_ms: i64,
    #[serde(default)]
    pub run_ms: i64,
    #[serde(default)]
    pub exit_code: Option<i64>,
    #[serde(default)]
    pub stdout: String,
    #[serde(default)]
    pub stderr: String,
    #[serde(default)]
    pub diagnostics: Vec<Mistake>,
}

/// §5.9. `playground.save` returns one of these; `playground.list` returns
/// `SnippetBrief`, which is the same minus `source` plus `bytes`.
#[derive(Debug, Clone, Deserialize)]
pub struct Snippet {
    pub id: String,
    pub name: String,
    pub lang: String,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SnippetBrief {
    pub id: String,
    pub name: String,
    pub lang: String,
    #[serde(default)]
    pub bytes: i64,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SnippetReply {
    pub snippet: Snippet,
}

/// `playground.list`. **Not in PROTOCOL.md** — §4.9c documents `run` and
/// `save` only, and `list`, `load` and `delete` shipped without being written
/// down. The shape here was established by probing the live server, and agrees
/// with what the LÖVE client recorded in `docs/decisions.md`.
#[derive(Debug, Clone, Deserialize)]
pub struct SnippetList {
    pub snippets: Vec<SnippetBrief>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlaygroundReply {
    pub run: PlaygroundRun,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// §8.1: exactly `v`, `id`, `type`, `payload`, with `payload` an object.
    #[test]
    fn a_request_frame_has_exactly_four_keys() {
        let frame = Frame::request("c-1", "ping", serde_json::json!({}));
        let value = serde_json::to_value(&frame).unwrap();
        let object = value.as_object().unwrap();
        assert_eq!(object.len(), 4);
        for key in ["v", "id", "type", "payload"] {
            assert!(object.contains_key(key), "missing {key}");
        }
        assert_eq!(object["v"], 1);
        assert!(object["payload"].is_object());
    }

    /// A `None` id still serialises as the key `id` with the value `null`,
    /// which is what §2 requires of a four-key envelope.
    #[test]
    fn a_null_id_is_a_present_key() {
        let frame = Frame {
            v: 1,
            id: None,
            kind: "run.log".into(),
            payload: serde_json::json!({}),
        };
        let text = serde_json::to_string(&frame).unwrap();
        assert!(text.contains("\"id\":null"), "{text}");
    }

    #[test]
    fn a_non_object_payload_becomes_an_empty_object() {
        let frame = Frame::request("c-1", "ping", serde_json::Value::Null);
        assert_eq!(frame.payload, serde_json::json!({}));
    }

    #[test]
    fn reply_suffixes_are_stripped_to_the_request_type() {
        let ok = Frame {
            v: 1,
            id: Some("c-1".into()),
            kind: "quest.submit.ok".into(),
            payload: serde_json::json!({}),
        };
        assert_eq!(ok.base_type(), "quest.submit");
        assert!(ok.is_ok() && !ok.is_err() && !ok.is_event());

        let event = Frame {
            v: 1,
            id: None,
            kind: "run.stage".into(),
            payload: serde_json::json!({}),
        };
        assert_eq!(event.base_type(), "run.stage");
        assert!(event.is_event());
    }

    /// §4.8: a `Quest` with no `solution` key deserialises, and the absence is
    /// `None` rather than an error.
    #[test]
    fn a_quest_without_a_solution_parses() {
        let quest: Quest = serde_json::from_value(serde_json::json!({
            "id": "rust.basic.01.hello", "land": "rust", "category": "basic",
            "node": 1, "title": "FIRST LIGHT", "difficulty": 1,
            "time_limit_s": null, "opened_at": null, "deadline_at": null,
            "starter": "fn main() {}", "state": "open", "stars": 0,
            "tests": { "match": "trim", "timeout_ms": 5000, "visible": [], "hidden_count": 2 }
        }))
        .unwrap();
        assert!(quest.solution.is_none());
        assert_eq!(quest.lang(), "rust");
        assert_eq!(quest.file_extension(), "rs");
        assert_eq!(quest.tests.hidden_count, 2);
    }
}

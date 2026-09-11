//! The test spec of SPEC §5.2, as it arrives from `quests.tests`.

use serde::{Deserialize, Serialize};

use cwbhacker_core::error::{bad_request, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Harness {
    Stdio,
    Cargo,
    Gotest,
}

impl Harness {
    /// The spelling the content pack uses, which is also the one a message to
    /// a player should use. `Debug` would say `Cargo`, and `harness = "Cargo"`
    /// is not a thing anybody can type into a TOML file.
    pub fn as_str(self) -> &'static str {
        match self {
            Harness::Stdio => "stdio",
            Harness::Cargo => "cargo",
            Harness::Gotest => "gotest",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MatchMode {
    Exact,
    /// The default. Trailing whitespace per line and at the end is stripped,
    /// because "your answer is right but has a trailing newline" is not a
    /// lesson worth teaching.
    Trim,
    Tokens,
    Float(f64),
}

impl MatchMode {
    pub fn parse(s: &str) -> Result<MatchMode> {
        if let Some(eps) = s.strip_prefix("float:") {
            let eps: f64 = eps
                .parse()
                .map_err(|_| bad_request(format!("'{s}' is not a float tolerance")))?;
            return Ok(MatchMode::Float(eps));
        }
        Ok(match s {
            "exact" => MatchMode::Exact,
            "trim" | "" => MatchMode::Trim,
            "tokens" => MatchMode::Tokens,
            other => return Err(bad_request(format!("unknown match mode '{other}'"))),
        })
    }

    pub fn matches(self, got: &str, expect: &str) -> bool {
        match self {
            MatchMode::Exact => got == expect,
            MatchMode::Trim => trim_block(got) == trim_block(expect),
            MatchMode::Tokens => tokens(got) == tokens(expect),
            MatchMode::Float(eps) => {
                let a = tokens(got);
                let b = tokens(expect);
                if a.len() != b.len() {
                    return false;
                }
                a.iter()
                    .zip(b.iter())
                    .all(|(x, y)| match (x.parse::<f64>(), y.parse::<f64>()) {
                        (Ok(x), Ok(y)) => (x - y).abs() <= eps,
                        _ => x == y,
                    })
            }
        }
    }
}

fn trim_block(text: &str) -> String {
    let trimmed: Vec<&str> = text.lines().map(|l| l.trim_end()).collect();
    trimmed.join("\n").trim_end().to_string()
}

fn tokens(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

#[derive(Debug, Clone)]
pub struct Case {
    pub name: String,
    pub stdin: String,
    pub expect: String,
    pub visible: bool,
}

#[derive(Debug, Clone)]
pub struct TestSpec {
    pub harness: Harness,
    pub timeout_ms: u64,
    pub compile_timeout_ms: u64,
    pub max_stdout_bytes: usize,
    pub cases: Vec<Case>,
    pub match_mode: MatchMode,
    /// The quest's **own** tests, for the `cargo` and `gotest` harnesses
    /// (SPEC §5.2). Present means "implement this; we grade it with the tests
    /// below"; absent means "you write the tests too".
    ///
    /// It is the difference between the two quest shapes these harnesses can
    /// teach, and it is also the only way a quest can break in a way that is
    /// not the player's fault — which is why the runner tracks whose file a
    /// diagnostic came from.
    pub test_source: Option<String>,
    /// Set by [`TestSpec::visible_only`]: this is a RUN, so the only tests
    /// that may execute are the ones the pack declared (PROTOCOL §4.9b).
    ///
    /// It matters only when the quest ships its own tests. For stdio the
    /// hidden *cases* are simply not handed to the runner, and for a quest
    /// whose tests the player wrote there is nothing hidden to protect. But a
    /// quest-supplied test file is one file: filtering its cases out of the
    /// spec would not stop `cargo test` or `go test` from running every test
    /// in it and streaming the result, and "a run cannot tell you whether the
    /// hidden cases pass" would be false.
    pub only_declared: bool,
    /// `gotest` only: build the test binary with `-race` (SPEC §5.1).
    ///
    /// Off by default and deliberately hard to reach. The detector only sees
    /// a race that actually raced on that run, so a quest that turns it on is
    /// making a promise about the schedule that the schedule does not make
    /// back. See `docs/decisions.md`.
    pub race: bool,
}

impl TestSpec {
    /// A one-case spec for the playground (PROTOCOL §4.9c): run the program
    /// once on this stdin under SPEC §5.3's limits, unchanged.
    ///
    /// The harness will compare the output to the empty string and decide
    /// `accepted` or `wrong_answer`; the playground **discards that**, because
    /// there is nothing to be right or wrong about. What it wants from the
    /// harness is the running — the timeout, the output cap, the stripped
    /// environment, the process group — and this is the cheapest way to get
    /// all of it without a second copy of the case loop.
    pub fn playground(stdin: &str, timeout_ms: u64, compile_timeout_ms: u64) -> TestSpec {
        TestSpec {
            harness: Harness::Stdio,
            timeout_ms,
            compile_timeout_ms,
            max_stdout_bytes: 262_144,
            cases: vec![Case {
                name: "playground".to_string(),
                stdin: stdin.to_string(),
                expect: String::new(),
                visible: true,
            }],
            match_mode: MatchMode::Trim,
            test_source: None,
            only_declared: false,
            race: false,
        }
    }

    /// The same spec with only the visible cases (PROTOCOL §4.9b).
    ///
    /// A run must not tell the player whether the hidden cases pass — that is
    /// what submitting is for — and the cleanest way to guarantee it is that
    /// the hidden cases are never handed to the runner at all. Nothing to
    /// leak, and nothing to accidentally report.
    pub fn visible_only(&self) -> TestSpec {
        TestSpec {
            cases: self.cases.iter().filter(|c| c.visible).cloned().collect(),
            only_declared: true,
            ..self.clone()
        }
    }

    pub fn parse(value: &serde_json::Value) -> Result<TestSpec> {
        let harness = match value
            .get("harness")
            .and_then(|v| v.as_str())
            .unwrap_or("stdio")
        {
            "stdio" => Harness::Stdio,
            "cargo" => Harness::Cargo,
            "gotest" => Harness::Gotest,
            other => return Err(bad_request(format!("unknown harness '{other}'"))),
        };
        let race = value.get("race").and_then(|v| v.as_bool()).unwrap_or(false);
        if race && harness != Harness::Gotest {
            // A quest that asks for `-race` under a harness that cannot give
            // it would be judged as if it had, which is worse than refusing.
            return Err(bad_request(format!(
                "race = true is a gotest option; this quest is '{}'",
                harness.as_str()
            )));
        }
        if value.get("test_source").is_some() && harness == Harness::Stdio {
            return Err(bad_request(
                "test_source belongs to the cargo and gotest harnesses; \
                 a stdio quest has no test file",
            ));
        }
        let cases = value
            .get("cases")
            .and_then(|v| v.as_array())
            .ok_or_else(|| bad_request("tests.cases must be an array"))?
            .iter()
            .map(|case| Case {
                name: case
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("case")
                    .to_string(),
                stdin: case
                    .get("stdin")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                expect: case
                    .get("expect")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                visible: case
                    .get("visible")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false),
            })
            .collect();
        Ok(TestSpec {
            harness,
            timeout_ms: value
                .get("timeout_ms")
                .and_then(|v| v.as_u64())
                .unwrap_or(5_000),
            compile_timeout_ms: value
                .get("compile_timeout_ms")
                .and_then(|v| v.as_u64())
                // SPEC §5.2's default is 30 s, which is the right number for
                // one `rustc` or one `go build`. A test harness builds more:
                // measured cold on this machine (empty caches, no
                // dependencies) `cargo test --no-run` takes 0.15 s but
                // `go test -c` takes 2.8 s — it compiles `testing`, `fmt` and
                // `runtime` before it sees the quest — and 4.3 s with
                // `-race`. Warm, both are ~0.15 s. Thirty seconds holds on
                // this machine and would not hold on a cold cache on a slower
                // one, and the failure mode is a `timeout` verdict on a
                // correct answer, which is the worst verdict this game can
                // hand anybody. Sixty is not a promise that the compile is
                // slow; it is the budget before the runner calls a *compiler*
                // hung.
                .unwrap_or(match harness {
                    Harness::Stdio => 30_000,
                    Harness::Cargo | Harness::Gotest => 60_000,
                }),
            max_stdout_bytes: value
                .get("max_stdout_bytes")
                .and_then(|v| v.as_u64())
                .unwrap_or(262_144) as usize,
            cases,
            match_mode: MatchMode::parse(
                value
                    .get("match")
                    .and_then(|v| v.as_str())
                    .unwrap_or("trim"),
            )?,
            only_declared: false,
            test_source: value
                .get("test_source")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_string),
            race,
        })
    }
}

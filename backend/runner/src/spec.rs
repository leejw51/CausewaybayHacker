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
}

impl TestSpec {
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
                .unwrap_or(30_000),
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
        })
    }
}

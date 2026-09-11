//! One timestamp format, everywhere: RFC3339 UTC with seconds (SPEC §2.2).

use chrono::{DateTime, SecondsFormat, Utc};

pub fn now() -> DateTime<Utc> {
    Utc::now()
}

pub fn stamp(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn now_stamp() -> String {
    stamp(now())
}

pub fn parse(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|t| t.with_timezone(&Utc))
}

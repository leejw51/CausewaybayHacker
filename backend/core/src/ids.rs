//! Identifiers (SPEC §4.2): a prefix and 16 lowercase hex from a CSPRNG.

use rand::RngCore;

fn suffix() -> String {
    let mut bytes = [0u8; 8];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

pub fn attempt_id() -> String {
    format!("att_{}", suffix())
}

pub fn drill_id() -> String {
    format!("drl_{}", suffix())
}

pub fn pack_id() -> String {
    format!("pack_{}", suffix())
}

/// A simulated live coding screen (PROTOCOL §5.11).
pub fn interview_id() -> String {
    format!("int_{}", suffix())
}

/// A playground scratchpad (PROTOCOL §5.9).
pub fn snippet_id() -> String {
    format!("pg_{}", suffix())
}

/// The capability that fetches a photo over HTTP (PROTOCOL §4.9f): 32 hex,
/// twice an id's entropy, because it is the *only* thing guarding the bytes.
/// There is no other HTTP auth in this server, so the token has to be
/// unguessable on its own rather than merely unique.
pub fn photo_token() -> String {
    let mut bytes = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

/// A quest id is `<land>.<category>.<node:02d>.<slug>` (SPEC §4.1). The
/// importer refuses a pack whose ids disagree with its own land/category, so
/// the check lives here rather than in a comment.
pub fn parse_quest_id(id: &str) -> Option<(&str, &str, u32, &str)> {
    let mut parts = id.splitn(4, '.');
    let land = parts.next()?;
    let category = parts.next()?;
    let node_text = parts.next()?;
    let slug = parts.next()?;
    if node_text.len() != 2 || !node_text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if slug.is_empty()
        || !slug
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return None;
    }
    Some((land, category, node_text.parse().ok()?, slug))
}

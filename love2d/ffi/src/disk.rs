//! The poster's non-key arithmetic: the QR label, the PNG's text chunks, the
//! reader's decode, and recovering a signer.
//!
//! `love2d/src/poster.lua` draws the picture and `love2d/src/diskreader.lua`
//! takes one back; what they cannot do in Lua is here. Every function is
//! pure over bytes or a path, touches no key material, and is exercised by
//! the crate's tests against the same fixtures the Lua suite uses.

use image::GenericImageView;
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use qrcode::{EcLevel, QrCode};
use std::collections::BTreeMap;
use std::io::Read;

use crate::evm;

/// The QR for `text`, byte mode, error-correction M, smallest version that
/// holds it: one string of `0`/`1` per row.
pub fn qr_rows(text: &str) -> Result<Vec<String>, String> {
    let code = QrCode::with_error_correction_level(text.as_bytes(), EcLevel::M)
        .map_err(|e| format!("no QR holds that: {e}"))?;
    let n = code.width();
    let colors = code.to_colors();
    Ok((0..n)
        .map(|r| {
            (0..n)
                .map(|c| {
                    if colors[r * n + c] == qrcode::Color::Dark {
                        '1'
                    } else {
                        '0'
                    }
                })
                .collect()
        })
        .collect())
}

// ------------------------------------------------------------------ PNG text

const PNG_SIG: [u8; 8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// One `iTXt` chunk: UTF-8 text, uncompressed, no language tag.
fn itxt_chunk(keyword: &str, text: &str) -> Vec<u8> {
    let key: Vec<u8> = keyword.bytes().take(79).collect();
    let mut data = Vec::with_capacity(key.len() + 5 + text.len());
    data.extend_from_slice(&key);
    // keyword \0, compression flag 0, method 0, language tag \0, translated \0
    data.extend_from_slice(&[0, 0, 0, 0, 0]);
    data.extend_from_slice(text.as_bytes());
    let mut out = Vec::with_capacity(data.len() + 12);
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(b"iTXt");
    out.extend_from_slice(&data);
    let mut h = crc32fast::Hasher::new();
    h.update(b"iTXt");
    h.update(&data);
    out.extend_from_slice(&h.finalize().to_be_bytes());
    out
}

/// `png` with the entries added as `iTXt` chunks before `IEND`.
pub fn with_png_text(png: &[u8], entries: &BTreeMap<String, String>) -> Result<Vec<u8>, String> {
    if png.len() < 8 || png[..8] != PNG_SIG {
        return Err("not a PNG".to_string());
    }
    let iend = iend_offset(png).ok_or_else(|| "PNG has no IEND".to_string())?;
    let mut out = Vec::with_capacity(png.len() + 256);
    out.extend_from_slice(&png[..iend]);
    for (k, v) in entries {
        out.extend_from_slice(&itxt_chunk(k, v));
    }
    out.extend_from_slice(&png[iend..]);
    Ok(out)
}

fn iend_offset(png: &[u8]) -> Option<usize> {
    let mut at = 8;
    while at + 8 <= png.len() {
        let len = u32::from_be_bytes([png[at], png[at + 1], png[at + 2], png[at + 3]]) as usize;
        if &png[at + 4..at + 8] == b"IEND" {
            return Some(at);
        }
        at += 12 + len;
    }
    None
}

/// Every `iTXt` keyword→text pair in a PNG. Empty for a PNG with none, and
/// for bytes that are not a PNG.
pub fn read_png_text(png: &[u8]) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if png.len() < 8 || png[..8] != PNG_SIG {
        return out;
    }
    let mut at = 8;
    while at + 8 <= png.len() {
        let len = u32::from_be_bytes([png[at], png[at + 1], png[at + 2], png[at + 3]]) as usize;
        let ty = &png[at + 4..at + 8];
        if ty == b"IEND" || at + 8 + len > png.len() {
            break;
        }
        if ty == b"iTXt" {
            let data = &png[at + 8..at + 8 + len];
            if let Some(k) = data.iter().position(|&b| b == 0) {
                // keyword \0 flag method lang \0 translated \0 text
                let mut o = k + 3;
                for _ in 0..2 {
                    if let Some(z) = data[o.min(data.len())..].iter().position(|&b| b == 0) {
                        o += z + 1;
                    }
                }
                if o <= data.len() {
                    out.insert(
                        String::from_utf8_lossy(&data[..k]).into_owned(),
                        String::from_utf8_lossy(&data[o..]).into_owned(),
                    );
                }
            }
        }
        at += 12 + len;
    }
    out
}

// ------------------------------------------------------------------- reading

/// What a picture says: its text chunks (when it is a PNG with any) and the
/// text of the first QR found in its pixels (when there is one). Either may
/// be absent; both absent is "no disk on that picture".
pub struct Disk {
    pub chunks: BTreeMap<String, String>,
    pub label: Option<String>,
}

pub fn read_disk(path: &str, always_label: bool) -> Result<Disk, String> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .and_then(|mut f| f.read_to_end(&mut bytes))
        .map_err(|e| format!("cannot read {path}: {e}"))?;
    let chunks = read_png_text(&bytes);
    // The label is only needed when the chunks do not carry the program —
    // unless the caller is proving a poster and wants both halves.
    let label = if !always_label && chunks.contains_key("Source") && chunks.contains_key("Signer") {
        None
    } else {
        decode_label(&bytes)
    };
    Ok(Disk { chunks, label })
}

/// The first QR in the picture, tried at the picture's own size and at a few
/// smaller ones: a 2048px poster's finder patterns are large, and a decoder
/// that locates once does better on a version it can hold in one look.
/// The largest picture a dropped file may decode to. A poster is 1080 by
/// 1920 or thereabouts; a PNG header can promise 30000 by 30000 in a few
/// hundred bytes, and without a limit the decoder allocates for it, which is
/// an out-of-memory abort that `catch_unwind` does not catch.
const MAX_LABEL_PIXELS: u64 = 4096 * 4096;

pub fn decode_label(bytes: &[u8]) -> Option<String> {
    use std::io::Cursor;
    let reader = image::ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let (w, h) = reader.into_dimensions().ok()?;
    if u64::from(w) * u64::from(h) > MAX_LABEL_PIXELS {
        return None;
    }
    let img = image::load_from_memory(bytes).ok()?;
    let (w, h) = img.dimensions();
    let mut sizes = vec![w];
    for target in [1024u32, 768, 512] {
        if target < w {
            sizes.push(target);
        }
    }
    for size in sizes {
        let gray = if size == w {
            img.to_luma8()
        } else {
            let hh = (h as u64 * size as u64 / w as u64) as u32;
            img.resize_exact(size, hh.max(1), image::imageops::FilterType::Triangle)
                .to_luma8()
        };
        let mut prepared = rqrr::PreparedImage::prepare(gray);
        for grid in prepared.detect_grids() {
            let mut out = Vec::new();
            if grid.decode_to(&mut out).is_ok() {
                return Some(String::from_utf8_lossy(&out).into_owned());
            }
        }
    }
    None
}

// ------------------------------------------------------------------ recover

/// The address behind an EIP-191 signature over `message`: `r||s||v` with
/// `v` in {27, 28} (or the raw 0/1), as `sign` produces it. Err for bytes
/// that are not a signature.
pub fn recover(message: &[u8], signature_hex: &str) -> Result<[u8; 20], String> {
    let body = signature_hex.strip_prefix("0x").unwrap_or(signature_hex);
    let sig = hex::decode(body).map_err(|_| "signature is not hex".to_string())?;
    if sig.len() != 65 {
        return Err("a signature is 65 bytes".to_string());
    }
    let v = if sig[64] >= 27 { sig[64] - 27 } else { sig[64] };
    let rec = RecoveryId::try_from(v).map_err(|_| "recovery id is not 0 or 1".to_string())?;
    let signature = Signature::from_slice(&sig[..64])
        .map_err(|_| "signature is not on the curve".to_string())?;
    let digest = evm::eip191_digest(message);
    let key = VerifyingKey::recover_from_prehash(&digest, &signature, rec)
        .map_err(|_| "no key recovers from that signature".to_string())?;
    Ok(evm::address_bytes(&key))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny_png() -> Vec<u8> {
        // 1×1 grey PNG, via the encoder we ship anyway.
        let img = image::GrayImage::from_pixel(1, 1, image::Luma([128u8]));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn text_chunks_round_trip() {
        let mut e = BTreeMap::new();
        e.insert("Source".to_string(), "print(\"héllo 🌏\")\n".to_string());
        e.insert("Signer".to_string(), "0xabc".to_string());
        let png = with_png_text(&tiny_png(), &e).unwrap();
        assert_eq!(read_png_text(&png), e);
        assert_eq!(&png[png.len() - 8..png.len() - 4], b"IEND");
        assert!(
            image::load_from_memory(&png).is_ok(),
            "still a PNG a decoder takes"
        );
    }

    #[test]
    fn refuses_what_is_not_a_png() {
        assert!(with_png_text(b"hello", &BTreeMap::new()).is_err());
        assert!(read_png_text(b"hello").is_empty());
    }

    #[test]
    fn qr_is_square_and_grows() {
        let small = qr_rows("CWBH1\nx").unwrap();
        assert!(small.iter().all(|r| r.len() == small.len()));
        let big = qr_rows(&"a".repeat(600)).unwrap();
        assert!(big.len() > small.len());
        assert!(qr_rows(&"a".repeat(5000)).is_err());
    }

    #[test]
    fn a_label_drawn_is_a_label_read() {
        // Render the QR at 4px a module into a grey PNG and decode it back.
        let text = "CWBH1\n0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F\n-\nrust\nfn main() {}\n";
        let rows = qr_rows(text).unwrap();
        let n = rows.len() as u32;
        let cell = 4u32;
        let quiet = 4 * cell;
        let side = n * cell + quiet * 2;
        let mut img = image::GrayImage::from_pixel(side, side, image::Luma([255u8]));
        for (r, row) in rows.iter().enumerate() {
            for (c, ch) in row.chars().enumerate() {
                if ch == '1' {
                    for dy in 0..cell {
                        for dx in 0..cell {
                            img.put_pixel(
                                quiet + c as u32 * cell + dx,
                                quiet + r as u32 * cell + dy,
                                image::Luma([0u8]),
                            );
                        }
                    }
                }
            }
        }
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Png).unwrap();
        assert_eq!(decode_label(&out.into_inner()).as_deref(), Some(text));
    }

    #[test]
    fn recovers_the_fixture_key() {
        // CausewaybayWallet testvectors/eip191.json: key 0x46…46, "Hello World".
        let sig = "0xf445005436439a4398409aee0e0b13702bdee4e3774b6aa67184f0732d3a270a1ef3802a2455afba1374fb2ad23345e89eb7366c9d567fe0e5338df934434e3b1c";
        let addr = recover(b"Hello World", sig).unwrap();
        assert_eq!(
            evm::to_eip55(&addr),
            "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"
        );
        // A different message recovers somebody else.
        assert_ne!(
            evm::to_eip55(&recover(b"Hello World!", sig).unwrap()),
            "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"
        );
        assert!(recover(b"x", "0x1234").is_err());
    }
}

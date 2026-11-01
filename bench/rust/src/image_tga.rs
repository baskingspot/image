//! `image`'s TGA decoder, reading into the caller's buffer, and its TGA
//! encoder, writing into it.

use image::codecs::tga::{TgaDecoder, TgaEncoder};
use image::{ExtendedColorType, ImageDecoder};
use std::io::Cursor;

pub const OPS: &[super::Op] = &[
    (c"tga-decode", decode),
    (c"tga-decode-rle", decode),
    (c"tga-encode", encode_raw),
    (c"tga-encode-rle", encode_rle),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = TgaDecoder::new(Cursor::new(input)).ok()?;
    let n = d.total_bytes() as usize;
    d.read_image(out.get_mut(..n)?).ok()?;
    Some(n)
}

/// The input is the width and height as little-endian u32s, then RGB or
/// RGBA pixels.
fn encode(input: &[u8], out: &mut [u8], rle: bool) -> Option<usize> {
    let w = u32::from_le_bytes(input.get(..4)?.try_into().ok()?);
    let h = u32::from_le_bytes(input.get(4..8)?.try_into().ok()?);
    let pixels = &input[8..];
    if w == 0 || h == 0 {
        return None;
    }
    let color = if pixels.len() / w as usize / h as usize == 4 {
        ExtendedColorType::Rgba8
    } else {
        ExtendedColorType::Rgb8
    };
    let mut cursor = Cursor::new(out);
    let encoder = TgaEncoder::new(&mut cursor);
    let encoder = if rle { encoder } else { encoder.disable_rle() };
    encoder.encode(pixels, w, h, color).ok()?;
    Some(cursor.position() as usize)
}

fn encode_raw(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, false)
}

fn encode_rle(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, true)
}

//! `image`'s BMP decoder and encoder. The decoder writes RGB or RGBA as
//! the file has alpha; RGB is decoded into the end of the caller's buffer
//! and widened to RGBA in place, so no call allocates pixels.

use image::codecs::bmp::{BmpDecoder, BmpEncoder};
use image::{ColorType, ExtendedColorType, ImageDecoder};
use std::io::Cursor;

pub const OPS: &[super::Op] = &[
    (c"bmp-decode", decode),
    (c"bmp-decode-rle", decode),
    (c"bmp-encode-rgb", encode_rgb),
    (c"bmp-encode-rgba", encode_rgba),
    (c"bmp-encode-gray", encode_gray),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = BmpDecoder::new(Cursor::new(input)).ok()?;
    let (w, h) = d.dimensions();
    let px = w as usize * h as usize;
    let n = d.total_bytes() as usize;
    let comps = match d.color_type() {
        ColorType::Rgba8 => 4,
        ColorType::Rgb8 => 3,
        ColorType::L8 => 1,
        _ => return None,
    };
    let rgba = out.get_mut(..4 * px)?;
    d.read_image(&mut rgba[4 * px - n..]).ok()?;
    widen(rgba, px, comps);
    Some(4 * px)
}

/// Widens `px` pixels of `comps` channels at the end of `out` to RGBA.
fn widen(out: &mut [u8], px: usize, comps: usize) {
    let start = (4 - comps) * px;
    for i in 0..px {
        let s = start + i * comps;
        let p = match comps {
            4 => return,
            3 => [out[s], out[s + 1], out[s + 2], 255],
            _ => [out[s], out[s], out[s], 255],
        };
        out[4 * i..4 * i + 4].copy_from_slice(&p);
    }
}

fn encode(input: &[u8], out: &mut [u8], c: ExtendedColorType, bpp: usize) -> Option<usize> {
    let side = ((input.len() / bpp) as f64).sqrt() as u32;
    let mut w = Cursor::new(out);
    BmpEncoder::new(&mut w).encode(input, side, side, c).ok()?;
    Some(w.position() as usize)
}

fn encode_rgb(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ExtendedColorType::Rgb8, 3)
}

fn encode_rgba(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ExtendedColorType::Rgba8, 4)
}

fn encode_gray(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ExtendedColorType::L8, 1)
}

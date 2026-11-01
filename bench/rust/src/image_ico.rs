//! `image`'s ICO decoder, which decodes the largest entry: the only one in
//! the benchmark's icons.

use image::codecs::ico::IcoDecoder;
use image::{ColorType, ImageDecoder};
use std::io::Cursor;

pub const OPS: &[super::Op] = &[(c"ico-decode", decode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = IcoDecoder::new(Cursor::new(input)).ok()?;
    if d.color_type() != ColorType::Rgba8 {
        return None;
    }
    let n = d.total_bytes() as usize;
    d.read_image(out.get_mut(..n)?).ok()?;
    Some(n)
}

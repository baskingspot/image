//! `image`'s lossless WebP encoder (the `image-webp` crate), writing raw
//! RGB or RGBA pixels (bench/corpus/webp_encode.sh) into the caller's
//! buffer. It has one level, a fast one, so it runs only on the `-z 0` row.

use image::codecs::webp::WebPEncoder;
use image::{ExtendedColorType, ImageEncoder};

pub const OPS: &[super::Op] = &[(c"webp-encode-z0", encode)];

fn encode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let (width, height) = crate::input_size();
    let n = width as usize * height as usize;
    let color = match input.len().checked_div(n)? {
        3 if input.len() == n * 3 => ExtendedColorType::Rgb8,
        4 if input.len() == n * 4 => ExtendedColorType::Rgba8,
        _ => return None,
    };
    let mut cursor = std::io::Cursor::new(out);
    WebPEncoder::new_lossless(&mut cursor)
        .write_image(input, width, height, color)
        .ok()?;
    Some(cursor.position() as usize)
}

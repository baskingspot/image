//! `image`'s WebP decoder (the `image-webp` crate) into RGBA8: straight into
//! the caller's buffer for files with alpha, and through `image`'s own
//! conversion for the rest, as its users write it.

use image::codecs::webp::WebPDecoder;
use image::{ColorType, DynamicImage, ImageDecoder};

pub const OPS: &[super::Op] = &[
    (c"webp-decode-lossless", decode),
    (c"webp-decode-lossless-large", decode),
    (c"webp-decode-lossy", decode),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = WebPDecoder::new(std::io::Cursor::new(input)).ok()?;
    let (w, h) = d.dimensions();
    let n = w as usize * h as usize * 4;
    if d.color_type() == ColorType::Rgba8 {
        d.read_image(out.get_mut(..n)?).ok()?;
    } else {
        let rgba = DynamicImage::from_decoder(d).ok()?.into_rgba8();
        out.get_mut(..n)?.copy_from_slice(rgba.as_raw());
    }
    Some(n)
}

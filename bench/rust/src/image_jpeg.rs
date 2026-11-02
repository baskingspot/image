//! `image`'s JPEG decoder (zune-jpeg underneath) into RGB8: straight into
//! the caller's buffer for color files, and through `image`'s own
//! conversion for grayscale ones, as its users write it.

use image::codecs::jpeg::JpegDecoder;
use image::{ColorType, DynamicImage, ImageDecoder};

pub const OPS: &[super::Op] = &[
    (c"jpeg-decode", decode),
    (c"jpeg-decode-progressive", decode),
    (c"jpeg-decode-444", decode),
    (c"jpeg-decode-cmyk", decode),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = JpegDecoder::new(std::io::Cursor::new(input)).ok()?;
    let (w, h) = d.dimensions();
    let n = w as usize * h as usize * 3;
    if d.color_type() == ColorType::Rgb8 {
        d.read_image(out.get_mut(..n)?).ok()?;
    } else {
        let rgb = DynamicImage::from_decoder(d).ok()?.into_rgb8();
        out.get_mut(..n)?.copy_from_slice(rgb.as_raw());
    }
    Some(n)
}

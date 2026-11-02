//! `image`'s JPEG decoder (zune-jpeg underneath) into RGB8: straight into
//! the caller's buffer for color files, and through `image`'s own
//! conversion for grayscale ones, as its users write it. Its JPEG encoder
//! writes into the caller's buffer at quality 85 and 95, RGB or gray; it
//! has no subsampling, so its color files are 4:4:4 at either quality.

use image::codecs::jpeg::{JpegDecoder, JpegEncoder};
use image::{ColorType, DynamicImage, ExtendedColorType, ImageDecoder};
use std::io::Cursor;

pub const OPS: &[super::Op] = &[
    (c"jpeg-decode", decode),
    (c"jpeg-decode-progressive", decode),
    (c"jpeg-decode-444", decode),
    (c"jpeg-decode-cmyk", decode),
    (c"jpeg-encode", encode_85),
    (c"jpeg-encode-444", encode_95),
    (c"jpeg-encode-gray", encode_gray),
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

fn encode(input: &[u8], out: &mut [u8], color: ExtendedColorType, quality: u8) -> Option<usize> {
    let (w, h) = crate::input_size();
    let channels = if color == ExtendedColorType::L8 { 1 } else { 3 };
    if input.len() != w as usize * h as usize * channels {
        return None;
    }
    let mut cursor = Cursor::new(out);
    JpegEncoder::new_with_quality(&mut cursor, quality)
        .encode(input, w, h, color)
        .ok()?;
    Some(cursor.position() as usize)
}

fn encode_85(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ExtendedColorType::Rgb8, 85)
}

fn encode_95(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ExtendedColorType::Rgb8, 95)
}

fn encode_gray(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ExtendedColorType::L8, 85)
}

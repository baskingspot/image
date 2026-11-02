//! TIFF encoding: `image`'s `TiffEncoder`, which writes uncompressed files
//! only, and for the compressed rows the `tiff` crate it is built on, with
//! Predictor 2 for LZW and Deflate (level 6) and its default strips of
//! about 1 MB, as its users write it.

use image::codecs::tiff::TiffEncoder;
use image::ExtendedColorType;
use std::io::Cursor;
use tiff::encoder::colortype::{RGB8, RGBA8};
use tiff::encoder::{Compression, DeflateLevel, Predictor};

pub const OPS: &[super::Op] = &[
    (c"tiff-encode-none", encode_none),
    (c"tiff-encode-packbits", |i, o| {
        encode(i, o, Compression::Packbits)
    }),
    (c"tiff-encode-lzw", |i, o| encode(i, o, Compression::Lzw)),
    (c"tiff-encode-deflate", |i, o| {
        encode(i, o, Compression::Deflate(DeflateLevel::Balanced))
    }),
];

/// The input's channels: 4 for RGBA, 3 for RGB, or None.
fn channels(input: &[u8]) -> Option<usize> {
    let (width, height) = crate::input_size();
    let n = width as usize * height as usize;
    match input.len() {
        l if n > 0 && l == n * 4 => Some(4),
        l if n > 0 && l == n * 3 => Some(3),
        _ => None,
    }
}

fn encode_none(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let (width, height) = crate::input_size();
    let color = match channels(input)? {
        4 => ExtendedColorType::Rgba8,
        _ => ExtendedColorType::Rgb8,
    };
    let mut w = Cursor::new(out);
    TiffEncoder::new(&mut w)
        .encode(input, width, height, color)
        .ok()?;
    Some(w.position() as usize)
}

fn encode(input: &[u8], out: &mut [u8], compression: Compression) -> Option<usize> {
    let (width, height) = crate::input_size();
    let bpp = channels(input)?;
    let mut w = Cursor::new(out);
    let mut e = tiff::encoder::TiffEncoder::new(&mut w)
        .ok()?
        .with_compression(compression);
    if compression != Compression::Packbits {
        e = e.with_predictor(Predictor::Horizontal);
    }
    if bpp == 4 {
        e.write_image::<RGBA8>(width, height, input).ok()?;
    } else {
        e.write_image::<RGB8>(width, height, input).ok()?;
    }
    Some(w.position() as usize)
}

//! `image`'s TIFF decoder (the `tiff` crate) into RGBA8, through `image`'s
//! own conversion, as its users write it.

use image::codecs::tiff::TiffDecoder;
use image::{ColorType, DynamicImage, ImageDecoder};

pub const OPS: &[super::Op] = &[
    (c"tiff-decode-none", decode),
    (c"tiff-decode-lzw", decode),
    (c"tiff-decode-deflate", decode),
    (c"tiff-decode-packbits", decode),
    (c"tiff-decode-g4", decode),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = TiffDecoder::new(std::io::Cursor::new(input)).ok()?;
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

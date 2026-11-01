//! `image`'s PNM decoder and encoder. Native decodes read into the caller's
//! buffer; RGBA decodes convert through `DynamicImage`, as a caller of the
//! crate would, and copy out only while checking. Encodes write into the
//! caller's buffer from raw pixels after an 8-byte width and height; its
//! PPM encoder takes only 8-bit samples.

use std::ffi::c_int;
use std::io::Cursor;

use image::codecs::pnm::{PnmDecoder, PnmEncoder, PnmSubtype, SampleEncoding};
use image::{DynamicImage, ExtendedColorType, ImageDecoder, ImageEncoder};

extern "C" {
    static bench_checking: c_int;
}

pub const OPS: &[super::Op] = &[
    (c"netpbm-decode-ppm", decode),
    (c"netpbm-decode-ppm-rgba", decode_rgba),
    (c"netpbm-decode-pgm", decode),
    (c"netpbm-decode-ppm16", decode),
    (c"netpbm-decode-pam", decode),
    (c"netpbm-decode-pbm", decode),
    (c"netpbm-decode-plain", decode),
    (c"netpbm-encode-ppm", encode_ppm),
    (c"netpbm-encode-pgm", encode_pgm),
    (c"netpbm-encode-pam", encode_pam),
    (c"netpbm-encode-plain", encode_plain),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = PnmDecoder::new(Cursor::new(input)).ok()?;
    let n = d.total_bytes() as usize;
    d.read_image(out.get_mut(..n)?).ok()?;
    Some(n)
}

fn copy_out(bytes: &[u8], out: &mut [u8]) -> Option<usize> {
    let n = bytes.len();
    // SAFETY: arm.c sets it before any call and only between calls.
    if unsafe { bench_checking } != 0 {
        out.get_mut(..n)?.copy_from_slice(bytes);
    }
    (n <= out.len()).then_some(n)
}

fn decode_rgba(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = PnmDecoder::new(Cursor::new(input)).ok()?;
    let img = DynamicImage::from_decoder(d).ok()?.into_rgba8();
    copy_out(img.as_raw(), out)
}

fn encode(
    input: &[u8],
    out: &mut [u8],
    subtype: PnmSubtype,
    color: ExtendedColorType,
) -> Option<usize> {
    let width = u32::from_le_bytes(input.get(..4)?.try_into().ok()?);
    let height = u32::from_le_bytes(input.get(4..8)?.try_into().ok()?);
    let mut w = Cursor::new(out);
    PnmEncoder::new(&mut w)
        .with_subtype(subtype)
        .write_image(&input[8..], width, height, color)
        .ok()?;
    Some(w.position() as usize)
}

fn encode_ppm(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let p = PnmSubtype::Pixmap(SampleEncoding::Binary);
    encode(input, out, p, ExtendedColorType::Rgb8)
}

fn encode_pgm(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let p = PnmSubtype::Graymap(SampleEncoding::Binary);
    encode(input, out, p, ExtendedColorType::L8)
}

fn encode_pam(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(
        input,
        out,
        PnmSubtype::ArbitraryMap,
        ExtendedColorType::Rgba8,
    )
}

fn encode_plain(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let p = PnmSubtype::Pixmap(SampleEncoding::Ascii);
    encode(input, out, p, ExtendedColorType::Rgb8)
}

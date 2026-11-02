//! `image`'s QOI decoder, reading into the caller's buffer, and the `qoi`
//! crate's encoder, which `image` uses, writing into it: `image`'s own
//! `QoiEncoder` encodes to a new `Vec` and copies it out.

use image::codecs::qoi::QoiDecoder;
use image::ImageDecoder;

pub const OPS: &[super::Op] = &[(c"qoi-decode", decode), (c"qoi-encode", encode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = QoiDecoder::new(std::io::Cursor::new(input)).ok()?;
    let n = d.total_bytes() as usize;
    d.read_image(out.get_mut(..n)?).ok()?;
    Some(n)
}

/// Raw pixels after a header of little-endian u32s: width, height, and
/// channels (bench/corpus/qoi_encode.sh).
fn encode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let (width, height) = crate::input_size();
    qoi::encode_to_buf(out, input, width, height).ok()
}

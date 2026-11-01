//! `image`'s QOI decoder, reading into the caller's buffer.

use image::codecs::qoi::QoiDecoder;
use image::ImageDecoder;

pub const OPS: &[super::Op] = &[(c"qoi-decode", decode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = QoiDecoder::new(std::io::Cursor::new(input)).ok()?;
    let n = d.total_bytes() as usize;
    d.read_image(out.get_mut(..n)?).ok()?;
    Some(n)
}

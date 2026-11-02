//! zune-qoi, decoding into the caller's buffer and encoding into it.

use zune_core::bit_depth::BitDepth;
use zune_core::bytestream::ZCursor;
use zune_core::colorspace::ColorSpace;
use zune_core::options::EncoderOptions;
use zune_qoi::{QoiDecoder, QoiEncoder};

pub const OPS: &[super::Op] = &[(c"qoi-decode", decode), (c"qoi-encode", encode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let mut d = QoiDecoder::new(ZCursor::new(input));
    d.decode_headers().ok()?;
    let n = d.output_buffer_size()?;
    d.decode_into(out.get_mut(..n)?).ok()?;
    Some(n)
}

/// Raw pixels after a header of little-endian u32s: width, height, and
/// channels (bench/corpus/qoi_encode.sh).
fn encode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let (width, height) = crate::input_size();
    let pixels = width as usize * height as usize;
    let colorspace = match input.len().checked_div(pixels)? {
        4 => ColorSpace::RGBA,
        _ => ColorSpace::RGB,
    };
    let options = EncoderOptions::new(width as usize, height as usize, colorspace, BitDepth::Eight);
    QoiEncoder::new(input, options).encode(out).ok()
}

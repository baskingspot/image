//! zune-qoi, decoding into the caller's buffer.

use zune_core::bytestream::ZCursor;
use zune_qoi::QoiDecoder;

pub const OPS: &[super::Op] = &[(c"qoi-decode", decode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let mut d = QoiDecoder::new(ZCursor::new(input));
    d.decode_headers().ok()?;
    let n = d.output_buffer_size()?;
    d.decode_into(out.get_mut(..n)?).ok()?;
    Some(n)
}

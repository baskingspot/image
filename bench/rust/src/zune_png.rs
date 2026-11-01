//! zune-png into RGBA8: it adds alpha and narrows 16-bit samples itself,
//! and gray with alpha is widened to RGBA here, in place.

use zune_core::bytestream::ZCursor;
use zune_core::options::DecoderOptions;
use zune_png::PngDecoder;

pub const OPS: &[super::Op] = &[(c"png-decode", decode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let options = DecoderOptions::default()
        .png_set_add_alpha_channel(true)
        .png_set_strip_to_8bit(true);
    let mut d = PngDecoder::new_with_options(ZCursor::new(input), options);
    d.decode_headers().ok()?;
    let (w, h) = d.dimensions()?;
    let pixels = w * h;
    let size = d.output_buffer_size()?;
    d.decode_into(out.get_mut(..size)?).ok()?;
    if size == pixels * 2 {
        for i in (0..pixels).rev() {
            let (y, a) = (out[i * 2], out[i * 2 + 1]);
            out[i * 4..i * 4 + 4].copy_from_slice(&[y, y, y, a]);
        }
    } else if size != pixels * 4 {
        return None;
    }
    Some(pixels * 4)
}

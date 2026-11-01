//! zune-bmp, decoding RGB, RGBA, or gray as the file has them into the end
//! of the caller's buffer and widening them to RGBA in place. It has no RLE
//! row: zune-bmp 0.5.2 rejects 8 of the 35 RLE8 inputs that Wuffs, `image`,
//! and this package decode alike.

use zune_bmp::BmpDecoder;
use zune_core::bytestream::ZCursor;

pub const OPS: &[super::Op] = &[(c"bmp-decode", decode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let mut d = BmpDecoder::new(ZCursor::new(input));
    d.decode_headers().ok()?;
    let (w, h) = d.dimensions()?;
    let px = w * h;
    let n = d.output_buf_size()?;
    let comps = n / px.max(1);
    let rgba = out.get_mut(..4 * px)?;
    d.decode_into(&mut rgba[4 * px - n..]).ok()?;
    widen(rgba, px, comps);
    Some(4 * px)
}

/// Widens `px` pixels of `comps` channels at the end of `out` to RGBA.
fn widen(out: &mut [u8], px: usize, comps: usize) {
    let start = (4 - comps) * px;
    for i in 0..px {
        let s = start + i * comps;
        let p = match comps {
            4 => return,
            3 => [out[s], out[s + 1], out[s + 2], 255],
            _ => [out[s], out[s], out[s], 255],
        };
        out[4 * i..4 * i + 4].copy_from_slice(&p);
    }
}

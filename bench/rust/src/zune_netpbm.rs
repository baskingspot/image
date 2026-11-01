//! zune-ppm, which reads and writes raw PGM, PPM, PAM, and PFM. Its decoder
//! returns its own buffer, copied out only while checking; PFM comes back
//! as RGB floats, where this package writes RGBA. Encodes write into the
//! caller's buffer from raw pixels after an 8-byte width and height.

use std::ffi::c_int;

use zune_core::bit_depth::BitDepth;
use zune_core::bytestream::ZCursor;
use zune_core::colorspace::ColorSpace;
use zune_core::options::EncoderOptions;
use zune_core::result::DecodingResult;
use zune_ppm::{PPMDecoder, PPMEncoder};

extern "C" {
    static bench_checking: c_int;
}

pub const OPS: &[super::Op] = &[
    (c"netpbm-decode-ppm", decode),
    (c"netpbm-decode-pgm", decode),
    (c"netpbm-decode-ppm16", decode),
    (c"netpbm-decode-pam", decode),
    (c"netpbm-decode-pfm", decode),
    (c"netpbm-encode-ppm", encode_ppm),
    (c"netpbm-encode-pgm", encode_pgm),
    (c"netpbm-encode-pam", encode_pam),
    (c"netpbm-encode-ppm16", encode_ppm16),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let mut d = PPMDecoder::new(ZCursor::new(input));
    let pixels = d.decode().ok()?;
    // SAFETY: each sample type to its bytes, in the machine's order.
    let bytes: &[u8] = unsafe {
        match &pixels {
            DecodingResult::U8(v) => v,
            DecodingResult::U16(v) => std::slice::from_raw_parts(v.as_ptr().cast(), v.len() * 2),
            DecodingResult::F32(v) => std::slice::from_raw_parts(v.as_ptr().cast(), v.len() * 4),
            _ => return None,
        }
    };
    let n = bytes.len();
    // SAFETY: arm.c sets it before any call and only between calls.
    if unsafe { bench_checking } != 0 {
        out.get_mut(..n)?.copy_from_slice(bytes);
    }
    (n <= out.len()).then_some(n)
}

fn encode(input: &[u8], out: &mut [u8], colorspace: ColorSpace, depth: BitDepth) -> Option<usize> {
    let width = u32::from_le_bytes(input.get(..4)?.try_into().ok()?) as usize;
    let height = u32::from_le_bytes(input.get(4..8)?.try_into().ok()?) as usize;
    let options = EncoderOptions::new(width, height, colorspace, depth);
    PPMEncoder::new(&input[8..], options).encode(out).ok()
}

fn encode_ppm(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ColorSpace::RGB, BitDepth::Eight)
}

fn encode_pgm(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ColorSpace::Luma, BitDepth::Eight)
}

fn encode_pam(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ColorSpace::RGBA, BitDepth::Eight)
}

fn encode_ppm16(input: &[u8], out: &mut [u8]) -> Option<usize> {
    encode(input, out, ColorSpace::RGB, BitDepth::Sixteen)
}

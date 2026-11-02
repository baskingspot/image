//! `image`'s GIF decoder (the `gif` crate) into RGBA8: `read_image` for the
//! first frame, and `into_frames` for the animation, whose frames `image`
//! composites with their disposal; the last of them is the answer.

use image::codecs::gif::GifDecoder;
use image::{AnimationDecoder, ImageDecoder};

pub const OPS: &[super::Op] = &[(c"gif-decode", decode), (c"gif-decode-anim", decode_anim)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = GifDecoder::new(std::io::Cursor::new(input)).ok()?;
    let (w, h) = d.dimensions();
    let n = w as usize * h as usize * 4;
    d.read_image(out.get_mut(..n)?).ok()?;
    Some(n)
}

fn decode_anim(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let d = GifDecoder::new(std::io::Cursor::new(input)).ok()?;
    let mut last = None;
    for frame in d.into_frames() {
        last = Some(frame.ok()?);
    }
    let raw = last?.into_buffer().into_raw();
    out.get_mut(..raw.len())?.copy_from_slice(&raw);
    Some(raw.len())
}

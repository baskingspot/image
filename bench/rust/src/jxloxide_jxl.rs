//! jxl-oxide, one thread, rendering the first keyframe and widening its
//! samples to RGBA16 (gray to RGB, opaque without alpha).

use jxl_oxide::{JxlImage, JxlThreadPool};

pub const OPS: &[super::Op] = &[(c"jxl-decode", decode), (c"jxl-decode-lossless", decode)];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let image = JxlImage::builder()
        .pool(JxlThreadPool::none())
        .read(input)
        .ok()?;
    let render = image.render_frame(0).ok()?;
    let mut stream = render.stream();
    let (w, h, c) = (
        stream.width() as usize,
        stream.height() as usize,
        stream.channels() as usize,
    );
    let n = w * h * 8;
    if c == 0 || c > 4 || out.len() < n {
        return None;
    }
    let mut samples = vec![0u16; w * h * c];
    if stream.write_to_buffer(&mut samples) != samples.len() {
        return None;
    }
    for (px, o) in samples.chunks_exact(c).zip(out[..n].chunks_exact_mut(8)) {
        let (rgb, a) = match c {
            1 => ([px[0]; 3], u16::MAX),
            2 => ([px[0]; 3], px[1]),
            3 => ([px[0], px[1], px[2]], u16::MAX),
            _ => ([px[0], px[1], px[2]], px[3]),
        };
        for (k, v) in rgb.iter().chain(std::iter::once(&a)).enumerate() {
            o[2 * k..2 * k + 2].copy_from_slice(&v.to_ne_bytes());
        }
    }
    Some(n)
}

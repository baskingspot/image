//! zune-jpeg into RGB8: it converts grayscale and CMYK to RGB itself.

use zune_core::bytestream::ZCursor;
use zune_core::colorspace::ColorSpace;
use zune_core::options::DecoderOptions;
use zune_jpeg::JpegDecoder;

pub const OPS: &[super::Op] = &[
    (c"jpeg-decode", decode),
    (c"jpeg-decode-progressive", decode),
    (c"jpeg-decode-444", decode),
];

fn decode(input: &[u8], out: &mut [u8]) -> Option<usize> {
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
    let mut d = JpegDecoder::new_with_options(ZCursor::new(input), options);
    d.decode_headers().ok()?;
    let (w, h) = d.dimensions()?;
    let size = d.output_buffer_size()?;
    if size != w * h * 3 {
        return None;
    }
    d.decode_into(out.get_mut(..size)?).ok()?;
    Some(size)
}

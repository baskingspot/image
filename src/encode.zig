//! What every encoder shares. A format with an encoder has, in its
//! namespace:
//!
//!   pub const EncodeOptions = struct { ... };   // every field defaulted
//!   pub const EncodeError = image.EncodeError || error{ ... };
//!   pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize
//!   pub fn encode(w: *std.Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void
//!
//! `encode` takes pixels in any `PixelFormat`, converting them with
//! `image.convert` to what the file stores, and writes the whole file to
//! `w`. Like decoders, encoders allocate nothing: `work` holds at least
//! `workLen` bytes, and null from `workLen` means the image is too large
//! for this format or for `usize`.

/// The errors every encoder can return. Each format's error set is these
/// plus its own causes.
pub const Error = error{
    /// The writer failed; its own error says why.
    WriteFailed,
    /// `work` is shorter than `workLen` says.
    WorkTooSmall,
    /// The format cannot store an image this large.
    ImageTooLarge,
    /// The source buffer is smaller than its dimensions and stride need.
    BufferTooSmall,
};

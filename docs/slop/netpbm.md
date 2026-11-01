# Netpbm: design notes

`src/netpbm/` decodes and encodes PBM, PGM, and PPM (plain and raw), PAM,
and PFM. The module docs in `Decoder.zig` and `encode.zig` are the contract;
this file records why, what the oracles disagree on, and what is still open.
Measurements: `results/netpbm-20261101.md`.

## Decisions

- **Native formats.** 8-bit samples for maxval ≤ 255, 16-bit above, in the
  layout the file stores (gray, gray and alpha, RGB, RGBA). PBM is `gray8`
  (0 and 255), PFM is `rgba_f32`. A file with maxval 255 or 65535 keeps its
  samples; any other maxval `m` scales `v` to `round(v · 255 / m)` or
  `round(v · 65535 / m)`, in integers. The specifications define a sample
  as the fraction `v / m` of full scale and say nothing about bit
  replication, so the exact rounded quotient is the only reading that
  depends on nothing but the file.
- **Other output formats** convert from the native one with
  `image.convert`, so a 16-bit file read as 8-bit takes each sample's high
  byte (Wuffs's rounding), while a maxval up to 255 scales straight to 8
  bits.
- **No work memory.** Rows already in the native layout are read straight
  into the destination; everything else unpacks spans of up to 4 KiB of
  native pixels on the stack (zero-copy from the reader's buffer) and
  converts them with `convert.Converter`.
- **Header strictness.** The decoder accepts what the specifications allow
  and what libnetpbm writes, and nothing it would have to guess at:
  - whitespace is C's `isspace` set (space, tab, CR, LF, VT, FF);
  - a comment runs from `#` to the next CR or LF, anywhere whitespace may
    be, including right after the last header number (`255#c\n` ends the
    header at the newline);
  - exactly one whitespace character ends a PBM, PGM, PPM, or PFM header;
  - zero width, height, depth, or maxval, maxval > 65535, or a non-digit in
    a number is `BadHeader`; a dimension over 2^32 − 1 is `ImageTooLarge`;
  - PAM is strict about its keywords (each of WIDTH, HEIGHT, DEPTH, MAXVAL,
    ENDHDR once, nothing unknown, one value per line except TUPLTYPE), and
    `P7` must be followed by a newline. BLACKANDWHITE reads as gray with its
    maxval. Planes past the tuple type's are skipped (the PAM specification
    recommends it). Without TUPLTYPE, depth 1–4 maps to gray, gray+alpha,
    RGB, RGBA; an unknown tuple type is `Unsupported`.
  - PFM: the scale is any nonzero decimal; its sign is the byte order, and
    its magnitude is not applied (the specification says it names units).
- **Plain rasters** are lenient as the specifications ask: comments between
  samples, any whitespace. A sample running into a non-separator, or junk
  after the last sample that does not start with whitespace or `#`, is
  `BadRaster`. A sample over maxval is `SampleOutOfRange` in every kind.
- **Frames.** A raw PBM, PGM, PPM, or PAM file is a sequence of images
  (libnetpbm's reading of concatenated files). Whitespace after an image is
  skipped; then the input must end or hold the same magic, size, and native
  format, otherwise `FrameMismatch`. `frame_count` is null, because only the
  end of the input tells. Plain files and PFM hold one image and the
  decoder reads nothing past it: a plain raster has no length, so a second
  plain image cannot be told from trailing text without reading on.
  Whether mismatched frames should rather be allowed (each frame its own
  size on a canvas) is an open question for the owner, below.
- **Encoder defaults.** With no `kind`, the encoder writes the file whose
  decode in the source's own format is lossless: PGM for gray, PPM for RGB,
  PAM (GRAYSCALE_ALPHA, RGB_ALPHA) for alpha, maxval 255 for 8-bit sources
  and 65535 for 16-bit. Float sources default to a 16-bit RGB_ALPHA PAM,
  because PFM has no alpha and `harness.checkEncoder` encodes with the
  default options. `.kind = .pfm` writes PFM (`Pf` for gray sources, `PF`
  otherwise, alpha dropped as `image.convert` drops it). A maxval is the format's own scaling, not
  `image.convert`'s: an explicit maxval `m` stores `round(v · m / 255)` of an
  8-bit sample and `round(v · m / 65535)` of a 16-bit one, even when `m` is
  255 or less (so a 16-bit source at maxval 255 rounds rather than taking
  the high byte as `convert` does). PBM thresholds gray at 128. Plain files break
  lines before 70 characters.

## Oracles

Wuffs reads raw P5 and P6 with maxval 255 or 65535, stb_image raw P5 and
P6, MagickWand everything. `test/oracle/netpbm.zig`'s module doc lists every
case where an oracle's answer does not count, each found from a real diff.
The headline ones:

- Every library has its own luma, so gray output of a color file is never
  compared.
- Wuffs does not read comments or VT/FF in headers, narrows 16-bit samples
  by taking the high byte, and writes 16-bit color only as BGRA.
- stb_image does not scale maxvals other than 255 and takes the character
  after maxval as the end of the header even when it is `#`.
- MagickWand checks little (it accepts maxvals to 2^32 − 1, clamps samples
  over maxval, reads non-digits in plain rasters as separators, finds a PAM
  ENDHDR anywhere in a line, pads short plain rasters), reads raw maxvals
  128–254 and 32768–65534 as if they were 255 and 65535, and computes in
  single-precision floats scaled by 65535: its 16-bit answers for other
  maxvals round the other way where the exact quotient is within a float's
  precision of .5, and its PFM answers are off by an ulp where
  `f · 65535 / 65535` does not round-trip in single precision. The oracle
  repeats both computations on our pixels and leaves those answers out
  only for the files they affect.
- MagickWand reads `PH` and `Ph` as its own half-float PFM; ours rejects
  them (`BadSignature`), and the oracle leaves those answers out.
- Header ends: the PFM specification ends the header at one whitespace
  character after the scale, and the PAM specification ends the ENDHDR
  line at its newline, with whitespace tokens between (so `ENDHDR\r\n`
  ends at the LF). MagickWand reads a PFM scale's line to its LF, wherever
  that is, and takes the one character after ENDHDR as the end of the
  header. Ours follows the specifications; `crlf.pam`,
  `scale-spaces.pfm`, and `separators.pfm` in the generated corpus pin
  these cases, and the oracle leaves MagickWand's answer out for them. A
  100000-input oracle run on another seed found the first three such
  inputs; they decode to their native formats, so they split the same way
  whatever `image.convert` does.

With those cases left out, nothing splits: every answer that counted
matched ours in the 100000-input gate run.

## Benchmarks

`results/netpbm-20261101.md` has the numbers. Against Wuffs, the bar for
raw PGM and PPM, no row is slower: 2.2–2.9× on icons and 1.0–1.6× above,
with peak RSS level. The gaps:

- Plain PPM decode is 0.90–0.96× image-rs. Each sample's position depends
  on the last one's length, a chain of about 15 cycles a sample however the
  digits are parsed; classifying 64-byte blocks into digit and space masks
  and walking the sample starts with bit operations would lift it.
- 16×16 PGM and PPM decode is 0.79–0.92× zune and image-rs, which do not
  check the input for another image after the first; from 32×32 up ours is
  level or ahead.

Notes on the arms:

- zune-ppm skips FF bytes at the start of a raster as header whitespace, so
  it fails on an image whose first pixel is white; the CNN screenshot is
  out of the bench corpus for that (`bench/corpus/netpbm.sh`), since
  `bench-compare` cannot drop one arm's row.
- image-rs writes PPM only from 8-bit samples, so it has no 16-bit encode
  row; stb_image and Wuffs encode nothing.
- Decode rows are `same` (identical pixels across arms) except PFM, which
  zune returns as RGB floats where this package writes RGBA; every encode
  row is `own` because the arms write different headers.

## Settled questions

Both decided by the owner as they stand: float sources default to a 16-bit
PAM, not PFM, and `FrameMismatch` stays strict (frames of a sequence must
match the first, though Netpbm's tools allow images of different sizes in
one stream).

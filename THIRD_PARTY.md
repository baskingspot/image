# Third-party material

The package itself (`src/`) contains no third-party code. The tests and
benchmarks use the test images and libraries below. Nothing here is part of
what a consumer of the package fetches.

## Vendored test images

Kept unmodified in `corpus/vendor/`, each directory's SHA-256 checksums
beside it in `<directory>.sha256`, which `just corpus` checks.

| Directory                 | Source                                                                                                                                                                                                                                                                                                                     | Archive SHA-256                                                    | License                                                                                                                   |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `corpus/vendor/pngsuite`  | PngSuite 2017-07-19, Willem van Schaik, [PngSuite-2017jul19.tgz](http://www.schaik.com/pngsuite/PngSuite-2017jul19.tgz)                                                                                                                                                                                                    | `0294b244c95a8342c01b00010cf34abdcabc7c6a34fd0fe1bd963917537bfdc8` | Free use, copying, modification, and distribution (`PngSuite.LICENSE`)                                                    |
| `corpus/vendor/bmpsuite`  | BMP Suite 2.8, Jason Summers, [bmpsuite-2.8.zip](https://entropymine.com/jason/bmpsuite/releases/bmpsuite-2.8.zip); the images and readme only                                                                                                                                                                             | `f1b1f18c4f310b76bf317378e64f25b84f875a3d0976fab33ff10befdb35d13f` | The images are in the public domain, except embedded ICC profiles (`readme.txt`); the generator, GPL-3.0, is not included |
| `corpus/vendor/generated` | Made from PngSuite by `corpus/generate` with ImageMagick and qoi.h's `qoiconv`, and with libjpeg-turbo's `cjpeg` and `tjbench` (`corpus/gen/jpeg.sh`: arithmetic, 12-bit, lossless, and CMYK and YCCK), libtiff's `tiffcp` (`corpus/gen/tiff.sh`: every compression and layout), and libjxl's `cjxl` (`corpus/gen/jxl.sh`) | -                                                                  | As PngSuite                                                                                                               |

## Fetched test images

Downloaded by `just corpus` into `corpus/fetched/` (not committed), each
archive checked against the SHA-256 in `corpus/sources.tsv`.

| Name                | Source                                                                          | Formats                         | License                                               |
| ------------------- | ------------------------------------------------------------------------------- | ------------------------------- | ----------------------------------------------------- |
| `qoi-test-images`   | [qoi_test_images.zip](https://qoiformat.org/qoi_test_images.zip), qoiformat.org | QOI, PNG                        | As given in the archive, per image                    |
| `libjpeg-turbo`     | libjpeg-turbo 3.2.0, `testimages/`                                              | JPEG, Netpbm, BMP               | IJG, BSD-3-Clause, and zlib (libjpeg-turbo's)         |
| `wuffs`             | Wuffs v0.4.0-alpha.12, `test/data/`                                             | PNG, GIF, BMP, WBMP, QOI, ...   | Apache-2.0 or MIT; images per `test/data/README.md`   |
| `giflib`            | giflib 6.1.3, `pic/`                                                            | GIF                             | MIT (giflib's `COPYING`)                              |
| `libwebp-test-data` | libwebp-test-data at 06ddd96                                                    | WebP                            | BSD-3-Clause (WebM project)                           |
| `libtiffpic`        | libtiff's pics-3.8.0                                                            | TIFF                            | libtiff's (BSD-style); per-image notes in the archive |
| `libtiff`           | libtiff 4.7.1, `test/images/`                                                   | TIFF                            | libtiff's (BSD-style)                                 |
| `jxl-conformance`   | libjxl/conformance at b1d0f99, `testcases/`                                     | JPEG XL                         | BSD-3-Clause                                          |
| `image-rs`          | image-rs/image v0.25.9, `tests/images/`                                         | ICO, CUR, TGA, Netpbm, BMP, ... | MIT or Apache-2.0; images per their sources           |

The ITU-T T.83 JPEG conformance files have no stable public download, so they
are not fetched; libjpeg-turbo's and Wuffs's JPEG files stand in for them.

## Benchmark corpus

`just bench-corpus` downloads the [QOI benchmark suite](https://qoiformat.org/benchmark/)
(`qoi_benchmark_suite.tar`, SHA-256
`00166f555ca760e23647025e46d9b046e03cd2e22869d4ecb496edc527cd0d7d`) and builds
`bench/corpus-gen/` from part of it; nothing from it is committed. Its images
come from several collections, each with its license in the archive (Kodak,
Tecnick, Wikipedia, pngimg.com, game screenshots, textures).

## Oracles and comparison libraries

From nixpkgs through the dev shell (`flake.nix`), used only by the tests and
benchmarks: libpng, libspng, libjpeg-turbo, giflib, libwebp, libtiff, libjxl,
stb_image, qoi.h, ImageMagick, Rust's `image` and `zune-qoi` crates (pinned in
`bench/rust/Cargo.lock`), and Go's `image` packages. Wuffs, which nixpkgs
lacks as a C library, is its single-file C release at v0.4.0-alpha.12
(Apache-2.0 or MIT), fetched by the flake and pinned by hash.

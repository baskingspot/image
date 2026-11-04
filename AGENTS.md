# AGENTS.md

Working notes for AI coding agents in baskingspot/image.

## What this is

Image decoders and encoders in Zig, with no C: PNG and APNG, JPEG, GIF, WebP, TIFF, JPEG XL, BMP, ICO and CUR, TGA, Netpbm, WBMP, and QOI. Think Wuffs's image formats, plus encoders and the formats Wuffs lacks. No release is tagged yet, and the API can change between commits.

`docs/slop/plan.md` is the scope, the API, the order of work, and the decisions still to measure. Read it before starting.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit. `.agents/setup` installs Nix when an orb lacks it and warms the dev shell.

## Safety

These decoders read untrusted files, so a hostile input must never crash, hang, read or write out of bounds, or use unbounded memory. It gets an error.

- Decoders allocate nothing: the caller passes the work memory and the pixel buffer, and a decoder states up front how much of each it needs. A dimension or size limit the caller sets is checked before any work.
- No `@setRuntimeSafety(false)` and no unchecked pointer arithmetic in parsers. A measured hot loop may drop a check only where the bound is proven in the same function, with a comment saying why.
- Every format gets a fuzz target from its first commit. Run `just fuzz` before pushing a format change; CI fuzzes on a schedule (`.github/workflows/fuzz.yml`), not on push (`docs/slop/plan.md`, Testing).

## Performance

Speed and memory count equally. Each format's best implementation is the bar, on both decode and encode, wall time and peak memory: Wuffs for PNG, GIF, BMP, and the simple formats; libjpeg-turbo for JPEG; libwebp for WebP; libtiff for TIFF; libjxl (and jxl-oxide for decode) for JPEG XL; libpng, libspng, and the reference encoders for encoding. stb_image, Rust's `image` and `zune-image`, and Go's `image` are comparison arms.

- SIMD with `@Vector` and `std.simd` where a measurement shows it pays: inflate, unfiltering, IDCT, color conversion, and upsampling are the usual places.
- Measure on real corpora: photographs, screenshots, icons, line art, animations, and the conformance suites, at sizes from 16×16 icons to 50-megapixel photos. Small images matter: per-call setup that loses on an icon is a regression.
- A change to a hot path comes with an interleaved A/B, pinned to one core (`taskset`), compared with benchstat, written up in `docs/slop/results/<topic>-<yyyymmdd>.md` with the raw output, the CPU named, and megapixels per second.
- A speed change that costs memory, or the reverse, is measured both ways and the trade written up; neither wins by default.

## Tests

Each decoder is checked differentially against its reference library on the same files: identical pixels for lossless formats, and for lossy ones identical pixels to the reference's output for the same decoding choices (IDCT, upsampling), or a stated error bound where the format allows implementation freedom. Each encoder's output must decode in the reference decoder to the input (lossless) or within the stated quality bound (lossy), and round-trip through our own decoder. Conformance suites (PngSuite, the JPEG and JPEG XL conformance sets, libwebp's and libtiff's test images) are vendored unmodified with their checksums in `THIRD_PARTY.md`; a file that cannot pass for a documented reason goes in a list in the test driver, with the reason.

## Agent notes

Docs split by reader. `README.md`, `CHANGELOG.md`, and `THIRD_PARTY.md` are for a person deciding whether and how to use the package. Agent material goes in `docs/slop/`: design notes, plans, and measurements in `docs/slop/results/`. `docs/slop/plan.md` is the architecture, the decisions still to measure, and who owns which files; update it when a decision lands. `AGENTS.md` and `//` code comments may link `docs/slop/`; no human document links or names it, and neither do doc comments (`///`, `//!`), which render in the API reference.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history. A change made for a measurement adds a short body that names its `docs/slop/results/` file and gives the headline number.
- Gate commands on their exit codes, and claim only what you ran.
- `just fmt` formats Zig, Nix, Markdown, and the justfile; `just lint` checks them and lints the workflows with actionlint and zizmor.
- Implement from the specifications and papers, not by translating another implementation's source. Reference libraries are oracles and benchmarks.
- This repo's GitHub settings come from `baskingspot/.github`: run `just settings --repo image` in a checkout of that repo. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.

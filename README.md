# image

Image decoders and encoders in Zig with no C: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and more.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

## Work on it

`nix develop` provides the toolchain, the reference libraries, and the
comparison arms, and `just ci` runs what CI runs: the tests in Debug,
ReleaseSafe, and on a big-endian target, the linters, a bounded fuzz run, and
the differential comparison against the reference decoders. `just fuzz`,
`just oracle`, and `just bench-compare` run the longer versions; `just corpus`
fetches the conformance suites (see `corpus/README.md`, `bench/README.md`,
and `THIRD_PARTY.md`).

## License

MIT. See `LICENSE`.

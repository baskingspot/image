# Conformance corpus

The files the tests, fuzzers, and oracle comparison read. THIRD_PARTY.md
names each source and its license.

- `vendor/`: small suites kept unmodified (PngSuite, BMP Suite) and the
  generated cases, committed. Each directory `D` has its SHA-256 checksums in
  `D.sha256` beside it.
- `fetched/`: the large suites, downloaded by `just corpus` and not
  committed. `sources.tsv` pins each archive's URL and SHA-256 and says which
  part of it to keep and where.
- `generate` and `gen/<format>.sh`: rebuild `vendor/generated/<format>/`
  from PngSuite with ImageMagick and qoi.h's `qoiconv`, for the cases the
  public suites lack (every Netpbm type, every TGA image type, ICO and CUR
  with BMP and PNG entries, WBMP, small QOI files). The output is committed,
  so a newer ImageMagick cannot change it; after adding a case, run
  `just corpus-sums corpus/vendor/generated/<format>`.

```sh
just corpus                    # fetch every suite and check everything
just corpus qoi-test-images    # fetch one
```

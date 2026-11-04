{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, except the toolchain
      # version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
      ];

      perSystem =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          # Wuffs's C library, the single-file release: nixpkgs packages only
          # its Go toolchain, at 0.3, which has no QOI. Pinned to the
          # v0.4.0-alpha.12 tag.
          wuffs-c = pkgs.stdenvNoCC.mkDerivation {
            pname = "wuffs-c";
            version = "0.4.0-alpha.12";
            src = pkgs.fetchurl {
              url = "https://raw.githubusercontent.com/google/wuffs/7f70dda95c77b10c087c0908790837b5e9c15713/release/c/wuffs-v0.4.c";
              sha256 = "0kghsn4xsvs3v7fnjxbjfy2li95yja1al1n9qfdnvga7fd2nd025";
            };
            dontUnpack = true;
            installPhase = "install -Dm644 $src $out/include/wuffs-v0.4.c";
          };
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = with config.devShells; [
              base
              docs
              zig
            ];

            # Project-specific tools.
            packages = with pkgs; [
              # The oracles and C comparison arms (bench/README.md), built
              # with the shell's cc and found with pkg-config or, for the
              # header-only ones, on the include path.
              pkg-config
              libpng
              libspng
              libjpeg_turbo
              giflib
              libwebp
              libtiff
              libjxl
              # libultrahdr: `is_uhdr_image`, the oracle for the JPEG
              # decoder's gain map flag.
              libultrahdr
              stb
              wuffs-c
              # qoi.h, the reference QOI decoder, and its qoiconv, which
              # encodes the QOI benchmark corpus with the reference encoder;
              # imagemagick resizes and converts that corpus's sources.
              qoi
              (lib.getBin qoi)
              imagemagick
              # The size bars for PNG encode: oxipng, and zopfli's zopflipng.
              oxipng
              zopfli
              # gifski, a GIF encoder arm (its C library, libgifski) and the
              # quantizer the GIF encoder's quality is measured against.
              gifski
              # The Rust (image, zune-image) and Go (image) arms.
              cargo
              rustc
              rustfmt
              go
              # `just bench-compare`: goperf supplies benchstat, util-linux
              # taskset, time is GNU time for peak RSS, and curl and unzip
              # fetch the corpora.
              goperf
              util-linux
              time
              curl
              unzip
              # `just test-be` runs the tests on a big-endian target.
              qemu-user
            ];

            # mozjpeg, the JPEG encoder's size bar, kept off PATH and
            # pkg-config: its cjpeg and libjpeg would shadow libjpeg-turbo's,
            # the oracle and corpus generator. Bench arms and scripts find it
            # here.
            MOZJPEG = pkgs.mozjpeg;
          };
        };
    };
}

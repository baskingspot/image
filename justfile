# image: Image decoders and encoders in Zig with no C: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and more. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md corpus/README.md docs/slop .github"
zig_sources := "src build.zig build.zig.zon test"

[private]
default:
    @just --list

[doc("Unit tests and each fuzz target over its seeds, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Unit tests on a big-endian target, s390x, under qemu")]
[group("test")]
test-be:
    zig build test -Dtarget=s390x-linux-musl -fqemu --summary all

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile")]
[group("lint")]
lint:
    ziglint
    zig fmt --check {{ zig_sources }}
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check
    ! rg -n setRuntimeSafety src

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt {{ zig_sources }}
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Fetch the conformance suites corpus/sources.tsv lists (NAMES, default all) and check the vendored ones")]
[group("corpus")]
corpus *NAMES:
    corpus/fetch {{ NAMES }}

[doc("Write the checksums of vendored directories DIRS (such as corpus/vendor/generated/tga; default every one with a .sha256 beside it)")]
[group("corpus")]
corpus-sums *DIRS:
    #!/usr/bin/env bash
    set -euo pipefail
    dirs=({{ DIRS }})
    [ ${#dirs[@]} -gt 0 ] || mapfile -t dirs < <(find corpus/vendor -name '*.sha256' | sed 's/\.sha256$//')
    for d in "${dirs[@]}"; do
        d=${d%/}
        (cd "$d" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs -r sha256sum) > "$d.sha256"
    done

[doc("Run every fuzz target (or TARGETS) for SECONDS in all, ReleaseSafe; findings go to zig-out/fuzz/")]
[group("fuzz")]
fuzz SECONDS="600" SEED="" *TARGETS:
    zig build fuzz -Doptimize=ReleaseSafe
    zig-out/bin/fuzz run {{ TARGETS }} --seconds {{ SECONDS }} {{ if SEED == "" { "" } else { "--seed " + SEED } }}

[doc("Run the fuzz targets on Zig's coverage-guided fuzzer for N inputs (such as 1M)")]
[group("fuzz")]
fuzz-zig N="1M":
    zig build fuzz-zig -Doptimize=ReleaseSafe --fuzz={{ N }}

[doc("CI's fuzzing: the QOI suite, 60 seconds of `just fuzz`, and 100K inputs on Zig's fuzzer")]
[group("fuzz")]
fuzz-ci:
    just corpus qoi-test-images
    just fuzz 60
    just fuzz-zig 100K

[doc("Build the C oracle, zig-out/bin/image-oracle, linking what test/oracle/formats.def names")]
[group("oracle")]
oracle-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p zig-out/bin
    # shellcheck disable=SC2046
    cc -O2 -std=c11 -Wall -o zig-out/bin/image-oracle test/oracle/*.c \
        $(just _link $(sed -n 's|.*// link: ||p' test/oracle/formats.def)) -lm

# The compiler flags for a list of libraries: pkg-config packages, -l flags
# as they are, and `-` for none.
[private]
_link *LIBS:
    #!/usr/bin/env bash
    set -euo pipefail
    for lib in {{ LIBS }}; do
        case "$lib" in
            -) ;;
            -l*) printf '%s ' "$lib" ;;
            *) printf '%s ' "$(pkg-config --cflags --libs "$lib")" ;;
        esac
    done

[doc("Compare every decoder with its oracles on its corpus and N fuzzed inputs (default 100000); disagreements go to zig-out/oracle/")]
[group("oracle")]
oracle N="100000" SEED="1": oracle-build
    zig build oracle -Doptimize=ReleaseSafe
    zig-out/bin/oracle-compare {{ N }} {{ SEED }}

[doc("CI's oracle run: the fetched suites and 20000 fuzzed inputs")]
[group("oracle")]
oracle-ci:
    just corpus qoi-test-images
    just oracle 20000 1

[doc("Everything CI runs")]
[group("ci")]
ci: test test-be lint fuzz-ci oracle-ci

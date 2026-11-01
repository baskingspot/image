# image: Image decoders and encoders in Zig with no C: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and more. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md bench/README.md corpus/README.md docs/slop .github"
zig_sources := "src build.zig build.zig.zon test bench/zig docs/slop/results"

# The arms `just bench-compare` runs, this package's first; the C arms come
# from bench/c/arms.tsv.

rust_arms := "image-rs zune"

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

[doc("Lint Zig, Go, Rust, Nix, Markdown, the workflows, and this justfile")]
[group("lint")]
lint:
    ziglint
    zig fmt --check {{ zig_sources }}
    test -z "$(gofmt -l bench/go)"
    cargo fmt --check --manifest-path bench/rust/Cargo.toml
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
    gofmt -w bench/go
    cargo fmt --manifest-path bench/rust/Cargo.toml
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

[doc("Fetch and generate the benchmark corpus in bench/corpus-gen/, and check it against the checksums in bench/corpus/")]
[group("bench")]
bench-corpus:
    bench/corpus/generate

[doc("Build every arm into zig-out/bin/bench-<arm>, for this machine's CPU")]
[group("bench")]
bench-build:
    #!/usr/bin/env bash
    set -euo pipefail
    export NIX_ENFORCE_NO_NATIVE=0
    mkdir -p zig-out/bin
    zig build bench
    grep -v '^#' bench/c/arms.tsv | while IFS=$'\t' read -r arm pkgs; do
        # shellcheck disable=SC2046,SC2086
        cc -O3 -march=native -std=gnu11 -o "zig-out/bin/bench-$arm" bench/c/arm.c bench/c/"$arm"-*.c \
            $(just _link $pkgs) -lm
    done
    for arm in {{ rust_arms }}; do
        RUSTFLAGS="-C target-cpu=native" CARGO_TARGET_DIR="bench/rust/target/$arm" \
            cargo build --quiet --release --locked --features "$arm" --manifest-path bench/rust/Cargo.toml
        cc -O3 -march=native -std=gnu11 -DBENCH_EXTERNAL_INIT -o "zig-out/bin/bench-$arm" bench/c/arm.c \
            "bench/rust/target/$arm/release/libbench_rust.a" -lpthread -ldl -lm
    done
    GOAMD64=v3 go build -C bench/go -o ../../zig-out/bin/bench-go .

[doc("Compare with Wuffs, the reference libraries, Rust, and Go on this machine: checksums, peak RSS, then ROUNDS rounds on one core that time the arms on each row back to back, benchstat against this package, and a summary per operation. OPS picks operations from bench/ops.tsv (default all). The numbers are not claims")]
[group("bench")]
bench-compare ROUNDS="10" *OPS: bench-corpus bench-build
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out"
    arms=(image $(grep -v '^#' bench/c/arms.tsv | cut -f1) {{ rust_arms }} go)
    ops=({{ OPS }})
    export BENCHTIME_MS="${BENCHTIME_MS:-50}"
    # The outputs must match before the timings mean anything: every arm's
    # checksums against this package's, on the rows both have. An `own`
    # operation (bench/ops.tsv) may differ, and the differences are listed.
    for arm in "${arms[@]}"; do
        zig-out/bin/bench-$arm check "${ops[@]}" > "$out/check-$arm.txt" 2> "$out/stderr-$arm.txt" ||
            { cat "$out/stderr-$arm.txt"; exit 1; }
    done
    {
        echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) threads"
        echo "image: ReleaseFast, native; C arms: cc -O3 -march=native; rust: target-cpu=native; go: GOAMD64=v3"
        echo "buffers: input ${BENCH_IN_OFFSET:-0} bytes past a page, output ${BENCH_OUT_OFFSET:-2048}; ${BENCHTIME_MS} ms a sample, {{ ROUNDS }} rounds"
    } | tee "$out/config.txt"
    status=0
    own=$(grep -v '^#' bench/ops.tsv | awk -F'\t' '$5 == "own" { print $2 }' | paste -sd'|')
    for arm in "${arms[@]:1}"; do
        join -t $'\t' <(grep -v '^#' "$out/check-image.txt" | sort) <(grep -v '^#' "$out/check-$arm.txt" | sort) |
            awk -F'\t' '$2 != $3' > "$out/check-diff-$arm.txt"
        if [ -s "$out/check-diff-$arm.txt" ]; then
            if grep -Ev "^(${own:-^})/" "$out/check-diff-$arm.txt" > "$out/check-fail-$arm.txt"; then
                echo "checksums differ between image and $arm (row, image, $arm):"
                cat "$out/check-fail-$arm.txt"
                status=1
            fi
        fi
        printf '%-9s %4d rows, %d differ on own operations, %d operations skipped\n' "$arm" \
            "$(grep -vc '^#' "$out/check-$arm.txt" || true)" "$(wc -l < "$out/check-diff-$arm.txt")" \
            "$(grep -c '^# SKIP' "$out/check-$arm.txt" || true)"
    done
    [ "$status" = 0 ] || exit 1
    # Peak RSS of one pass over each operation's inputs: the inputs and
    # output buffers, which every arm holds alike, plus the arm's runtime
    # and any memory its library allocates.
    echo
    {
        printf '%-22s' "peak RSS (MiB)"; printf '%9s' "${arms[@]}"; echo
        for op in ${ops[@]:-$(grep -v '^#' bench/ops.tsv | cut -f1)}; do
            printf '%-22s' "$op"
            for arm in "${arms[@]}"; do
                command time -f %M -o "$out/rss-run.txt" zig-out/bin/bench-$arm check "$op" > "$out/rss-check.txt" 2> /dev/null
                if grep -q '^# SKIP' "$out/rss-check.txt"; then printf '%9s' -; continue; fi
                awk '{ printf "%9.1f", $1 / 1024 }' "$out/rss-run.txt"
            done
            echo
        done
    } | tee "$out/rss.txt"
    echo
    # The rounds. Each arm runs as a server (`bench-<arm> serve`) pinned to
    # the last core, and each row is timed by every arm that has it back to
    # back, in an order that rotates from row to row and round to round, so
    # the arms' samples of a row see the same machine. Every round starts
    # the servers afresh. Round 0 sizes each row's loop to BENCHTIME_MS and
    # is not counted; the rounds after it run that many iterations.
    core=$(( $(nproc) - 1 ))
    taskset -cp 0 $$ > /dev/null
    declare -A arg_of has iters to from
    while IFS=$'\t' read -r arg row _; do arg_of[$row]=$arg; done < <(grep -v '^#' bench/ops.tsv)
    mapfile -t rows < <(grep -v '^#' "$out/check-image.txt" | cut -f1)
    for arm in "${arms[@]}"; do
        while IFS=$'\t' read -r row _; do has[$arm/$row]=1; done < <(grep -v '^#' "$out/check-$arm.txt")
    done
    fifos=$(mktemp -d)
    trap 'rm -rf "$fifos"' EXIT
    start() {
        for arm in "${arms[@]}"; do
            mkfifo "$fifos/$arm.in" "$fifos/$arm.out"
            taskset -c "$core" zig-out/bin/bench-$arm serve < "$fifos/$arm.in" > "$fifos/$arm.out" 2>> "$out/stderr-$arm.txt" &
            exec {fd}> "$fifos/$arm.in"
            to[$arm]=$fd
            exec {fd}< "$fifos/$arm.out"
            from[$arm]=$fd
        done
    }
    stop() {
        for arm in "${arms[@]}"; do eval "exec ${to[$arm]}>&-"; done
        wait
        for arm in "${arms[@]}"; do eval "exec ${from[$arm]}<&-"; done
        rm -f "$fifos"/*
    }
    sample() {
        printf '%s %s %s\n' "$2" "$3" "$4" >&"${to[$1]}"
        if ! IFS= read -r line <&"${from[$1]}" || [[ $line != Benchmark* ]]; then
            echo "bench-$1 failed on $2 $3: $line"
            cat "$out/stderr-$1.txt"
            exit 1
        fi
    }
    for round in $(seq 0 {{ ROUNDS }}); do
        start
        j=0
        for row in "${rows[@]}"; do
            arg=${arg_of[${row%%/*}]}
            input=${row#*/}
            present=()
            for arm in "${arms[@]}"; do [ -n "${has[$arm/$row]:-}" ] && present+=("$arm"); done
            for i in "${!present[@]}"; do
                arm=${present[$(( (round + j + i) % ${#present[@]} ))]}
                if [ "$round" = 0 ]; then
                    sample "$arm" "$arg" "$input" 0
                    IFS=$'\t' read -r _ n _ <<< "$line"
                    iters[$arm/$row]=$n
                else
                    sample "$arm" "$arg" "$input" "${iters[$arm/$row]}"
                    echo "$line" >> "$out/raw-$arm.txt"
                fi
            done
            j=$(( j + 1 ))
        done
        stop
        echo "round $round of {{ ROUNDS }} done at $(date +%T)"
    done
    # Only the rows, and of each row only its throughput, for benchstat.
    files=()
    for arm in "${arms[@]}"; do
        [ -s "$out/raw-$arm.txt" ] || continue
        awk -F'\t' '/^Benchmark/ { print $1 "\t" $2 "\t" $4 }' "$out/raw-$arm.txt" > "$out/$arm.txt"
        files+=("$arm=$out/$arm.txt")
    done
    benchstat "${files[@]}" > "$out/benchstat.txt"
    echo "benchstat: $out/benchstat.txt"
    echo
    just bench-summary "$out" | tee "$out/summary.txt"

[doc("Summarize a bench-compare run in DIR: per operation and image size, this package's geomean throughput against each arm's, and each row's ratio with its interval into DIR/rows.txt")]
[group("bench")]
bench-summary DIR="zig-out/bench-compare":
    #!/usr/bin/env bash
    set -euo pipefail
    files=()
    for arm in image $(grep -v '^#' bench/c/arms.tsv | cut -f1) {{ rust_arms }} go; do
        [ -s "{{ DIR }}/$arm.txt" ] && files+=("{{ DIR }}/$arm.txt")
    done
    : > "{{ DIR }}/rows.txt"
    awk -v rows="{{ DIR }}/rows.txt" -f bench/summary.awk "${files[@]}"

[doc("Everything CI runs")]
[group("ci")]
ci: test test-be lint fuzz-ci oracle-ci

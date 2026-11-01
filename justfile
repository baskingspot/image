# image: Image decoders and encoders in Zig with no C: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and more. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md docs/slop .github"

[private]
default:
    @just --list

[doc("Unit tests, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig build.zig.zon
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Everything CI runs")]
[group("ci")]
ci: test lint

// The C arms' shared harness (bench/README.md): each arm is arm.c plus the
// files that register its operations, `bench/c/<arm>-*.c`, one per format
// or family. A file registers its functions with `BENCH_OP` at load time,
// so adding one touches no table.
#ifndef BENCH_ARM_H
#define BENCH_ARM_H

#include <stddef.h>
#include <stdint.h>

// One call of an operation: decode or convert `in` into `out`, which holds
// `out_cap` bytes (the operation's output bytes per pixel, from
// bench/ops.tsv, times the input's pixels). Returns the bytes written, or 0
// on failure. Called out of line, as a library is.
typedef size_t (*bench_fn)(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap);

void bench_register(const char *op, bench_fn fn);

// Called before anything else; an arm written in another language defines
// it to call bench_register.
void bench_init(void);

// Set while `check` runs: an arm whose library returns its own buffer
// copies it to `out` only then, so timed calls do not pay for a copy.
extern int bench_checking;

// The input's width and height, from the `-WxH` that ends its name, set
// before any call on it. An encode row's input is raw pixels, tightly
// packed and nothing else; its bytes per pixel are its length over
// width times height.
extern uint32_t bench_width, bench_height;

#define BENCH_OP(name, fn)                                      \
  __attribute__((constructor)) static void register_##fn(void) { \
    bench_register(name, fn);                                   \
  }

#endif

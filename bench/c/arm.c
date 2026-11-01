// The C arms' main (bench/README.md, "Arm contract"):
//
//   bench-<arm> check [OP...]   one call per input: `<Row>/<input>\tlen=N fnv=H`
//   bench-<arm> bench [OP...]   each input timed for BENCHTIME_MS
//   bench-<arm> serve           `OP INPUT N` lines on stdin, a row each
//
// Run from the repository root. Every buffer is an anonymous mapping of its
// own, the input BENCH_IN_OFFSET bytes into its first page and the output
// BENCH_OUT_OFFSET bytes into its, both written before timing. An input the
// operation fails (returns 0 for) is `# SKIP <Row>/<input>: failed`, in
// place of its line, and is not timed.
#define _GNU_SOURCE
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#include "arm.h"

struct reg {
  const char *op;
  bench_fn fn;
};
int bench_checking;
static struct reg regs[256];
static int nregs;

void bench_register(const char *op, bench_fn fn) {
  regs[nregs].op = op;
  regs[nregs].fn = fn;
  nregs++;
}

struct opline {
  char name[64], row[64], dir[256];
  size_t out_bpp;
};
static struct opline ops[256];
static int nops;

static void load_ops(void) {
  FILE *f = fopen("bench/ops.tsv", "r");
  if (!f) {
    perror("bench/ops.tsv");
    exit(1);
  }
  char line[512];
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    struct opline *o = &ops[nops];
    char output[16];
    if (sscanf(line, "%63s %63s %255s %zu %15s", o->name, o->row, o->dir, &o->out_bpp, output) == 5) nops++;
  }
  fclose(f);
  for (int i = 0; i < nregs; i++) {
    int found = 0;
    for (int j = 0; j < nops; j++) found |= strcmp(regs[i].op, ops[j].name) == 0;
    if (!found) {
      fprintf(stderr, "arm: %s is not in bench/ops.tsv\n", regs[i].op);
      exit(1);
    }
  }
}

static const struct opline *find_op(const char *name) {
  for (int j = 0; j < nops; j++)
    if (strcmp(ops[j].name, name) == 0) return &ops[j];
  return NULL;
}

static bench_fn find_fn(const char *name) {
  for (int i = 0; i < nregs; i++)
    if (strcmp(regs[i].op, name) == 0) return regs[i].fn;
  return NULL;
}

static size_t env_size(const char *name, size_t dflt) {
  const char *v = getenv(name);
  return v ? strtoull(v, NULL, 10) : dflt;
}

static uint8_t *map(size_t len, size_t offset) {
  size_t total = (len + offset + 4095) / 4096 * 4096;
  uint8_t *p = mmap(NULL, total ? total : 4096, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) {
    perror("mmap");
    exit(1);
  }
  // Every page, so no timed call faults one in.
  memset(p, 0x55, total);
  return p + offset;
}

static void unmap(uint8_t *p, size_t len, size_t offset) {
  size_t total = (len + offset + 4095) / 4096 * 4096;
  munmap(p - offset, total ? total : 4096);
}

// An input's pixels, from its name: `<anything>-<W>x<H>.<ext>`.
static size_t pixels_of(const char *name) {
  const char *dash = strrchr(name, '-');
  unsigned long w, h;
  if (!dash || sscanf(dash + 1, "%lux%lu", &w, &h) != 2) {
    fprintf(stderr, "arm: input %s has no -WxH in its name\n", name);
    exit(1);
  }
  return (size_t)w * h;
}

// The loaded input: the last one asked for stays.
static char cur_path[512];
static uint8_t *in_buf, *out_buf;
static size_t in_len, out_cap;
static const size_t page = 4096;

static void load(const struct opline *o, const char *input) {
  char path[512];
  snprintf(path, sizeof path, "bench/corpus-gen/%s/%s", o->dir, input);
  size_t cap = o->out_bpp * pixels_of(input) + 64;
  if (strcmp(path, cur_path) == 0 && cap == out_cap) return;
  if (in_buf) unmap(in_buf, in_len, env_size("BENCH_IN_OFFSET", 0));
  if (out_buf) unmap(out_buf, out_cap, env_size("BENCH_OUT_OFFSET", 2048));
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  in_len = ftell(f);
  fseek(f, 0, SEEK_SET);
  in_buf = map(in_len, env_size("BENCH_IN_OFFSET", 0));
  if (fread(in_buf, 1, in_len, f) != in_len) {
    perror(path);
    exit(1);
  }
  fclose(f);
  out_cap = cap;
  out_buf = map(out_cap, env_size("BENCH_OUT_OFFSET", 2048));
  snprintf(cur_path, sizeof cur_path, "%s", path);
  (void)page;
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + ts.tv_nsec;
}

static uint64_t fnv(const uint8_t *p, size_t n) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ull;
  return h;
}

// N calls, or as many as fill BENCHTIME_MS when N is 0, grown as Go's
// testing.B grows them. Returns the calls made and sets *ns to their total
// time.
static uint64_t timed(bench_fn fn, uint64_t n, uint64_t *ns) {
  volatile size_t sink = 0;
  if (n) {
    uint64_t t = now_ns();
    for (uint64_t i = 0; i < n; i++) {
      __asm__ volatile("" : : "r"(in_buf) : "memory");
      sink = fn(in_buf, in_len, out_buf, out_cap);
    }
    *ns = now_ns() - t;
    return n;
  }
  uint64_t target = env_size("BENCHTIME_MS", 100) * 1000000u;
  n = 1;
  for (;;) {
    uint64_t t = now_ns();
    for (uint64_t i = 0; i < n; i++) {
      __asm__ volatile("" : : "r"(in_buf) : "memory");
      sink = fn(in_buf, in_len, out_buf, out_cap);
    }
    *ns = now_ns() - t;
    if (*ns >= target || n >= 1000000000u) break;
    uint64_t next = *ns ? n * target / *ns * 6 / 5 : n * 100;
    if (next > n * 100) next = n * 100;
    n = next > n ? next : n + 1;
  }
  (void)sink;
  return n;
}

static void skip(const char *prefix, const struct opline *o, const char *input) {
  printf("# SKIP %s%s/%s: failed\n", prefix, o->row, input);
  fflush(stdout);
}

static void row(const struct opline *o, const char *input, uint64_t n) {
  bench_fn fn = find_fn(o->name);
  load(o, input);
  // One untimed call, which must succeed.
  if (!fn(in_buf, in_len, out_buf, out_cap)) {
    skip("Benchmark", o, input);
    return;
  }
  uint64_t ns = 0;
  n = timed(fn, n, &ns);
  double per = (double)ns / n;
  printf("Benchmark%s/%s\t%llu\t%.1f ns/op\t%.2f MP/s\n", o->row, input, (unsigned long long)n, per,
         pixels_of(input) / per * 1000.0);
  fflush(stdout);
}

static int by_name(const struct dirent **a, const struct dirent **b) {
  return strverscmp((*a)->d_name, (*b)->d_name);
}

static void each_input(const struct opline *o, int check, uint64_t n) {
  char dir[512];
  snprintf(dir, sizeof dir, "bench/corpus-gen/%s", o->dir);
  struct dirent **list;
  int count = scandir(dir, &list, NULL, by_name);
  if (count < 0) {
    perror(dir);
    exit(1);
  }
  for (int i = 0; i < count; i++) {
    const char *name = list[i]->d_name;
    if (name[0] == '.') continue;
    if (check) {
      load(o, name);
      size_t len = find_fn(o->name)(in_buf, in_len, out_buf, out_cap);
      if (len)
        printf("%s/%s\tlen=%zu fnv=%016llx\n", o->row, name, len,
               (unsigned long long)fnv(out_buf, len));
      else
        skip("", o, name);
    } else {
      row(o, name, n);
    }
    free(list[i]);
  }
  free(list);
}

// An arm built outside C (Zig, Rust) defines bench_init to register its
// operations, and compiles this file with -DBENCH_EXTERNAL_INIT.
#ifndef BENCH_EXTERNAL_INIT
void bench_init(void) {}
#endif

int main(int argc, char **argv) {
  bench_init();
  load_ops();
  if (argc < 2) {
    fprintf(stderr, "usage: %s check|bench|serve [OP...]\n", argv[0]);
    return 2;
  }
  if (strcmp(argv[1], "serve") == 0) {
    char op[64], input[256];
    unsigned long long n;
    while (scanf("%63s %255s %llu", op, input, &n) == 3) {
      const struct opline *o = find_op(op);
      if (!o || !find_fn(op)) {
        printf("# SKIP %s\n", op);
        fflush(stdout);
        continue;
      }
      row(o, input, n);
    }
    return 0;
  }
  int check = strcmp(argv[1], "check") == 0;
  bench_checking = check;
  for (int j = 0; j < nops; j++) {
    int wanted = argc == 2;
    for (int a = 2; a < argc; a++) wanted |= strcmp(argv[a], ops[j].name) == 0;
    if (!wanted) continue;
    if (!find_fn(ops[j].name)) {
      printf("# SKIP Benchmark%s: no function in this arm\n", ops[j].row);
      continue;
    }
    each_input(&ops[j], check, 0);
  }
  return 0;
}

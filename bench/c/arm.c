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
//
// An operation marked `rotate=<op>` in bench/ops.tsv calls <op>'s function
// and has a row per input size instead of per input, `rotate<N>-<W>x<H>`,
// whose calls take its N inputs of that size in turn, so no one file's
// branches are learned; `check` reports their outputs' lengths and hashes
// summed.
#define _GNU_SOURCE
#include <dirent.h>
#include <inttypes.h>
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
uint32_t bench_width, bench_height;
static struct reg regs[256];
static int nregs;

void bench_register(const char *op, bench_fn fn) {
  regs[nregs].op = op;
  regs[nregs].fn = fn;
  nregs++;
}

struct opline {
  // `fn` is the registered function's operation: `name`, or the one a
  // rotating operation names.
  char name[64], row[64], dir[256], fn[64];
  size_t out_bpp;
  int rotate;
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
    char output[16], inputs[64] = "";
    int n = sscanf(line, "%63s %63s %255s %zu %15s %63s", o->name, o->row, o->dir, &o->out_bpp, output,
                   inputs);
    if (n < 5) continue;
    o->rotate = strncmp(inputs, "rotate=", 7) == 0;
    snprintf(o->fn, sizeof o->fn, "%s", o->rotate ? inputs + 7 : o->name);
    nops++;
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

static bench_fn find_fn(const struct opline *o) {
  for (int i = 0; i < nregs; i++)
    if (strcmp(regs[i].op, o->fn) == 0) return regs[i].fn;
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

// An input's size, from its name: `<anything>-<W>x<H>.<ext>`.
static void size_of(const char *name, uint32_t *w, uint32_t *h) {
  const char *dash = strrchr(name, '-');
  if (!dash || sscanf(dash + 1, "%" SCNu32 "x%" SCNu32, w, h) != 2) {
    fprintf(stderr, "arm: input %s has no -WxH in its name\n", name);
    exit(1);
  }
}

static size_t pixels_of(const char *name) {
  uint32_t w, h;
  size_of(name, &w, &h);
  return (size_t)w * h;
}

static int by_name(const struct dirent **a, const struct dirent **b) {
  return strverscmp((*a)->d_name, (*b)->d_name);
}

// The operation's input files, by name in version order; free with
// free_inputs.
static int list_inputs(const struct opline *o, struct dirent ***list) {
  char dir[512];
  snprintf(dir, sizeof dir, "bench/corpus-gen/%s", o->dir);
  int count = scandir(dir, list, NULL, by_name);
  if (count < 0) {
    perror(dir);
    exit(1);
  }
  int n = 0;
  for (int i = 0; i < count; i++) {
    if ((*list)[i]->d_name[0] == '.')
      free((*list)[i]);
    else
      (*list)[n++] = (*list)[i];
  }
  return n;
}

static void free_inputs(struct dirent **list, int n) {
  for (int i = 0; i < n; i++) free(list[i]);
  free(list);
}

// The loaded inputs, the last row asked for: one file, or a rotating row's
// files, each in its own mapping, and one output buffer.
#define MAX_INPUTS 1024
static char cur_key[600];
static struct {
  uint8_t *buf;
  size_t len;
} in[MAX_INPUTS];
static int nin;
static uint8_t *out_buf;
static size_t out_cap;

static void load_file(const struct opline *o, const char *name) {
  char path[512];
  snprintf(path, sizeof path, "bench/corpus-gen/%s/%s", o->dir, name);
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  size_t len = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *buf = map(len, env_size("BENCH_IN_OFFSET", 0));
  if (fread(buf, 1, len, f) != len) {
    perror(path);
    exit(1);
  }
  fclose(f);
  if (nin == MAX_INPUTS) {
    fprintf(stderr, "arm: more than %d inputs in a row\n", MAX_INPUTS);
    exit(1);
  }
  in[nin].buf = buf;
  in[nin].len = len;
  nin++;
}

// Loads row `input` of `o`: the file, or for a rotating operation every
// file of the size `input` ends in.
static void load(const struct opline *o, const char *input) {
  char key[600];
  snprintf(key, sizeof key, "%s/%s", o->dir, input);
  size_t cap = o->out_bpp * pixels_of(input) + 64;
  if (strcmp(key, cur_key) == 0 && cap == out_cap) return;
  for (int i = 0; i < nin; i++) unmap(in[i].buf, in[i].len, env_size("BENCH_IN_OFFSET", 0));
  nin = 0;
  if (out_buf) unmap(out_buf, out_cap, env_size("BENCH_OUT_OFFSET", 2048));
  size_of(input, &bench_width, &bench_height);
  if (o->rotate) {
    struct dirent **list;
    int n = list_inputs(o, &list);
    for (int i = 0; i < n; i++) {
      uint32_t w, h;
      size_of(list[i]->d_name, &w, &h);
      if (w == bench_width && h == bench_height) load_file(o, list[i]->d_name);
    }
    free_inputs(list, n);
  } else {
    load_file(o, input);
  }
  out_cap = cap;
  out_buf = map(out_cap, env_size("BENCH_OUT_OFFSET", 2048));
  snprintf(cur_key, sizeof cur_key, "%s", key);
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + ts.tv_nsec;
}

static uint64_t fnv(uint64_t h, const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ull;
  return h;
}

// N calls, or as many as fill BENCHTIME_MS when N is 0, grown as Go's
// testing.B grows them, each on the next loaded input. Returns the calls
// made and sets *ns to their total time.
static uint64_t timed(bench_fn fn, uint64_t n, uint64_t *ns) {
  volatile size_t sink = 0;
  int k = 0;
  uint64_t target = env_size("BENCHTIME_MS", 100) * 1000000u;
  uint64_t calls = n ? n : 1;
  for (;;) {
    uint64_t t = now_ns();
    for (uint64_t i = 0; i < calls; i++) {
      __asm__ volatile("" : : "r"(in[k].buf) : "memory");
      sink = fn(in[k].buf, in[k].len, out_buf, out_cap);
      k = k + 1 == nin ? 0 : k + 1;
    }
    *ns = now_ns() - t;
    if (n || *ns >= target || calls >= 1000000000u) break;
    uint64_t next = *ns ? calls * target / *ns * 6 / 5 : calls * 100;
    if (next > calls * 100) next = calls * 100;
    calls = next > calls ? next : calls + 1;
  }
  (void)sink;
  return calls;
}

static void skip(const char *prefix, const struct opline *o, const char *input) {
  printf("# SKIP %s%s/%s: failed\n", prefix, o->row, input);
  fflush(stdout);
}

// One untimed call on every loaded input: the bytes they wrote, in all,
// and the sum of their outputs' FNV-1a hashes, which is the same in any
// order; or 0 when one fails.
static size_t first_calls(bench_fn fn, uint64_t *hash) {
  size_t total = 0;
  *hash = 0;
  for (int k = 0; k < nin; k++) {
    size_t len = fn(in[k].buf, in[k].len, out_buf, out_cap);
    if (!len) return 0;
    *hash += fnv(0xcbf29ce484222325ull, out_buf, len);
    total += len;
  }
  return total;
}

static void row(const struct opline *o, const char *input, uint64_t n) {
  bench_fn fn = find_fn(o);
  load(o, input);
  uint64_t hash;
  if (!first_calls(fn, &hash)) {
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

// The operation's rows: its inputs, or for a rotating operation one name
// per input size, `rotate<N>-<W>x<H>`, in the order the sizes first appear.
static int row_names(const struct opline *o, char (*names)[256], int max) {
  struct dirent **list;
  int n = list_inputs(o, &list), rows = 0;
  for (int i = 0; i < n && rows < max; i++) {
    if (!o->rotate) {
      snprintf(names[rows++], 256, "%s", list[i]->d_name);
      continue;
    }
    uint32_t w, h, w2, h2;
    size_of(list[i]->d_name, &w, &h);
    int count = 0, seen = 0;
    for (int j = 0; j < n; j++) {
      size_of(list[j]->d_name, &w2, &h2);
      if (w2 == w && h2 == h) {
        seen |= j < i;
        count++;
      }
    }
    if (!seen) snprintf(names[rows++], 256, "rotate%d-%" PRIu32 "x%" PRIu32, count, w, h);
  }
  free_inputs(list, n);
  return rows;
}

static void each_row(const struct opline *o, int check, uint64_t n) {
  static char names[MAX_INPUTS][256];
  int rows = row_names(o, names, MAX_INPUTS);
  for (int i = 0; i < rows; i++) {
    if (!check) {
      row(o, names[i], n);
      continue;
    }
    load(o, names[i]);
    uint64_t hash;
    size_t len = first_calls(find_fn(o), &hash);
    if (len)
      printf("%s/%s\tlen=%zu fnv=%016llx\n", o->row, names[i], len, (unsigned long long)hash);
    else
      skip("", o, names[i]);
  }
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
      if (!o || !find_fn(o)) {
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
    if (!find_fn(&ops[j])) {
      printf("# SKIP Benchmark%s: no function in this arm\n", ops[j].row);
      continue;
    }
    each_row(&ops[j], check, 0);
  }
  return 0;
}

// The Go arm (bench/README.md): Go's image packages under the harness
// contract bench/c/arm.c implements, written again in Go because a cgo call
// per operation would cost more than decoding an icon. Each file beside this
// one registers one format's operations from init with register.
//
//	bench-go check [OP...]   one call per input: `<Row>/<input>\tlen=N fnv=H`
//	bench-go bench [OP...]   each input timed for BENCHTIME_MS
//	bench-go serve           `OP INPUT N` lines on stdin, a row each
//
// An input the operation fails (returns 0 for) is `# SKIP <Row>/<input>:
// failed`, in place of its line, and is not timed. A rotating operation
// (`rotate=<op>` in bench/ops.tsv) has a row per input size whose calls take
// its inputs of that size in turn, as arm.c's do. inWidth and inHeight are
// the input's size, from its name.
package main

import (
	"bufio"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// An operation writes out from in and returns the bytes written, or 0.
type opFunc func(in, out []byte) int

var funcs = map[string]opFunc{}

func register(op string, f opFunc) { funcs[op] = f }

type opLine struct {
	// fn is the registered function's operation: name, or the one a
	// rotating operation names.
	name, row, dir, fn string
	outBpp             int
	rotate             bool
}

var ops []opLine

func loadOps() {
	data, err := os.ReadFile("bench/ops.tsv")
	if err != nil {
		fail(err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 5 || strings.HasPrefix(line, "#") {
			continue
		}
		bpp, _ := strconv.Atoi(f[3])
		o := opLine{name: f[0], row: f[1], dir: f[2], fn: f[0], outBpp: bpp}
		if len(f) > 5 && strings.HasPrefix(f[5], "rotate=") {
			o.rotate, o.fn = true, strings.TrimPrefix(f[5], "rotate=")
		}
		ops = append(ops, o)
	}
	for name := range funcs {
		if findOp(name) == nil {
			fail(fmt.Errorf("%s is not in bench/ops.tsv", name))
		}
	}
}

func findOp(name string) *opLine {
	for i := range ops {
		if ops[i].name == name {
			return &ops[i]
		}
	}
	return nil
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "bench-go:", err)
	os.Exit(1)
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return v
	}
	return def
}

// An anonymous mapping of its own, every page written, with the buffer
// offset bytes into its first page, as arm.c places them.
func mapBuf(n, offset int) []byte {
	total := (n + offset + 4095) / 4096 * 4096
	if total == 0 {
		total = 4096
	}
	m, err := syscall.Mmap(-1, 0, total, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
	if err != nil {
		fail(err)
	}
	for i := range m {
		m[i] = 0x55
	}
	return m[offset : offset+n]
}

func sizeOf(name string) (int, int) {
	dash := strings.LastIndex(name, "-")
	var w, h int
	if dash < 0 {
		fail(fmt.Errorf("input %s has no -WxH in its name", name))
	}
	if _, err := fmt.Sscanf(name[dash+1:], "%dx%d", &w, &h); err != nil {
		fail(fmt.Errorf("input %s has no -WxH in its name", name))
	}
	return w, h
}

func pixelsOf(name string) int {
	w, h := sizeOf(name)
	return w * h
}

// The operation's input files, by name.
func inputs(o *opLine) []string {
	entries, err := os.ReadDir(filepath.Join("bench/corpus-gen", o.dir))
	if err != nil {
		fail(err)
	}
	var names []string
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

var curKey string
var ins [][]byte
var out []byte
var inWidth, inHeight int

// load loads row input of o: the file, or for a rotating operation every
// file of the size input ends in.
func load(o *opLine, input string) {
	key := filepath.Join(o.dir, input)
	outCap := o.outBpp*pixelsOf(input) + 64
	if key == curKey && len(out) == outCap {
		return
	}
	inWidth, inHeight = sizeOf(input)
	names := []string{input}
	if o.rotate {
		names = nil
		for _, name := range inputs(o) {
			if w, h := sizeOf(name); w == inWidth && h == inHeight {
				names = append(names, name)
			}
		}
	}
	ins = nil
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join("bench/corpus-gen", o.dir, name))
		if err != nil {
			fail(err)
		}
		in := mapBuf(len(data), envInt("BENCH_IN_OFFSET", 0))
		copy(in, data)
		ins = append(ins, in)
	}
	out = mapBuf(outCap, envInt("BENCH_OUT_OFFSET", 2048))
	curKey = key
}

var sink int

// n calls, or as many as fill BENCHTIME_MS when n is 0, grown as
// testing.B grows them, each on the next loaded input.
func timed(f opFunc, n int) (int, time.Duration) {
	k := 0
	run := func(calls int) time.Duration {
		t := time.Now()
		for i := 0; i < calls; i++ {
			sink = f(ins[k], out)
			if k++; k == len(ins) {
				k = 0
			}
		}
		return time.Since(t)
	}
	if n > 0 {
		return n, run(n)
	}
	target := time.Duration(envInt("BENCHTIME_MS", 100)) * time.Millisecond
	for n = 1; ; {
		d := run(n)
		if d >= target || n >= 1e9 {
			return n, d
		}
		next := n * 100
		if d > 0 {
			next = int(int64(n) * int64(target) / int64(d) * 6 / 5)
		}
		next = min(next, n*100)
		n = max(next, n+1)
	}
}

// skip reports an input the operation failed, in place of its line.
func skip(prefix string, o *opLine, input string) {
	fmt.Printf("# SKIP %s%s/%s: failed\n", prefix, o.row, input)
}

// firstCalls makes one untimed call on every loaded input and returns the
// bytes they wrote, in all, and the sum of their outputs' FNV-1a hashes;
// or 0 when one fails.
func firstCalls(f opFunc) (int, uint64) {
	total, sum := 0, uint64(0)
	for _, in := range ins {
		n := f(in, out)
		if n == 0 {
			return 0, 0
		}
		h := fnv.New64a()
		h.Write(out[:n])
		sum += h.Sum64()
		total += n
	}
	return total, sum
}

func row(o *opLine, input string, n int) {
	load(o, input)
	if total, _ := firstCalls(funcs[o.fn]); total == 0 {
		skip("Benchmark", o, input)
		return
	}
	n, d := timed(funcs[o.fn], n)
	per := float64(d.Nanoseconds()) / float64(n)
	fmt.Printf("Benchmark%s/%s\t%d\t%.1f ns/op\t%.2f MP/s\n", o.row, input, n, per, float64(pixelsOf(input))/per*1000)
}

// rowNames returns the operation's rows: its inputs, or for a rotating
// operation one name per input size, rotate<N>-<W>x<H>.
func rowNames(o *opLine) []string {
	names := inputs(o)
	if !o.rotate {
		return names
	}
	var rows []string
	count := map[[2]int]int{}
	for _, name := range names {
		w, h := sizeOf(name)
		count[[2]int{w, h}]++
	}
	for _, name := range names {
		w, h := sizeOf(name)
		if c := count[[2]int{w, h}]; c > 0 {
			rows = append(rows, fmt.Sprintf("rotate%d-%dx%d", c, w, h))
			count[[2]int{w, h}] = 0
		}
	}
	return rows
}

func eachRow(o *opLine, check bool) {
	for _, name := range rowNames(o) {
		if !check {
			row(o, name, 0)
			continue
		}
		load(o, name)
		n, h := firstCalls(funcs[o.fn])
		if n == 0 {
			skip("", o, name)
			continue
		}
		fmt.Printf("%s/%s\tlen=%d fnv=%016x\n", o.row, name, n, h)
	}
}

func main() {
	loadOps()
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: %s check|bench|serve [OP...]\n", os.Args[0])
		os.Exit(2)
	}
	if os.Args[1] == "serve" {
		sc := bufio.NewScanner(os.Stdin)
		for sc.Scan() {
			var op, input string
			var n int
			if _, err := fmt.Sscan(sc.Text(), &op, &input, &n); err != nil {
				continue
			}
			o := findOp(op)
			if o == nil || funcs[o.fn] == nil {
				fmt.Printf("# SKIP %s\n", op)
				continue
			}
			row(o, input, n)
		}
		return
	}
	check := os.Args[1] == "check"
	for i := range ops {
		o := &ops[i]
		wanted := len(os.Args) == 2
		for _, a := range os.Args[2:] {
			wanted = wanted || a == o.name
		}
		if !wanted {
			continue
		}
		if funcs[o.fn] == nil {
			fmt.Printf("# SKIP Benchmark%s: no function in this arm\n", o.row)
			continue
		}
		eachRow(o, check)
	}
}

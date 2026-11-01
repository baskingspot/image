// The Go arm (bench/README.md): Go's image packages under the harness
// contract bench/c/arm.c implements, written again in Go because a cgo call
// per operation would cost more than decoding an icon. Each file beside this
// one registers one format's operations from init with register.
//
//	bench-go check [OP...]   one call per input: `<Row>/<input>\tlen=N fnv=H`
//	bench-go bench [OP...]   each input timed for BENCHTIME_MS
//	bench-go serve           `OP INPUT N` lines on stdin, a row each
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
	name, row, dir string
	outBpp         int
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
		ops = append(ops, opLine{f[0], f[1], f[2], bpp})
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

func pixelsOf(name string) int {
	dash := strings.LastIndex(name, "-")
	var w, h int
	if dash < 0 {
		fail(fmt.Errorf("input %s has no -WxH in its name", name))
	}
	if _, err := fmt.Sscanf(name[dash+1:], "%dx%d", &w, &h); err != nil {
		fail(fmt.Errorf("input %s has no -WxH in its name", name))
	}
	return w * h
}

var curPath string
var in, out []byte

func load(o *opLine, input string) {
	path := filepath.Join("bench/corpus-gen", o.dir, input)
	outCap := o.outBpp*pixelsOf(input) + 64
	if path == curPath && len(out) == outCap {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	in = mapBuf(len(data), envInt("BENCH_IN_OFFSET", 0))
	copy(in, data)
	out = mapBuf(outCap, envInt("BENCH_OUT_OFFSET", 2048))
	curPath = path
}

var sink int

// n calls after one untimed call, or as many as fill BENCHTIME_MS when n
// is 0, grown as testing.B grows them.
func timed(f opFunc, n int) (int, time.Duration) {
	sink = f(in, out)
	if n > 0 {
		t := time.Now()
		for i := 0; i < n; i++ {
			sink = f(in, out)
		}
		return n, time.Since(t)
	}
	target := time.Duration(envInt("BENCHTIME_MS", 100)) * time.Millisecond
	for n = 1; ; {
		t := time.Now()
		for i := 0; i < n; i++ {
			sink = f(in, out)
		}
		d := time.Since(t)
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

func row(o *opLine, input string, n int) {
	load(o, input)
	n, d := timed(funcs[o.name], n)
	per := float64(d.Nanoseconds()) / float64(n)
	fmt.Printf("Benchmark%s/%s\t%d\t%.1f ns/op\t%.2f MP/s\n", o.row, input, n, per, float64(pixelsOf(input))/per*1000)
}

func eachInput(o *opLine, check bool) {
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
	for _, name := range names {
		if !check {
			row(o, name, 0)
			continue
		}
		load(o, name)
		n := funcs[o.name](in, out)
		h := fnv.New64a()
		h.Write(out[:n])
		fmt.Printf("%s/%s\tlen=%d fnv=%016x\n", o.row, name, n, h.Sum64())
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
			if o == nil || funcs[op] == nil {
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
		if funcs[o.name] == nil {
			fmt.Printf("# SKIP Benchmark%s: no function in this arm\n", o.row)
			continue
		}
		eachInput(o, check)
	}
}

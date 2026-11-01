// Go's image/color conversions on wuffs-probe.zig's kinds of input, written as
// <dir>/<src>-<dst>.in and .out in this package's pixel formats (16-bit
// samples little endian), for the Zig probe to compare with image.convert.
package main

import (
	"encoding/binary"
	"image"
	"image/color"
	"image/draw"
	"math/rand"
	"os"
	"path/filepath"
)

type pair struct {
	src, dst string
	in       func() []color.Color
	conv     func(color.Color) []byte
}

func le16(v uint16) []byte { return binary.LittleEndian.AppendUint16(nil, v) }

// Every (c, a) pair with colors c, 255-c, (91c+17)&255, and 1M random ones.
func nrgba8(premul bool) []color.Color {
	var out []color.Color
	for a := 0; a < 256; a++ {
		for c := 0; c < 256; c++ {
			r, g, b := uint8(c), uint8(255-c), uint8(c*91+17)
			if premul {
				out = append(out, color.RGBA{r, g, b, uint8(a)})
			} else {
				out = append(out, color.NRGBA{r, g, b, uint8(a)})
			}
		}
	}
	rnd := rand.New(rand.NewSource(1))
	for i := 0; i < 1<<20; i++ {
		v := rnd.Uint32()
		r, g, b, a := uint8(v), uint8(v>>8), uint8(v>>16), uint8(v>>24)
		if premul {
			out = append(out, color.RGBA{r, g, b, a})
		} else {
			out = append(out, color.NRGBA{r, g, b, a})
		}
	}
	return out
}

func rgb8() []color.Color {
	out := make([]color.Color, 0, 1<<24)
	for v := 0; v < 1<<24; v++ {
		out = append(out, color.RGBA{uint8(v), uint8(v >> 8), uint8(v >> 16), 255})
	}
	return out
}

// Every alpha with 16 random colors, and 1M random pixels.
func nrgba16(premul bool) []color.Color {
	rnd := rand.New(rand.NewSource(2))
	var out []color.Color
	add := func(r, g, b, a uint16) {
		if premul {
			out = append(out, color.RGBA64{r, g, b, a})
		} else {
			out = append(out, color.NRGBA64{r, g, b, a})
		}
	}
	for a := 0; a < 65536; a++ {
		for i := 0; i < 16; i++ {
			add(uint16(rnd.Uint32()), uint16(rnd.Uint32()), uint16(rnd.Uint32()), uint16(a))
		}
	}
	for i := 0; i < 1<<20; i++ {
		add(uint16(rnd.Uint32()), uint16(rnd.Uint32()), uint16(rnd.Uint32()), uint16(rnd.Uint32()))
	}
	return out
}

func gray16() []color.Color {
	var out []color.Color
	for v := 0; v < 65536; v++ {
		out = append(out, color.Gray16{uint16(v)})
	}
	return out
}

// The source pixel's bytes in this package's format.
func srcBytes(c color.Color) []byte {
	switch c := c.(type) {
	case color.NRGBA:
		return []byte{c.R, c.G, c.B, c.A}
	case color.RGBA:
		return []byte{c.R, c.G, c.B, c.A}
	case color.NRGBA64:
		return append(append(append(le16(c.R), le16(c.G)...), le16(c.B)...), le16(c.A)...)
	case color.RGBA64:
		return append(append(append(le16(c.R), le16(c.G)...), le16(c.B)...), le16(c.A)...)
	case color.Gray16:
		return le16(c.Y)
	}
	panic("source")
}

func to(m color.Model) func(color.Color) []byte {
	return func(c color.Color) []byte {
		switch d := m.Convert(c).(type) {
		case color.NRGBA:
			return []byte{d.R, d.G, d.B, d.A}
		case color.RGBA:
			return []byte{d.R, d.G, d.B, d.A}
		case color.NRGBA64:
			return append(append(append(le16(d.R), le16(d.G)...), le16(d.B)...), le16(d.A)...)
		case color.RGBA64:
			return append(append(append(le16(d.R), le16(d.G)...), le16(d.B)...), le16(d.A)...)
		case color.Gray:
			return []byte{d.Y}
		case color.Gray16:
			return le16(d.Y)
		}
		panic("model")
	}
}

func main() {
	dir := os.Args[1]
	sources := map[string]func() []color.Color{
		"rgba8":         func() []color.Color { return nrgba8(false) },
		"rgba8_premul":  func() []color.Color { return nrgba8(true) },
		"rgb8":          rgb8,
		"rgba16":        func() []color.Color { return nrgba16(false) },
		"rgba16_premul": func() []color.Color { return nrgba16(true) },
		"gray16":        gray16,
	}
	models := map[string]color.Model{
		"rgba8": color.NRGBAModel, "rgba8_premul": color.RGBAModel,
		"rgba16": color.NRGBA64Model, "rgba16_premul": color.RGBA64Model,
		"gray8": color.GrayModel, "gray16": color.Gray16Model,
	}
	pairs := map[string][]string{
		"rgba8":         {"rgba8_premul", "rgba16", "rgba16_premul", "gray8", "gray16"},
		"rgba8_premul":  {"rgba8", "rgba16", "gray8"},
		"rgb8":          {"gray8"},
		"rgba16":        {"rgba8", "rgba8_premul", "rgba16_premul", "gray8", "gray16"},
		"rgba16_premul": {"rgba8", "rgba8_premul", "rgba16", "gray8"},
		"gray16":        {"gray8"},
	}
	for s, dsts := range pairs {
		in := sources[s]()
		var inb []byte
		for _, c := range in {
			if s == "rgb8" {
				inb = append(inb, srcBytes(c)[:3]...)
			} else {
				inb = append(inb, srcBytes(c)...)
			}
		}
		for _, d := range dsts {
			conv := to(models[d])
			var outb []byte
			for _, c := range in {
				outb = append(outb, conv(c)...)
			}
			write(dir, s, d, inb, outb)
		}
	}
	// draw.Draw's NRGBA to RGBA path (draw.Src), which the bench's Go arm
	// times, apart from color.RGBAModel.
	in := nrgba8(false)
	n := len(in)
	src := image.NewNRGBA(image.Rect(0, 0, n, 1))
	for i, c := range in {
		src.Set(i, 0, c)
	}
	dst := image.NewRGBA(image.Rect(0, 0, n, 1))
	draw.Draw(dst, dst.Rect, src, image.Point{}, draw.Src)
	write(dir, "rgba8", "rgba8_premul.draw", src.Pix, dst.Pix)
}

func write(dir, s, d string, in, out []byte) {
	base := filepath.Join(dir, s+"-"+d)
	if err := os.WriteFile(base+".in", in, 0o644); err != nil {
		panic(err)
	}
	if err := os.WriteFile(base+".out", out, 0o644); err != nil {
		panic(err)
	}
}

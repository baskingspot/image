// Go's image/gif into RGBA8. `gif-decode` is gif.Decode, the first frame,
// whose palette has the transparent index as transparent black;
// `gif-decode-anim` is gif.DecodeAll, played into the canvas with each
// frame's disposal applied before the next, since image/gif leaves
// compositing to its caller.
package main

import (
	"bytes"
	"image"
	"image/color"
	"image/gif"
)

// rgba is a palette as straight RGBA8, with a flag per entry for alpha 0.
func rgba(p color.Palette) ([][4]byte, []bool) {
	out := make([][4]byte, len(p))
	clear := make([]bool, len(p))
	for i, c := range p {
		n := color.NRGBAModel.Convert(c).(color.NRGBA)
		out[i] = [4]byte{n.R, n.G, n.B, n.A}
		clear[i] = n.A == 0
	}
	return out, clear
}

// drawFrame writes frame m into the canvas out, w pixels wide: every pixel when
// over is false, and only the opaque ones when it is true.
func drawFrame(out []byte, w int, m *image.Paletted, over bool) {
	pal, clear := rgba(m.Palette)
	b := m.Bounds()
	for y := b.Min.Y; y < b.Max.Y; y++ {
		row := m.Pix[(y-b.Min.Y)*m.Stride:]
		at := 4 * (y*w + b.Min.X)
		for x := 0; x < b.Dx(); x++ {
			k := row[x]
			if !over || !clear[k] {
				copy(out[at+4*x:at+4*x+4], pal[k][:])
			}
		}
	}
}

func init() {
	register("gif-decode", func(in, out []byte) int {
		img, err := gif.Decode(bytes.NewReader(in))
		if err != nil {
			return 0
		}
		m, ok := img.(*image.Paletted)
		b := img.Bounds()
		n := 4 * b.Dx() * b.Dy()
		if !ok || n > len(out) || b.Min != (image.Point{}) {
			return 0
		}
		drawFrame(out, b.Dx(), m, false)
		return n
	})
	var saved []byte
	register("gif-decode-anim", func(in, out []byte) int {
		g, err := gif.DecodeAll(bytes.NewReader(in))
		if err != nil {
			return 0
		}
		w, h := g.Config.Width, g.Config.Height
		n := 4 * w * h
		if n > len(out) {
			return 0
		}
		canvas := out[:n]
		for i, m := range g.Image {
			b := m.Bounds()
			if i == 0 && b != image.Rect(0, 0, w, h) {
				clear(canvas)
			}
			if i > 0 {
				p := g.Image[i-1].Bounds()
				for y := p.Min.Y; y < p.Max.Y; y++ {
					row := canvas[4*(y*w+p.Min.X) : 4*(y*w+p.Max.X)]
					switch g.Disposal[i-1] {
					case gif.DisposalBackground:
						clear(row)
					case gif.DisposalPrevious:
						copy(row, saved[(y-p.Min.Y)*4*p.Dx():])
					}
				}
			}
			if g.Disposal[i] == gif.DisposalPrevious {
				saved = saved[:0]
				for y := b.Min.Y; y < b.Max.Y; y++ {
					saved = append(saved, canvas[4*(y*w+b.Min.X):4*(y*w+b.Max.X)]...)
				}
			}
			drawFrame(canvas, w, m, i > 0)
		}
		return n
	})
}

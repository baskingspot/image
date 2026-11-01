// golang.org/x/image/bmp: decode to straight RGBA, and encode square raw
// RGBA (as NRGBA, so 32-bit with alpha) and gray (8-bit with a gray
// table) pixels. It reads no RLE, and Go has no RGB image to encode from.
package main

import (
	"bytes"
	"errors"
	"image"
	"image/color"

	"golang.org/x/image/bmp"
)

func init() {
	register("bmp-decode", bmpDecode)
	register("bmp-encode-rgba", func(in, out []byte) int {
		s := side(len(in) / 4)
		return bmpEncode(out, &image.NRGBA{Pix: in, Stride: 4 * s, Rect: image.Rect(0, 0, s, s)})
	})
	register("bmp-encode-gray", func(in, out []byte) int {
		s := side(len(in))
		return bmpEncode(out, &image.Gray{Pix: in, Stride: s, Rect: image.Rect(0, 0, s, s)})
	})
}

func bmpDecode(in, out []byte) int {
	img, err := bmp.Decode(bytes.NewReader(in))
	if err != nil {
		return 0
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if 4*w*h > len(out) {
		return 0
	}
	switch m := img.(type) {
	case *image.NRGBA:
		for y := 0; y < h; y++ {
			copy(out[4*w*y:4*w*(y+1)], m.Pix[m.Stride*y:])
		}
	case *image.RGBA:
		// Opaque, so premultiplied is straight.
		for y := 0; y < h; y++ {
			copy(out[4*w*y:4*w*(y+1)], m.Pix[m.Stride*y:])
		}
	case *image.Paletted:
		var lut [256][4]byte
		for i, c := range m.Palette {
			n := color.NRGBAModel.Convert(c).(color.NRGBA)
			lut[i] = [4]byte{n.R, n.G, n.B, n.A}
		}
		for y := 0; y < h; y++ {
			row := m.Pix[m.Stride*y:]
			for x := 0; x < w; x++ {
				copy(out[4*(w*y+x):], lut[row[x]][:])
			}
		}
	default:
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				n := color.NRGBAModel.Convert(img.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
				copy(out[4*(w*y+x):], []byte{n.R, n.G, n.B, n.A})
			}
		}
	}
	return 4 * w * h
}

// A writer into the caller's buffer.
type sliceWriter struct {
	out []byte
	n   int
}

var errFull = errors.New("output buffer full")

func (s *sliceWriter) Write(p []byte) (int, error) {
	if s.n+len(p) > len(s.out) {
		return 0, errFull
	}
	copy(s.out[s.n:], p)
	s.n += len(p)
	return len(p), nil
}

func bmpEncode(out []byte, img image.Image) int {
	w := &sliceWriter{out: out}
	if bmp.Encode(w, img) != nil {
		return 0
	}
	return w.n
}

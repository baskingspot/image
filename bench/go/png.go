// Go's image/png into RGBA8: a copy for NRGBA images, and for the other
// models a conversion to straight RGBA pixel by pixel, since image/draw
// would premultiply.
package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
)

func init() {
	register("png-decode", func(in, out []byte) int {
		img, err := png.Decode(bytes.NewReader(in))
		if err != nil {
			return 0
		}
		b := img.Bounds()
		w, h := b.Dx(), b.Dy()
		n := 4 * w * h
		if n > len(out) {
			return 0
		}
		if m, ok := img.(*image.NRGBA); ok && m.Stride == 4*w {
			copy(out, m.Pix[:n])
			return n
		}
		i := 0
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				c := color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
				out[i], out[i+1], out[i+2], out[i+3] = c.R, c.G, c.B, c.A
				i += 4
			}
		}
		return n
	})
}

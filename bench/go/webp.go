// golang.org/x/image/webp into RGBA8: a copy for NRGBA images (lossless,
// or lossy with alpha), and for lossy images without alpha, whose YCbCr
// image Go converts with its own rounding, a conversion pixel by pixel.
package main

import (
	"bytes"
	"image"
	"image/color"

	"golang.org/x/image/webp"
)

func init() {
	register("webp-decode-lossless", webpDecode)
	register("webp-decode-lossless-large", webpDecode)
	register("webp-decode-lossy", webpDecode)
}

func webpDecode(in, out []byte) int {
	img, err := webp.Decode(bytes.NewReader(in))
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
}

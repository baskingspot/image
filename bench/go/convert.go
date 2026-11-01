// The conversion rows Go's image/draw has: NRGBA to RGBA (premultiplied)
// and Gray to RGBA, over square images (the raw inputs are square).
package main

import (
	"image"
	"image/draw"
	"math"
)

func init() {
	register("convert-rgba8-premul", func(in, out []byte) int {
		s := side(len(in) / 4)
		src := &image.NRGBA{Pix: in, Stride: 4 * s, Rect: image.Rect(0, 0, s, s)}
		return drawTo(out, s, src)
	})
	register("convert-gray8-rgba8", func(in, out []byte) int {
		s := side(len(in))
		src := &image.Gray{Pix: in, Stride: s, Rect: image.Rect(0, 0, s, s)}
		return drawTo(out, s, src)
	})
}

func side(pixels int) int { return int(math.Sqrt(float64(pixels))) }

func drawTo(out []byte, s int, src image.Image) int {
	dst := &image.RGBA{Pix: out[:4*s*s], Stride: 4 * s, Rect: image.Rect(0, 0, s, s)}
	draw.Draw(dst, dst.Rect, src, image.Point{}, draw.Src)
	return 4 * s * s
}

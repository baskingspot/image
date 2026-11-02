// The conversion rows Go's image/draw has: NRGBA to RGBA (premultiplied)
// and Gray to RGBA, over raw pixels at the input's size.
package main

import (
	"image"
	"image/draw"
)

func init() {
	register("convert-rgba8-premul", func(in, out []byte) int {
		if len(in) != 4*inWidth*inHeight {
			return 0
		}
		return drawTo(out, &image.NRGBA{Pix: in, Stride: 4 * inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)})
	})
	register("convert-gray8-rgba8", func(in, out []byte) int {
		if len(in) != inWidth*inHeight {
			return 0
		}
		return drawTo(out, &image.Gray{Pix: in, Stride: inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)})
	})
}

func drawTo(out []byte, src image.Image) int {
	n := 4 * inWidth * inHeight
	dst := &image.RGBA{Pix: out[:n], Stride: 4 * inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)}
	draw.Draw(dst, dst.Rect, src, image.Point{}, draw.Src)
	return n
}

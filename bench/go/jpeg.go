// Go's image/jpeg into RGB8: YCbCr images through color.YCbCrToRGB,
// grayscale replicated, and CMYK through its color model, pixel by pixel.
package main

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
)

func decodeJPEG(in, out []byte) int {
	img, err := jpeg.Decode(bytes.NewReader(in))
	if err != nil {
		return 0
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	n := 3 * w * h
	if n > len(out) {
		return 0
	}
	i := 0
	switch m := img.(type) {
	case *image.YCbCr:
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				yi, ci := m.YOffset(x, y), m.COffset(x, y)
				out[i], out[i+1], out[i+2] = color.YCbCrToRGB(m.Y[yi], m.Cb[ci], m.Cr[ci])
				i += 3
			}
		}
	case *image.Gray:
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for _, v := range m.Pix[m.PixOffset(b.Min.X, y):][:w] {
				out[i], out[i+1], out[i+2] = v, v, v
				i += 3
			}
		}
	default:
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				c := color.RGBAModel.Convert(img.At(x, y)).(color.RGBA)
				out[i], out[i+1], out[i+2] = c.R, c.G, c.B
				i += 3
			}
		}
	}
	return n
}

func init() {
	register("jpeg-decode", decodeJPEG)
	register("jpeg-decode-progressive", decodeJPEG)
	register("jpeg-decode-444", decodeJPEG)
	register("jpeg-decode-cmyk", decodeJPEG)
}

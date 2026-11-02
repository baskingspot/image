// Go's image/jpeg into RGB8: YCbCr images through color.YCbCrToRGB,
// grayscale replicated, and CMYK through its color model, pixel by pixel.
// Its encoder at quality 85: raw RGB copied into an image.RGBA first, the
// type its fast path takes (it always subsamples to 4:2:0), and gray as an
// image.Gray over the input.
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
	register("jpeg-encode", func(in, out []byte) int {
		n := inWidth * inHeight
		if len(in) != 3*n {
			return 0
		}
		if cap(jpegRGBA) < 4*n {
			jpegRGBA = make([]byte, 4*n)
		}
		px := jpegRGBA[:4*n]
		for i := 0; i < n; i++ {
			px[4*i], px[4*i+1], px[4*i+2], px[4*i+3] = in[3*i], in[3*i+1], in[3*i+2], 255
		}
		return encodeJPEG(out, &image.RGBA{Pix: px, Stride: 4 * inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)})
	})
	register("jpeg-encode-gray", func(in, out []byte) int {
		if len(in) != inWidth*inHeight {
			return 0
		}
		return encodeJPEG(out, &image.Gray{Pix: in, Stride: inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)})
	})
}

// The RGBA copy of the encode rows' input, kept between calls.
var jpegRGBA []byte

func encodeJPEG(out []byte, img image.Image) int {
	w := &sliceWriter{out: out}
	if jpeg.Encode(w, img, &jpeg.Options{Quality: 85}) != nil {
		return 0
	}
	return w.n
}

// golang.org/x/image/tiff to straight RGBA: a copy for its RGBA images
// (every input is opaque, so premultiplied is straight), a gray expansion
// for bilevel and gray, and a conversion pixel by pixel for the rest.
package main

import (
	"bytes"
	"image"
	"image/color"

	"golang.org/x/image/tiff"
)

func init() {
	for _, op := range []string{"none", "lzw", "deflate", "packbits", "g4"} {
		register("tiff-decode-"+op, tiffDecode)
	}
}

func tiffDecode(in, out []byte) int {
	img, err := tiff.Decode(bytes.NewReader(in))
	if err != nil {
		return 0
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if 4*w*h > len(out) {
		return 0
	}
	switch m := img.(type) {
	case *image.RGBA:
		for y := 0; y < h; y++ {
			copy(out[4*w*y:4*w*(y+1)], m.Pix[m.Stride*y:])
		}
	case *image.Gray:
		for y := 0; y < h; y++ {
			row := m.Pix[m.Stride*y:]
			o := out[4*w*y:]
			for x := 0; x < w; x++ {
				v := row[x]
				o[4*x], o[4*x+1], o[4*x+2], o[4*x+3] = v, v, v, 0xff
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

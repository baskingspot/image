// golang.org/x/image/tiff encoding raw RGBA as NRGBA: uncompressed, and
// Deflate, which it writes without a predictor (it takes one only for LZW,
// which it does not write). Go has no RGB image type, so it skips the RGB
// inputs.
package main

import (
	"image"

	"golang.org/x/image/tiff"
)

func init() {
	register("tiff-encode-none", func(in, out []byte) int { return tiffEncode(in, out, tiff.Uncompressed) })
	register("tiff-encode-deflate", func(in, out []byte) int { return tiffEncode(in, out, tiff.Deflate) })
}

func tiffEncode(in, out []byte, c tiff.CompressionType) int {
	if len(in) != 4*inWidth*inHeight {
		return 0
	}
	img := &image.NRGBA{Pix: in, Stride: 4 * inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)}
	w := &sliceWriter{out: out}
	if tiff.Encode(w, img, &tiff.Options{Compression: c}) != nil {
		return 0
	}
	return w.n
}

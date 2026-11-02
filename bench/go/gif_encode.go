// Go's image/gif encoder: raw RGBA8 (bench/corpus/gif_encode.sh) to a
// file in memory. `gif-encode` is gif.Encode with its defaults, which
// quantizes to the Plan 9 palette with Floyd-Steinberg dithering whatever
// the image holds; `gif-encode-few` builds the image's own palette (alpha
// below 128 as one transparent color), as a caller with at most 256 colors
// does, and fails an image with more; `gif-encode-anim` is gif.EncodeAll
// of every whole canvas drawn into the Plan 9 palette with
// Floyd-Steinberg, 10 hundredths of a second each, looping forever. Go
// neither crops nor writes transparency for the drawn frames.
package main

import (
	"bytes"
	"image"
	"image/color"
	"image/color/palette"
	"image/draw"
	"image/gif"
)

// rgbaImage wraps the input as straight-alpha pixels.
func rgbaImage(in []byte) *image.NRGBA {
	return &image.NRGBA{Pix: in, Stride: 4 * inWidth, Rect: image.Rect(0, 0, inWidth, inHeight)}
}

// written copies the encoder's file into out, or returns 0 when it fails
// or does not fit.
func written(buf *bytes.Buffer, err error, out []byte) int {
	if err != nil || buf.Len() > len(out) {
		return 0
	}
	return copy(out, buf.Bytes())
}

func init() {
	register("gif-encode", func(in, out []byte) int {
		if len(in) != 4*inWidth*inHeight {
			return 0
		}
		var buf bytes.Buffer
		err := gif.Encode(&buf, rgbaImage(in), nil)
		return written(&buf, err, out)
	})
	register("gif-encode-few", func(in, out []byte) int {
		if len(in) != 4*inWidth*inHeight {
			return 0
		}
		index := map[uint32]uint8{}
		var pal color.Palette
		p := image.NewPaletted(image.Rect(0, 0, inWidth, inHeight), nil)
		for i := 0; i < inWidth*inHeight; i++ {
			px := in[4*i : 4*i+4]
			key := uint32(1 << 24)
			c := color.NRGBA{}
			if px[3] >= 128 {
				key = uint32(px[0])<<16 | uint32(px[1])<<8 | uint32(px[2])
				c = color.NRGBA{px[0], px[1], px[2], 255}
			}
			k, ok := index[key]
			if !ok {
				if len(pal) == 256 {
					return 0
				}
				k = uint8(len(pal))
				index[key] = k
				pal = append(pal, c)
			}
			p.Pix[i] = k
		}
		p.Palette = pal
		var buf bytes.Buffer
		err := gif.Encode(&buf, p, nil)
		return written(&buf, err, out)
	})
	register("gif-encode-anim", func(in, out []byte) int {
		canvas := 4 * inWidth * inHeight
		if canvas == 0 || len(in)%canvas != 0 {
			return 0
		}
		g := &gif.GIF{}
		r := image.Rect(0, 0, inWidth, inHeight)
		for at := 0; at < len(in); at += canvas {
			p := image.NewPaletted(r, palette.Plan9)
			src := &image.NRGBA{Pix: in[at : at+canvas], Stride: 4 * inWidth, Rect: r}
			draw.FloydSteinberg.Draw(p, r, src, image.Point{})
			g.Image = append(g.Image, p)
			g.Delay = append(g.Delay, 10)
		}
		var buf bytes.Buffer
		err := gif.EncodeAll(&buf, g)
		return written(&buf, err, out)
	})
}

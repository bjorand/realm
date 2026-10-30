package main

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"strings"

	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	tileW, tileH = 32, 16
	recolorFrom  = 33 // TUNIC: people's tunic, recolored per person
)

// screen is an 8-bit picture in store colors, like the video card's: bit 7
// marks a shaded dot.
type screen struct {
	w, h int
	px   []byte
}

func newScreen(w, h int, bg byte) *screen {
	s := &screen{w, h, make([]byte, w*h)}
	for i := range s.px {
		s.px[i] = bg
	}
	return s
}

// blit draws sp with its top left at (left, top), as isodraw::blit does.
func (s *screen) blit(sp *Sprite, left, top int, flip bool, to byte) {
	for y := 0; y < sp.H; y++ {
		for x := 0; x < sp.W; x++ {
			sx, sy := left+x, top+y
			if sx < 0 || sy < 0 || sx >= s.w || sy >= s.h {
				continue
			}
			c := sp.Px[y*sp.W+x]
			if flip {
				c = sp.Px[y*sp.W+sp.W-1-x]
			}
			o := &s.px[sy*s.w+sx]
			switch {
			case c == clear:
			case c == shadow:
				*o |= 128
			default:
				if to != 0 && (c == recolorFrom || c == recolorFrom+1) {
					c = to + (c - recolorFrom)
				}
				*o = c
			}
		}
	}
}

func (s *screen) blitFoot(sp *Sprite, fx, fy int, flip bool, to byte) {
	ax := sp.AX
	if flip {
		ax = sp.W - 1 - sp.AX
	}
	s.blit(sp, fx-ax, fy-sp.AY, flip, to)
}

func toRGBA(pal []uint16, c byte) color.RGBA {
	v := pal[c&127]
	if c >= 128 {
		v = (v >> 1) & 0x7BEF
	}
	r, g, b := rgb888(v)
	return color.RGBA{r, g, b, 255}
}

// image scales the screen up by k.
func (s *screen) image(pal []uint16, k int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, s.w*k, s.h*k))
	for y := 0; y < s.h; y++ {
		for x := 0; x < s.w; x++ {
			c := toRGBA(pal, s.px[y*s.w+x])
			draw.Draw(img, image.Rect(x*k, y*k, x*k+k, y*k+k), &image.Uniform{c}, image.Point{}, draw.Src)
		}
	}
	return img
}

func label(img *image.RGBA, x, y int, text string, c color.Color) {
	d := font.Drawer{Dst: img, Src: image.NewUniform(c), Face: basicfont.Face7x13,
		Dot: fixed.P(x, y)}
	d.DrawString(text)
}

// tunics stands in for the game's iso.color calls: a few tunics to show
// recolored people.
var tunics = []uint32{0x2f7fd0, 0x6e6a64, 0x2a2a2e, 0xd8d4cc, 0x3f8a4a, 0xa83232}

func withTunics(pal []uint16) []uint16 {
	out := append([]uint16(nil), pal...)
	for i, t := range tunics {
		r, g, b := uint8(t>>16), uint8(t>>8), uint8(t)
		out[firstTunic+2*i] = rgb565(r, g, b)
		out[firstTunic+2*i+1] = rgb565(r/2+8, g/2+4, b/2+8)
	}
	return out
}

func find(sprites []*Sprite, name string) *Sprite {
	for _, s := range sprites {
		if s.Name == name {
			return s
		}
	}
	return nil
}

// Sheet draws every sprite at 3x on a ground tile, with its name and size.
func Sheet(pal []uint16, sprites []*Sprite, bg byte) *image.RGBA {
	const k, cellW, cols = 3, 92, 8
	rowH := 0
	var rows [][]*Sprite
	for i, s := range sprites {
		if i%cols == 0 {
			rows = append(rows, nil)
		}
		rows[len(rows)-1] = append(rows[len(rows)-1], s)
	}
	heights := make([]int, len(rows))
	for i, r := range rows {
		for _, s := range r {
			heights[i] = max(heights[i], s.H+tileH)
		}
		rowH += heights[i]*k + 34
	}
	pal = withTunics(pal)
	img := image.NewRGBA(image.Rect(0, 0, cols*cellW*k/2, rowH+8))
	draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{24, 28, 26, 255}}, image.Point{}, draw.Src)
	y := 4
	for i, r := range rows {
		h := heights[i]
		for j, s := range r {
			sc := newScreen(cellW/2, h, bg)
			fx, fy := sc.w/2, h-tileH/2
			if s.Kind == "ground" {
				sc.blit(s, fx-tileW/2, fy-tileH/2, false, 0)
			} else {
				if g := find(sprites, "grass/0"); g != nil {
					sc.blit(g, fx-tileW/2, fy-tileH/2, false, 0)
				}
				to := byte(0)
				if s.Kind == "person" {
					to = firstTunic + 2*byte(j%len(tunics))
				}
				sc.blitFoot(s, fx, fy, false, to)
			}
			x := j * cellW * k / 2
			draw.Draw(img, image.Rect(x, y, x+sc.w*k, y+h*k), sc.image(pal, k), image.Point{}, draw.Src)
			label(img, x+2, y+h*k+12, s.Name, color.RGBA{230, 230, 220, 255})
			label(img, x+2, y+h*k+25, fmt.Sprintf("%dx%d %dB", s.W, s.H, s.W*s.H), color.RGBA{120, 200, 150, 255})
		}
		y += h*k + 34
	}
	return img
}

// Scene draws a small village corner the way the video card would: ground,
// then objects and people back to front, so new sprites can be judged in
// place. Every object and person of the library appears in it.
func Scene(pal []uint16, sprites []*Sprite) *image.RGBA {
	const n = 14
	ground := make([]string, n*n)
	object := make([]string, n*n)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			g := fmt.Sprintf("grass/%d", (x*7+y*3)%3)
			switch {
			case x == 6 || x == 7:
				g = fmt.Sprintf("dirt/%d", (x+y)%3)
			case x >= 9 && y >= 9:
				g = fmt.Sprintf("stone/%d", (x+y)%3)
			case y == 0 && x < 4:
				g = fmt.Sprintf("water/%d", x%3)
			case y == 1 && x < 4:
				g = fmt.Sprintf("sand/%d", x%3)
			}
			ground[y*n+x] = g
		}
	}
	// Objects on the free tiles, two apart, people beside them.
	type actor struct {
		s      *Sprite
		x, y   int
		flip   bool
		tunic  byte
		frames int
	}
	var actors []actor
	slots := [][2]int{}
	for y := 2; y < n; y += 2 {
		for x := 1; x < n; x += 2 {
			if x != 7 {
				slots = append(slots, [2]int{x, y})
			}
		}
	}
	i := 0
	for _, s := range sprites {
		if s.Kind == "ground" || i >= len(slots) {
			continue
		}
		p := slots[i]
		i++
		if s.Kind == "object" {
			object[p[1]*n+p[0]] = s.Name
		} else {
			actors = append(actors, actor{s: s, x: p[0], y: p[1], flip: i%2 == 0,
				tunic: firstTunic + 2*byte(i%len(tunics))})
		}
	}
	const hw, hh = tileW / 2, tileH / 2
	camX, camY := -(n-1)*hw-8, -40
	sc := newScreen(n*tileW+16, n*tileH+80, 9)
	for d := 0; d <= 2*n-2; d++ {
		for x := 0; x < n; x++ {
			y := d - x
			if y < 0 || y >= n {
				continue
			}
			if s := find(sprites, ground[y*n+x]); s != nil {
				sc.blit(s, (x-y)*hw-camX, d*hh-camY, false, 0)
			}
		}
	}
	for d := 0; d <= 2*n-2; d++ {
		fy := d*hh + hh - camY
		for x := 0; x < n; x++ {
			y := d - x
			if y < 0 || y >= n {
				continue
			}
			fx := (2*x-d)*hw + hw - camX
			if s := find(sprites, object[y*n+x]); s != nil {
				sc.blitFoot(s, fx, fy, false, 0)
			}
			for _, a := range actors {
				if a.x == x && a.y == y {
					sc.blitFoot(a.s, fx, fy, a.flip, a.tunic)
				}
			}
		}
	}
	img := sc.image(withTunics(pal), 2)
	var names []string
	for _, a := range actors {
		names = append(names, a.s.Name)
	}
	label(img, 6, 16, "people: "+strings.Join(names, " "), color.RGBA{240, 240, 230, 255})
	return img
}

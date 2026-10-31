package main

import "fmt"

// The grounds and the wall, drawn for tw x th tiles (realm: 32x32).

var groundKinds = []string{"water", "sand", "grass", "stone", "dirt"}

// diamondHalf is the half width of row r of a tw x th ground diamond.
func diamondHalf(r, tw, th int) int {
	hw, hh := tw/2, th/2
	if r < hh {
		return (r + 1) * hw / hh
	}
	return (th - r) * hw / hh
}

// groundSprite draws ground g, variant v, as the first realm generator did
// (termina 2823598, makeGround), on a tw x th diamond.
func groundSprite(p *Palette, g, v, tw, th int) *Sprite {
	c := &canvas{&Sprite{Name: fmt.Sprintf("%s/%d", groundKinds[g], v), Kind: "ground",
		W: tw, H: th, Px: make([]byte, tw*th)}, p}
	k := float64(tw) / float64(th) // the diamond's sides: k dots across per line
	rnd := func(x, y, s int) float64 { return float64(hash3u(x, y, s)&0xFFFF) / 65535 }
	for y := 0; y < th; y++ {
		half := diamondHalf(y, tw, th)
		for x := tw/2 - half; x < tw/2+half; x++ {
			n := rnd(x, y, 100+v*7+g*31)
			col := ""
			switch groundKinds[g] {
			case "grass":
				col = "grass0"
				if n >= .85 {
					col = "grass2"
				} else if n >= .55 {
					col = "grass1"
				}
				if v == 2 && n > .985 {
					col = "flower_y"
					if x&1 == 1 {
						col = "flower_r"
					}
				}
			case "sand":
				col = "sand0"
				if n >= .7 {
					col = "sand1"
				}
			case "water":
				// Short horizontal ripples.
				col = "water0"
				if rnd((x+v*5)/6, y, 300+v) > .82 {
					col = "water1"
				}
				if n > .97 {
					col = "water2"
				}
			case "dirt":
				col = "dirt0"
				if n >= .6 {
					col = "dirt1"
				}
			case "stone":
				// Paving stones on a grid that follows the diamond's sides.
				ky := int(k * float64(y))
				u, w := (x+ky+v*3)%12, (ky-x+64+v*5)%12
				col = "stone0"
				switch {
				case u == 0 || w == 0:
					col = "stone1"
				case n >= .8:
					col = "stone2"
				}
			}
			c.s.Px[y*tw+x] = c.col(col)
		}
	}
	return c.s
}

// wallSprite is a cube of masonry on its tile, as makeWall drew it: a lit
// top, a mid left face and a dark right face, wh dots high.
func wallSprite(p *Palette, tw, th, wh int) *Sprite {
	hw, hh := tw/2, th/2
	c := &canvas{&Sprite{Name: "wall", Kind: "object", W: tw, H: th + wh, AX: hw, AY: wh + hh,
		Px: make([]byte, tw*(th+wh))}, p}
	set := func(x, y int, col string) {
		if x >= 0 && y >= 0 && x < c.s.W && y < c.s.H {
			c.s.Px[y*c.s.W+x] = c.col(col)
		}
	}
	for y := 0; y < th; y++ {
		half := diamondHalf(y, tw, th)
		for x := hw - half; x < hw+half; x++ {
			col := "wall_top"
			if float64(hash3u(x, y, 700)&0xFFFF)/65535 > .9 {
				col = "wall_l"
			}
			set(x, y, col)
		}
	}
	for x := 0; x < tw; x++ {
		left := x < hw
		// Top edge of the face: from the side corner down to the front corner.
		y0 := th - int(float64(x-hw)*float64(th)/float64(tw))
		if left {
			y0 = hh + int(float64(x)*float64(th)/float64(tw))
		}
		for dy := 0; dy < wh; dy++ {
			course := (dy + 3) / 7
			across := tw - x
			if left {
				across = x
			}
			col := "wall_r"
			switch {
			case (dy+3)%7 == 0 || (across+course*6)%12 == 0:
				col = "mortar"
			case left:
				col = "wall_l"
			}
			set(x, y0+dy, col)
		}
	}
	return c.s
}

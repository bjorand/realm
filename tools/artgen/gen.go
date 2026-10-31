package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// Procedural sprites: props shaded like the trees and walls of the first
// realm.art (light from the top left, a dot per pixel). `artgen gen`
// writes them as text sources, which can then be retouched by hand (drop
// them from gens first, or the next gen overwrites them).

// canvas draws around a foot point; coordinates are relative to it.
type canvas struct {
	s *Sprite
	p *Palette
}

func newCanvas(p *Palette, name string) *canvas {
	const w, h = 96, 96
	return &canvas{&Sprite{Name: name, Kind: "object", W: w, H: h, AX: w / 2, AY: h * 3 / 4,
		Px: make([]byte, w*h)}, p}
}

func (c *canvas) col(name string) byte {
	col := c.p.byName[name]
	if col == nil {
		panic("no color " + name)
	}
	return byte(col.Index)
}

func (c *canvas) set(x, y int, name string) {
	x, y = x+c.s.AX, y+c.s.AY
	if x >= 0 && y >= 0 && x < c.s.W && y < c.s.H {
		c.s.Px[y*c.s.W+x] = c.col(name)
	}
}

func (c *canvas) get(x, y int) byte {
	x, y = x+c.s.AX, y+c.s.AY
	if x < 0 || y < 0 || x >= c.s.W || y >= c.s.H {
		return clear
	}
	return c.s.Px[y*c.s.W+x]
}

// shade darkens the ground in an ellipse where nothing is drawn yet.
func (c *canvas) shade(cx, cy, rx, ry int) {
	for y := -ry; y <= ry; y++ {
		for x := -rx; x <= rx; x++ {
			if x*x*ry*ry+y*y*rx*rx <= rx*rx*ry*ry && c.get(cx+x, cy+y) == clear {
				c.s.Px[(cy+y+c.s.AY)*c.s.W+cx+x+c.s.AX] = shadow
			}
		}
	}
}

func noise2(x, y, seed int) float64 { return float64(uint32(hash3u(x, y, seed))&0xFFFF) / 65535 }

func hash3u(x, y, s int) uint32 {
	h := uint32(int32(x))*374761393 + uint32(int32(y))*668265263 + uint32(int32(s))*2246822519
	h = (h ^ (h >> 13)) * 1274126177
	return h ^ (h >> 16)
}

// box is a block on a diamond footprint of half width a (half height a/2),
// from height z0 to z0+h. The faces get (u, v): u across the face from its
// back corner, v up from its bottom edge.
func (c *canvas) box(a, z0, h int, top, left, right func(u, v int) string) {
	for y := -a/2 - z0 - h - 1; y <= a/2-z0+1; y++ {
		for x := -a; x < a; x++ {
			fx := float64(x) + .5
			in := func(z int) bool {
				return math.Abs(fx)/float64(a)+math.Abs(float64(y+z))/(float64(a)/2) <= 1
			}
			if in(z0 + h) {
				c.set(x, y, top(x+a, y+z0+h+a/2))
				continue
			}
			hit := false
			for z := z0; z <= z0+h; z++ {
				if in(z) {
					hit = true
					break
				}
			}
			if !hit {
				continue
			}
			if x < 0 {
				bottom := (x+a)/2 - z0
				c.set(x, y, left(x+a, bottom-y))
			} else {
				bottom := (a-x)/2 - z0
				c.set(x, y, right(x, bottom-y))
			}
		}
	}
}

// cylinder stands on an ellipse of radius r (r/2 deep), from z0 to z0+h.
// side gets the light (-1 dark right, 1 lit left) and the height; top the
// distance from the center (0-1) and the dot.
func (c *canvas) cylinder(r, z0, h int, side func(l float64, x, v int) string, top func(d float64, x, y int) string) {
	ry := float64(r) / 2
	for y := -r - z0 - h; y <= r-z0; y++ {
		for x := -r; x <= r; x++ {
			fx := float64(x)
			at := func(z int) float64 {
				dy := float64(y + z)
				return fx*fx/float64(r*r) + dy*dy/(ry*ry)
			}
			if d := at(z0 + h); d <= 1 {
				c.set(x, y, top(math.Sqrt(d), x, y+z0+h))
				continue
			}
			for z := z0 + h; z >= z0; z-- {
				if at(z) <= 1 {
					c.set(x, y, side(-fx/float64(r), x, z-z0))
					break
				}
			}
		}
	}
}

type ball struct{ x, y, r float64 }

// canopy draws leafy balls lit from the top left with a dark rim, like the
// trees.
func (c *canvas) canopy(balls []ball, seed int, berries string) {
	for y := -60; y <= 10; y++ {
		for x := -30; x <= 30; x++ {
			best := -1.0
			for _, b := range balls {
				dx, dy := (float64(x)-b.x)/b.r, (float64(y)-b.y)/b.r
				if d := dx*dx + dy*dy; d <= 1 {
					best = math.Max(best, -.55*dx-.8*dy+(1-d)*.4)
				}
			}
			if best < -.9 {
				continue
			}
			l := best + noise2(x, y, seed)*.35
			col := "leaf_d"
			switch {
			case l > .75:
				col = "leaf2"
			case l > .25:
				col = "leaf1"
			case l > -.35:
				col = "leaf0"
			}
			if berries != "" && noise2(x, y, seed+1) > .93 && l > -.2 {
				col = berries
			}
			c.set(x, y, col)
		}
	}
	c.rim("leaf_d", "leaf0", "leaf1", "leaf2", berries)
}

// rim darkens the dots of the given colors that touch the air.
func (c *canvas) rim(dark string, of ...string) {
	want := map[byte]bool{}
	for _, n := range of {
		if n != "" {
			want[c.col(n)] = true
		}
	}
	var edge [][2]int
	for y := -c.s.AY; y < c.s.H-c.s.AY; y++ {
		for x := -c.s.AX; x < c.s.W-c.s.AX; x++ {
			if !want[c.get(x, y)] {
				continue
			}
			for _, d := range [][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
				if n := c.get(x+d[0], y+d[1]); n == clear || n == shadow {
					edge = append(edge, [2]int{x, y})
					break
				}
			}
		}
	}
	for _, e := range edge {
		c.set(e[0], e[1], dark)
	}
}

func woodGrain(u, v, seed int) string {
	if noise2(u, v/3, seed) > .85 {
		return "wood_d"
	}
	return "wood"
}

var gens = map[string]func(c *canvas){
	"bush/0": func(c *canvas) {
		c.canopy([]ball{{0, -8, 8}, {-7, -5, 6}, {7, -5, 6}, {-3, -13, 5}, {4, -12, 5}}, 810, "")
		c.shade(2, 0, 12, 4)
	},
	"bush/1": func(c *canvas) {
		c.canopy([]ball{{-1, -7, 7}, {6, -5, 5}, {-6, -4, 5}, {2, -11, 5}}, 820, "apple")
		c.shade(2, 0, 10, 3)
	},
	"flowers/0": func(c *canvas) {
		heads := []string{"flower_r", "flower_y", "flower_p", "flower_y", "flower_r", "text"}
		for i := 0; i < 16; i++ {
			x := int(noise2(i, 0, 830)*20) - 10
			y := int(noise2(i, 1, 830)*10) - 5
			if math.Abs(float64(x))/11+math.Abs(float64(y))/5.5 > 1 {
				continue
			}
			c.set(x, y, "leaf0")
			c.set(x, y-1, "leaf1")
			c.set(x, y-2, heads[i%len(heads)])
			if i%3 == 0 {
				c.set(x+1, y-2, heads[i%len(heads)])
			}
		}
	},
	"barrel": func(c *canvas) {
		const h = 14
		c.cylinder(6, 0, h, func(l float64, x, v int) string {
			switch {
			case v == 2 || v == h-3:
				return "metal_d"
			case (x+7)%3 == 0:
				return "wood_d"
			case l > .45:
				return "wood_l"
			case l > -.4:
				return "wood"
			}
			return "wood_d"
		}, func(d float64, x, y int) string {
			if d > .75 {
				return "wood_l"
			}
			if (x+8)%3 == 0 {
				return "wood_d"
			}
			return "wood"
		})
		c.shade(3, 1, 8, 3)
	},
	"crate": func(c *canvas) {
		const a, h = 9, 13
		// Planks framed by a border and a diagonal brace; the right face is
		// a shade darker than the left.
		face := func(base, frame string) func(u, v int) string {
			return func(u, v int) string {
				switch {
				case u <= 1 || u >= a-1 || v <= 1 || v >= h-1 || u == v || u == v+1:
					return frame
				case v%4 == 0:
					return frame
				}
				if base == "wood" {
					return woodGrain(u, v, 840)
				}
				return base
			}
		}
		c.box(a, 0, h, func(u, v int) string {
			if (u+2*v)%6 == 0 {
				return "wood"
			}
			return "wood_l"
		}, face("wood", "wood_d"), face("wood_d", "line"))
		c.shade(4, 2, 12, 4)
	},
	"chest": func(c *canvas) {
		const a, h = 8, 8
		side := func(base string) func(u, v int) string {
			return func(u, v int) string {
				switch {
				case v == 5:
					return "metal_d"
				case v >= 6:
					return "wood_l"
				case u <= 1:
					return "metal"
				}
				return base
			}
		}
		c.box(a, 0, h, func(u, v int) string {
			if v == a/2 || u == a {
				return "wood_d"
			}
			return "wood_l"
		}, side("wood"), side("wood_d"))
		c.set(-4, -3, "gold")
		c.set(-5, -3, "gold")
		c.set(-4, -2, "gold_d")
		c.set(-5, -2, "gold_d")
		c.shade(3, 2, 11, 4)
	},
	"well": func(c *canvas) {
		const r, h = 12, 9
		c.cylinder(r, 0, h, func(l float64, x, v int) string {
			course := v / 3
			if v%3 == 0 || (x+r+course*4)%7 == 0 {
				return "mortar"
			}
			if l < -.35 {
				return "stone1"
			}
			return "stone0"
		}, func(d float64, x, y int) string {
			if d > .72 {
				if d > .9 {
					return "stone1"
				}
				return "stone2"
			}
			return "water_in"
		})
		for _, px := range []int{-r + 1, r - 2} {
			for z := h - 2; z < h+20; z++ {
				c.set(px, -z, "wood")
				c.set(px+1, -z, "wood_d")
			}
		}
		for x := -r - 1; x <= r; x++ {
			c.set(x, -h-20, "wood_l")
			c.set(x, -h-19, "wood_d")
		}
		// Gabled straw roof over the beam.
		for row := 0; row < 8; row++ {
			half := r + 3 - row*2
			for x := -half; x <= half; x++ {
				col := "straw"
				if row == 0 || (x+row)%4 == 0 {
					col = "straw_d"
				}
				c.set(x, -h-21-row, col)
			}
		}
		for z := h - 1; z < h+19; z++ {
			if z > h+10 {
				c.set(0, -z, "metal_d")
			}
		}
		c.set(-1, -h-10, "wood_d")
		c.set(0, -h-10, "wood_d")
		c.set(1, -h-10, "wood_d")
		c.set(0, -h-9, "wood_d")
		c.shade(4, 2, 16, 6)
	},
	"stall": func(c *canvas) {
		const a, h = 14, 10
		front := func(base string) func(u, v int) string {
			return func(u, v int) string {
				if v >= h-1 || u%5 == 0 {
					return "wood_d"
				}
				return base
			}
		}
		c.box(a, 0, h, func(u, v int) string {
			if (u+v)%7 == 0 {
				return "wood"
			}
			return "wood_l"
		}, front("wood"), front("wood_d"))
		// Goods on the counter: apples and coins.
		for i, g := range [][2]int{{-6, -h - 1}, {-4, -h - 2}, {-2, -h - 1}, {3, -h - 2}, {5, -h - 1}} {
			col := "apple"
			if i >= 3 {
				col = "gold"
			}
			c.set(g[0], g[1], col)
			c.set(g[0]+1, g[1], col)
		}
		for _, px := range []int{-a + 1, a - 2} {
			for z := 0; z < 32; z++ {
				c.set(px, -z, "wood")
				c.set(px+1, -z, "wood_d")
			}
		}
		// Striped awning, sloping toward the viewer, with a scalloped edge.
		for row := 0; row < 9; row++ {
			for x := -a - 1; x <= a+1; x++ {
				col := "cloth"
				if ((x+a+1)/3)%2 == 0 {
					col = "cloth_l"
				}
				if row == 0 {
					col = "line"
				}
				c.set(x, -40+row, col)
			}
		}
		for x := -a - 1; x <= a+1; x++ {
			if (x+a+1)%3 != 2 {
				col := "cloth"
				if ((x+a+1)/3)%2 == 0 {
					col = "cloth_l"
				}
				c.set(x, -31, col)
			}
		}
		c.shade(3, 2, 17, 6)
	},
	"sign": func(c *canvas) {
		for z := 0; z < 24; z++ {
			c.set(0, -z, "wood")
			c.set(1, -z, "wood_d")
		}
		for y := -27; y <= -18; y++ {
			for x := -7; x <= 8; x++ {
				col := "wood_l"
				switch {
				case y == -27 || y == -18 || x == -7 || x == 8:
					col = "wood_d"
				case (y == -24 || y == -21) && x > -5 && x < 6 && noise2(x, y, 850) > .25:
					col = "line"
				}
				c.set(x, y, col)
			}
		}
		c.shade(3, 1, 7, 2)
	},
	"fence/0": func(c *canvas) {
		// Along the map's x axis: down-right on the screen.
		for x := -15; x <= 15; x++ {
			y := x / 2
			for _, z := range []int{4, 10} {
				c.set(x, y-z, "wood_l")
				c.set(x, y-z+1, "wood_d")
			}
		}
		for _, px := range []int{-14, 0, 13} {
			y := px / 2
			for z := 0; z < 15; z++ {
				c.set(px, y-z, "wood")
				c.set(px+1, y-z, "wood_d")
			}
			c.set(px, y-15, "wood_l")
			c.shade(px+2, y+1, 2, 1)
		}
	},
}

// Gen writes the procedural sprites to dir.
func Gen(p *Palette, dir string) error {
	for name, f := range gens {
		c := newCanvas(p, name)
		f(c)
		c.s.crop()
		var b strings.Builder
		b.WriteString("# generated by artgen gen (tools/artgen/gen.go)\n")
		path := filepath.Join(dir, strings.ReplaceAll(name, "/", "-")+".txt")
		if err := WriteSprite(path, c.s, p); err != nil {
			return err
		}
		data, _ := os.ReadFile(path)
		if err := os.WriteFile(path, append([]byte(b.String()), data...), 0o644); err != nil {
			return err
		}
	}
	fmt.Printf("%s: %d generated sprites\n", dir, len(gens))
	return nil
}

// The bars of the F3 graph: people sprites 3 dots wide and 2 to 16 high
// with a dark outline,
// in the tunic colors so that each bar takes its own color, and a blank
// sprite that only carries a label.
func init() {
	for h := 2; h <= 16; h += 2 {
		gens[fmt.Sprintf("meter%d", h)] = func(c *canvas) {
			c.s.Kind = "person"
			for y := 0; y < h; y++ {
				c.set(-2, -y, "line")
				c.set(-1, -y, "tunic")
				c.set(0, -y, "tunic")
				c.set(1, -y, "tunic_d")
				c.set(2, -y, "line")
			}
			for x := -2; x <= 2; x++ {
				c.set(x, -h, "line") // dark outline: readable on any ground
			}
		}
	}
	gens["blank"] = func(c *canvas) {
		c.s.Kind = "person"
		c.set(0, 0, "line")
	}
}

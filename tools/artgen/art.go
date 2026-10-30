package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Layout of the video card's iso store (termina video/include/vlink.h).
const (
	storeSize  = 32768
	palOff     = 0
	spritesOff = 256
	maxSprites = 64
	mapOff     = spritesOff + 8*maxSprites
	maxTiles   = 4096
	pixelsOff  = mapOff + 2*maxTiles
	colors     = 128
	clear      = 0
	shadow     = 0xFF
	firstTunic = 64 // 64-127 are set at run time with iso.color
)

// Color is a palette entry, kept as the store keeps it: RGB565.
type Color struct {
	Index int
	Char  byte
	Name  string
	RGB   uint16
}

// Palette maps names and characters to the store's colors 1-63.
type Palette struct {
	Colors []Color
	byName map[string]*Color
	byChar map[byte]*Color
}

// Sprite is one picture: palette indexes, 0 clear, 0xFF shadow.
type Sprite struct {
	Name   string
	Kind   string // ground, object or person
	W, H   int
	AX, AY int // the dot standing on the foot point
	Px     []byte
}

func rgb565(r, g, b uint8) uint16 {
	return uint16(r>>3)<<11 | uint16(g>>2)<<5 | uint16(b>>3)
}

func rgb888(c uint16) (r, g, b uint8) {
	r5, g6, b5 := uint8(c>>11), uint8(c>>5&63), uint8(c&31)
	return r5<<3 | r5>>2, g6<<2 | g6>>4, b5<<3 | b5>>2
}

func (p *Palette) index() {
	p.byName, p.byChar = map[string]*Color{}, map[byte]*Color{}
	for i := range p.Colors {
		c := &p.Colors[i]
		p.byName[c.Name], p.byChar[c.Char] = c, c
	}
}

// ------------------------------------------------------------------ text files

// ReadPalette reads lines "index char name #rrggbb".
func ReadPalette(path string) (*Palette, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	p := &Palette{}
	seen, chars, names := map[int]bool{}, map[byte]bool{}, map[string]bool{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' {
			continue
		}
		var c Color
		var ch, hex string
		if _, err := fmt.Sscanf(line, "%d %s %s %s", &c.Index, &ch, &c.Name, &hex); err != nil || len(ch) != 1 || len(hex) != 7 {
			return nil, fmt.Errorf("%s:%d: want \"index char name #rrggbb\"", path, n)
		}
		v, err := strconv.ParseUint(hex[1:], 16, 32)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %v", path, n, err)
		}
		if c.Index < 1 || c.Index >= firstTunic || seen[c.Index] {
			return nil, fmt.Errorf("%s:%d: index %d taken or outside 1-%d", path, n, c.Index, firstTunic-1)
		}
		if ch == "." || ch == "%" {
			return nil, fmt.Errorf("%s:%d: . and %% mean clear and shadow", path, n)
		}
		if chars[ch[0]] || names[c.Name] {
			return nil, fmt.Errorf("%s:%d: character or name used twice", path, n)
		}
		seen[c.Index], chars[ch[0]], names[c.Name] = true, true, true
		c.Char, c.RGB = ch[0], rgb565(uint8(v>>16), uint8(v>>8), uint8(v))
		p.Colors = append(p.Colors, c)
	}
	p.index()
	return p, sc.Err()
}

// WritePalette writes the palette in index order.
func WritePalette(path string, p *Palette) error {
	var b strings.Builder
	b.WriteString("# realm palette: index char name #rrggbb (RGB565 once packed).\n")
	b.WriteString("# 0 is clear, 64-127 are the tunics set by the game, 128-255 the shades.\n")
	cs := append([]Color(nil), p.Colors...)
	sort.Slice(cs, func(i, j int) bool { return cs[i].Index < cs[j].Index })
	for _, c := range cs {
		r, g, bl := rgb888(c.RGB)
		fmt.Fprintf(&b, "%d %c %s #%02x%02x%02x\n", c.Index, c.Char, c.Name, r, g, bl)
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

// ReadSprite reads a sprite file: "key value" lines (name, kind, anchor,
// legend), a "---" line, then the rows. The legend maps characters to color
// names for this file ("legend o=line t=tunic"); other characters use the
// palette's own. "." is clear and "%" a shadow.
func ReadSprite(path string, p *Palette) (*Sprite, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s := &Sprite{Kind: "object"}
	legend := map[byte]byte{'.': clear, '%': shadow}
	scale, shade, hasShade := 1, [4]int{}, false
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	i := 0
	for ; i < len(lines) && strings.TrimSpace(lines[i]) != "---"; i++ {
		f := strings.Fields(lines[i])
		if len(f) == 0 || strings.HasPrefix(f[0], "#") {
			continue
		}
		bad := func() error { return fmt.Errorf("%s:%d: bad %s line", path, i+1, f[0]) }
		switch f[0] {
		case "name":
			if len(f) != 2 {
				return nil, bad()
			}
			s.Name = f[1]
		case "kind":
			if len(f) != 2 || (f[1] != "ground" && f[1] != "object" && f[1] != "person") {
				return nil, bad()
			}
			s.Kind = f[1]
		case "anchor":
			if len(f) != 3 {
				return nil, bad()
			}
			s.AX, _ = strconv.Atoi(f[1])
			s.AY, _ = strconv.Atoi(f[2])
		case "scale":
			if len(f) != 2 {
				return nil, bad()
			}
			scale, _ = strconv.Atoi(f[1])
			if scale < 1 || scale > 8 {
				return nil, bad()
			}
		case "shadow":
			if len(f) != 5 {
				return nil, bad()
			}
			for k := range shade {
				shade[k], _ = strconv.Atoi(f[k+1])
			}
			hasShade = true
		case "legend":
			for _, kv := range f[1:] {
				k, v, ok := strings.Cut(kv, "=")
				c := p.byName[v]
				if !ok || len(k) != 1 || c == nil {
					return nil, fmt.Errorf("%s:%d: legend %q: unknown color", path, i+1, kv)
				}
				legend[k[0]] = byte(c.Index)
			}
		default:
			return nil, bad()
		}
	}
	if s.Name == "" || i == len(lines) {
		return nil, fmt.Errorf("%s: needs a name and a --- line", path)
	}
	var rows []string
	for _, l := range lines[i+1:] {
		l = strings.TrimRight(l, " \t")
		if l != "" {
			rows = append(rows, l)
		}
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("%s: no pixels", path)
	}
	s.H = len(rows)
	for _, r := range rows {
		s.W = max(s.W, len(r))
	}
	s.Px = make([]byte, s.W*s.H)
	for y, r := range rows {
		for x := 0; x < len(r); x++ {
			ch := r[x]
			if v, ok := legend[ch]; ok {
				s.Px[y*s.W+x] = v
			} else if c := p.byChar[ch]; c != nil {
				s.Px[y*s.W+x] = byte(c.Index)
			} else {
				return nil, fmt.Errorf("%s: row %d: unknown character %q", path, y+1, ch)
			}
		}
	}
	if scale > 1 {
		s.scale(scale)
	}
	if hasShade {
		s.shadow(s.AX+shade[0], s.AY+shade[1], shade[2], shade[3])
	}
	if scale > 1 || hasShade {
		s.crop()
	}
	if s.W > 255 || s.H > 255 {
		return nil, fmt.Errorf("%s: %dx%d, at most 255x255", path, s.W, s.H)
	}
	return s, nil
}

// scale makes every dot k x k; the anchor is already in scaled dots.
func (s *Sprite) scale(k int) {
	px := make([]byte, s.W*k*s.H*k)
	for y := 0; y < s.H*k; y++ {
		for x := 0; x < s.W*k; x++ {
			px[y*s.W*k+x] = s.Px[(y/k)*s.W+x/k]
		}
	}
	s.W, s.H, s.Px = s.W*k, s.H*k, px
}

// shadow darkens an ellipse of the ground around (cx, cy) where nothing is
// drawn, growing the sprite if needed.
func (s *Sprite) shadow(cx, cy, rx, ry int) {
	s.grow(min(0, cx-rx), min(0, cy-ry), max(s.W, cx+rx+1), max(s.H, cy+ry+1))
	cx, cy = cx-min(0, cx-rx), cy-min(0, cy-ry)
	for y := -ry; y <= ry; y++ {
		for x := -rx; x <= rx; x++ {
			if x*x*ry*ry+y*y*rx*rx > rx*rx*ry*ry {
				continue
			}
			i := (cy+y)*s.W + cx + x
			if s.Px[i] == clear {
				s.Px[i] = shadow
			}
		}
	}
}

// grow makes the canvas cover [x0, x1) x [y0, y1) in current coordinates.
func (s *Sprite) grow(x0, y0, x1, y1 int) {
	w, h := x1-x0, y1-y0
	if x0 == 0 && y0 == 0 && w == s.W && h == s.H {
		return
	}
	px := make([]byte, w*h)
	for y := 0; y < s.H; y++ {
		copy(px[(y-y0)*w-x0:], s.Px[y*s.W:(y+1)*s.W])
	}
	s.W, s.H, s.Px = w, h, px
	s.AX, s.AY = s.AX-x0, s.AY-y0
}

// crop drops the clear border, keeping the foot point in place.
func (s *Sprite) crop() {
	x0, y0, x1, y1 := s.W, s.H, -1, -1
	for y := 0; y < s.H; y++ {
		for x := 0; x < s.W; x++ {
			if s.Px[y*s.W+x] != clear {
				x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
			}
		}
	}
	if x1 < 0 {
		return
	}
	w := x1 - x0 + 1
	px := make([]byte, 0, w*(y1-y0+1))
	for y := y0; y <= y1; y++ {
		px = append(px, s.Px[y*s.W+x0:y*s.W+x1+1]...)
	}
	s.W, s.H, s.Px = w, y1-y0+1, px
	s.AX, s.AY = s.AX-x0, s.AY-y0
}

// WriteSprite writes s with the palette's characters.
func WriteSprite(path string, s *Sprite, p *Palette) error {
	var b strings.Builder
	fmt.Fprintf(&b, "name %s\nkind %s\nanchor %d %d\n---\n", s.Name, s.Kind, s.AX, s.AY)
	byIndex := map[byte]byte{clear: '.', shadow: '%'}
	for _, c := range p.Colors {
		byIndex[byte(c.Index)] = c.Char
	}
	for y := 0; y < s.H; y++ {
		for x := 0; x < s.W; x++ {
			ch, ok := byIndex[s.Px[y*s.W+x]]
			if !ok {
				return fmt.Errorf("%s: color %d not in the palette", s.Name, s.Px[y*s.W+x])
			}
			b.WriteByte(ch)
		}
		b.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

// ReadSprites reads every *.txt of dir, sorted by name.
func ReadSprites(dir string, p *Palette) ([]*Sprite, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.txt"))
	if err != nil {
		return nil, err
	}
	var out []*Sprite
	seen := map[string]string{}
	for _, f := range files {
		s, err := ReadSprite(f, p)
		if err != nil {
			return nil, err
		}
		if prev, ok := seen[s.Name]; ok {
			return nil, fmt.Errorf("sprite %s in %s and %s", s.Name, prev, f)
		}
		seen[s.Name] = f
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// ------------------------------------------------------------------ store

func (p *Palette) store565() []byte {
	b := make([]byte, 2*colors)
	for _, c := range p.Colors {
		binary.LittleEndian.PutUint16(b[2*c.Index:], c.RGB)
	}
	return b
}

// PackStore lays sprites out as iso.load expects; the map is empty (0xFF).
func PackStore(p *Palette, sprites []*Sprite) ([]byte, error) {
	if len(sprites) > maxSprites {
		return nil, fmt.Errorf("%d sprites, the store holds %d", len(sprites), maxSprites)
	}
	out := make([]byte, pixelsOff, storeSize)
	copy(out[palOff:], p.store565())
	for i := mapOff; i < pixelsOff; i++ {
		out[i] = 0xFF
	}
	for i, s := range sprites {
		e := out[spritesOff+8*i:]
		e[0], e[1], e[2], e[3] = byte(s.W), byte(s.H), byte(s.AX), byte(s.AY)
		binary.LittleEndian.PutUint32(e[4:], uint32(len(out)))
		out = append(out, s.Px...)
	}
	if len(out) > storeSize {
		return nil, fmt.Errorf("%d bytes, the store holds %d", len(out), storeSize)
	}
	return out, nil
}

// UnpackStore reads the palette and sprites of a store (realm.art).
func UnpackStore(b []byte) ([]uint16, []*Sprite, error) {
	if len(b) < pixelsOff || len(b) > storeSize {
		return nil, nil, fmt.Errorf("%d bytes: not an iso store", len(b))
	}
	pal := make([]uint16, colors)
	for i := range pal {
		pal[i] = binary.LittleEndian.Uint16(b[palOff+2*i:])
	}
	var sprites []*Sprite
	for i := 0; i < maxSprites; i++ {
		e := b[spritesOff+8*i:]
		w, h := int(e[0]), int(e[1])
		if w == 0 {
			continue
		}
		off := int(binary.LittleEndian.Uint32(e[4:]))
		if off+w*h > len(b) {
			return nil, nil, fmt.Errorf("sprite %d outside the store", i)
		}
		sprites = append(sprites, &Sprite{Name: strconv.Itoa(i), Kind: "object", W: w, H: h,
			AX: int(e[2]), AY: int(e[3]), Px: append([]byte(nil), b[off:off+w*h]...)})
	}
	return pal, sprites, nil
}

// ------------------------------------------------------------------ RLE

// RLE encodes a sprite for the video card (vlink.h, VLINK_ISO_RLE): h + 1
// row offsets (u16 LE, from the start, the last one the end), then per row
// runs: n < 128 skips n + 1 clear dots, n >= 128 is followed by n - 127
// dots. Clear dots at the end of a row are not written. ok is false when
// it would not fit the u16 offsets.
func RLE(s *Sprite) (out []byte, ok bool) {
	out = make([]byte, 2*(s.H+1))
	for y := 0; y < s.H; y++ {
		binary.LittleEndian.PutUint16(out[2*y:], uint16(len(out)))
		row := s.Px[y*s.W : (y+1)*s.W]
		end := len(row)
		for end > 0 && row[end-1] == clear {
			end--
		}
		for x := 0; x < end; {
			if row[x] == clear {
				n := 0
				for x+n < end && row[x+n] == clear && n < 128 {
					n++
				}
				out = append(out, byte(n-1))
				x += n
				continue
			}
			n := 0
			for x+n < end && row[x+n] != clear && n < 128 {
				n++
			}
			out = append(out, byte(127+n))
			out = append(out, row[x:x+n]...)
			x += n
		}
		if len(out) > 0xFFFF {
			return nil, false
		}
	}
	binary.LittleEndian.PutUint16(out[2*s.H:], uint16(len(out)))
	return out, true
}

// UnRLE decodes what RLE wrote, as the video card reads it.
func UnRLE(b []byte, w, h int) []byte {
	px := make([]byte, w*h)
	end := int(binary.LittleEndian.Uint16(b[2*h:]))
	for y := 0; y < h; y++ {
		p, e := int(binary.LittleEndian.Uint16(b[2*y:])), int(binary.LittleEndian.Uint16(b[2*y+2:]))
		e = min(e, end)
		for i := 0; p < e && i < w; {
			n := int(b[p])
			p++
			if n < 128 {
				i += n + 1
				continue
			}
			for n -= 127; n > 0 && p < e && i < w; n, i, p = n-1, i+1, p+1 {
				px[y*w+i] = b[p]
			}
		}
	}
	return px
}

// The store of the V4 video card (termina, 2026-10-31): 48 KB, 128
// sprites, the second 64 after the map, raw or run-length pixels.
const (
	storeSize4  = 49152
	sprites64   = pixelsOff // the second table sits where pixels began
	pixelsOff4  = sprites64 + 8*64
	maxSprites4 = 128
	flagRLE     = 1
)

// noRLE keeps PackStore4 to raw pixels (artgen store4 -raw).
var noRLE bool

// PackStore4 lays sprites out for the V4 card, each in its shorter form.
func PackStore4(p *Palette, sprites []*Sprite) ([]byte, error) {
	if len(sprites) > maxSprites4 {
		return nil, fmt.Errorf("%d sprites, the store holds %d", len(sprites), maxSprites4)
	}
	out := make([]byte, pixelsOff4, storeSize4)
	copy(out[palOff:], p.store565())
	for i := mapOff; i < sprites64; i++ {
		out[i] = 0xFF
	}
	for i, s := range sprites {
		e := out[spritesOff+8*i:]
		if i >= 64 {
			e = out[sprites64+8*(i-64):]
		}
		data, flags := s.Px, byte(0)
		if r, ok := RLE(s); ok && len(r) < len(data) && !noRLE {
			data, flags = r, flagRLE
		}
		e[0], e[1], e[2], e[3] = byte(s.W), byte(s.H), byte(s.AX), byte(s.AY)
		at := len(out)
		e[4], e[5], e[6], e[7] = byte(at), byte(at>>8), byte(at>>16), flags
		out = append(out, data...)
	}
	if len(out) > storeSize4 {
		return nil, fmt.Errorf("%d bytes, the store holds %d", len(out), storeSize4)
	}
	return out, nil
}

// ------------------------------------------------------------------ library

// The library (realm.lib) holds every sprite, raw and run-length; the game
// packs the ones a scene needs into the store, in the form the video card
// reads. Little-endian:
//
//	"RLIB" version(2) count(u16) palette(256: 128 x RGB565)
//	count x { name length(u8) name w h ax ay(u8 each) kind(u8)
//	          raw offset(u32) rle offset(u32) rle length(u32, 0: none) }
//	pixels at their offsets from the start of the file
const libVersion = 2

var kinds = []string{"ground", "object", "person"}

func kindByte(k string) byte {
	for i, n := range kinds {
		if n == k {
			return byte(i)
		}
	}
	return 1
}

// PackLibrary encodes the library.
func PackLibrary(p *Palette, sprites []*Sprite) ([]byte, error) {
	head := 4 + 1 + 2 + 2*colors
	idxLen := 0
	for _, s := range sprites {
		if len(s.Name) > 32 {
			return nil, fmt.Errorf("%s: name longer than 32", s.Name)
		}
		idxLen += 1 + len(s.Name) + 17
	}
	out := make([]byte, 0, head+idxLen)
	out = append(out, "RLIB"...)
	out = append(out, libVersion)
	out = binary.LittleEndian.AppendUint16(out, uint16(len(sprites)))
	out = append(out, p.store565()...)
	var data []byte
	at := head + idxLen
	for _, s := range sprites {
		out = append(out, byte(len(s.Name)))
		out = append(out, s.Name...)
		out = append(out, byte(s.W), byte(s.H), byte(s.AX), byte(s.AY), kindByte(s.Kind))
		out = binary.LittleEndian.AppendUint32(out, uint32(at+len(data)))
		data = append(data, s.Px...)
		r, ok := RLE(s)
		if !ok {
			r = nil
		}
		out = binary.LittleEndian.AppendUint32(out, uint32(at+len(data)))
		out = binary.LittleEndian.AppendUint32(out, uint32(len(r)))
		data = append(data, r...)
	}
	return append(out, data...), nil
}

// UnpackLibrary decodes a library; the run-length pixels must match.
func UnpackLibrary(b []byte) ([]uint16, []*Sprite, error) {
	head := 4 + 1 + 2 + 2*colors
	if len(b) < head || string(b[:4]) != "RLIB" || b[4] != libVersion {
		return nil, nil, fmt.Errorf("not a realm library")
	}
	n := int(binary.LittleEndian.Uint16(b[5:]))
	pal := make([]uint16, colors)
	for i := range pal {
		pal[i] = binary.LittleEndian.Uint16(b[7+2*i:])
	}
	var sprites []*Sprite
	pos := head
	for i := 0; i < n; i++ {
		if pos >= len(b) || pos+1+int(b[pos])+17 > len(b) {
			return nil, nil, fmt.Errorf("index cut short")
		}
		l := int(b[pos])
		s := &Sprite{Name: string(b[pos+1 : pos+1+l])}
		e := b[pos+1+l:]
		s.W, s.H, s.AX, s.AY = int(e[0]), int(e[1]), int(e[2]), int(e[3])
		s.Kind = kinds[min(int(e[4]), len(kinds)-1)]
		off := int(binary.LittleEndian.Uint32(e[5:]))
		roff, rlen := int(binary.LittleEndian.Uint32(e[9:])), int(binary.LittleEndian.Uint32(e[13:]))
		if off+s.W*s.H > len(b) || roff+rlen > len(b) {
			return nil, nil, fmt.Errorf("%s: pixels outside the file", s.Name)
		}
		s.Px = b[off : off+s.W*s.H]
		if rlen > 0 && !bytes.Equal(UnRLE(b[roff:roff+rlen], s.W, s.H), s.Px) {
			return nil, nil, fmt.Errorf("%s: run-length pixels differ", s.Name)
		}
		sprites = append(sprites, s)
		pos += 1 + l + 17
	}
	return pal, sprites, nil
}

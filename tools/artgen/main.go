// artgen builds realm's art from text sources.
//
//	artgen gen    [-art ../../art]          procedural sprites to text sources
//	artgen build  [-art ../../art] [-out ../../packages/realm/realm.lib]
//	artgen sheet  [-art ../../art] out.png   every sprite, 3x, with sizes
//	artgen scene  [-art ../../art] out.png   the sprites in a village corner
//	artgen unpack realm.art dir             a store back to text sources
//	artgen store4 [-raw] out.bin            every sprite in a V4 video card store
//
// The sources are art/palette.txt and art/sprites/*.txt (see ReadSprite).
// realm.lib holds them all; the game packs the ones a scene needs into the
// video card's 32 KB store.
package main

import (
	"flag"
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	art := fs.String("art", "../../art", "directory of palette.txt and sprites/")
	out := fs.String("out", "../../packages/realm/realm.lib", "library to write")
	raw := fs.Bool("raw", false, "store4: no run-length pixels")
	fs.Parse(os.Args[2:])
	var err error
	switch os.Args[1] {
	case "build":
		err = build(*art, *out)
	case "sheet", "scene":
		if fs.NArg() != 1 {
			usage()
		}
		err = picture(os.Args[1], *art, fs.Arg(0))
	case "gen":
		var p *Palette
		if p, err = ReadPalette(filepath.Join(*art, "palette.txt")); err == nil {
			err = Gen(p, filepath.Join(*art, "sprites"))
		}
	case "store4":
		// Every sprite in one V4 store (raw with -raw), to test the video card.
		if fs.NArg() != 1 {
			usage()
		}
		var p *Palette
		var sprites []*Sprite
		if p, sprites, err = load(*art); err == nil {
			var st []byte
			if *raw {
				noRLE = true
			}
			if st, err = PackStore4(p, sprites); err == nil {
				err = os.WriteFile(fs.Arg(0), st, 0o644)
			}
		}
	case "unpack":
		if fs.NArg() != 2 {
			usage()
		}
		err = unpack(fs.Arg(0), fs.Arg(1))
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "artgen:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: artgen build|sheet out.png|scene out.png|unpack realm.art dir [-art dir] [-out file]")
	os.Exit(2)
}

func load(art string) (*Palette, []*Sprite, error) {
	p, err := ReadPalette(filepath.Join(art, "palette.txt"))
	if err != nil {
		return nil, nil, err
	}
	sprites, err := ReadSprites(filepath.Join(art, "sprites"), p)
	return p, sprites, err
}

func build(art, out string) error {
	p, sprites, err := load(art)
	if err != nil {
		return err
	}
	lib, err := PackLibrary(p, sprites)
	if err != nil {
		return err
	}
	if err := os.WriteFile(out, lib, 0o644); err != nil {
		return err
	}
	px, packed := 0, 0
	for _, s := range sprites {
		px += len(s.Px)
		if r, ok := RLE(s); ok && len(r) < len(s.Px) {
			packed += len(r)
		} else {
			packed += len(s.Px)
		}
	}
	fmt.Printf("%s: %d sprites, %d bytes of pixels, %d run-length\n", out, len(sprites), px, packed)
	fmt.Printf("a scene holds %d sprites and %d bytes (V4 video card: %d and %d)\n",
		maxSprites, storeSize-pixelsOff, maxSprites4, storeSize4-pixelsOff4)
	return nil
}

func picture(kind, art, out string) error {
	p, sprites, err := load(art)
	if err != nil {
		return err
	}
	pal := make([]uint16, colors)
	copy(pal, func() []uint16 {
		b := p.store565()
		v := make([]uint16, colors)
		for i := range v {
			v[i] = uint16(b[2*i]) | uint16(b[2*i+1])<<8
		}
		return v
	}())
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	defer f.Close()
	if kind == "sheet" {
		bg := byte(0)
		if c := p.byName["hud_bg"]; c != nil {
			bg = byte(c.Index)
		}
		return png.Encode(f, Sheet(pal, sprites, bg))
	}
	return png.Encode(f, Scene(pal, sprites))
}

// Names of the colors and sprites of the first realm.art, in store order.
var (
	oldColors = strings.Fields(`grass0 grass1 grass2 sand0 sand1 water0 water1 water2 deep
		stone0 stone1 stone2 dirt0 dirt1 trunk trunk_d leaf0 leaf1 leaf2 leaf_d rock0 rock1 rock2
		wall_top wall_l wall_r mortar skin hair line boots pants tunic tunic_d flower_r flower_y
		text hud_bg phos`)
	oldSprites = strings.Fields(`water/0 water/1 water/2 sand/0 sand/1 sand/2 grass/0 grass/1
		grass/2 stone/0 stone/1 stone/2 dirt/0 dirt/1 dirt/2 tree/0 tree/1 tree/2 rock/0 rock/1
		wall person/0 person/1 person/2`)
	charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
)

func unpack(in, dir string) error {
	b, err := os.ReadFile(in)
	if err != nil {
		return err
	}
	pal, sprites, err := UnpackStore(b)
	if err != nil {
		return err
	}
	p := &Palette{}
	for i := 1; i < firstTunic; i++ {
		if pal[i] == 0 && i > len(oldColors) {
			continue
		}
		name := fmt.Sprintf("c%d", i)
		if i <= len(oldColors) {
			name = oldColors[i-1]
		}
		p.Colors = append(p.Colors, Color{Index: i, Char: charset[i-1], Name: name, RGB: pal[i]})
	}
	p.index()
	if err := os.MkdirAll(filepath.Join(dir, "sprites"), 0o755); err != nil {
		return err
	}
	if err := WritePalette(filepath.Join(dir, "palette.txt"), p); err != nil {
		return err
	}
	for i, s := range sprites {
		if i < len(oldSprites) {
			s.Name = oldSprites[i]
		}
		switch {
		case s.W == tileW && s.H == tileH:
			s.Kind = "ground"
		case strings.HasPrefix(s.Name, "person/"):
			s.Kind = "person"
		}
		file := strings.ReplaceAll(s.Name, "/", "-") + ".txt"
		if err := WriteSprite(filepath.Join(dir, "sprites", file), s, p); err != nil {
			return err
		}
	}
	fmt.Printf("%s: %d colors, %d sprites\n", dir, len(p.Colors), len(sprites))
	return nil
}

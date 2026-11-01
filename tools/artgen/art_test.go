package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestLibraryRoundTrip(t *testing.T) {
	p, sprites, err := load("../../art")
	if err != nil {
		t.Fatal(err)
	}
	lib, err := PackLibrary(p, sprites)
	if err != nil {
		t.Fatal(err)
	}
	pal, back, err := UnpackLibrary(lib)
	if err != nil {
		t.Fatal(err)
	}
	if len(back) != len(sprites) || pal[1] != p.Colors[0].RGB {
		t.Fatalf("%d sprites back of %d", len(back), len(sprites))
	}
	for i, s := range sprites {
		b := back[i]
		if b.Name != s.Name || b.W != s.W || b.H != s.H || b.AX != s.AX || b.AY != s.AY ||
			b.Kind != s.Kind || !bytes.Equal(b.Px, s.Px) {
			t.Fatalf("%s changed", s.Name)
		}
	}
}

func TestStoreBudget(t *testing.T) {
	p := &Palette{}
	big := &Sprite{Name: "big", W: 200, H: 200, Px: make([]byte, 40000)}
	if _, err := PackStore(p, []*Sprite{big}); err == nil {
		t.Fatal("a 40 KB sprite fit in the store")
	}
	many := make([]*Sprite, maxSprites+1)
	for i := range many {
		many[i] = &Sprite{W: 1, H: 1, Px: []byte{1}}
	}
	if _, err := PackStore(p, many); err == nil {
		t.Fatal("65 sprites fit in the store")
	}
}

func TestBadSprite(t *testing.T) {
	p, err := ReadPalette("../../art/palette.txt")
	if err != nil {
		t.Fatal(err)
	}
	f := filepath.Join(t.TempDir(), "x.txt")
	os.WriteFile(f, []byte("name x\n---\n.?.\n"), 0o644)
	if _, err := ReadSprite(f, p); err == nil {
		t.Fatal("unknown character accepted")
	}
	os.WriteFile(f, []byte("name x\nlegend o=nope\n---\n.o.\n"), 0o644)
	if _, err := ReadSprite(f, p); err == nil {
		t.Fatal("unknown legend color accepted")
	}
}

func TestRLE(t *testing.T) {
	_, sprites, err := load("../../art")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range sprites {
		r, ok := RLE(s)
		if !ok {
			t.Fatalf("%s: too big for run-length", s.Name)
		}
		if !bytes.Equal(UnRLE(r, s.W, s.H), s.Px) {
			t.Fatalf("%s: run-length round trip differs", s.Name)
		}
	}
	// Long runs split at 128.
	long := &Sprite{W: 300 / 2, H: 1, Px: make([]byte, 150)}
	for i := 10; i < 150; i++ {
		long.Px[i] = 5
	}
	long.Px[149], long.Px[148] = 0, 0
	r, _ := RLE(long)
	if !bytes.Equal(UnRLE(r, long.W, long.H), long.Px) {
		t.Fatal("long runs differ")
	}
}

// What every scene needs fits one store: each person's frames and every
// ground and object but their variants ("tree/1"), which the game leaves
// out when the store is full. Each sprite reads back.
func TestStore4(t *testing.T) {
	p, all, err := load("../../art")
	if err != nil {
		t.Fatal(err)
	}
	var sprites []*Sprite
	for _, s := range all {
		if s.Kind == "person" || !variant.MatchString(s.Name) {
			sprites = append(sprites, s)
		}
	}
	st, err := PackStore4(p, sprites)
	if err != nil {
		t.Fatal(err)
	}
	for i, s := range sprites {
		e := st[spritesOff+8*i:]
		if i >= 64 {
			e = st[sprites64+8*(i-64):]
		}
		off := int(e[4]) | int(e[5])<<8 | int(e[6])<<16
		px := st[off:]
		if e[7]&flagRLE != 0 {
			px = UnRLE(px, s.W, s.H)
		}
		if !bytes.Equal(px[:s.W*s.H], s.Px) {
			t.Fatalf("%s reads back wrong", s.Name)
		}
	}
	t.Logf("%d sprites in %d bytes of %d", len(sprites), len(st), storeSize4)
}

var variant = regexp.MustCompile(`/[1-9][0-9]*$`)

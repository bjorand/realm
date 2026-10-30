package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The text sources still hold the first realm.art, byte for byte.
func TestFirstArtRoundTrip(t *testing.T) {
	want, err := os.ReadFile("testdata/realm-0.1.art")
	if err != nil {
		t.Fatal(err)
	}
	p, sprites, err := load("../../art")
	if err != nil {
		t.Fatal(err)
	}
	var ordered []*Sprite
	for _, n := range oldSprites {
		s := find(sprites, n)
		if s == nil {
			t.Fatalf("missing %s", n)
		}
		ordered = append(ordered, s)
	}
	// Only the first realm.art colors, as it had them.
	old := &Palette{}
	for _, c := range p.Colors {
		if c.Index <= len(oldColors) {
			old.Colors = append(old.Colors, c)
		}
	}
	got, err := PackStore(old, ordered)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("store differs: %d bytes, want %d", len(got), len(want))
	}
}

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

// The whole library fits one V4 store, and each sprite reads back.
func TestStore4(t *testing.T) {
	p, sprites, err := load("../../art")
	if err != nil {
		t.Fatal(err)
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

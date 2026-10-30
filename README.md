# realm

Isometric world for Termina, by Vendetta 84: an island village to walk
around, the first step toward an online world. The source is public, but
realm is not open source: all rights reserved, see [LICENSE](LICENSE).

## Installing

This repository is its own `pkg` registry, published on GitHub Pages at
`https://bjorand.github.io/realm/`. On the machine:

```
pkg source add realm https://bjorand.github.io/realm/
pkg update
pkg install realm
realm
```

It needs the HDMI firmware from 2026-10-30 on (the `iso` library and
`pkg source`).

## Files

- `packages/realm/realm.lua`: the game (map generation, people, walking,
  camera). It draws through the firmware's `iso` library, so the Pico video
  card does the drawing.
- `packages/realm/realm.art`: the colors and the 24 sprites, in the store
  layout of `video/include/isodraw.h` in the termina repository. Sprite
  numbers and colors are listed at the top of `realm.lua`.
- `packages/realm/package.lua`: the `pkg` manifest.
- `.github/workflows/publish.yml`: validates the package and publishes the
  registry, with the `mkindex` tool of termina-packages.

## Developing

Copy `realm.lua` and `realm.art` to the root of `A:` (or of the emulator's
`A:` directory) and type `realm`.

To check the package before pushing, from a termina-packages checkout:

```
go run ./tools/mkindex -packages ../realm/packages
```

A release is a push to `main` with a new `version` in `package.lua`: the
CI refuses changed files under an already published version.

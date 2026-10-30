# realm

Isometric world for Termina, by Vendetta 84: an island village to walk
around, the first step toward an online world. Proprietary, see
[LICENSE](LICENSE); not part of the public package registry.

## Files

- `realm.lua`: the game (map generation, people, walking, camera). It
  draws through the firmware's `iso` library, so the Pico video card does
  the drawing (HDMI firmware from 2026-10-30 on).
- `realm.art`: the colors and the 24 sprites, in the store layout of
  `video/include/isodraw.h` in the termina repository. Sprite numbers and
  colors are listed at the top of `realm.lua`.
- `package.lua`: the `pkg` manifest.

## Trying it

Copy `realm.lua` and `realm.art` to the root of `A:` (or of the emulator's
`A:` directory) and type `realm`. Installed as a package, the files go to
`A:\pkg\realm\`, where `realm.lua` looks for `realm.art` first.

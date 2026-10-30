# realm

Isometric world for Termina, by Vendetta 84: an island village to walk
around, the first step toward an online world. The source is public, but
realm is not open source: all rights reserved, see [LICENSE](LICENSE).

## Files

- `realm.lua`: the game (map generation, people, walking, camera). It
  draws through the firmware's `iso` library, so the Pico video card does
  the drawing (HDMI firmware from 2026-10-30 on).
- `realm.art`: the colors and the 24 sprites, in the store layout of
  `video/include/isodraw.h` in the termina repository. Sprite numbers and
  colors are listed at the top of `realm.lua`.
- `package.lua`: the `pkg` manifest.

## Trying it

On the machine, `pkg install realm` then `realm`: the package is published
by [termina-packages](https://github.com/bjorand/termina-packages), which
holds a copy of these files under `packages/realm/`.

While developing, copy `realm.lua` and `realm.art` to the root of `A:` (or
of the emulator's `A:` directory) and type `realm`.

## Releasing

Bump `version` in `package.lua`, then copy `package.lua`, `realm.lua`,
`realm.art` and `LICENSE` to `packages/realm/` in termina-packages and push
there: its CI publishes the new version.

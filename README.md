# realm

Online isometric world for Termina, by Vendetta 84: an island village
shared with other players, wolves in the woods, a quest from Ada and Tom's
shop. The source is public, but realm is not open source: all rights
reserved, see [LICENSE](LICENSE).

The world lives on a realm server
([realm-server](https://github.com/bjorand/realm-server)): the machine
connects to it over TCP, and the server decides where everyone is, who hits
whom and what each player owns.

## Installing

This repository is its own `pkg` registry, published on GitHub Pages at
`https://bjorand.github.io/realm/`. On the machine:

```
pkg source add realm https://bjorand.github.io/realm/
pkg update
pkg install realm
realm 192.168.1.10:7878 bob
```

The server address and the name are remembered: later, `realm` alone
connects again (without a name, it asks for one). It needs the HDMI
firmware from 2026-10-30 on (the `iso` library and `pkg source`).

## Playing

- A click walks, attacks a wolf (auto-attack every 1.5 s while next to it)
  or talks to a villager; arrows (or ZQSD/WASD) walk.
- 1-9 pick in a menu, Esc closes it. H drinks a potion, Space stops
  fighting, C switches the camera, Esc quits.
- Ada, on the square, asks for 5 wolves; Tom, in the house north east of
  the square, sells potions and a sword and buys pelts.

## Files

- `packages/realm/realm.lua`: the client (network, people, walking,
  camera, status line). The map comes from the server. It draws through the
  firmware's `iso` library, so the Pico video card does the drawing.
- `packages/realm/realm.art`: the colors and the 24 sprites, in the store
  layout of `video/include/isodraw.h` in the termina repository. Sprite
  numbers and colors are listed at the top of `realm.lua`.
- `packages/realm/package.lua`: the `pkg` manifest.
- `.github/workflows/publish.yml`: validates the package and publishes the
  registry, with the `mkindex` tool of termina-packages.

## Developing

Run a server (`go run ./cmd/realm-server` in a realm-server checkout),
copy `realm.lua` and `realm.art` to the root of `A:` (or of the emulator's
`A:` directory) and type `realm <pc address>:7878 <name>` (`localhost` in
the emulator).

To check the package before pushing, from a termina-packages checkout:

```
go run ./tools/mkindex -packages ../realm/packages
```

A release is a push to `main` with a new `version` in `package.lua`: the
CI refuses changed files under an already published version.

# realm

Online isometric world for Termina, by Vendetta 84: an island village
shared with other players, wolves in the woods, a haunted graveyard, a
quest from Ada and Tom's shop. The source is public, but realm is not
open source: all rights reserved, see [LICENSE](LICENSE).

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
connects again (without a name, it asks for one).

The world is drawn as Ultima Online did: square ground diamonds (32x32),
tall walls, and trees or walls in front of the player letting it show
through a dithered circle. This needs the video card V5: flash both boards
with the HDMI firmware of 2026-10-31 on (the test pattern reads
`TERMINA VIDEO 640x480 V5`); on an older card realm stops with a message.
Torchlight needs the V6 card (firmware 1.1.0 on both boards, test pattern
`TERMINA VIDEO 640x480 V6`): on V5 the night is just darker everywhere.
Walls stop the torchlight from V9 on (firmware 1.4.0 on both boards): before,
it shines through them.

## Playing

realm opens on a splash screen with its version on the bottom row, for
2.5 seconds or until a key or a click.

- A click walks, attacks a monster (auto-attack every 1.5 s while next to it),
  talks to a villager, opens a dead player's body or reads a resurrection
  scroll over a ghost; arrows (or ZQSD/WASD) walk. Players are seen
  punching, or raising and swinging the sword once they own one (the
  sword's swing needs a realm server that names the weapon in its hits).
- E opens what you wear, in the top right corner: six slots (weapon,
  head, body, shield, feet, ring), each item with its damage, armor or
  bonus, and your armor (each point takes 4% off the damage you take). A
  click on an item takes it off into the bag; a click on gear in the bag
  puts it on. Heavy gear needs strength. Gear needs a realm server with
  slots.
- P opens the character sheet: level, XP, health, armor and the four attributes
  (strength: damage, dexterity: hitting and being missed, vitality: health,
  intelligence: potions and XP). Wolves and Ada's quest give XP; each level
  up gives a point, spent with 1-4 or a click on the attribute's line while
  the sheet is open. Levels need a realm server that knows them.
- Enter opens a chat line on the status line (60 characters, Enter sends,
  Esc cancels): every player sees it over your head for a few seconds, and
  on their status line. Chat needs a realm server that knows `chat`.
- 1-9 pick in a menu, Esc closes it. J opens the quest journal, H drinks
  a potion, T lights or puts out a torch, Space stops fighting, C switches the camera, Esc quits.
- The bag, in the bottom right corner: I or a click opens it. It shows
  your gold and every item with its count (12 slots); a click on a
  potion drinks it, on a torch or matches lights the torch, on anything
  else tells what it is. What you get (a slain wolf's pelt, what Tom
  sells you) pops up beside the bag.
- F3 shows the frame rate and, in the top left corner, a graph of the
  network lag over the last 16 seconds (a bar a second, 2 dots per 20 ms;
  green under 80 ms, yellow under 200 ms, red above or lost).
- The server keeps the time of day, shown after your name on the status
  line: a day lasts 24 minutes, nights (21:00-5:00) are dark and blue, dawn
  and dusk warm. Names and the status line stay lit. A lit torch (yours or
  anyone's) lights about 3 tiles around it; it burns 10 minutes, each
  lighting takes a match, and putting it out keeps the rest for later.
- Ada, on the square, asks for 5 wolves; Tom, in the house north east of
  the square, sells potions, torches, matches and resurrection scrolls and
  buys pelts; Bram the
  smith, in the south west house, sells weapons, armor, shields, boots and
  rings and buys gear back at half price.
- Death is as in Ultima Online: your bag and gold stay on your body, and
  you walk on as a ghost (a pale sheet), still wearing your gear. Monsters
  ignore you, you cannot fight nor trade, and the living only hear you
  moan. Walk to the golden ankh on the square (a click on it walks beside
  it), or have a friend read a resurrection scroll (Tom sells them) beside
  you, to live again; then go back for your body before someone else loots
  it: anyone may, and it turns to dust after 15 minutes. Needs a realm
  server with ghosts.
- At night (21:00-5:00) skeletons walk the graveyard in the north east
  woods, at the end of the trail from the north road. At midnight their
  lord, the Revenant, rises: half as big again as them, he calls them to
  his side at half health. Whoever slays him takes the grave blade, the
  best weapon there is. Needs a realm server with the graveyard.

## Files

- `packages/realm/realm.lua`: the client (network, people, walking,
  camera, status line). The map comes from the server. It draws through the
  firmware's `iso` library, so the Pico video card does the drawing.
- `packages/realm/realm.lib`: every sprite, raw and run-length, each
  deflated (the game inflates what it loads with `zlib.inflate`; a package
  file holds 64 KB), and the palette, built by artgen. The game packs the
  sprites a scene needs into the video card's store (the layout of
  `video/include/vlink.h` in the termina repository: 128 run-length sprites
  and 48 KB); variants that do not fit are drawn as their `/0`.
- `art/palette.txt`, `art/sprites/*.txt`: the art sources, as text (see
  below).
- `tools/artgen/`: builds `realm.lib` from `art/`, draws contact sheets,
  generates the grounds, the wall and the props.
- `packages/realm/package.lua`: the `pkg` manifest.
- `.github/workflows/publish.yml`: validates the package and publishes the
  registry, with the `mkindex` tool of termina-packages.

## Developing

Run a server (`go run ./cmd/realm-server` in a realm-server checkout),
copy `realm.lua` and `realm.lib` to the root of `A:` (or of the emulator's
`A:` directory) and type `realm <pc address>:7878 <name>` (`localhost` in
the emulator).

## Art

Each sprite is a text file in `art/sprites/`: a few `key value` lines,
`---`, then one character per dot.

```
name wolf/0          library name; "x/1", "x/2" are variants or walk frames
kind person          ground, object or person (people get tunic recoloring)
scale 2              optional: each dot drawn 2x2, like the villagers
anchor 16 19         the dot standing on the tile's foot point (scaled dots)
shadow 0 0 13 3      optional: ground shadow ellipse dx dy rx ry from the anchor
legend o=line f=tunic e=eye
---
............o.o.
...
```

`.` is clear, `%` a shadow, and other characters are the file's legend or
the palette's own characters (`art/palette.txt`). In people, `tunic` and
`tunic_d` take each person's color: one wolf drawing makes grey, black and
white wolves. Grounds, the wall and props (`well`, `stall`, `barrel`...)
are generated by `tools/artgen/gen.go`.

From `tools/artgen`:

```
go run . gen                  regenerate grounds, wall and props into art/sprites
go run . build                write packages/realm/realm.lib
go run . sheet sheet.png      every sprite at 3x with its size
go run . scene scene.png      the sprites in a village corner
go test .                     library and run-length round trips, store budget
go run . store4 [-raw] out    every sprite in one video card store
```

To check the package before pushing, from a termina-packages checkout:

```
go run ./tools/mkindex -packages ../realm/packages
```

A release is a push to `main` with a new `version` in `package.lua` (and
the same `VERSION` at the top of `realm.lua`, shown on the splash screen):
the CI refuses changed files under an already published version.

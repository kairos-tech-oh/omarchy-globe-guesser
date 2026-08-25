# Globe Guesser

A photograph, somewhere on Earth. Click the map — or spin the globe — to say
where you think it was taken.

Five rounds, 5,000 points each, scored on how close you got. Your best run is
kept.

## What it does

- **A real photo, with real coordinates.** Each round draws a city from a
  bundled list of the 1,000 largest in the world, then asks Wikimedia Commons
  for photographs taken near it. The answer is the photograph's *own* recorded
  position, not the city centre.
- **Two ways to guess.** A flat world map, or a globe you can spin. Both are
  drawn from bundled Natural Earth outlines, so both work with the machine
  offline — only the photograph needs a connection.
- **Playable without a mouse.** Arrow keys (or `hjkl`) place and nudge the pin,
  `Enter` confirms, `M` and `G` switch between map and globe, `Esc` closes.
- **Attribution shown.** Commons photographs are almost all CC-licensed. The
  photographer and the licence appear with the answer, because the licence is
  only honoured if they travel with the picture.

## Use

| Control | What it does |
|---|---|
| Click the map or globe | Place your guess |
| Drag | Pan the map, or spin the globe |
| Scroll | Zoom, centred on the pointer |
| Arrow keys / `hjkl` | Place the pin, then nudge it — finer the further you are zoomed in |
| `M` / `G` | Switch to the map / the globe |
| `Enter` | Confirm the guess, then move to the next round |
| `Esc` | Close the panel — a game in progress is still there when you reopen it |
| Skip | Draw a different photo without scoring the round |

## Install

```sh
omarchy plugin add https://github.com/kairos-tech-oh/omarchy-globe-gueser.git --enable
```

Then add **Globe Guesser** to your bar from the Omarchy settings UI, under *Fun*.

The shell normally picks the plugin up immediately. If the widget does not
appear, restart it once:

```sh
omarchy restart shell
```

## Update

```sh
omarchy plugin update kairos.globe-guesser --yes
```

## Remove

```sh
omarchy plugin remove kairos.globe-guesser --yes
```

If the plugin directory was placed at `~/.config/omarchy/plugins/kairos.globe-guesser`
by hand rather than by `omarchy plugin add`, remove that directory and restart
the shell instead:

```sh
rm -rf ~/.config/omarchy/plugins/kairos.globe-guesser
omarchy restart shell
```

**State left behind.** Two things, and `omarchy plugin remove` deletes neither,
so remove them by hand if you want nothing left:

```sh
rm -f  ~/.local/state/omarchy/globe-guesser-state.json   # best score, games played
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-globe-guesser"
rm -rf ~/.cache/omarchy-globe-guesser                     # only if XDG_RUNTIME_DIR was unavailable
```

The first is a 34-byte JSON file holding your best score and how many games you
have finished. The second is the photo cache: at most two JPEGs at a time, in a
directory that is cleared at logout anyway because it lives on tmpfs. Your
chosen settings live in the shell's own `shell.json` alongside every other
widget's, and are removed with the widget when you delete it from your bar.

## Settings

Under *Fun* in the Omarchy settings UI.

| Setting | Options | Default | What it changes |
|---|---|---|---|
| Difficulty | easy / normal / hard | normal | Which cities a round can come from: the 150 largest, the 500 largest, or all 1,000 |
| Rounds per game | 3–10 | 5 | How many photos make up one game |
| Starting view | map / globe | map | Which surface a round opens on. You can switch mid-round either way |
| Photo radius (km) | 5–50 | 10 | How far from a city centre a photo may have been taken. Larger finds more countryside; smaller keeps photos recognisably in the city |

## Network use

Two requests per round, both anonymous, neither needing an API key or an
account.

| Service | What for | Published limit | What this plugin does |
|---|---|---|---|
| `commons.wikimedia.org/w/api.php` | One `geosearch` query listing photographs near a city, with their coordinates, licence and author | No hard anonymous limit; the [user-agent policy](https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy) requires a descriptive User-Agent | Sends one identifying User-Agent, one query per round, and never more than one request per second |
| `upload.wikimedia.org` | Downloads the one chosen photograph | — | One download per round, capped at 6 MB, no redirects followed |

Every response is capped at the producer before the shell can hold it: 512 KiB
for the query, 6 MB for the photograph. Nothing else is contacted, ever. The
map, the globe, the scoring and the "12 km from Kyoto" line are all computed
from bundled data.

Turn the network off mid-game and the photograph fails with a readable message
and a **Try another** button; the guessing surface itself never needed it.

## Where the map comes from

`data/WorldOutline.js` and `data/Places.js` are generated from
[Natural Earth](https://www.naturalearthdata.com/) (public domain), pinned to an
exact upstream commit. `data/PROVENANCE.md` records the commit, the SHA-256 of
every input and output, and how to reproduce them:

```sh
tools/build-world.py --check
```

## Development

```sh
tools/run-checks.sh
```

Runs three things: that both data files rebuild byte-for-byte from the pinned
upstream commit, that the maths and the sanitisers behave under Node, and that
they behave under Qt's V4 engine — which is the engine omarchy-shell actually
uses, and is not Node.

### Files

| File | What it is |
|---|---|
| `BarWidget.qml` | The bar slot and the click target that opens the panel |
| `Panel.qml` | The game: state machine, the two network calls, scoring, persistence |
| `GlobeMap.qml` | The guessing surface — outline canvas, markers, pan/zoom/spin |
| `PhotoPane.qml` | The photograph, its loading and error states, and its attribution |
| `GeoMath.js` | Projections and their inverses, great-circle distance, the score curve |
| `Sanitise.js` | Everything that crosses into or out of the plugin as text |
| `data/` | Generated country outlines and city list, with provenance |
| `tools/` | The generator and the check suite |

## Dependencies

`curl`, `head`, `od`, `mktemp`, `timeout`, `find` — all present on any Omarchy
install. `python3` and `node` are needed only to regenerate the data or run the
checks, never to play.

## Attribution

Photographs are served by [Wikimedia Commons](https://commons.wikimedia.org/)
and remain under their own licences, shown with each answer. Map and city data
are from [Natural Earth](https://www.naturalearthdata.com/), public domain.

## Licence

MIT. See `LICENSE`.

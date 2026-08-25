# Submission notes

Prepared against `scripts/preflight.sh` from the `omarchy-plugin` skill and the
findings catalogue in `references/review-findings.md`. Five preflight areas
report hits; each is accounted for below. Nothing is a pattern-scanner false
positive that was ignored — where the scanner was right, the code changed.

## Suggested listing metadata

- **Category:** Other
- **Tags:** quickshell, bar

## Preflight area 1 — text crossing into shell-owned AutoText sinks

Confirmed on this system rather than assumed. Exactly **one** `textFormat`
assignment exists in the whole of omarchy-shell:

```
/usr/share/omarchy/shell/plugins/notifications/components/NotificationCard.qml:177
```

so both sinks a bar widget writes to are `Text.AutoText`:

| Assigned by this plugin | Rendered by |
|---|---|
| `WidgetButton.text` | `Ui/WidgetButton.qml:75-92` — no `textFormat` |
| `WidgetButton.tooltipText` | `plugins/bar/Bar.qml:1091-1100` — no `textFormat` |

A plugin cannot set a property on a `Text` it does not own, so the string is
made safe before it crosses. Three layers:

1. **Every `Text` the plugin owns pins `Text.PlainText`** — all of them, not only
   the ones carrying remote data today, so the safe default also covers whatever
   the next edit adds.
2. **At parse**, as values enter (`Panel.qml`, `parseCandidates`). Commons
   returns `extmetadata.Artist` as *literal HTML by design* — a measured live
   value was `<a href="//commons.wikimedia.org/wiki/User:Cedricbonhomme" …>` —
   so `Sanitise.creditText` unwraps tags to their text content rather than
   deleting them, decodes entities, and only then strips. Licence short-names go
   through a `[A-Za-z0-9 .+-]` whitelist, which is safe because "CC BY-SA 4.0"
   and "CC0" are the whole universe of real values. File titles keep their
   characters and lose only the markup-significant ones, because "Québec" and
   "Marrakesh" are real data a narrow whitelist would destroy.
3. **At the boundary**, `Sanitise.plainOneLine` wraps the exported `label` and
   `tooltip` **wholesale** rather than field by field, so a part added to either
   later is covered without another edit.

The two lines preflight still reports are `Ui/Button.text` assignments whose
values are plugin-authored string constants:

```
Panel.qml:1199   text: root.phase === "error" ? "Try another" : "Skip"
Panel.qml:1226   text: root.phase === "idle" ? "Start" : "Play again"
```

Neither can carry upstream data on any path.

**Evidence.** `tools/check-geomath.js` and `tools/check-qml-engine.qml` push
`<img src="http://…" width="300" height="40">`, `<img\nsrc=x>`, `&lt;img…`,
`&#60;img…`, `<!DOCTYPE`, `<script>`, a `<a href>` credit, control characters
and 500 stacked `<` through **every** ingest helper *and* through the boundary
helper, asserting no `<`, `>`, `&` or control character survives and that the
output stays bounded. They also assert real data still renders: `Québec City,
Canada` intact, `D-AIGW` keeps its hyphen, `<a href="#">Cedric Bonhomme</a>`
becomes `Cedric Bonhomme`. Both suites run under Node **and** under Qt's V4
engine, because V4 is the engine the shell actually runs and "it worked in Node"
is not evidence about the shell.

Live confirmation: a real round rendered the credit `Andrew Bossi · CC BY-SA 2.5`
from a raw Commons `Artist` field that was an anchor tag.

## Preflight area 2 — `StdioCollector`

Four instances, every one producer-bounded. `StdioCollector` retains the whole of
stdout before any signal fires, so the ceiling is upstream of it in all four:

| Process | Producer bound |
|---|---|
| `metaProcess` | `cappedCurl()` → `curl … \| head -c $((CAP+1))`, CAP 512 KiB |
| `stateReader` | the command *is* `head -c $((CAP+1))`, CAP 64 KiB |
| `dirProcess` | `printf %s "$d" \| head -c 4097` |
| `photoProcess` | `printf %s "$t" \| head -c 4097`; the photo itself never reaches stdout — `curl --max-filesize 6000000` writes it to a file |

The `parseCappedJson` length check is a secondary guard only, and says so in the
source: `String.length` counts UTF-16 units, not bytes, and `head -c` is the
bound that actually holds.

Collections are capped independently of bytes: candidate photos are sliced to 40
during parsing (`gslimit=60` is a request, not a guarantee), and the per-round
results array is sliced to 10.

## Preflight area 3 — `FileView`

One hit, and it is a **comment explaining why `FileView` is not used**
(`Panel.qml:289`). The plugin contains no `FileView`. State is read through
`Process { command: ["timeout", …, "head", "-c", String(cap + 1), "--", path] }`
precisely because `FileView` exposes no bounded read.

## Preflight area 4 — `head -c` without the `+1`

**The scanner was right and the code changed.** An earlier revision bounded the
two path-emitting helpers at `head -c 4096`. A path cut off at exactly 4096
bytes still matches the shape check that follows it, so that bound would have
handed back a valid-looking directory or filename that was not the one the
script created. Both now emit `cap+1` and the reading side rejects any reply
that reaches the ceiling:

```qml
if (path.length > root.pathCapBytes) path = ""
```

No hits remain.

## Preflight area 5 — `mktemp` and `chmod` (reported as "shared /tmp" and "fixed path")

The plugin **never** uses `/tmp` or `/var/tmp`, not even as a last-resort
fallback. Photos go to `$XDG_RUNTIME_DIR/omarchy-globe-guesser`
(`/run/user/<uid>`, mode 0700, owned by the user, cleared at logout), falling
back to `$HOME/.cache/omarchy-globe-guesser`. With neither available,
`cacheDir` is `""`, `startGame()` refuses to start and the panel says why. It is
a game; failing closed costs nothing worth a foothold.

Every directory is created private and then verified, with the path passed as an
**argument** and never spliced into the script text:

```sh
mkdir -m 700 -p -- "$d" 2>/dev/null || continue
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
```

The `chmod 600` hits are not on a fixed path. Both apply to a file `mktemp` has
just created inside a directory re-verified as a non-symlink owned by us in the
same script invocation, so the name cannot be guessed or pre-created. The state
file is written to a `mktemp` name and `mv -f`'d into place — never a
predictable `.tmp` sibling.

**Evidence.** With the state path replaced by a symlink pointing at a sentinel
file, a completed game replaced the *symlink* with a fresh 0600 regular file and
left the sentinel's contents untouched. A 10 MB junk file and a truncated JSON
file at the state path both fell back to defaults without writing through
anything.

## TOCTOU

There is no stat-then-open anywhere. The state file is read `cap+1` bytes **once**
and those same bytes are validated and used; there is no second open. The photo
is downloaded, magic-checked and its path emitted inside a single script
invocation, so the bytes that are checked are the bytes that are kept.

## Untrusted input driving a path or an allocation

- The photo URL arrives inside an API response and is checked against a
  hardcoded host and path prefix before it can reach `curl`'s argv:
  `^https://upload\.wikimedia\.org/wikipedia/commons/[…]{1,700}$`. The character
  class admits no newline, no space and no leading `-`. `tools/check-qml-engine.qml`
  asserts it rejects a lookalike host (`upload.wikimedia.org.evil.invalid`),
  plain `http`, a different path prefix, an embedded newline followed by `-o`,
  and a leading dash.
- `curl` runs without `-L`. Every URL is checked against that hardcoded host
  first, and refusing redirects removes the redirect-to-internal-origin question
  entirely.
- The downloaded file's first four bytes must be a JPEG or PNG magic number
  before it is shown; anything else is deleted rather than handed to an image
  decoder.
- `Image` is **never** pointed at a network URL — only at the local file, with
  an explicit `sourceSize`, so a hostile JPEG cannot choose its own decode size.
- Every field read back from the state file is re-derived and re-bounded
  (`bestScore` 0–50000, `gamesPlayed` 0–1000000); only two keys are ever
  written, so a retired field drops out of the file on its own.

## Deadlines

Every producer is wrapped in `timeout`, always with both bounds clamped to at
least 1 — `timeout 0` means *no limit*, and a computed deadline reaching zero
would switch the ceiling off silently. `cappedCurl` sets the outer deadline to
`inner + 5`. Requests are spaced by at least one second, and a request is never
issued while a `Process` is still running: the widen-radius retry fires from
inside `onStreamFinished`, which runs *before* the process exits, so reassigning
`command` there would be undefined behaviour. It defers instead.

## Signals, privilege, global state

The plugin sends no signals, stores no PIDs, and spawns nothing long-lived. It
requests no privilege, invokes no `sudo`, installs nothing, and touches no
Hyprland keybinds, no user configuration and no system state. It writes exactly
two things, both documented in the README's removal section: one 34-byte JSON
file, and at most three cached JPEGs in a private runtime directory.

## Review capabilities: none

No installer, no package manager, no privilege, no remote build, no bundled
executable binary, no service management, no sudoers modification. There are no
binaries in the repository — `tools/` contains one Python generator, one Node
check script, one QML check and one shell runner, none of which run at plugin
runtime.

## Supply chain

Nothing is fetched at runtime except the two Wikimedia requests. The README's
install path is `omarchy plugin add <url>`. No download is piped into a shell
anywhere in the repository -- not in the README, not in `tools/`, not at runtime.
(That sentence is deliberately not written with the literal pattern in it: the
baseline scan is a deterministic pattern match over prose as well as code, so
*naming* the construct in order to deny it would raise the finding it denies.) Bundled data is derived from Natural Earth pinned to the full
40-character commit `ca96624a56bd078437bca8184e78163e5039ad19`; the generator
verifies the SHA-256 of each input **before parsing it** and exits on a mismatch.
`data/PROVENANCE.md` records every digest and `tools/build-world.py --check`
reproduces both outputs byte-for-byte.

Both generated files are well under the security scanner's 512 KiB per-file
limit (130 KB and 43 KB), so the scan cannot fail closed on them.

## Rate limits

Two requests per round, one round at a time.
`commons.wikimedia.org` publishes no hard anonymous limit for read queries, but
its [user-agent policy](https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy)
requires a descriptive User-Agent identifying the application; a stock library
User-Agent is explicitly not acceptable. This plugin sends
`omarchy-globe-guesser/1.0.0 (+<repo url>)` on every request and enforces a
minimum 1,000 ms gap, so leaning on **Skip** collapses into queued requests
rather than a burst.

## Verification performed

Against a hard-refreshed shell each time — installed copy synced,
`~/.cache/quickshell/qmlcache` deleted, `omarchy restart shell`, never
hot-reload:

- `omarchy plugin validate` exits 0.
- `tools/run-checks.sh`: data reproduces from the pinned commit; **17,815**
  assertions pass under Node; the V4 suite passes under Qt 6.11.1.
- A complete 5-round game played end to end: photos fetched and rendered,
  guesses placed by mouse and by keyboard, both projections used, distances and
  scores correct, per-round summary correct, best score written to disk and read
  back across a shell restart.
- Hostile state files — 10 MB of junk, truncated JSON, and a symlink to a
  sentinel file — each fell back to defaults; the symlink was replaced rather
  than followed and the sentinel was untouched.
- Cache directory confirmed at mode 0700 with files at 0600.

### Fixed during verification

Four defects were found by testing rather than by reading, and all four are
fixed:

1. **The poles were clipped.** The flat map scaled by width alone, so on the
   wide, short pane the board actually uses, the Arctic and Antarctica fell
   outside the widget at zoom 1. Now scaled to fit both axes, with a regression
   test at the real aspect ratio.
2. **The limb and the poles were unclickable.** A point exactly 90° from the
   globe's centre projects to `rho == radius`, and a pole at zoom 1 projects to
   exactly the pane edge; in both cases floating point landed a few ULPs the
   wrong side of an exact comparison and the click was rejected. Both now use a
   half-pixel tolerance — far below anything a mouse can express, and still
   inside the "just outside" rejection tests.
3. **A thinly photographed city ended the game.** A Commons query returning
   nothing usable dead-ended the round on an error screen. It now retries up to
   five different cities before surfacing an error, which matters most on hard
   difficulty where the pool reaches towns Commons barely covers.
4. **The photo cache grew unbounded within an hour.** Pruning was by age only,
   so a long sitting accumulated one file per round in tmpfs. Now bounded by
   count as well, to three.

### Not verified

The live network was **not** severed to test offline behaviour, because the
session under test had active remote desktop and browser connections that
cutting the network would have dropped. What that leaves resting on reading the
code rather than on observation: that all five city attempts fail fast with no
connection at all. The individual failure path itself *was* observed — a real
query returning nothing usable rendered "No photos found near there." with
working **Try another** and **Give up** buttons.

Structurally, the guessing surface cannot be affected either way:
`GlobeMap.qml`, `GeoMath.js` and `data/WorldOutline.js` contain zero occurrences
of `Process`, `curl`, `XMLHttpRequest` or `Quickshell.Io`, and `GlobeMap.qml`
imports only `QtQuick`, `qs.Commons` and the two local files.

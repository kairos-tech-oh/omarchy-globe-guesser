---
id: omarchy-globe-guesser.world-data-reproducible
project: omarchy-globe-guesser
category: data
severity: critical
environment: any
depends_on: []
---

# bundled outlines and places rebuild byte-for-byte from pinned upstream

## Claim
`tools/build-world.py --check` passes: `WorldOutline.js` and `Places.js`
both reproduce exactly from their pinned upstream commit, within every
ceiling.

## Why
Both files are generated, not hand-maintained — this is the only thing
that would catch them drifting from what the build script produces today,
or the pinned source going missing upstream.

## Check
```bash
python3 tools/build-world.py --check
```

## Depends On
None

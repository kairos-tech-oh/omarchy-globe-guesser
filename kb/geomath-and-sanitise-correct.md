---
id: omarchy-globe-guesser.geomath-and-sanitise-correct
project: omarchy-globe-guesser
category: logic
severity: critical
environment: any
depends_on: []
---

# distance scoring and input sanitising behave under Node

## Claim
`tools/check-geomath.js` passes: great-circle distance scoring and input
sanitising give the expected answers.

## Why
Scoring is the entire game — a wrong distance calculation changes every
round's result without any visible error.

## Check
```bash
node tools/check-geomath.js
```

## Depends On
None

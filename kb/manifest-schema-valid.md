---
id: omarchy-globe-guesser.manifest-schema-valid
project: omarchy-globe-guesser
category: manifest
severity: critical
environment: any
depends_on: []
---

# manifest.json is well-formed and its entry point exists

## Claim
`manifest.json` has `schemaVersion`, `id`, `name`, `version`, and
`entryPoints.barWidget`, and that file exists.

## Why
This is the minimum Omarchy needs to load the widget at all.

## Check
```bash
m=manifest.json
jq -e '.schemaVersion and .id and .name and .version and .entryPoints.barWidget' "$m" >/dev/null
[ -f "$(jq -r '.entryPoints.barWidget' "$m")" ]
```

## Depends On
None

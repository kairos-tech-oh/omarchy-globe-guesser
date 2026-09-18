---
id: omarchy-globe-guesser.qt-v4-engine-behaves
project: omarchy-globe-guesser
category: logic
severity: warn
environment: omarchy-desktop
depends_on: [omarchy-globe-guesser.geomath-and-sanitise-correct]
---

# GeoMath, Sanitise, and the data also behave under Qt's V4 engine

## Claim
`tools/check-qml-engine.qml`, run offscreen through Qt's `qml` runner,
exits 0.

## Why
Node isn't the engine omarchy-shell actually runs on — this is the one
check that runs the real logic on the real engine.

## Check
```bash
QT_QPA_PLATFORM=offscreen qml6 tools/check-qml-engine.qml
```

## Depends On
[[geomath-and-sanitise-correct]]

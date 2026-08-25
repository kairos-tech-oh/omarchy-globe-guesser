#!/usr/bin/env node
//
// Round-trip and safety checks for GeoMath.js and Sanitise.js.
//
//   node tools/check-geomath.js
//
// Runs under plain node here, and under Qt's V4 engine via
// tools/check-qml-engine.qml. Both matter: V4 is not node, and a regex or a
// numeric edge that behaves in one has to be shown to behave in the other,
// because V4 is the engine the shell actually runs.
//
// The two files under test are `.pragma library` QML JS resources. They contain
// no imports and no QML types, so they load as plain scripts once that first
// line is dropped.

"use strict"

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const root = path.resolve(__dirname, "..")

function load(name) {
  const source = fs.readFileSync(path.join(root, name), "utf8")
      .replace(/^\s*\.pragma\s+library\s*$/m, "")
  const context = { Math, isFinite, String, Number, Infinity, JSON }
  vm.createContext(context)
  vm.runInContext(source, context, { filename: name })
  return context
}

const Geo = load("GeoMath.js")
const Safe = load("Sanitise.js")

let failures = 0
let checks = 0

function ok(condition, description, detail) {
  checks++
  if (!condition) {
    failures++
    console.error("FAIL  " + description + (detail ? "\n        " + detail : ""))
  }
}

function near(actual, expected, tolerance, description) {
  const delta = Math.abs(actual - expected)
  ok(delta <= tolerance, description,
     `expected ${expected}, got ${actual}, delta ${delta} > ${tolerance}`)
}

// --------------------------------------------------------------- projections

// Views chosen to cover what the UI can actually reach: both modes, a
// non-square pane, several zooms, and rotations that put the pole and the
// antimeridian at the centre.
const views = []
for (const mode of ["map", "globe"]) {
  for (const zoom of [1, 1.7, 4, 12]) {
    for (const centre of [[0, 0], [45, -120], [-33.9, 151.2], [89, 180], [-89, -180], [0, 179.5]]) {
      // Two aspect ratios: a squarish pane, and the wide, short one the game
      // actually uses once the photo has taken the top of the board. The wide
      // case is the one where scaling by width alone clips the poles.
      views.push({ mode, width: 900, height: 520, zoom,
                   centreLat: centre[0], centreLon: centre[1] })
      views.push({ mode, width: 940, height: 330, zoom,
                   centreLat: centre[0], centreLon: centre[1] })
    }
  }
}

// A grid plus the awkward specific points: both poles, the antimeridian from
// both sides, the prime meridian, the equator.
const points = []
for (let lat = -80; lat <= 80; lat += 20) {
  for (let lon = -180; lon < 180; lon += 30) points.push([lat, lon])
}
points.push([90, 0], [-90, 0], [0, 180], [0, -180], [0, 0],
            [89.9, 179.9], [-89.9, -179.9], [51.5074, -0.1278], [35.687, 139.7495])

for (const view of views) {
  for (const [lat, lon] of points) {
    const projected = Geo.project(view, lat, lon)

    ok(isFinite(projected.x) && isFinite(projected.y),
       `finite projection ${view.mode} z${view.zoom} (${lat},${lon})`,
       `got x=${projected.x} y=${projected.y}`)
    if (!projected.visible) continue

    // Only points that land inside the pane are round-tripped. A visible point
    // off the edge of the widget is legitimate -- it is simply scrolled out of
    // sight -- and unproject is not defined for coordinates the user cannot
    // click.
    if (projected.x < 0 || projected.x > view.width) continue
    if (projected.y < 0 || projected.y > view.height) continue

    const back = Geo.unproject(view, projected.x, projected.y)
    ok(back !== null, `round trip returns a point ${view.mode} z${view.zoom} (${lat},${lon})`)
    if (!back) continue

    // Compared as a distance on the globe rather than in degrees: at the poles
    // every longitude names the same place, so a degree comparison reports a
    // 180-degree "error" for two identical points.
    const km = Geo.haversineKm(lat, lon, back.lat, back.lon)
    near(km, 0, 1.0, `round trip ${view.mode} z${view.zoom} (${lat},${lon}) -> (${back.lat},${back.lon})`)
  }
}

// The globe must refuse a click outside its disc rather than snapping it to the
// limb: the limb is exactly where a mis-click lands.
{
  const view = { mode: "globe", width: 900, height: 520, zoom: 1, centreLat: 0, centreLon: 0 }
  const radius = (Math.min(view.width, view.height) / 2) * 0.92
  const cx = view.width / 2
  const cy = view.height / 2

  ok(Geo.unproject(view, cx + radius * 0.99, cy) !== null, "just inside the limb is a point")
  ok(Geo.unproject(view, cx + radius * 1.01, cy) === null, "just outside the limb is not a point")
  ok(Geo.unproject(view, 0, 0) === null, "the pane corner is not a point")

  const centre = Geo.unproject(view, cx, cy)
  near(centre.lat, 0, 1e-9, "globe centre latitude")
  near(centre.lon, 0, 1e-9, "globe centre longitude")
}

// At zoom 1 the entire world has to be inside a wide, short pane -- both poles
// and both edges. This is the regression that clipped the Arctic off the board.
{
  const view = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
  for (const [lat, lon] of [[90, 0], [-90, 0], [0, -180], [0, 179.99], [71, -8]]) {
    const p = Geo.project(view, lat, lon)
    ok(p.x >= -1 && p.x <= view.width + 1 && p.y >= -1 && p.y <= view.height + 1,
       `whole world fits at zoom 1: (${lat},${lon})`, `got x=${p.x} y=${p.y}`)
  }
}

// The flat map must refuse a click above the pole rather than clamping to it.
{
  const view = { mode: "map", width: 900, height: 520, zoom: 1, centreLat: 80, centreLon: 0 }
  ok(Geo.unproject(view, 450, 260) !== null, "map centre is a point")
  ok(Geo.unproject(view, 450, -400) === null, "above the north pole is not a point")
  ok(Geo.unproject(view, 450, 2000) === null, "below the south pole is not a point")
}

// The back of the globe must report itself invisible, or it paints mirrored
// over the front.
{
  const view = { mode: "globe", width: 900, height: 520, zoom: 1, centreLat: 0, centreLon: 0 }
  ok(Geo.project(view, 0, 0).visible === true, "the sub-point is visible")
  ok(Geo.project(view, 0, 180).visible === false, "the antipode is not visible")
  ok(Geo.project(view, 0, 91).visible === false, "just past the limb is not visible")
  ok(Geo.project(view, 0, 89).visible === true, "just inside the limb is visible")
}

// ------------------------------------------------------------------ distance

near(Geo.haversineKm(0, 0, 0, 0), 0, 1e-9, "zero distance")
near(Geo.haversineKm(51.5074, -0.1278, 40.7128, -74.0060), 5570, 15, "London to New York")
near(Geo.haversineKm(35.6762, 139.6503, -33.8688, 151.2093), 7823, 25, "Tokyo to Sydney")
near(Geo.haversineKm(90, 0, -90, 0), 20015, 5, "pole to pole")
// The wrap: two points either side of the antimeridian are neighbours, not
// half a planet apart.
near(Geo.haversineKm(0, 179.5, 0, -179.5), 111.2, 1, "across the antimeridian")

// -------------------------------------------------------------------- scoring

ok(Geo.scoreFor(0) === 5000, "a perfect guess scores 5000")
ok(Geo.scoreFor(20000) === 0 || Geo.scoreFor(20000) < 5, "a hopeless guess scores about nothing")
ok(Geo.scoreFor(-1) === 0, "a negative distance scores 0")
ok(Geo.scoreFor(NaN) === 0, "NaN scores 0")
ok(Geo.scoreFor(Infinity) === 0, "Infinity scores 0")
for (let km = 0; km < 20000; km += 250) {
  ok(Geo.scoreFor(km) >= Geo.scoreFor(km + 250), `score falls monotonically at ${km} km`)
  ok(Geo.scoreFor(km) >= 0 && Geo.scoreFor(km) <= 5000, `score stays in range at ${km} km`)
}

ok(Geo.formatDistance(0.42) === "420 m", "sub-kilometre formats as metres")
ok(Geo.formatDistance(12.34) === "12.3 km", "short distance keeps a decimal")
ok(Geo.formatDistance(12480) === "12,480 km", "long distance is grouped")
ok(Geo.formatNumber(25000) === "25,000", "score grouping")
ok(Geo.formatNumber(0) === "0", "zero grouping")
ok(Geo.formatNumber(999) === "999", "three digits are not grouped")

// -------------------------------------------------------------- nearest place

{
  const places = [
    ["Kyoto", "Japan", 35.0116, 135.7681],
    ["Osaka", "Japan", 34.6937, 135.5023],
    ["Reykjavik", "Iceland", 64.1355, -21.8954]
  ]
  const found = Geo.nearestPlace(places, 35.02, 135.77)
  ok(found.name === "Kyoto", "nearest place picks Kyoto", `got ${found && found.name}`)
  ok(found.distanceKm < 5, "nearest place reports a small distance")

  // The wrap again: a point just east of the antimeridian must not pick a city
  // by going the long way round.
  const wrapped = Geo.nearestPlace(
    [["East", "A", 0, 179.9], ["West", "B", 0, -170]], 0, -179.9)
  ok(wrapped.name === "East", "nearest place respects the antimeridian",
     `got ${wrapped && wrapped.name}`)
}

// ------------------------------------------------------------------ sanitising
//
// The payload class reviewers actually use, pushed through every ingest helper
// AND through the boundary helper, because pinning textFormat on the plugin's
// own Text elements does nothing for the bar label and tooltip.
//
// Control characters are built with String.fromCharCode rather than written
// literally, so no raw control byte is ever encoded into this source file.
const NUL = String.fromCharCode(0)
const CR = String.fromCharCode(13)
const LF = String.fromCharCode(10)

const payloads = [
  '<img src="http://127.0.0.1:1/x.png" width="300" height="40">',
  '<img' + LF + 'src=x onerror=alert(1)>',
  '&lt;img src="http://example.invalid/x.png"&gt;',
  '&#60;img src=x&#62;',
  '<!DOCTYPE html><html><body>',
  '<script>fetch("http://example.invalid")</script>',
  '<a href="//commons.wikimedia.org/wiki/User:Someone" title="x">Someone</a>',
  'plain & simple <b>bold</b>',
  'line one' + LF + 'line two' + CR + 'line three' + NUL,
  '<'.repeat(500) + 'x'
]

const helpers = [
  ["plainOneLine", v => Safe.plainOneLine(v, 200)],
  ["creditText", v => Safe.creditText(v, 120)],
  ["titleText", v => Safe.titleText(v, 90)],
  ["licenceText", v => Safe.licenceText(v)],
  // The boundary: whatever any ingest helper produced, wrapped again on the way
  // out, which is how the exported label and tooltip are actually built.
  ["credit->boundary", v => Safe.plainOneLine(Safe.creditText(v, 120), 200)],
  ["title->boundary", v => Safe.plainOneLine(Safe.titleText(v, 90), 200)]
]

const CONTROL = new RegExp("[" + NUL + "-" + String.fromCharCode(31) + String.fromCharCode(127) + "]")

for (const [name, fn] of helpers) {
  for (const payload of payloads) {
    const out = fn(payload)
    ok(out.indexOf("<") === -1, `${name}: no < survives`, JSON.stringify(out))
    ok(out.indexOf(">") === -1, `${name}: no > survives`, JSON.stringify(out))
    ok(out.indexOf("&") === -1, `${name}: no & survives`, JSON.stringify(out))
    ok(!CONTROL.test(out), `${name}: no control characters survive`, JSON.stringify(out))
    ok(out.length <= 201, `${name}: output stays bounded`, `length ${out.length}`)
  }
}

// A double pass must be a no-op: sanitising an already-sanitised string must
// not be able to reassemble a tag out of the pieces.
for (const payload of payloads) {
  const once = Safe.plainOneLine(payload, 200)
  ok(Safe.plainOneLine(once, 200) === once, "plainOneLine is idempotent", JSON.stringify(once))
}

// And real data has to survive, or the sanitiser is just breaking the plugin.
ok(Safe.plainOneLine("Quebec City, Canada", 80) === "Quebec City, Canada", "plain text is untouched")
ok(Safe.plainOneLine("Marrakesh", 80) === "Marrakesh", "accented text survives")
ok(Safe.plainOneLine("D-AIGW", 80) === "D-AIGW", "hyphens survive")
ok(Safe.creditText('<a href="#">Cedric Bonhomme</a>', 120) === "Cedric Bonhomme",
   "a credit link unwraps to its text", JSON.stringify(Safe.creditText('<a href="#">Cedric Bonhomme</a>', 120)))
ok(Safe.titleText("File:Kyoto_City_Government_-_panoramio.jpg", 90) === "Kyoto City Government - panoramio",
   "a file title cleans up", JSON.stringify(Safe.titleText("File:Kyoto_City_Government_-_panoramio.jpg", 90)))
ok(Safe.licenceText("CC BY-SA 4.0") === "CC BY-SA 4.0", "a licence survives its whitelist")
ok(Safe.licenceText("CC0") === "CC0", "CC0 survives")
ok(Safe.plainOneLine(undefined, 80) === "", "undefined is empty")
ok(Safe.plainOneLine(null, 80) === "", "null is empty")

// --------------------------------------------------------------------- report

console.log(`${checks - failures}/${checks} checks passed`)
if (failures > 0) {
  console.error(`${failures} FAILED`)
  process.exit(1)
}

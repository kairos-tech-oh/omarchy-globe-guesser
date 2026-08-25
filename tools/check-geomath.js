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

    // Mercator sends the poles to infinity and every tile scheme cuts the world
    // off at 85.05 degrees instead. A point beyond that is clamped on the way
    // out, so it cannot come back as itself -- that is the projection working,
    // not a rounding failure, and it is asserted as clamping further down.
    if (view.mode === "map" && Math.abs(lat) > Geo.MERCATOR_MAX_LAT) continue

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

// At zoom 1 the whole usable world has to be inside a wide, short pane. This is
// the regression that clipped the Arctic off the board, restated for Mercator:
// the world is square here, so it is fitted to the SHORTER pane dimension, and
// anything wider than that repeats rather than being cut off.
{
  const view = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
  for (const [lat, lon] of [[85, 0], [-85, 0], [0, -180], [0, 179.99],
                            [71, -8], [64.14, -21.9], [-54.8, -68.3]]) {
    const p = Geo.project(view, lat, lon)
    ok(p.x >= -1 && p.x <= view.width + 1 && p.y >= -1 && p.y <= view.height + 1,
       `whole world fits at zoom 1: (${lat},${lon})`, `got x=${p.x} y=${p.y}`)
  }
  // The world is exactly as tall as the pane at zoom 1, so the two edges land
  // on the two edges. If this drifts, the top or bottom of the map is either
  // clipped or floating.
  near(Geo.mapWorldSize(view), 330, 1e-9, "world size fits the shorter dimension")
  near(Geo.project(view, Geo.MERCATOR_MAX_LAT, 0).y, 0, 0.6, "north edge sits at the pane top")
  near(Geo.project(view, -Geo.MERCATOR_MAX_LAT, 0).y, 330, 0.6, "south edge sits at the pane bottom")
}

// ------------------------------------------------------------------ mercator

// The identities the tile grid depends on. If any of these drift, the tiles and
// the pin stop agreeing and every guess is quietly off by however much.
near(Geo.lonToWorldX(-180), 0, 1e-12, "lon -180 is world x 0")
near(Geo.lonToWorldX(0), 0.5, 1e-12, "lon 0 is world x 0.5")
near(Geo.latToWorldY(0), 0.5, 1e-12, "the equator is world y 0.5")
near(Geo.latToWorldY(Geo.MERCATOR_MAX_LAT), 0, 1e-9, "the north edge is world y 0")
near(Geo.latToWorldY(-Geo.MERCATOR_MAX_LAT), 1, 1e-9, "the south edge is world y 1")

// The world is square at exactly this latitude -- that is what makes it the
// cutoff every tile scheme uses, and getting it wrong stretches the whole map.
near(Geo.MERCATOR_MAX_LAT, 85.05112877980659, 1e-9, "the mercator cutoff")

for (let lat = -85; lat <= 85; lat += 5) {
  near(Geo.worldYToLat(Geo.latToWorldY(lat)), lat, 1e-9, `world y round trip at ${lat}`)
}
for (let lon = -180; lon < 180; lon += 15) {
  near(Geo.worldXToLon(Geo.lonToWorldX(lon)), lon, 1e-9, `world x round trip at ${lon}`)
}

// sinh is hand-rolled because V4 cannot be relied on to have Math.sinh.
for (const x of [-3, -1, -0.1, 0, 0.1, 1, 3]) {
  near(Geo.sinh(x), (Math.exp(x) - Math.exp(-x)) / 2, 1e-12, `sinh at ${x}`)
}

// Beyond the cutoff, latitude clamps rather than exploding. A pole must still
// produce a finite pixel, or the marker layer places a pin at NaN and vanishes.
{
  const view = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
  for (const lat of [90, -90, 89.9, -89.9]) {
    const p = Geo.project(view, lat, 0)
    ok(isFinite(p.x) && isFinite(p.y), `a pole still projects finitely (${lat})`,
       `got x=${p.x} y=${p.y}`)
  }
  near(Geo.project(view, 90, 0).y, Geo.project(view, Geo.MERCATOR_MAX_LAT, 0).y, 1e-9,
       "the north pole clamps to the north edge")
  near(Geo.project(view, -90, 0).y, Geo.project(view, -Geo.MERCATOR_MAX_LAT, 0).y, 1e-9,
       "the south pole clamps to the south edge")
}

// Zooming about a point must leave that point where it was. This is what breaks
// first if the drag maths and the projection maths ever disagree.
{
  for (const zoom of [1, 2.5, 8]) {
    const view = { mode: "map", width: 940, height: 330, zoom, centreLat: 40, centreLon: -3 }
    // The anchor is taken from a real coordinate rather than an arbitrary pixel,
    // because at minimum zoom the world is narrower than the pane and a pixel
    // chosen by hand can easily land in the background beside it -- where
    // unproject correctly returns nothing.
    const anchor = Geo.project(view, 45, 5)
    const px = anchor.x, py = anchor.y
    const before = Geo.unproject(view, px, py)
    const zoomed = Object.assign({}, view, { zoom: zoom * 1.25 })
    // Re-centre the way GlobeMap.zoomBy does, then confirm the anchor held.
    const after = Geo.unproject(zoomed, px, py)
    zoomed.centreLat = Geo.worldYToLat(Geo.clamp(
      Geo.latToWorldY(zoomed.centreLat) + (Geo.latToWorldY(before.lat) - Geo.latToWorldY(after.lat)), 0, 1))
    zoomed.centreLon = Geo.wrapLongitude(zoomed.centreLon + (before.lon - after.lon))
    const held = Geo.unproject(zoomed, px, py)
    near(Geo.haversineKm(before.lat, before.lon, held.lat, held.lon), 0, 1.0,
         `zoom anchor holds at z${zoom}`)
  }
}

// The flat map must refuse a click off the sheet rather than clamping onto it.
{
  const view = { mode: "map", width: 900, height: 520, zoom: 1, centreLat: 80, centreLon: 0 }
  ok(Geo.unproject(view, 450, 260) !== null, "map centre is a point")
  ok(Geo.unproject(view, 450, -400) === null, "above the top of the world is not a point")
  ok(Geo.unproject(view, 450, 2000) === null, "below the bottom of the world is not a point")
}

// One world, not a repeating strip: at minimum zoom the pane is wider than the
// world, and the background either side of it is not clickable. Two clicks in
// three would otherwise drop a pin a whole world-width from where they landed.
{
  const view = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
  const size = Geo.mapWorldSize(view)          // 330
  const left = view.width / 2 - size / 2       // 305
  const right = view.width / 2 + size / 2      // 635

  ok(Geo.unproject(view, left + 2, 165) !== null, "just inside the west edge is a point")
  ok(Geo.unproject(view, right - 2, 165) !== null, "just inside the east edge is a point")
  ok(Geo.unproject(view, left - 4, 165) === null, "the margin west of the world is not a point")
  ok(Geo.unproject(view, right + 4, 165) === null, "the margin east of the world is not a point")
  ok(Geo.unproject(view, 10, 165) === null, "the far left of the pane is not a point")
  ok(Geo.unproject(view, 930, 165) === null, "the far right of the pane is not a point")

  // The edges themselves still resolve, to the antimeridian on both sides.
  near(Math.abs(Geo.unproject(view, left, 165).lon), 180, 1e-6, "the west edge is the antimeridian")
  near(Math.abs(Geo.unproject(view, right, 165).lon), 180, 1e-6, "the east edge is the antimeridian")
}

// ---------------------------------------------------------------- tile grid

{
  const view = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
  const tiles = Geo.tileGrid(view, 64)
  ok(tiles.length > 0, "a grid is produced at minimum zoom")

  for (const t of tiles) {
    ok(Number.isInteger(t.z) && t.z >= 0 && t.z <= 19, "tile z is a valid level", JSON.stringify(t))
    const n = Math.pow(2, t.z)
    ok(Number.isInteger(t.x) && t.x >= 0 && t.x < n, "tile x is inside the pyramid", JSON.stringify(t))
    ok(Number.isInteger(t.y) && t.y >= 0 && t.y < n, "tile y is inside the pyramid", JSON.stringify(t))
    ok(isFinite(t.sx) && isFinite(t.sy) && t.size > 0, "tile geometry is finite", JSON.stringify(t))
  }

  // A tile's own top-left corner must land where the projection puts that
  // corner's coordinate. This is the assertion that the tiles and the pin agree;
  // if it drifts, every guess is quietly off by however much it drifted.
  for (const t of tiles) {
    const n = Math.pow(2, t.z)
    const lon = Geo.worldXToLon(t.x / n)
    const lat = Geo.worldYToLat(t.y / n)
    const p = Geo.project(view, lat, lon)
    near(p.x, t.sx, 0.001, `tile ${t.z}/${t.x}/${t.y} x agrees with the projection`)
    near(p.y, t.sy, 0.001, `tile ${t.z}/${t.x}/${t.y} y agrees with the projection`)
  }

  // The cap bounds what is built, because each entry becomes an Image that
  // fetches and decodes inside the shell.
  ok(Geo.tileGrid(view, 3).length <= 3, "the tile cap is honoured")
  ok(Geo.tileGrid(view, 0).length > 0, "a zero cap falls back to a sane default")

  // Tiles must cover the pane at every zoom the UI can reach, and stay bounded.
  for (const zoom of [1, 1.4, 2, 3.7, 8, 16, 40]) {
    const v = { mode: "map", width: 940, height: 330, zoom, centreLat: 48.85, centreLon: 2.29 }
    const g = Geo.tileGrid(v, 64)
    ok(g.length > 0 && g.length <= 64, `grid is non-empty and bounded at z${zoom}`,
       `got ${g.length}`)
    const px = g[0].size
    ok(px >= 256 / Math.SQRT2 - 1 && px <= 256 * Math.SQRT2 + 1,
       `tiles stay near native size at z${zoom}`, `got ${px}`)
  }
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

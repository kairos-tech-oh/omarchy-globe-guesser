// Confirms GeoMath.js, Sanitise.js and the two generated data files load and
// behave correctly under Qt's V4 engine -- the one that actually runs inside
// omarchy-shell.
//
// tools/check-geomath.js proves the same properties under Node. V4 is a
// different engine with a different JavaScript subset, and "it worked in Node"
// has never been evidence about the shell. This file closes that gap: same
// libraries, same expectations, V4 doing the arithmetic and running the regexes.
//
// Run it with:
//
//     tools/run-checks.sh
//
// The result is communicated through the exit code rather than console output,
// because Qt's `qml` runner suppresses console messages on some builds -- and an
// assertion that fails loudly is worth more than a number nobody reads. Exit 0
// means every check passed; any other value is the number of the first check
// that did not.

import QtQuick
import "../GeoMath.js" as GeoMath
import "../Sanitise.js" as Sanitise
import "../data/WorldOutline.js" as WorldOutline
import "../data/Places.js" as Places

QtObject {
  function fail(code) {
    Qt.exit(code)
    return false
  }

  Component.onCompleted: {
    // 1-9: the bundled data loaded, completely, and inside its own ceilings.
    if (!WorldOutline.RINGS || WorldOutline.RINGS.length === 0) return fail(1)
    if (WorldOutline.RINGS.length > WorldOutline.MAX_RINGS) return fail(2)
    var points = 0
    for (var r = 0; r < WorldOutline.RINGS.length; r++) points += WorldOutline.RINGS[r].length / 2
    if (points > WorldOutline.MAX_POINTS) return fail(3)
    if (!Places.PLACES || Places.PLACES.length === 0) return fail(4)
    if (Places.PLACES.length > Places.MAX_PLACES) return fail(5)
    if (Places.TIER_EASY > Places.TIER_NORMAL) return fail(6)
    if (Places.TIER_NORMAL > Places.PLACES.length) return fail(7)

    // 8: every place is a well-formed coordinate. A single bad row would put a
    // round somewhere that is not on Earth.
    for (var p = 0; p < Places.PLACES.length; p++) {
      var place = Places.PLACES[p]
      if (place.length !== 4) return fail(8)
      if (!isFinite(place[2]) || Math.abs(place[2]) > 90) return fail(8)
      if (!isFinite(place[3]) || Math.abs(place[3]) > 180) return fail(8)
    }

    // 10-19: projections round-trip under V4.
    var modes = ["map", "globe"]
    var zooms = [1, 1.7, 4, 12]
    var centres = [[0, 0], [45, -120], [-33.9, 151.2], [89, 180], [0, 179.5]]
    var samples = [[0, 0], [51.5074, -0.1278], [35.687, 139.7495], [-33.87, 151.21],
                   [90, 0], [-90, 0], [0, 180], [0, -180], [64.14, -21.9]]

    for (var m = 0; m < modes.length; m++) {
      for (var z = 0; z < zooms.length; z++) {
        for (var c = 0; c < centres.length; c++) {
          var view = { mode: modes[m], width: 900, height: 520, zoom: zooms[z],
                       centreLat: centres[c][0], centreLon: centres[c][1] }
          for (var s = 0; s < samples.length; s++) {
            var projected = GeoMath.project(view, samples[s][0], samples[s][1])
            if (!isFinite(projected.x) || !isFinite(projected.y)) return fail(10)
            if (!projected.visible) continue
            if (projected.x < 0 || projected.x > view.width) continue
            if (projected.y < 0 || projected.y > view.height) continue
            var back = GeoMath.unproject(view, projected.x, projected.y)
            if (!back) return fail(11)
            if (GeoMath.haversineKm(samples[s][0], samples[s][1], back.lat, back.lon) > 1.0)
              return fail(12)
          }
        }
      }
    }

    // 13: the back of the globe reports itself hidden. Without this the far
    // hemisphere paints mirrored over the near one.
    var globe = { mode: "globe", width: 900, height: 520, zoom: 1, centreLat: 0, centreLon: 0 }
    if (GeoMath.project(globe, 0, 180).visible) return fail(13)
    if (!GeoMath.project(globe, 0, 0).visible) return fail(13)

    // 14: a click outside the disc is not a guess.
    if (GeoMath.unproject(globe, 0, 0) !== null) return fail(14)
    var radius = GeoMath.globeRadius(globe)
    if (GeoMath.unproject(globe, 450 + radius * 1.02, 260) !== null) return fail(14)
    if (GeoMath.unproject(globe, 450 + radius * 0.98, 260) === null) return fail(14)

    // 15: and the limb itself still is one. This is the case an exact
    // comparison gets wrong: 90 degrees from centre lands a few ULPs outside
    // the radius it should equal.
    var limb = GeoMath.project(globe, 0, 90)
    if (!limb.visible) return fail(15)
    if (GeoMath.unproject(globe, limb.x, limb.y) === null) return fail(15)

    // 16: past the pole on the flat map is not a guess either.
    var flat = { mode: "map", width: 900, height: 520, zoom: 1, centreLat: 80, centreLon: 0 }
    if (GeoMath.unproject(flat, 450, -400) !== null) return fail(16)

    // 20-29: distance and scoring.
    if (Math.abs(GeoMath.haversineKm(0, 0, 0, 0)) > 1e-9) return fail(20)
    if (Math.abs(GeoMath.haversineKm(51.5074, -0.1278, 40.7128, -74.006) - 5570) > 15) return fail(21)
    // Across the antimeridian two neighbours must not read as half a planet.
    if (Math.abs(GeoMath.haversineKm(0, 179.5, 0, -179.5) - 111.2) > 1) return fail(22)
    if (GeoMath.scoreFor(0) !== 5000) return fail(23)
    if (GeoMath.scoreFor(-1) !== 0) return fail(24)
    if (GeoMath.scoreFor(NaN) !== 0) return fail(25)
    if (GeoMath.scoreFor(20000) > 5) return fail(26)
    for (var km = 0; km < 20000; km += 500) {
      if (GeoMath.scoreFor(km) < GeoMath.scoreFor(km + 500)) return fail(27)
      if (GeoMath.scoreFor(km) < 0 || GeoMath.scoreFor(km) > 5000) return fail(28)
    }
    if (GeoMath.formatNumber(25000) !== "25,000") return fail(29)

    // 30: nearest place, against the real bundled list.
    var near = GeoMath.nearestPlace(Places.PLACES, 35.02, 135.77)
    if (!near || near.distanceKm > 40) return fail(30)

    // 40-49: sanitising, under V4's regex engine rather than Node's. These are
    // the payloads marketplace reviewers use, pushed through every ingest helper
    // and through the boundary helper the bar label and tooltip actually use.
    var NUL = String.fromCharCode(0)
    var LF = String.fromCharCode(10)
    var payloads = [
      '<img src="http://127.0.0.1:1/x.png" width="300" height="40">',
      '<img' + LF + 'src=x onerror=alert(1)>',
      '&lt;img src="http://example.invalid/x.png"&gt;',
      '&#60;img src=x&#62;',
      '<!DOCTYPE html><html><body>',
      '<script>fetch("http://example.invalid")</scr' + 'ipt>',
      '<a href="//commons.wikimedia.org/wiki/User:Someone">Someone</a>',
      'line one' + LF + 'line two' + NUL
    ]

    for (var i = 0; i < payloads.length; i++) {
      var outputs = [
        Sanitise.plainOneLine(payloads[i], 200),
        Sanitise.creditText(payloads[i], 120),
        Sanitise.titleText(payloads[i], 90),
        Sanitise.licenceText(payloads[i]),
        // The boundary: whatever an ingest helper produced, wrapped again on
        // the way out, which is how label and tooltip are built.
        Sanitise.plainOneLine(Sanitise.creditText(payloads[i], 120), 200)
      ]
      for (var o = 0; o < outputs.length; o++) {
        if (outputs[o].indexOf("<") >= 0) return fail(40)
        if (outputs[o].indexOf(">") >= 0) return fail(41)
        if (outputs[o].indexOf("&") >= 0) return fail(42)
        if (/[\x00-\x1f\x7f]/.test(outputs[o])) return fail(43)
        if (outputs[o].length > 201) return fail(44)
      }
    }

    // 45-49: and real data still renders.
    if (Sanitise.plainOneLine("Quebec City, Canada", 80) !== "Quebec City, Canada") return fail(45)
    if (Sanitise.creditText('<a href="#">Cedric Bonhomme</a>', 120) !== "Cedric Bonhomme") return fail(46)
    if (Sanitise.titleText("File:Kyoto_City_Government_-_panoramio.jpg", 90)
        !== "Kyoto City Government - panoramio") return fail(47)
    if (Sanitise.licenceText("CC BY-SA 4.0") !== "CC BY-SA 4.0") return fail(48)
    if (Sanitise.plainOneLine(null, 80) !== "") return fail(49)

    // 50: the URL allowlist, which is the only gate between an API response and
    // curl's argv. Kept in step with the copy in Panel.qml by hand; if that one
    // changes, this must too.
    var allowed = /^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]{1,700}$/
    if (!allowed.test("https://upload.wikimedia.org/wikipedia/commons/thumb/d/d4/A.jpg/1280px-A.jpg"))
      return fail(50)
    if (allowed.test("https://evil.invalid/wikipedia/commons/x.jpg")) return fail(51)
    if (allowed.test("http://upload.wikimedia.org/wikipedia/commons/x.jpg")) return fail(52)
    if (allowed.test("https://upload.wikimedia.org.evil.invalid/wikipedia/commons/x.jpg")) return fail(53)
    if (allowed.test("https://upload.wikimedia.org/wikipedia/commons/x.jpg" + LF + "-o/etc/passwd"))
      return fail(54)
    if (allowed.test("-https://upload.wikimedia.org/wikipedia/commons/x.jpg")) return fail(55)
    if (allowed.test("https://upload.wikimedia.org/wikipedia/other/x.jpg")) return fail(56)

    Qt.exit(0)
  }
}

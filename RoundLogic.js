.pragma library
.import "Sanitise.js" as Sanitise

// ------------------------------------------------------------- the network

// Producer-bounded curl. Both bounds are outside QML on purpose:
//
//   head -c   closes the pipe at the byte ceiling, at the producer, before
//             StdioCollector can retain anything
//   timeout   is the deadline that still applies while curl is blocked in a
//             syscall; curl's own --max-time is the inner limit
//
// timeout 0 means *no limit*, so both bounds are clamped to at least 1: a
// computed deadline that reached zero would quietly switch the ceiling off.
// The URL and every option travel as argv entries; nothing is spliced into the
// script text.
//
// On curl\'s --max-time specifically: it is a deadline for the whole transfer,
// not a socket-idle timer that resets on every byte. Measured on curl 8.21
// against a server sending one byte every 50ms and never going idle --
// "Operation timed out after 5000 milliseconds with 100 bytes received". The
// outer `timeout` is a second wall clock regardless, so a drip-feed is bounded
// twice over.
//
// No -L. Every URL this plugin fetches is checked against a hardcoded host
// before it is used, and refusing redirects means a compromised or
// misconfigured endpoint cannot use one to send the request somewhere else.
function cappedCurl(url, capBytes, maxTimeSec, userAgent) {
  var innerSec = Math.max(1, Math.round(maxTimeSec))
  var deadlineSec = Math.max(1, innerSec + 5)
  return ["timeout", "-k", "2", String(deadlineSec),
          "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
          String(capBytes + 1),
          "-fsS", "--proto", "=https", "--max-time", String(innerSec),
          // Wikimedia serves these replies gzipped, and the JSON compresses
          // to roughly a fifth. curl inflates before writing to stdout, so
          // `head -c` still bounds the *decompressed* stream -- the ceiling
          // is not weakened by asking for compression, only the wire time is.
          "--compressed",
          "-A", String(userAgent),
          "--", String(url)]
}

// curl's exit status does not survive that pipeline -- head exits 0 whether
// curl succeeded, 404'd or was killed at the deadline -- so an empty body is
// what reports producer failure. The length check is a secondary guard only:
// String.length counts UTF-16 units rather than bytes, and head -c is the
// bound that actually holds.
function parseCappedJson(raw, capBytes) {
  var text = String(raw || "")
  if (text.trim() === "") throw new Error("empty response")
  if (text.length > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
  return JSON.parse(text)
}

// Where a round comes from.
//
// This asks *English Wikipedia* for the ARTICLES near a point and their lead
// images -- not Commons for the FILES near a point, which is what an earlier
// revision did and what made the game unplayable.
//
// The difference is the whole fix for "that photo is not a place". Commons
// geosearch returns anything anyone ever tagged with a coordinate: a plate of
// food, a beetle, a gravestone, a museum exhibit, somebody's dog. None of
// those can be guessed from, because none of them look like anywhere.
// A Wikipedia article that *has* a coordinate is, almost by definition, a
// place -- a station, a bridge, a district, a park, a temple -- and its lead
// image is a photograph of that place, chosen by an editor to show what it
// looks like.
//
// Measured over nine cities it is also five to eight times smaller on the
// wire (12.9-21.1 KiB against 89-153 KiB) and finds far more usable photos:
// Reykjavik went from 3 to 37.
//
// colimit and pilimit are set to max deliberately. Both default to 10, so
// without them only the first ten articles come back with the coordinates and
// the thumbnail that make them usable at all -- which looks exactly like a
// sparse city and is impossible to tell apart from one.
function placesUrl(latitude, longitude, radiusMetres, maxRadiusMetres) {
  var query = [
    "action=query",
    "format=json",
    "formatversion=2",
    "generator=geosearch",
    "ggscoord=" + encodeURIComponent(latitude.toFixed(5) + "|" + longitude.toFixed(5)),
    "ggsradius=" + String(clampRadius(radiusMetres, maxRadiusMetres)),
    "ggslimit=100",
    "prop=coordinates|pageimages",
    "colimit=max",
    "piprop=thumbnail|name",
    "pithumbsize=1280",
    "pilimit=max"
  ]
  return "https://en.wikipedia.org/w/api.php?" + query.join("&")
}

// 10..10000 metres, enforced here as well as at the setting, because the
// widen retry computes a radius rather than reading one.
function clampRadius(metres, maxRadiusMetres) {
  var value = Math.round(Number(metres))
  if (!isFinite(value)) return maxRadiusMetres
  return Math.min(maxRadiusMetres, Math.max(10, value))
}

// Licence and author for one file, asked of Commons at reveal time.
//
// Wikipedia's pageimages gives a usable thumbnail URL but no licence, and
// these photographs are almost all CC-licensed, so the credit has to come from
// somewhere. Fetching it per round rather than per candidate turns what would
// have been a bulk query for sixty files into a 361-byte one for the single
// file actually shown -- and it happens while the player is looking at the
// answer, off the path that decides how fast the photo appears.
function attributionUrl(fileName) {
  var query = [
    "action=query",
    "format=json",
    "formatversion=2",
    "titles=" + encodeURIComponent("File:" + fileName),
    "prop=imageinfo",
    "iiprop=extmetadata",
    "iiextmetadatafilter=LicenseShortName|Artist"
  ]
  return "https://commons.wikimedia.org/w/api.php?" + query.join("&")
}

// ------------------------------------------------------------ what counts
//
// Article lead images are already overwhelmingly photographs of places, so
// these are a second pass over a good source rather than a rescue of a bad
// one. Three filters and a score.

// Articles that carry a coordinate without being somewhere you could stand.
// Overwhelmingly events -- a battle, a siege, a terrorist attack -- which are
// pinned to where they happened and illustrated with a scroll painting or a
// memorial plaque. Also the meta-articles ("List of...", "History of...")
// and vehicles, which get a coordinate when they end up as a museum ship.
var REJECT_ARTICLE = new RegExp(
    "(rebellion|incident|\\bbattle\\b|\\bsiege\\b|\\bwar\\b|massacre|treaty"
  + "|election|disaster|\\bcrash\\b|bombing|\\battack\\b|\\briot|scandal"
  + "|murder|shooting|earthquake|\\bflood|explosion|derailment|hijack"
  + "|protest|\\bstrike\\b|championship|olympic|world cup|tournament"
  + "|^list of|^timeline of|^index of|^outline of|^history of|^culture of"
  + "|^economy of|^demographics of|^politics of|^transport in|^education in"
  + "|\\(disambiguation\\)|^(hms|uss|ss|mv|rms|hmas|hmcs) )", "i")

// Filenames that are not photographs of anywhere. Coats of arms, flags, logos
// and maps are what an administrative-division article uses when nobody has
// photographed the place; the rest are documents and artwork.
var REJECT_FILE = new RegExp(
    "(\\bmap\\b|karte|carte|mapa|logo|coat.of.arms|wappen|escudo|\\bflag\\b"
  + "|bandera|blason|blazon|\\bseal\\b|emblem|\\bcrest\\b|\\bbadge\\b"
  + "|diagram|\\bplan\\b|\\bchart\\b|banner|poster|\\bscan\\b|drawing"
  + "|painting|portrait|\\bsvg\\b|screenshot|\\bicon\\b|placeholder"
  + "|no.image|\\bcover\\b|1[0-8]\\d\\d)", "i")

// A close-up of a thing at a place is not a picture of the place. These do not
// reject outright -- a detail shot of a famous facade is still guessable --
// but they push a candidate below anything better in the same reply.
var CLOSE_UP_WORDS = new RegExp(
    "(interior|inside|\\bdetail|close.?up|macro|plaque|inscription|gravestone"
  + "|\\btomb\\b|\\bgrave\\b|statue of|bust of|\\bsign\\b|signage|\\bmenu\\b"
  + "|exhibit|artifact|artefact)", "i")

// What a guessable photograph tends to be of. Anything matching gets lifted
// above the rest of the same reply, which is what turns "a place" into "a
// place you can actually recognise something in".
var PLACE_WORDS = new RegExp(
    "(\\bview\\b|panorama|skyline|street|avenue|boulevard|\\broad\\b|square"
  + "|plaza|piazza|bridge|castle|cathedral|church|temple|mosque|synagogue"
  + "|station|\\bpark\\b|garden|harbou?r|\\bport\\b|market|tower|palace"
  + "|monument|\\bcity\\b|\\btown\\b|village|district|quarter|beach|river"
  + "|lake|mountain|valley|centre|center|\\bhall\\b|museum|stadium|airport"
  + "|university|cityscape|aerial|waterfront|old.town)", "i")

// The URL a photo may be downloaded from. Hardcoded host, hardcoded path
// prefix, and a character set that leaves no room for a newline, a space or a
// leading dash. This is the only gate between an API response and curl's argv.
//
// Every one of 254 thumbnails sampled across six cities was served from this
// host, including the ones Wikipedia hands back with utm_* query parameters
// appended -- which is why the character class has to admit ? & and =.
var ALLOWED_PHOTO_URL =
    /^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]{1,700}$/

// A Commons filename is about to be spliced into a URL query and handed to
// curl as argv. encodeURIComponent does the escaping and the value never
// reaches a shell, so the only things worth refusing here are a length no
// real filename has and the control characters -- a newline above all --
// that could forge structure inside the request.
//
// Deliberately NOT a shell-metacharacter blocklist. An earlier revision also
// refused quotes, ampersands and backticks, which sounds prudent and cost
// 6.6% of real filenames when measured against 333 of them: every one a
// legitimate French or Italian name -- Musee de l'homme, Pont de l'Alma,
// Sant'Andrea al Quirinale. Refusing characters that were never dangerous on
// this path silently deleted the best photographs in some of the best cities.
function safeFileName(value) {
  var name = String(value === undefined || value === null ? "" : value)
  if (name.length === 0 || name.length > 240) return ""
  if (/[\u0000-\u001f\u007f]/.test(name)) return ""
  return name
}

function parseCandidates(raw, capBytes, maxCandidates) {
  var parsed = parseCappedJson(raw, capBytes)
  var pages = parsed && parsed.query && Array.isArray(parsed.query.pages)
      ? parsed.query.pages : []

  var out = []
  for (var i = 0; i < pages.length && out.length < maxCandidates; i++) {
    var page = pages[i]
    if (!page || typeof page !== "object") continue

    var thumb = page.thumbnail
    var coords = Array.isArray(page.coordinates) && page.coordinates.length > 0
        ? page.coordinates[0] : null
    if (!thumb || !coords) continue

    var fileName = safeFileName(page.pageimage)
    if (fileName === "") continue

    // The extension is checked on the FILE, not on the thumbnail URL.
    // Wikimedia renders an SVG thumbnail as a PNG, so a coat of arms arrives
    // with PNG magic bytes and sails through the download check -- 14 of 254
    // sampled lead images were SVG, and every one was a crest or a logo.
    if (!/\.(jpe?g|png)$/i.test(fileName)) continue

    var articleTitle = String(page.title || "")
    if (articleTitle === "") continue
    if (REJECT_ARTICLE.test(articleTitle)) continue
    if (REJECT_FILE.test(fileName)) continue

    // The thumbnail is capped at 1280 wide, so a small one means the original
    // was small -- usually a thumbnail-sized upload rather than a photograph.
    var width = Number(thumb.width)
    var height = Number(thumb.height)
    if (!(width >= 640) || !(height >= 400)) continue

    var latitude = Number(coords.lat)
    var longitude = Number(coords.lon)
    if (!isFinite(latitude) || !isFinite(longitude)) continue
    if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) continue

    var url = String(thumb.source || "")
    if (!ALLOWED_PHOTO_URL.test(url)) continue

    var haystack = articleTitle + " " + fileName
    var score = 0
    if (PLACE_WORDS.test(haystack)) score += 2
    if (CLOSE_UP_WORDS.test(haystack)) score -= 3
    // Landscape, and large. Both correlate with a photograph taken to show
    // somewhere rather than to document an object.
    if (width > height) score += 1
    if (width >= 1000) score += 1

    out.push({
      lat: latitude,
      lon: longitude,
      url: url,
      file: fileName,
      score: score,
      // Sanitised as it enters, so nothing downstream -- including anything
      // added later -- has to remember to do it.
      title: Sanitise.plainOneLine(articleTitle, 90)
    })
  }
  return out
}

// Picks one candidate, preferring the most place-like.
//
// Not simply the highest score: taking the single best would make a city show
// the same photograph every time it came up, because the ranking is
// deterministic. Everything within one point of the best is eligible, and the
// choice among those is random -- so the game stays varied while still never
// reaching for the worst thing in the reply when it has a better option.
function chooseCandidate(candidates, random) {
  var best = -Infinity
  var i
  for (i = 0; i < candidates.length; i++)
    if (candidates[i].score > best) best = candidates[i].score

  var shortlist = []
  for (i = 0; i < candidates.length; i++)
    if (candidates[i].score >= best - 1) shortlist.push(candidates[i])

  return shortlist[Math.floor(random() * shortlist.length)]
}

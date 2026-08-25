import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GeoMath.js" as GeoMath
import "Sanitise.js" as Sanitise
import "data/Places.js" as Places

// Globe Guesser: the game, the two network calls it makes, and the one small
// file it keeps.
//
// The map and the globe never touch the network -- they are drawn from bundled
// Natural Earth outlines in GlobeMap.qml -- so the guessing half of the game
// works with the machine offline. Only the photograph needs a connection, and
// it comes from Wikimedia Commons, anonymously and without an API key.
//
// Two requests per round, both described at the Process that issues them:
//
//   1. one api.php query returning candidate photos near a city, each with its
//      own coordinates, licence and author
//   2. one download of the single chosen photo to a private directory
//
// The downloaded file is what Image renders. Image.source is never pointed at a
// network URL: the address arrives inside an API response, so it is
// attacker-influenced, and a remote Image would hand that response an unbounded
// fetch and decode inside the shared, long-lived shell process.
Panel {
  id: root
  moduleName: "kairos.globe-guesser"

  // One panel instance exists per bar, so on a multi-monitor desktop several
  // would race to claim the same IPC name and whichever registered first would
  // win. Only the largest screen's instance claims it, so
  //
  //     omarchy-shell kairos.globe-guesser toggle
  //
  // always acts on a predictable panel -- and is bindable to a key.
  readonly property var panelScreen: anchorItem && anchorItem.QsWindow.window
    ? anchorItem.QsWindow.window.screen : null
  readonly property var mainScreen: {
    var best = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }
  ipcTarget: panelScreen && panelScreen === mainScreen ? moduleName : ""

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false

  // ---------------------------------------------------------------- settings
  //
  // Every one of these is clamped here rather than trusted, and every one has a
  // matching entry in manifest.json. The manifest is what the shell's settings
  // UI and a reviewer read, so the two drifting apart is a defect in itself.
  readonly property string difficulty: {
    var value = String(setting("difficulty", "normal"))
    return ["easy", "normal", "hard"].indexOf(value) >= 0 ? value : "normal"
  }
  readonly property int roundsPerGame:
      Math.min(10, Math.max(3, parseInt(setting("roundsPerGame", 5), 10) || 5))
  readonly property string defaultView: setting("defaultView", "map") === "globe" ? "globe" : "map"
  readonly property int searchRadiusKm:
      Math.min(50, Math.max(5, parseInt(setting("searchRadiusKm", 10), 10) || 10))

  // ---------------------------------------------------------------- ceilings
  //
  // Sized from measured replies. A Commons geosearch page with imageinfo and
  // extmetadata for 60 files measured 89-153 KiB across eight cities; 512 KiB is
  // more than three times the largest of those and is still a hard bound on what
  // the shell can be made to hold. The bound is applied at the producer, by
  // `head -c`, because StdioCollector retains the whole of stdout before any
  // signal fires -- a check inside onStreamFinished is downstream of the
  // allocation it claims to prevent.
  readonly property int metaCapBytes: 524288
  readonly property int stateCapBytes: 65536

  // Both helper scripts emit a filesystem path on stdout. PATH_MAX is 4096, so
  // anything longer is not a path this system can even open.
  //
  // The producer is asked for one byte more than this, and a reply that reaches
  // the ceiling is rejected rather than used. That distinction matters here more
  // than it looks: a path cut off at exactly the ceiling still matches the shape
  // check below, so bounding at the ceiling itself would hand back a
  // valid-looking directory or filename that is not the one the script created.
  readonly property int pathCapBytes: 4096

  // Six megabytes is generous for a 1280px JPEG (a measured one was 418 KiB) and
  // is enforced by curl itself, before the bytes are written.
  readonly property int photoCapBytes: 6000000

  // How many candidate photos are retained from one reply. gslimit is a request,
  // not a guarantee, so the list is cut before QML holds it.
  readonly property int maxCandidates: 40

  // The Wikimedia user-agent policy requires a request to identify the
  // application; a stock library User-Agent is explicitly not acceptable.
  readonly property string userAgent:
      "omarchy-globe-guesser/1.0.0 (+https://github.com/kairos-tech-oh/omarchy-globe-gueser)"

  // Commons is generous with anonymous read queries and this plugin makes one
  // per round, but a player leaning on Skip should not be able to turn that into
  // a burst. Anything arriving sooner is queued, not dropped and not sent.
  readonly property int minRequestGapMs: 1000
  property real lastRequestMs: 0

  // ------------------------------------------------------------- game state
  //
  // phase drives the whole UI:
  //   idle      the start screen
  //   loading   fetching this round's photo
  //   guessing  photo is up, waiting for a guess
  //   revealed  guess locked in, answer shown
  //   summary   the game is over
  property string phase: "idle"

  // The round on screen. { lat, lon, title, credit, licence, path, city, country }
  property var round: null

  // The next round, fetched while the player reads the reveal so that Next is
  // instant. One slot, discarded when a game ends.
  property var pendingRound: null
  property bool pendingFailed: false

  property var guess: null
  property int roundIndex: 0
  property int totalScore: 0
  property var results: []
  property string mapMode: "map"
  property string statusText: ""

  // Indices into Places.PLACES already used this game, so one game cannot show
  // the same city twice.
  property var usedPlaces: []

  // Set once at construction. "" means there was nowhere private to write, and
  // the game refuses to start rather than falling back to a shared directory.
  property string cacheDir: ""
  property bool cacheChecked: false

  // -------------------------------------------------------------- highscores
  property int bestScore: 0
  property int gamesPlayed: 0
  property bool stateLoaded: false

  // ---------------------------------------------------------------- the pool
  //
  // The ceiling from the generator is re-applied here. A cap that only exists in
  // tools/build-world.py is a cap the running shell does not have: the shell
  // loads whatever bytes are on disk.
  readonly property var places: {
    var all = Places.PLACES
    if (!Array.isArray(all)) return []
    var limit = Math.min(Places.MAX_PLACES || 1000, 1000)
    var out = []
    for (var i = 0; i < all.length && out.length < limit; i++) {
      var place = all[i]
      if (!Array.isArray(place) || place.length < 4) continue
      var latitude = Number(place[2])
      var longitude = Number(place[3])
      if (!isFinite(latitude) || !isFinite(longitude)) continue
      if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) continue
      out.push([String(place[0]), String(place[1]), latitude, longitude])
    }
    return out
  }

  readonly property int poolSize: {
    if (root.difficulty === "easy") return Math.min(Places.TIER_EASY || 150, root.places.length)
    if (root.difficulty === "normal") return Math.min(Places.TIER_NORMAL || 500, root.places.length)
    return root.places.length
  }

  // ------------------------------------------------------------- bar surface
  //
  // `label` and `tooltip` are the two strings that leave this plugin for text
  // sinks it does not own. The shell renders both through components that set no
  // textFormat and therefore fall back to Qt's Text.AutoText -- Ui/WidgetButton
  // for the label, plugins/bar/Bar.qml for the tooltip. A plugin cannot set a
  // property on a Text it does not own, so the string has to be safe before it
  // goes.
  //
  // Both are wrapped wholesale rather than field by field, so a part added to
  // either later is covered without anyone having to remember. Today every
  // piece is a plugin-authored constant or a formatted number; the point is that
  // the boundary is guarded, not that the current contents happen to be safe.
  readonly property string label: Sanitise.plainOneLine(root.composeLabel(), 40)

  function composeLabel() {
    if (root.phase === "guessing" || root.phase === "revealed" || root.phase === "loading")
      return "GLOBE " + (root.roundIndex + 1) + "/" + root.roundsPerGame
    if (root.bestScore > 0) return "GLOBE " + GeoMath.formatNumber(root.bestScore)
    return "GLOBE"
  }

  readonly property string tooltip: Sanitise.plainOneLine(root.composeTooltip(), 200)

  function composeTooltip() {
    if (root.cacheChecked && root.cacheDir === "")
      return "Globe Guesser: no private directory to cache photos in"
    var parts = ["Globe Guesser"]
    if (root.phase === "guessing") parts.push("round " + (root.roundIndex + 1) + " — make a guess")
    else if (root.phase === "revealed") parts.push("round " + (root.roundIndex + 1) + " — scored")
    else if (root.phase === "loading") parts.push("finding a photo")
    if (root.bestScore > 0) parts.push("best " + GeoMath.formatNumber(root.bestScore))
    if (root.gamesPlayed > 0) parts.push(root.gamesPlayed + (root.gamesPlayed === 1 ? " game" : " games"))
    return parts.join(" · ")
  }

  // ---------------------------------------------------------- panel plumbing

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    setCenterHoverRevealSuppressed(true)
    root.controller.show()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && root.bar.shell && typeof root.bar.shell.focusAdjacentPanel === "function")
      root.bar.shell.focusAdjacentPanel(root.barIdentity, direction)
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  // ------------------------------------------------------------ private dir
  //
  // Photos are written to $XDG_RUNTIME_DIR/omarchy-globe-guesser, which is
  // /run/user/<uid>: mode 0700, owned by this user, and cleared at logout. If
  // that is not available the fallback is $HOME/.cache/omarchy-globe-guesser.
  //
  // There is deliberately no /tmp fallback, not even a last-resort one. /tmp is
  // shared and predictable, so another local user can pre-create a path there as
  // a symlink and redirect a write into a file of their choosing. With nowhere
  // private to write, this plugin does nothing and says so -- it is a game, and
  // failing closed costs nothing worth a foothold.
  //
  // The candidates are passed as arguments, never spliced into the script text,
  // and the directory is created private and then verified: a directory, not a
  // symlink, and owned by us.
  readonly property string dirScript:
    'for d in "$@"; do\n' +
    '  [ -n "$d" ] || continue\n' +
    '  mkdir -m 700 -p -- "$d" 2>/dev/null || continue\n' +
    '  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue\n' +
    '  printf %s "$d" | head -c ' + (pathCapBytes + 1) + '\n' +
    '  exit 0\n' +
    'done\n' +
    'exit 1\n'

  Process {
    id: dirProcess
    running: true
    command: {
      var runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
      var home = Quickshell.env("HOME") || ""
      var candidates = []
      if (runtime !== "") candidates.push(runtime + "/omarchy-globe-guesser")
      if (home !== "") candidates.push(home + "/.cache/omarchy-globe-guesser")
      return ["timeout", "-k", "2", "6", "sh", "-c", root.dirScript, "sh"].concat(candidates)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/[\r\n]+$/, "")
        // At or over the ceiling means the reply was cut off, and a cut-off
        // path still looks like a path. Nothing, rather than the wrong
        // directory.
        if (path.length > root.pathCapBytes) path = ""
        // An absolute path with no surprises in it, or nothing. This is the
        // value every later argv splices a filename onto.
        root.cacheDir = /^\/[A-Za-z0-9._\/-]+$/.test(path) ? path : ""
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.cacheDir = ""
      root.cacheChecked = true
    }
  }

  // ------------------------------------------------------------ persistence
  //
  // One small file: the best score and how many games have been finished.
  readonly property string statePath: {
    var stateHome = Quickshell.env("XDG_STATE_HOME") || ""
    if (stateHome === "") {
      var home = Quickshell.env("HOME") || ""
      if (home === "") return ""
      stateHome = home + "/.local/state"
    }
    return stateHome + "/omarchy/globe-guesser-state.json"
  }

  // Read once, bounded, at the producer.
  //
  // Not FileView: it exposes no way to bound a read, so a state file that has
  // been grown to a gigabyte by anything at all is pulled whole into the shell
  // before a size check downstream could refuse it.
  //
  // cap+1 bytes are requested, not cap. `head -c cap` on an oversized file
  // yields a valid-looking JSON prefix, which would be accepted and then written
  // back as permanently truncated state. Asking for one more byte than the
  // ceiling is what makes "exactly at the limit" distinguishable from "cut off".
  //
  // The bytes that arrive are the bytes that are validated and used. There is no
  // second open: a stat followed by a separate read is a window in which the
  // file can be replaced, and what was checked is then not what was loaded.
  Process {
    id: stateReader
    running: root.statePath !== ""
    command: ["timeout", "-k", "2", "6", "head", "-c", String(root.stateCapBytes + 1), "--", root.statePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
    onExited: function (exitCode) {
      // A missing file is the normal first run, not an error.
      if (exitCode !== 0) root.stateLoaded = true
    }
  }

  function applyState(raw) {
    root.stateLoaded = true
    try {
      var text = String(raw || "")
      if (text.trim() === "") return
      // Over the ceiling means corrupt or hostile either way. Defaults take
      // over silently: this is a score file, not something worth interrupting
      // anyone over.
      if (text.length > root.stateCapBytes) return

      var parsed = JSON.parse(text)
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return

      // Every field re-derived and re-bounded. Nothing is carried across on
      // trust, and unknown keys simply never make it into a property.
      var best = Number(parsed.bestScore)
      var played = Number(parsed.gamesPlayed)
      root.bestScore = isFinite(best) ? Math.min(50000, Math.max(0, Math.round(best))) : 0
      root.gamesPlayed = isFinite(played) ? Math.min(1000000, Math.max(0, Math.round(played))) : 0
    } catch (error) {
      root.bestScore = 0
      root.gamesPlayed = 0
    }
  }

  // Written through the same hardened-directory discipline as the photo cache:
  // the directory is created 0700 and verified, the payload arrives on stdin
  // rather than in argv, and it lands on a mktemp name that is then renamed into
  // place. A fixed `.tmp` sibling would be predictable, and predictable is what
  // lets someone else decide where a truncating write actually goes.
  readonly property string writeScript:
    'p="$1"; d=$(dirname -- "$p")\n' +
    'mkdir -m 700 -p -- "$d" 2>/dev/null || exit 1\n' +
    '[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || exit 1\n' +
    't=$(mktemp "$d/.globe-guesser.XXXXXXXX") || exit 1\n' +
    'chmod 600 -- "$t" || { rm -f -- "$t"; exit 1; }\n' +
    'cat > "$t" || { rm -f -- "$t"; exit 1; }\n' +
    'mv -f -- "$t" "$p" || { rm -f -- "$t"; exit 1; }\n'

  Process {
    id: stateWriter
    property string payload: ""
    stdinEnabled: true

    // Written here rather than straight after `running = true`: assigning
    // running and writing on the next line races the spawn, and a payload
    // written before the child exists is simply dropped -- which would truncate
    // the state file rather than fail visibly.
    onStarted: {
      write(payload)
      payload = ""
      // Closing stdin is what lets `cat` in the script see end of input and
      // finish; without it the write never completes and timeout kills it.
      stdinEnabled = false
    }
  }

  function saveState() {
    if (root.statePath === "" || stateWriter.running) return
    // Only these two keys are ever written, so a field retired from a future
    // version drops out of the file on its own rather than lingering.
    stateWriter.payload = JSON.stringify({
      bestScore: root.bestScore,
      gamesPlayed: root.gamesPlayed
    }) + "\n"
    stateWriter.command = ["timeout", "-k", "2", "6", "sh", "-c", root.writeScript, "sh", root.statePath]
    stateWriter.stdinEnabled = true
    stateWriter.running = true
  }

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
  // No -L. Every URL this plugin fetches is checked against a hardcoded host
  // before it is used, and refusing redirects means a compromised or
  // misconfigured endpoint cannot use one to send the request somewhere else.
  function cappedCurl(url, capBytes, maxTimeSec) {
    var innerSec = Math.max(1, Math.round(maxTimeSec))
    var deadlineSec = Math.max(1, innerSec + 5)
    return ["timeout", "-k", "2", String(deadlineSec),
            "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
            String(capBytes + 1),
            "-fsS", "--proto=https", "--max-time", String(innerSec),
            "-A", root.userAgent,
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

  function commonsUrl(latitude, longitude, radiusMetres) {
    var query = [
      "action=query",
      "format=json",
      "formatversion=2",
      "generator=geosearch",
      "ggscoord=" + encodeURIComponent(latitude.toFixed(5) + "|" + longitude.toFixed(5)),
      "ggsradius=" + String(Math.round(radiusMetres)),
      "ggsnamespace=6",
      "ggslimit=60",
      "prop=coordinates|imageinfo",
      "iiprop=url|size|mime|extmetadata",
      "iiurlwidth=1280",
      "iiextmetadatafilter=LicenseShortName|Artist"
    ]
    return "https://commons.wikimedia.org/w/api.php?" + query.join("&")
  }

  // Titles that are reliably not photographs of a place. Commons geosearch
  // returns whatever is tagged with coordinates, which includes a great many
  // maps, coats of arms and scanned documents; without this a round in three is
  // a picture of a municipal crest.
  readonly property var rejectTitle: /(\bmap\b|karte|carte|mapa|logo|coat.of.arms|wappen|escudo|\bflag\b|bandera|diagram|\bplan\b|\bchart\b|blazon|\bseal\b|banner|poster|\bscan\b|drawing|painting|\bsvg\b|1[0-8]\d\d)/i

  // The URL a photo may be downloaded from. Hardcoded host, hardcoded path
  // prefix, and a character set that leaves no room for a newline, a space or a
  // leading dash. This is the only gate between an API response and curl's argv.
  readonly property var allowedPhotoUrl:
      /^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]{1,700}$/

  function parseCandidates(raw) {
    var parsed = root.parseCappedJson(raw, root.metaCapBytes)
    var pages = parsed && parsed.query && Array.isArray(parsed.query.pages)
        ? parsed.query.pages : []

    var out = []
    for (var i = 0; i < pages.length && out.length < root.maxCandidates; i++) {
      var page = pages[i]
      if (!page || typeof page !== "object") continue

      var info = Array.isArray(page.imageinfo) && page.imageinfo.length > 0 ? page.imageinfo[0] : null
      var coords = Array.isArray(page.coordinates) && page.coordinates.length > 0 ? page.coordinates[0] : null
      if (!info || !coords) continue

      if (info.mime !== "image/jpeg" && info.mime !== "image/png") continue
      if (Number(info.width) < 800 || Number(info.height) < 600) continue

      var title = String(page.title || "")
      if (root.rejectTitle.test(title)) continue

      var latitude = Number(coords.lat)
      var longitude = Number(coords.lon)
      if (!isFinite(latitude) || !isFinite(longitude)) continue
      if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) continue

      var url = String(info.thumburl || info.url || "")
      if (!root.allowedPhotoUrl.test(url)) continue

      var extra = info.extmetadata || {}
      out.push({
        lat: latitude,
        lon: longitude,
        url: url,
        // Sanitised as it enters, so nothing downstream -- including anything
        // added later -- has to remember to do it. The Commons Artist field is
        // literal HTML by design, so creditText unwraps tags to their text
        // instead of deleting them outright.
        title: Sanitise.titleText(title, 90),
        credit: Sanitise.creditText(extra.Artist ? extra.Artist.value : "", 90),
        licence: Sanitise.licenceText(extra.LicenseShortName ? extra.LicenseShortName.value : "")
      })
    }
    return out
  }

  // Which slot the reply in flight belongs to: "current" for the round the
  // player is waiting on, "pending" for the one being fetched behind the reveal.
  property string fetchTarget: "current"
  property var fetchPlace: null
  property bool fetchWidened: false

  Process {
    id: metaProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var candidates = root.parseCandidates(text)
          if (candidates.length < 3 && !root.fetchWidened) {
            // A thin result usually means a city centre nobody photographs.
            // Widening once is cheaper than throwing the city away.
            root.fetchWidened = true
            root.requestMeta(root.fetchPlace, root.searchRadiusKm * 2500)
            return
          }
          if (candidates.length === 0) throw new Error("no usable photos")
          root.beginDownload(candidates[Math.floor(Math.random() * candidates.length)])
        } catch (error) {
          root.fetchFailed("No photos found near there.")
        }
      }
    }
    onExited: function (exitCode) {
      // head masks curl's status, so a non-zero exit here is the outer timeout
      // or a failure to spawn. onStreamFinished has already run for the success
      // path; guard against reporting twice.
      if (exitCode !== 0 && root.phase === "loading" && root.round === null)
        root.fetchFailed("Could not reach Wikimedia Commons.")
    }
  }

  // Download, magic-check and prune, in one script so the bytes that are checked
  // are the bytes that are kept.
  //
  //   $1 the private directory   $2 the URL   $3 the user agent
  //
  // The file is created by mktemp inside a directory that has just been
  // re-verified as ours, so its name cannot be guessed or pre-created. curl
  // enforces the byte ceiling itself with --max-filesize, before anything is
  // written, and the first four bytes are then checked against the two formats
  // this plugin will render. A reply that is not a JPEG or a PNG is deleted
  // rather than handed to an image decoder.
  //
  // Two prunes, because each catches what the other misses.
  //
  // By age, for files an earlier session left behind. By count, for this one:
  // an age bound alone lets a long sitting accumulate a photo per round for an
  // hour, and these live in tmpfs, which is RAM.
  //
  // Two existing files are kept, not one, and the prune runs before mktemp, so
  // the ceiling is three: during a reveal the round on screen and the one being
  // prefetched behind it are both live, and this run is about to add a third.
  // Pruning harder would delete a photo that is about to be shown.
  //
  // LC_ALL=C is pinned on both the find and the sort: %T@ is printed with a dot
  // as its decimal separator, and a numeric sort under a locale that uses a
  // comma would order the timestamps wrongly and delete the newest files. The
  // names come from mktemp, so they hold no whitespace for `read -r` to trip on.
  readonly property string downloadScript:
    'd="$1"; u="$2"; ua="$3"\n' +
    '[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || exit 1\n' +
    'find "$d" -maxdepth 1 -type f -name "photo.*" -mmin +60 -delete 2>/dev/null\n' +
    'LC_ALL=C find "$d" -maxdepth 1 -type f -name "photo.*" -printf "%T@\\t%p\\n" 2>/dev/null \\\n' +
    '  | LC_ALL=C sort -rn | tail -n +3 | cut -f2- \\\n' +
    '  | while IFS= read -r old; do rm -f -- "$old"; done\n' +
    't=$(mktemp "$d/photo.XXXXXXXX") || exit 1\n' +
    'chmod 600 -- "$t" || { rm -f -- "$t"; exit 1; }\n' +
    'curl -fsS --proto "=https" --max-time 20 --max-filesize ' + photoCapBytes +
      ' -A "$ua" -o "$t" -- "$u" || { rm -f -- "$t"; exit 2; }\n' +
    'magic=$(od -An -tx1 -N4 -- "$t" | tr -d " \\n")\n' +
    'case "$magic" in\n' +
    '  ffd8ff??) ;;\n' +
    '  89504e47) ;;\n' +
    '  *) rm -f -- "$t"; exit 3 ;;\n' +
    'esac\n' +
    'printf %s "$t" | head -c ' + (pathCapBytes + 1) + '\n'

  property var downloadCandidate: null

  Process {
    id: photoProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/[\r\n]+$/, "")
        // The path came back out of our own script, but it is still checked --
        // for length first, because a truncated path keeps the prefix that the
        // containment check looks at, and then for containment.
        if (path.length > root.pathCapBytes
            || root.cacheDir === "" || path.indexOf(root.cacheDir + "/photo.") !== 0) {
          root.fetchFailed("The photo did not arrive intact.")
          return
        }
        root.deliverRound(path)
      }
    }
    onExited: function (exitCode) {
      if (exitCode === 0) return
      root.fetchFailed(exitCode === 3 ? "That file was not an image."
                                      : "Could not download the photo.")
    }
  }

  // ------------------------------------------------------------- round flow

  function pickPlace() {
    if (root.poolSize <= 0) return null
    // Every city in the tier is eligible except the ones already seen this
    // game. Sampling with retries rather than building an exclusion list keeps
    // this O(1) in the common case; the pool is at least 150 and a game is at
    // most 10 rounds, so the loop cannot run long.
    for (var attempt = 0; attempt < 60; attempt++) {
      var index = Math.floor(Math.random() * root.poolSize)
      if (root.usedPlaces.indexOf(index) >= 0) continue
      var used = root.usedPlaces.slice(0)
      used.push(index)
      root.usedPlaces = used
      return root.places[index]
    }
    return root.places[Math.floor(Math.random() * root.poolSize)]
  }

  function requestMeta(place, radiusMetres) {
    if (!place) {
      root.fetchFailed("No cities available.")
      return
    }
    root.fetchPlace = place

    var now = Date.now()
    var wait = Math.max(0, root.minRequestGapMs - (now - root.lastRequestMs))

    // Reassigning `command` on a Process that has not exited yet is undefined
    // behaviour, and the widen-radius retry is issued from inside
    // onStreamFinished -- which runs *before* the process exits. Waiting is not
    // an optimisation here; it is what makes that path work on purpose rather
    // than by accident.
    if (metaProcess.running || photoProcess.running) wait = Math.max(wait, 250)

    if (wait > 0) {
      // Queued, not dropped and not sent early: ten frantic clicks on Skip
      // collapse into one request rather than ten. The timer calls back into
      // this function, so a still-running process simply defers again.
      gapTimer.pendingRadius = radiusMetres
      gapTimer.interval = wait
      gapTimer.restart()
      return
    }
    root.lastRequestMs = now
    metaProcess.command = root.cappedCurl(
        root.commonsUrl(place[2], place[3], radiusMetres), root.metaCapBytes, 15)
    metaProcess.running = true
  }

  Timer {
    id: gapTimer
    property real pendingRadius: 10000
    repeat: false
    onTriggered: root.requestMeta(root.fetchPlace, pendingRadius)
  }

  function beginDownload(candidate) {
    if (root.cacheDir === "") {
      root.fetchFailed("No private directory to cache photos in.")
      return
    }
    root.downloadCandidate = candidate
    photoProcess.command = ["timeout", "-k", "2", "30", "sh", "-c", root.downloadScript, "sh",
                            root.cacheDir, candidate.url, root.userAgent]
    photoProcess.running = true
  }

  function deliverRound(path) {
    var candidate = root.downloadCandidate
    if (!candidate) return
    var nearest = GeoMath.nearestPlace(root.places, candidate.lat, candidate.lon)

    var built = {
      lat: candidate.lat,
      lon: candidate.lon,
      title: candidate.title,
      credit: candidate.credit,
      licence: candidate.licence,
      path: path,
      city: nearest ? Sanitise.plainOneLine(nearest.name, 60) : "",
      country: nearest ? Sanitise.plainOneLine(nearest.country, 60) : "",
      cityKm: nearest ? nearest.distanceKm : NaN
    }

    if (root.fetchTarget === "pending") {
      root.pendingRound = built
      return
    }

    root.round = built
    root.guess = null
    root.statusText = ""
    root.phase = "guessing"
  }

  // How many different cities one round may try before giving up. Commons
  // coverage is uneven -- a place can be tagged with nothing but municipal
  // crests, or with nothing at all -- and on hard difficulty, where the pool
  // runs down to towns of a few hundred thousand, that is common rather than
  // rare. Dead-ending the round on the first miss would make the harder
  // settings feel broken when they are merely thinly photographed.
  readonly property int maxFetchAttempts: 5
  property int fetchAttempts: 0

  function fetchFailed(message) {
    if (root.fetchTarget === "pending") {
      // A failed prefetch is not worth telling anyone about: Next simply
      // fetches for itself when it is pressed.
      root.pendingFailed = true
      return
    }

    if (root.fetchAttempts < root.maxFetchAttempts) {
      root.fetchAttempts += 1
      root.fetchWidened = false
      root.statusText = ""
      root.phase = "loading"
      root.requestMeta(root.pickPlace(), root.searchRadiusKm * 1000)
      return
    }

    root.statusText = message
    root.phase = "error"
  }

  function fetchRound(target) {
    root.fetchTarget = target
    root.fetchWidened = false
    root.fetchAttempts = 0
    if (target === "current") {
      root.round = null
      root.guess = null
      root.statusText = ""
      root.phase = "loading"
    }
    root.requestMeta(root.pickPlace(), root.searchRadiusKm * 1000)
  }

  function startGame() {
    if (root.cacheDir === "") {
      root.statusText = "There is nowhere private to cache photos, so the game cannot start. "
          + "Neither XDG_RUNTIME_DIR nor ~/.cache was usable."
      root.phase = "error"
      return
    }
    root.roundIndex = 0
    root.totalScore = 0
    root.results = []
    root.usedPlaces = []
    root.pendingRound = null
    root.pendingFailed = false
    root.mapMode = root.defaultView
    if (mapLoader.item) mapLoader.item.resetView()
    root.fetchRound("current")
  }

  function placeGuess(latitude, longitude) {
    if (root.phase !== "guessing") return
    root.guess = { lat: latitude, lon: longitude }
  }

  // Arrow keys (and hjkl, which PanelKeyCatcher folds into the same signal)
  // nudge the pin, so a round can be played without ever reaching for the
  // mouse. On a desktop driven by the keyboard, a game that demands a pointer
  // is a game half the users cannot play.
  //
  // The first press drops the pin wherever the view is centred, so there is
  // always something to move; after that each press walks it. The step shrinks
  // as the map is zoomed in, so the same key is a coarse sweep at world scale
  // and a fine adjustment close up.
  function nudgeGuess(dx, dy) {
    if (root.phase !== "guessing") return
    if (!mapLoader.item) return

    if (!root.guess) {
      root.guess = { lat: mapLoader.item.centreLat, lon: mapLoader.item.centreLon }
      return
    }

    var step = 5 / Math.max(1, mapLoader.item.zoom)
    root.guess = {
      // Clamped rather than wrapped: walking off the top of the world and
      // reappearing at the bottom is disorienting, and the poles are a real
      // place a guess can legitimately sit.
      lat: GeoMath.clamp(root.guess.lat - dy * step, -90, 90),
      // Wrapped, because east of the antimeridian genuinely is west of it.
      lon: GeoMath.wrapLongitude(root.guess.lon + dx * step)
    }
  }

  function confirmGuess() {
    if (root.phase !== "guessing" || !root.guess || !root.round) return

    var km = GeoMath.haversineKm(root.guess.lat, root.guess.lon, root.round.lat, root.round.lon)
    var score = GeoMath.scoreFor(km)

    var results = root.results.slice(0)
    results.push({ km: km, score: score, city: root.round.city, country: root.round.country })
    // The results list is bounded by roundsPerGame, which is itself clamped to
    // 10, but the slice makes that true of the array rather than of the caller.
    root.results = results.slice(0, 10)
    root.totalScore += score

    root.phase = "revealed"
    if (mapLoader.item) mapLoader.item.frameResult()

    // Fetch the next round now, while the reveal is being read, so Next is
    // instant. Skipped on the last round, where there is nothing to fetch.
    if (root.roundIndex + 1 < root.roundsPerGame) {
      root.pendingRound = null
      root.pendingFailed = false
      root.fetchRound("pending")
    }
  }

  function nextRound() {
    if (root.phase !== "revealed") return

    if (root.roundIndex + 1 >= root.roundsPerGame) {
      root.gamesPlayed += 1
      if (root.totalScore > root.bestScore) root.bestScore = root.totalScore
      root.saveState()
      root.phase = "summary"
      return
    }

    root.roundIndex += 1
    root.guess = null
    if (mapLoader.item) mapLoader.item.resetView()

    if (root.pendingRound) {
      root.round = root.pendingRound
      root.pendingRound = null
      root.statusText = ""
      root.phase = "guessing"
      return
    }
    // The prefetch failed or has not landed yet. Either way this is now the
    // request the player is waiting on.
    root.round = null
    root.phase = "loading"
    if (!metaProcess.running && !photoProcess.running) root.fetchRound("current")
    else root.fetchTarget = "current"
  }

  function skipRound() {
    if (root.phase !== "guessing" && root.phase !== "error") return
    root.fetchRound("current")
  }

  function abandonGame() {
    root.phase = "idle"
    root.round = null
    root.pendingRound = null
    root.guess = null
    root.statusText = ""
  }

  // ---------------------------------------------------------------- the view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    padding: Style.space(14)
    // fittedContentWidth clamps to the screen, so these are the size the game
    // would like rather than a size it insists on: on a small display the board
    // shrinks instead of overflowing.
    contentWidth: panel.fittedContentWidth(Style.space(940))
    contentHeight: panel.fittedContentHeight(Style.space(660), Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { root.nudgeGuess(dx, dy) }
      onTextKey: function (key) {
        // One-key view switch, so the map/globe toggle is reachable without the
        // mouse too.
        if (key === "m") root.mapMode = "map"
        else if (key === "g") root.mapMode = "globe"
      }
      onReturnRequested: {
        if (root.phase === "guessing" && root.guess) root.confirmGuess()
        else if (root.phase === "revealed") root.nextRound()
        else if (root.phase === "error") root.skipRound()
        else if (root.phase === "idle" || root.phase === "summary") root.startGame()
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: Math.max(titleColumn.implicitHeight, headerControls.implicitHeight)

          Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - headerControls.width - Style.space(12)
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "GLOBE GUESSER"
              textFormat: Text.PlainText
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: {
                if (root.phase === "idle")
                  return root.bestScore > 0
                    ? "Best " + GeoMath.formatNumber(root.bestScore) + " · "
                      + root.gamesPlayed + (root.gamesPlayed === 1 ? " game played" : " games played")
                    : "Guess where the photo was taken"
                if (root.phase === "summary") return "Game over"
                return "Round " + (root.roundIndex + 1) + " of " + root.roundsPerGame
                     + " · " + GeoMath.formatNumber(root.totalScore) + " points"
              }
              textFormat: Text.PlainText
              color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                             root.bar ? root.bar.foreground.g : 0.8,
                             root.bar ? root.bar.foreground.b : 0.8, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerControls
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            visible: root.phase === "guessing" || root.phase === "revealed"

            Button {
              text: "Map"
              selected: root.mapMode === "map"
              onClicked: root.mapMode = "map"
            }

            Button {
              text: "Globe"
              selected: root.mapMode === "globe"
              onClicked: root.mapMode = "globe"
            }
          }
        }

        // -------------------------------------------------------------- board
        Item {
          id: board
          width: parent.width
          height: parent.height - y - footer.height - Style.space(20)

          // ---- start screen, errors, and the summary all share this space
          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(40), Style.space(520))
            spacing: Style.space(12)
            visible: root.phase === "idle" || root.phase === "error" || root.phase === "summary"

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: {
                if (root.phase === "error") return root.statusText
                if (root.phase === "summary")
                  return GeoMath.formatNumber(root.totalScore) + " out of "
                       + GeoMath.formatNumber(root.roundsPerGame * 5000)
                return "A photograph, somewhere on Earth. Click the map or spin the globe "
                     + "to say where you think it was taken."
              }
              wrapMode: Text.WordWrap
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: Style.font.family
              font.pixelSize: root.phase === "summary" ? Style.font.display : Style.font.body
              font.bold: root.phase === "summary"
            }

            // Per-round breakdown, only on the summary.
            Column {
              width: parent.width
              spacing: Style.space(3)
              visible: root.phase === "summary"

              Repeater {
                model: root.results

                Item {
                  required property var modelData
                  required property int index
                  width: parent.width
                  height: roundLine.implicitHeight + Style.space(4)

                  Text {
                    id: roundLine
                    anchors.left: parent.left
                    width: parent.width - roundScore.width - Style.space(10)
                    textFormat: Text.PlainText
                    text: (index + 1) + ". " + GeoMath.formatDistance(modelData.km)
                        + (modelData.city !== "" ? " — " + modelData.city + ", " + modelData.country : "")
                    color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                                   root.bar ? root.bar.foreground.g : 0.8,
                                   root.bar ? root.bar.foreground.b : 0.8, 0.75)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    id: roundScore
                    anchors.right: parent.right
                    textFormat: Text.PlainText
                    text: GeoMath.formatNumber(modelData.score)
                    color: root.bar ? root.bar.foreground : Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              visible: root.phase === "summary" && root.totalScore >= root.bestScore && root.totalScore > 0
              text: "A new best."
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // ---- the playing board
          Column {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.phase === "loading" || root.phase === "guessing" || root.phase === "revealed"

            PhotoPane {
              id: photo
              width: parent.width
              height: Math.round(parent.height * 0.44)
              photoPath: root.round ? root.round.path : ""
              loading: root.phase === "loading"
              showAttribution: root.phase === "revealed"
              photoTitle: root.round ? root.round.title : ""
              photoCredit: root.round ? root.round.credit : ""
              photoLicence: root.round ? root.round.licence : ""
              foreground: root.bar ? root.bar.foreground : Color.popups.text
            }

            Item {
              width: parent.width
              height: parent.height - photo.height - parent.spacing

              // The 130 KiB of country outlines are imported by GlobeMap.qml, so
              // they stay out of the QML engine until someone actually plays.
              // active latches true and never goes back: a game in progress must
              // not lose its map because the panel was closed for a moment.
              Loader {
                id: mapLoader
                anchors.fill: parent
                active: false
                source: Qt.resolvedUrl("GlobeMap.qml")

                onLoaded: {
                  item.mode = Qt.binding(function () { return root.mapMode })
                  item.guess = Qt.binding(function () { return root.guess })
                  item.answer = Qt.binding(function () {
                    return root.phase === "revealed" && root.round
                        ? { lat: root.round.lat, lon: root.round.lon } : null
                  })
                  item.interactive = Qt.binding(function () { return root.phase === "guessing" })
                  item.landStroke = Qt.binding(function () {
                    return root.bar ? root.bar.foreground : Color.popups.text
                  })
                  item.guessColor = Qt.binding(function () {
                    return root.bar ? root.bar.foreground : Color.popups.text
                  })
                  item.guessPlaced.connect(root.placeGuess)
                }
              }

              Connections {
                target: root
                function onPhaseChanged() {
                  if (!mapLoader.active
                      && (root.phase === "loading" || root.phase === "guessing"))
                    mapLoader.active = true
                }
              }

              Text {
                anchors.centerIn: parent
                visible: !mapLoader.active
                text: "Loading the world…"
                textFormat: Text.PlainText
                color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                               root.bar ? root.bar.foreground.g : 0.8,
                               root.bar ? root.bar.foreground.b : 0.8, 0.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // ------------------------------------------------------------ footer
        Item {
          id: footer
          width: parent.width
          height: footerRow.implicitHeight

          Text {
            id: verdict
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - footerRow.width - Style.space(12)
            textFormat: Text.PlainText
            visible: root.phase === "revealed" || root.phase === "guessing"
            text: {
              if (root.phase === "guessing")
                return root.guess
                  ? "Arrow keys nudge the pin · Enter confirms"
                  : "Click the map, or press an arrow key · M map, G globe"
              if (!root.round || root.results.length === 0) return ""
              var last = root.results[root.results.length - 1]
              var where = root.round.city !== ""
                  ? (root.round.cityKm < 5
                      ? root.round.city + ", " + root.round.country
                      : Math.round(root.round.cityKm) + " km from " + root.round.city
                        + ", " + root.round.country)
                  : ""
              return GeoMath.formatDistance(last.km) + " away"
                   + (where !== "" ? " — " + where : "")
                   + " · " + GeoMath.formatNumber(last.score) + " points"
            }
            color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                           root.bar ? root.bar.foreground.g : 0.8,
                           root.bar ? root.bar.foreground.b : 0.8, 0.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Row {
            id: footerRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              visible: root.phase === "guessing" || root.phase === "error"
              text: root.phase === "error" ? "Try another" : "Skip"
              onClicked: root.skipRound()
            }

            Button {
              visible: root.phase === "guessing" || root.phase === "revealed"
                       || root.phase === "loading" || root.phase === "error"
              text: "Give up"
              onClicked: root.abandonGame()
            }

            Button {
              visible: root.phase === "guessing"
              text: "Confirm"
              active: root.guess !== null
              onClicked: root.confirmGuess()
            }

            Button {
              visible: root.phase === "revealed"
              text: root.roundIndex + 1 >= root.roundsPerGame ? "Finish" : "Next round"
              active: true
              onClicked: root.nextRound()
            }

            Button {
              visible: root.phase === "idle" || root.phase === "summary"
              text: root.phase === "idle" ? "Start" : "Play again"
              active: true
              onClicked: root.startGame()
            }
          }
        }
      }
    }
  }
}

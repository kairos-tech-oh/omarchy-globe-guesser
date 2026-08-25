import QtQuick
import "GeoMath.js" as GeoMath

// OpenStreetMap raster tiles for the flat map.
//
// ---------------------------------------------------------------------------
// Why this file is allowed to point Image.source at a network URL when
// PhotoPane.qml is emphatically not
// ---------------------------------------------------------------------------
//
// A photograph's URL arrives inside an API response. It is attacker-influenced,
// so it is checked against a host allowlist, fetched by curl under a byte
// ceiling, magic-checked, and only then handed to Image as a local file.
//
// A tile's URL contains nothing that came off the network. It is a hardcoded
// host, a hardcoded style, and three integers that GeoMath computed from the
// pane geometry -- and both check suites assert, for every zoom the UI can
// reach, that all three are integers inside the tile pyramid. There is no input
// here for anything to influence. Fetching each tile through curl instead would
// buy nothing and would replace Qt's pixmap cache, which is what makes panning
// back over ground you have already seen cost nothing.
//
// The provider is CARTO rather than tile.openstreetmap.org. The OSM Foundation's
// tile usage policy forbids distributing an application that draws on their
// servers -- they are donated infrastructure for the map's own site, not a free
// CDN -- so using them here would be taking something that was asked not to be
// taken. CARTO renders the same OpenStreetMap data and publishes these basemaps
// for public use with attribution, which the map shows.
//
// ---------------------------------------------------------------------------
// Why the model and the positions are separate
// ---------------------------------------------------------------------------
//
// Panning moves the map continuously but changes WHICH tiles are needed only
// when a whole new row or column comes into view. If the Repeater's model were
// recomputed from the view, every drag frame would hand it a fresh JS array,
// and a Repeater given a new array destroys and recreates every delegate it
// has -- eighteen Images torn down and rebuilt sixty times a second, visible as
// flicker and paid for in nothing.
//
// So the model is rebuilt only when the tile window changes, and each tile's
// position is a binding on the frame. Panning then moves two numbers.
Item {
  id: root

  // The GeoMath view object the map is currently drawn with.
  property var view: null

  // Whether tiles are wanted at all. Set false for the globe, which cannot use
  // them.
  //
  // This gates the computation, not just the drawing, and the difference
  // matters: an invisible Image still loads. Hiding the layer while leaving its
  // bindings live would mean spinning the globe kept moving the tile window,
  // rebuilding the model and fetching tiles nobody could see -- a steady stream
  // of requests for pixels that are never drawn.
  property bool active: true

  // How many tiles may exist at once. The ceiling is on what is BUILT, not on
  // what is drawn: every entry becomes an Image that fetches and decodes inside
  // the shared shell process, so an unbounded grid is an unbounded number of
  // requests. A 940x330 pane needs about eighteen.
  property int maxTiles: 64

  // False once tiles have failed repeatedly without a single success -- offline,
  // or the provider is down. The caller shows the bundled vector outlines
  // instead, so the game stays playable rather than presenting a blank rectangle
  // and no explanation.
  readonly property bool healthy: root.failures < 8 || root.successes > 0

  property int failures: 0
  property int successes: 0

  // Where the pane sits in tile units, right now. Changes every drag frame.
  readonly property var frame: (root.active && root.view)
      ? GeoMath.tileFrame(root.view) : null

  // Which tiles are needed. Changes only when the window moves by a whole tile,
  // which is what `frameKey` detects.
  readonly property string frameKey: root.frame
      ? root.frame.z + "/" + root.frame.iMin + "," + root.frame.iMax
                    + "/" + root.frame.jMin + "," + root.frame.jMax
      : ""

  property var tiles: []

  // Rebuilt on the rare event, not the common one. Going inactive drives
  // frameKey to "" and empties the model, so the Images are destroyed rather
  // than left loading in the background.
  function rebuild() {
    root.tiles = (root.active && root.view)
        ? GeoMath.tileGrid(root.view, root.maxTiles) : []
  }

  onFrameKeyChanged: root.rebuild()

  // A change handler only fires on a CHANGE, and the first frameKey is computed
  // during initialisation -- so without this the layer can come up with a valid
  // window and an empty model, and stay that way until the player happens to
  // pan far enough to cross a tile boundary.
  Component.onCompleted: root.rebuild()

  // Hardcoded, and not a settable property: nothing should be able to point this
  // somewhere else, and a style name is not a setting anyone asked for.
  readonly property string tileStyle: "dark_all"

  function tileUrl(z, x, y) {
    return "https://basemaps.cartocdn.com/" + root.tileStyle
         + "/" + z + "/" + x + "/" + y + ".png"
  }

  function noteFailure() {
    // Bounded so a long session offline cannot count upwards forever.
    if (root.failures < 1000) root.failures += 1
  }

  function noteSuccess() {
    if (root.successes < 1000) root.successes += 1
    root.failures = 0
  }

  Repeater {
    model: root.tiles

    Image {
      required property var modelData

      // Bound to the frame, not read from the model, so panning moves the tile
      // instead of rebuilding it.
      x: root.frame ? (modelData.x - root.frame.left) * root.frame.px : 0
      y: root.frame ? (modelData.y - root.frame.top) * root.frame.px : 0
      width: root.frame ? root.frame.px : 0
      height: root.frame ? root.frame.px : 0

      source: root.tileUrl(modelData.z, modelData.x, modelData.y)

      // Qt's pixmap cache keys on the URL, and a tile at a given z/x/y is the
      // same bytes forever, so panning back over ground already seen costs
      // nothing the second time. This is the opposite of the round's
      // photograph, which is written once and never revisited.
      cache: true
      asynchronous: true

      // The tile is drawn at whatever size the fractional zoom asks for, which
      // is within about 41% of native either way, so it is always being scaled
      // slightly and always wants the smoothing.
      smooth: true
      fillMode: Image.Stretch

      // A tile that has not arrived stays invisible rather than flashing a
      // placeholder. Underneath is either the previous frame's tiles or the
      // bundled outlines, both of which are better than a hole.
      visible: status === Image.Ready

      onStatusChanged: {
        if (status === Image.Error) root.noteFailure()
        else if (status === Image.Ready) root.noteSuccess()
      }
    }
  }
}

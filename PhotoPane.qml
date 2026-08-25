import QtQuick
import qs.Commons

// The photo half of the board.
//
// The source is always a local file that Panel.qml has already downloaded and
// checked. It is never a network URL: the address comes out of an API response,
// so it is attacker-influenced, and pointing Image.source at it would hand a
// remote server an unbounded fetch and decode inside the long-lived shell
// process. By the time a path reaches this file it has been through a host
// allowlist, a byte ceiling, and a magic-number check.
Item {
  id: root

  // Absolute path to the downloaded file, or "" for none.
  property string photoPath: ""

  property bool loading: false
  property string errorText: ""

  // Shown only after the guess is locked in: naming the place while the player
  // is still guessing would give the answer away.
  property bool showAttribution: false
  property string photoTitle: ""
  property string photoCredit: ""
  property string photoLicence: ""

  property color foreground: Color.popups.text
  property color background: Color.popups.background

  readonly property bool ready: image.status === Image.Ready

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    radius: Style.cornerRadius
    clip: true

    Image {
      id: image
      anchors.fill: parent
      source: root.photoPath === "" ? "" : "file://" + root.photoPath
      fillMode: Image.PreserveAspectCrop
      asynchronous: true

      // Qt's pixmap cache keys on URL, and a round's file is written once and
      // never revisited, so caching it would only hold bytes the game is
      // finished with.
      cache: false

      // The decode size is decided here, not by the file. Without an explicit
      // sourceSize a 100-megapixel JPEG is decompressed at full resolution into
      // the shell's heap before anyone sees it; with one, the decoder is told
      // the ceiling up front. Rounded up to a power-of-two-ish step so a resize
      // by a few pixels does not force a re-decode.
      sourceSize.width: Math.max(320, Math.ceil(root.width / 160) * 160)
      sourceSize.height: Math.max(240, Math.ceil(root.height / 160) * 160)

      visible: status === Image.Ready
    }

    // Loading.
    Text {
      anchors.centerIn: parent
      visible: root.loading && !image.visible && root.errorText === ""
      text: "Finding a photo…"
      textFormat: Text.PlainText
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.7)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // Failure, including a file that arrived but would not decode.
    Text {
      anchors.centerIn: parent
      anchors.margins: Style.space(16)
      width: parent.width - Style.space(32)
      visible: root.errorText !== "" || (root.photoPath !== "" && image.status === Image.Error)
      text: root.errorText !== "" ? root.errorText : "That photo would not load."
      textFormat: Text.PlainText
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    // Attribution. Commons photos are almost all CC-licensed, and the licence
    // is only honoured if the author and the terms travel with the picture, so
    // this is a requirement of using the images at all rather than a nicety.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: attributionColumn.implicitHeight + Style.space(16)
      visible: root.showAttribution && root.ready
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.82)

      Column {
        id: attributionColumn
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: root.photoTitle
          // Every Text in this plugin pins PlainText, not only the ones that
          // happen to carry remote data today, so the safe default also covers
          // whatever the next edit adds.
          textFormat: Text.PlainText
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: {
            var parts = []
            if (root.photoCredit !== "") parts.push(root.photoCredit)
            if (root.photoLicence !== "") parts.push(root.photoLicence)
            return parts.join(" · ")
          }
          textFormat: Text.PlainText
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.65)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}

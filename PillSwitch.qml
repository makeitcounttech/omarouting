import QtQuick
import qs.Commons

// Pill segmented switch (active = accent fill, text Color.background), shared look with OmaOpus/DÆMON/Agents.
Rectangle {
  id: root
  property var options: []          // [{key, label, badge?}]
  property string current: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  signal picked(string key)

  implicitHeight: Style.space(26)
  radius: height / 2
  color: Qt.alpha(foreground, 0.06)

  Row {
    anchors.fill: parent
    anchors.margins: Style.space(3)
    Repeater {
      model: root.options
      Rectangle {
        required property var modelData
        readonly property bool active: modelData.key === root.current
        width: (root.width - Style.space(6)) / Math.max(1, root.options.length)
        height: parent.height
        radius: height / 2
        color: active ? Color.accent : (hover.containsMouse ? Qt.alpha(root.foreground, 0.08) : "transparent")
        Behavior on color { ColorAnimation { duration: 120 } }
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)
          Text {
            text: modelData.label
            color: active ? Color.background : root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            font.bold: active
          }
          Rectangle {
            visible: (modelData.badge || 0) > 0
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(13)
            width: Math.max(height, badgeLabel.implicitWidth + Style.space(6))
            radius: height / 2
            color: active ? Qt.alpha(Color.background, 0.25) : Qt.alpha(root.foreground, 0.12)
            Text {
              id: badgeLabel
              anchors.centerIn: parent
              text: String(modelData.badge || 0)
              color: active ? Color.background : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.picked(modelData.key)
        }
      }
    }
  }
}

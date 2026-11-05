import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "nobynoooob.soundboard"

  // The manifest is bar-widget-only, so the shell does not instantiate a
  // service for us. Keep the engine mounted here, invisible and always on.
  readonly property var service: serviceLoader.item

  Loader {
    id: serviceLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Service.qml")
  }

  implicitWidth: statusIcon.implicitWidth + Style.space(14)
  implicitHeight: barSize

  function statusText() {
    if (!root.service || !root.service.routerActive) return "Soundboard · off · right-click to arm"
    if (root.service.routerEngaged) return "Soundboard · clips live — mic bridged"
    return "Soundboard · armed, mic untouched · click to open"
  }

  Text {
    id: statusIcon
    anchors.centerIn: parent
    text: "󰝚"
    color: root.service && root.service.routerActive
      ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.9)
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.icon

    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 140 }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    onClicked: function(mouse) {
      if (!root.service) return
      if (mouse.button === Qt.LeftButton) root.service.toggleWindow()
      else root.service.toggleRouter()
    }

    onWheel: function(wheel) {
      if (!root.service || !root.service.routerActive) return
      var delta = wheel.angleDelta.y > 0 ? 5 : -5
      root.service.setVolume(root.service.masterVolume + delta)
    }

    onEntered: if (root.bar) root.bar.showTooltip(root, root.statusText())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}

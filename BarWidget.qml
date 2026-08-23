/*
 BarWidget.qml — the ♞ pill for the OMA-CHESS plugin in the Omarchy bar.

 This file has exactly two jobs:
   1. Render the bar icon (WidgetButton) and toggle the panel on click.
   2. Forward the panel's lifecycle so both clicks AND shell IPC commands
      (omarchy-shell shell summon/hide oma.chess) work.

 CONTRACT WARNING for contributors: Quattro's Bar.findPanelWidget() looks
 for open/close/opened on this root before routing summon/hide commands.
 If you delete any of the forwarded functions/properties below (opened,
 popoutSwitchClosing, open, close, togglePanel, closeForPopoutSwitch),
 the panel will open once and then never again — a documented failure mode.

 The actual panel UI lives in Panel.qml, loaded through the Loader below.
 Settings typed into the panel are written back through hostWidget.settings;
 see Panel.qml's persistSettings().
*/

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "oma.chess"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function setLiveGame(live) {
    button.active = live === true
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  /*
   The panel is loaded eagerly (active: true) so its service starts polling
   as soon as accounts are configured. injectPanel runs twice on purpose:
   once immediately and once via Qt.callLater, because the bar assigns
   `bar`/`settings` after creation and property-change handlers alone have
   historically raced shell startup.
  */
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  /*
   IPC surface: lets users bind hotkeys like
     omarchy-shell shell toggle oma.chess
   show/hide are aliases because different parts of Omarchy call either name.
  */
  IpcHandler {
    target: "oma.chess"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "♞"
    tooltipText: "OMA-CHESS"

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}

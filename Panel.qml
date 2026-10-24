import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Bose QC Ultra widget: battery in the bar and a two-tab popup, Sound (modes,
// noise cancellation, spatial audio, EQ) and Settings (toggles, sidetone,
// shortcut button, device info).
//
// All Bluetooth work goes through bin/bosejson.py, one short RFCOMM session per
// call. The headphones accept a single BMAP client at a time, so calls are
// queued here and never overlap; a busy link is reported, not retried forever.
//
// Bar button: left click opens the panel, right click re-reads.
// Panel: Esc closes, r refreshes, 1/2 switch tab.
Panel {
  id: root
  moduleName: "io.github.borferkic.bose"
  ipcTarget: "io.github.borferkic.bose"
  manageIpc: false

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    u = u.replace(/^file:\/\//, "")
    try { u = decodeURIComponent(u) } catch (e) {}
    return u.replace(/\/+$/, "")
  }

  // ---- connection (BlueZ) -------------------------------------------------
  readonly property string match: String(setting("deviceMatch", "bose")).toLowerCase()
  readonly property var btDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property bool connected: {
    for (var i = 0; i < btDevices.length; i++) {
      var d = btDevices[i]
      if (!d || !d.connected) continue
      var n = String((d.deviceName || "") + " " + (d.name || "")).toLowerCase()
      if (n.indexOf(match) >= 0) return true
    }
    return false
  }
  visible: connected
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- state --------------------------------------------------------------
  property var rep: null          // last status report from the helper
  property string errorCode: ""
  property string errorText: ""
  property bool working: false
  property int tab: 0
  property var queue: []

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool es: String(Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG")).indexOf("es") === 0

  readonly property var esText: ({
    "Sound": "Sonido", "Settings": "Ajustes", "Modes": "Modos", "Noise cancellation": "Cancelación de ruido",
    "Spatial audio": "Audio espacial", "Equalizer": "Ecualizador", "Bass": "Graves", "Mid": "Medios",
    "Treble": "Agudos", "Off": "Apagado", "Room": "Sala", "Head tracking": "Seguimiento",
    "Reset EQ": "Restablecer EQ", "Wind block": "Bloqueo de viento", "Multipoint": "Multipunto",
    "Connect to two devices at once": "Conectar a dos dispositivos a la vez",
    "Auto pause": "Pausa automática", "Pause when you take them off": "Pausa al quitártelos",
    "Auto answer": "Respuesta automática", "Answer calls when you put them on": "Responder llamadas al ponértelos",
    "Voice prompts": "Avisos de voz", "Spoken battery and mode messages": "Mensajes hablados de batería y modo",
    "Self voice": "Voz propia", "Shortcut button": "Botón de acceso directo", "Device": "Dispositivo",
    "Pairing mode": "Modo emparejamiento", "Power off": "Apagar", "Refresh": "Actualizar",
    "Reading…": "Leyendo…", "Firmware": "Firmware", "Name": "Nombre", "Max ANC": "Máx. ANC", "Aware": "Ambiente",
    "Headphones are busy: close the Bose app or wait a few seconds": "Auriculares ocupados: cierra la app de Bose o espera unos segundos",
    "Headphones not reachable": "Auriculares no accesibles",
    "Long press": "Pulsación larga", "Low": "Bajo", "Medium": "Medio", "High": "Alto"
  })
  function tr(s) { return es && esText[s] !== undefined ? esText[s] : s }

  readonly property string batteryText: rep && rep.battery !== undefined ? rep.battery + "%" : ""
  readonly property string icon: String.fromCodePoint(0xF02CB)

  // ---- helper process queue ----------------------------------------------
  function run(args) {
    // A newer read supersedes one still waiting; setters are all kept in order.
    if (args[0] === "status") {
      for (var i = 0; i < queue.length; i++) if (queue[i][0] === "status") return
    }
    queue.push(args)
    pump()
  }

  function pump() {
    if (proc.running || queue.length === 0) return
    var args = queue.shift()
    proc.args = args
    proc.gotOutput = false
    working = true
    proc.command = ["python3", "-B", "-I", root.pluginDir + "/bin/bosejson.py"].concat(args)
    proc.running = true
  }

  function handle(args, res) {
    if (res.ok) {
      errorCode = ""
      errorText = ""
      if (args[0] === "status") rep = res
      else settleTimer.restart()
    } else {
      errorCode = res.error || "error"
      errorText = res.message || ""
      // Roll the optimistic UI back to what the headphones really have.
      if (args[0] !== "status") settleTimer.restart()
    }
  }

  function patch(obj) {
    if (!rep) return
    var n = {}
    for (var k in rep) n[k] = rep[k]
    for (var p in obj) n[p] = obj[p]
    rep = n
  }

  function refresh() { run(["status"]) }

  function setMode(profile) {
    patch({ mode: profile.name, modeIdx: profile.idx })
    run(["mode", profile.name])
  }

  // Display name of the active mode: the profile list has the proper casing,
  // while the headphones report the factory modes in lowercase.
  readonly property string modeName: {
    if (!rep) return ""
    var ps = rep.profiles || []
    for (var i = 0; i < ps.length; i++) if (ps[i].idx === rep.modeIdx) return ps[i].name
    return rep.mode
  }
  function setCnc(v) {
    patch({ cnc: v })
    run(["cnc", String(v)])
  }
  function setSpatial(v) {
    patch({ spatial: v })
    run(["spatial", v])
  }
  function setEq(index, v) {
    if (!rep || !rep.eq) return
    var bands = rep.eq.map(function (b) { return { name: b.name, min: b.min, max: b.max, value: b.value } })
    bands[index].value = v
    patch({ eq: bands })
    run(["eq", String(bands[0].value), String(bands[1].value), String(bands[2].value)])
  }
  function resetEq() {
    if (!rep || !rep.eq) return
    patch({ eq: rep.eq.map(function (b) { return { name: b.name, min: b.min, max: b.max, value: 0 } }) })
    run(["eq", "0", "0", "0"])
  }
  function setFlag(cmd, key, on) {
    var o = {}
    o[key] = on
    patch(o)
    run([cmd, on ? "on" : "off"])
  }

  Process {
    id: proc
    property var args: []
    property bool gotOutput: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(String(text).trim().split("\n").pop()) } catch (e) {}
        if (res) {
          proc.gotOutput = true
          root.handle(proc.args, res)
        }
      }
    }
    onExited: function (exitCode) {
      if (!proc.gotOutput) {
        root.errorCode = "helper"
        root.errorText = "bosejson.py exited " + exitCode
      }
      root.working = root.queue.length > 0
      root.pump()
    }
  }

  // Re-read once the setters have gone quiet, to show what the headphones kept.
  Timer {
    id: settleTimer
    interval: 600
    onTriggered: root.refresh()
  }

  // Read when the headphones appear, and keep the battery fresh.
  onConnectedChanged: {
    if (connected) startTimer.restart()
    else { rep = null; queue = [] }
  }
  Timer {
    id: startTimer
    interval: 3000
    onTriggered: root.refresh()
  }
  Timer {
    interval: Math.max(1, Number(root.setting("pollMinutes", 5))) * 60000
    running: root.connected && !root.opened
    repeat: true
    onTriggered: root.refresh()
  }
  // Fresher state while the panel is on screen.
  Timer {
    interval: 30000
    running: root.connected && root.opened
    repeat: true
    onTriggered: root.refresh()
  }
  onOpenedChanged: if (opened && connected) refresh()
  Component.onCompleted: if (connected) refresh()

  ShellIpc {
    target: "io.github.borferkic.bose"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function (b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function (t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "1") root.tab = 0
        else if (t === "2") root.tab = 1
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---- header ----
        Item {
          width: parent.width
          implicitHeight: heroText.implicitHeight

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
          Column {
            id: heroText
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: batt.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.rep ? root.rep.name : "Bose"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: (root.working && !root.rep ? root.tr("Reading…") : root.modeName).toUpperCase()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
          Text {
            id: batt
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.batteryText
            color: !root.rep ? root.foreground : (root.rep.battery <= 15 ? "#e06c75" : (root.rep.battery <= 30 ? "#e5c07b" : root.foreground))
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        Text {
          visible: root.errorCode !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.errorCode === "busy" ? root.tr("Headphones are busy: close the Bose app or wait a few seconds")
            : (root.errorCode === "not_found" || root.errorCode === "connection") ? root.tr("Headphones not reachable")
            : root.errorText
          color: "#e06c75"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- tabs ----
        ButtonGroup {
          options: [{ value: "0", label: "1  " + root.tr("Sound") }, { value: "1", label: "2  " + root.tr("Settings") }]
          value: String(root.tab)
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function (v) { root.tab = Number(v) }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- Sound tab ----
        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.tab === 0 && root.rep !== null

          PanelSectionHeader {
            text: root.tr("Modes").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.rep ? root.rep.profiles : []
              delegate: Button {
                required property var modelData
                text: modelData.name
                selected: !!root.rep && root.rep.modeIdx === modelData.idx
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.setMode(modelData)
              }
            }
          }

          PanelSectionHeader {
            text: root.tr("Noise cancellation").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Item {
            width: parent.width
            implicitHeight: cncSlider.implicitHeight
            Text {
              id: cncLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.tr("Max ANC")
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: cncRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.tr("Aware")
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            PanelSlider {
              id: cncSlider
              anchors.left: cncLeft.right
              anchors.right: cncRight.left
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              bar: root.bar
              minimum: 0
              maximum: root.rep ? root.rep.cncMax : 10
              step: 1
              integer: true
              tickCount: 11
              value: root.rep ? root.rep.cnc : 0
              onReleased: function (v) { root.setCnc(Math.round(v)) }
            }
          }

          PanelSectionHeader {
            text: root.tr("Spatial audio").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          ButtonGroup {
            visible: root.rep && root.rep.spatial !== null
            options: [{ value: "off", label: root.tr("Off") }, { value: "room", label: root.tr("Room") },
                      { value: "head", label: root.tr("Head tracking") }]
            value: root.rep && root.rep.spatial ? root.rep.spatial : "off"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function (v) { root.setSpatial(v) }
          }

          PanelSeparator { foreground: root.foreground }
          Item {
            width: parent.width
            implicitHeight: eqTitle.implicitHeight
            PanelSectionHeader {
              id: eqTitle
              anchors.left: parent.left
              text: root.tr("Equalizer").toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Button {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.tr("Reset EQ")
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.resetEq()
            }
          }
          Repeater {
            model: root.rep && root.rep.eq ? root.rep.eq : []
            delegate: Item {
              required property var modelData
              required property int index
              width: column.width
              implicitHeight: eqRow.implicitHeight
              Row {
                id: eqRow
                width: parent.width
                spacing: Style.space(10)
                Text {
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.tr(modelData.name)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                PanelSlider {
                  width: parent.width - Style.space(60) - Style.space(44) - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  minimum: modelData.min
                  maximum: modelData.max
                  step: 1
                  integer: true
                  value: modelData.value
                  onReleased: function (v) { root.setEq(index, Math.round(v)) }
                }
                Text {
                  width: Style.space(44)
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: (modelData.value > 0 ? "+" : "") + modelData.value
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }
        }

        // ---- Settings tab ----
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.tab === 1 && root.rep !== null

          Toggle {
            width: parent.width
            visible: root.rep && root.rep.wind !== null
            label: root.tr("Wind block")
            checked: !!(root.rep && root.rep.wind)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setFlag("wind", "wind", !checked)
          }
          Toggle {
            width: parent.width
            label: root.tr("Multipoint")
            description: root.tr("Connect to two devices at once")
            checked: !!(root.rep && root.rep.multipoint)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setFlag("multipoint", "multipoint", !checked)
          }
          Toggle {
            width: parent.width
            label: root.tr("Auto pause")
            description: root.tr("Pause when you take them off")
            checked: !!(root.rep && root.rep.autoPause)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setFlag("autopause", "autoPause", !checked)
          }
          Toggle {
            width: parent.width
            label: root.tr("Auto answer")
            description: root.tr("Answer calls when you put them on")
            checked: !!(root.rep && root.rep.autoAnswer)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setFlag("autoanswer", "autoAnswer", !checked)
          }
          Toggle {
            width: parent.width
            label: root.tr("Voice prompts")
            description: root.tr("Spoken battery and mode messages")
            checked: !!(root.rep && root.rep.prompts)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setFlag("prompts", "prompts", !checked)
          }

          PanelSectionHeader {
            text: root.tr("Self voice").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          ButtonGroup {
            options: [{ value: "off", label: root.tr("Off") }, { value: "low", label: root.tr("Low") },
                      { value: "medium", label: root.tr("Medium") }, { value: "high", label: root.tr("High") }]
            value: root.rep ? String(root.rep.sidetone) : "off"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function (v) { root.patch({ sidetone: v }); root.run(["sidetone", v]) }
          }

          PanelSectionHeader {
            visible: root.rep && root.rep.button !== null
            text: root.tr("Shortcut button").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Flow {
            visible: root.rep && root.rep.button !== null
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.rep && root.rep.button ? root.rep.button.supported.filter(function (a) { return a.indexOf("unknown") !== 0 }).concat(root.rep.button.action) : []
              delegate: Button {
                required property var modelData
                text: modelData
                selected: root.rep && root.rep.button && root.rep.button.action === modelData
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  var b = root.rep.button
                  root.patch({ button: { name: b.name, event: b.event, action: modelData, supported: b.supported } })
                  root.run(["button", modelData])
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader {
            text: root.tr("Device").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.rep ? (root.rep.model + "\n" + root.tr("Firmware") + " " + root.rep.firmware) : ""
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            spacing: Style.space(6)
            Button {
              text: root.tr("Pairing mode")
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.run(["pair"])
            }
            Button {
              text: root.tr("Power off")
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: { root.run(["off"]); root.close() }
            }
            Button {
              text: root.tr("Refresh")
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.refresh()
            }
          }
        }
      }
    }
  }
}

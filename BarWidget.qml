import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Status bar widget for Antigravity AI multi-account quota monitoring.
// Displays active account remaining quota, health status dot, and
// provides instant access to detailed usage panel with Catppuccin-themed 2-column cards.
BarWidget {
  id: root
  moduleName: "antigravity.manager"

  readonly property string glyph: "🤖"

  // Catppuccin Mocha Palette
  readonly property var catppuccin: ({
    base: "#1e1e2e",
    mantle: "#181825",
    crust: "#11111b",
    surface0: "#313244",
    surface1: "#45475a",
    surface2: "#585b70",
    overlay0: "#6c7086",
    overlay1: "#7f849c",
    text: "#cdd6f4",
    subtext0: "#a6adc8",
    subtext1: "#bac2de",
    blue: "#89b4fa",
    sapphire: "#74c7ec",
    mauve: "#cba6f7",
    green: "#a6e3a1",
    yellow: "#f9e2af",
    peach: "#fab387",
    red: "#f38ba8",
    maroon: "#eba0ac",
    teal: "#94e2d5"
  })

  QuotaBackend {
    id: backend
    refreshIntervalSec: {
      var v = root.setting("refreshIntervalSec", 300)
      return parseInt(v, 10) || 300
    }
  }

  readonly property var activeAcc: backend.currentAccount
  readonly property var accounts: backend.accounts || []
  readonly property bool loading: backend.loading

  readonly property double remainingFraction: activeAcc && activeAcc.geminiFiveHourRemaining !== undefined
    ? activeAcc.geminiFiveHourRemaining
    : (activeAcc && activeAcc.overallRemaining !== undefined ? activeAcc.overallRemaining : 1.0)
  readonly property string percentLabel: activeAcc && activeAcc.geminiFiveHourPercent !== undefined
    ? Math.round(activeAcc.geminiFiveHourPercent) + "%"
    : (activeAcc && activeAcc.overallPercent !== undefined ? Math.round(activeAcc.overallPercent) + "%" : "--%")
  readonly property string resetLabel: activeAcc && activeAcc.geminiFiveHourResetFormatted
    ? activeAcc.geminiFiveHourResetFormatted
    : (activeAcc && activeAcc.overallResetFormatted ? activeAcc.overallResetFormatted : "")

  readonly property color statusColor: {
    if (!activeAcc) return catppuccin.overlay0
    if (activeAcc.error) return catppuccin.red
    if (remainingFraction >= 0.5) return catppuccin.green
    if (remainingFraction >= 0.2) return catppuccin.peach
    return catppuccin.red
  }

  function quotaColor(fraction) {
    if (fraction === undefined || fraction === null) return catppuccin.overlay0
    if (fraction >= 0.5) return catppuccin.green
    if (fraction >= 0.2) return catppuccin.peach
    return catppuccin.red
  }

  readonly property string tooltipInfo: {
    var lines = ["Antigravity 配额监控 (Catppuccin)"]
    if (activeAcc) {
      lines.push("当前活跃账号: " + activeAcc.email)
      var g5 = activeAcc.geminiFiveHourPercent !== undefined ? activeAcc.geminiFiveHourPercent : 100
      var g5r = activeAcc.geminiFiveHourResetFormatted || "充裕"
      var gw = activeAcc.geminiWeeklyPercent !== undefined ? activeAcc.geminiWeeklyPercent : 100
      var gwr = activeAcc.geminiWeeklyResetFormatted || "充裕"
      lines.push("• Gemini 3.0: 5h " + g5 + "% (" + g5r + ") · 周 " + gw + "% (" + gwr + ")")

      var c5 = activeAcc.claudeFiveHourPercent !== undefined ? activeAcc.claudeFiveHourPercent : 100
      var c5r = activeAcc.claudeFiveHourResetFormatted || "充裕"
      var cw = activeAcc.claudeWeeklyPercent !== undefined ? activeAcc.claudeWeeklyPercent : 100
      var cwr = activeAcc.claudeWeeklyResetFormatted || "充裕"
      lines.push("• Claude 4.6: 5h " + c5 + "% (" + c5r + ") · 周 " + cw + "% (" + cwr + ")")

      if (backend.accounts && backend.accounts.length > 1) {
        lines.push("共 " + backend.accounts.length + " 个账号已就绪")
      }
    } else {
      lines.push("正在加载或未配置账号...")
    }
    lines.push("左键: 打开配额矩阵 · 中键: 轮换账号 · 右键: 刷新")
    return lines.join("\n")
  }

  // Panel state
  property bool panelOpen: false
  readonly property bool opened: root.panelOpen
  property bool showAddSection: false
  property string addMode: "oauth"  // "oauth" or "manual"

  function open() { root.panelOpen = true }
  function close() {
    root.panelOpen = false
  }
  function togglePanel() {
    if (root.panelOpen) {
      root.close()
    } else {
      root.open()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "antigravity.usage"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { backend.refresh(true) }
    function cycle(): void { backend.cycleAccount() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : (root.glyph + " " + root.percentLabel)
    labelVisible: !root.vertical
    hasVisualContent: true
    horizontalMargin: 8.5
    tooltipText: root.tooltipInfo

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        backend.refresh(true)
      } else if (b === Qt.MiddleButton) {
        backend.cycleAccount()
      } else {
        root.togglePanel()
      }
    }

    // Status indicator dot
    Rectangle {
      width: Style.space(6)
      height: Style.space(6)
      radius: Style.space(3)
      color: root.statusColor
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      visible: !root.vertical
    }

    // Vertical layout
    Column {
      visible: root.vertical
      anchors.fill: parent

      OpticalGlyph {
        width: button.width
        height: Style.bar.iconSlot
        text: root.glyph
        fontFamily: button.fontFamily
        fontSize: Style.font.icon
        color: button.foreground
      }

      OpticalGlyph {
        width: button.width
        height: Style.bar.iconSlot
        text: root.percentLabel
        fontFamily: button.fontFamily
        fontSize: button.fontSize * 0.85
        color: root.statusColor
      }
    }
  }

  // Active panel open indicator underline
  Rectangle {
    readonly property bool vertical: !!root.bar && root.bar.vertical
    visible: root.panelOpen
    color: root.catppuccin.blue
    radius: Math.min(width, height) / 2
    width: vertical ? Style.space(2) : Math.max(Style.space(12), button.labelWidth)
    height: vertical ? Math.max(Style.space(12), button.labelWidth) : Style.space(2)
    x: vertical
      ? (root.bar.position === "left" ? root.width - width - Style.space(2) : Style.space(2))
      : Math.round((root.width - width) / 2)
    y: vertical
      ? Math.round((root.height - height) / 2)
      : (root.bar && root.bar.position === "top"
        ? root.height - height - Style.space(2) : Style.space(2))
  }

  // =========================================================================
  // Detailed Popup Panel (Native KeyboardPanel with Catppuccin 2-Col Grid)
  // =========================================================================
  KeyboardPanel {
    id: popupPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    focusTarget: keyCatcher
    contentWidth: popupPanel.fittedContentWidth(Style.space(620))
    contentHeight: popupPanel.fittedContentHeight(panelColumn.implicitHeight + Style.space(24), Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: manualEmailInput.activeFocus || manualTokenInput.activeFocus || (typeof callbackUrlInput !== "undefined" && callbackUrlInput.activeFocus)

      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") {
          backend.refresh(true)
        } else if (t === "Escape") {
          root.close()
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        anchors.margins: Style.space(8)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // =================================================================
          // 1. Header: Catppuccin Title, Badges, Add Account, Refresh & Close
          // =================================================================
          Item {
            width: parent.width
            height: Style.space(34)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: root.glyph
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: "Antigravity Manager"
                color: root.catppuccin.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              // Account Count Badge
              Rectangle {
                height: Style.space(20)
                width: accountBadgeText.implicitWidth + Style.space(12)
                radius: Style.space(10)
                color: root.catppuccin.surface0
                border.color: root.catppuccin.surface1
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: accountBadgeText
                  anchors.centerIn: parent
                  text: root.accounts.length + " 个账号"
                  color: root.catppuccin.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Header Actions
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              // Proxy Server Toggle Button
              Rectangle {
                id: proxyToggleBtn
                height: Style.space(28)
                width: proxyRow.implicitWidth + Style.space(14)
                radius: Style.space(6)
                color: backend.proxyRunning
                  ? Qt.rgba(166/255, 227/255, 161/255, 0.18)
                  : (proxyToggleArea.containsMouse ? root.catppuccin.surface1 : root.catppuccin.surface0)
                border.color: backend.proxyRunning ? root.catppuccin.green : root.catppuccin.surface1
                border.width: 1

                MouseArea {
                  id: proxyToggleArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: backend.toggleProxy()
                }

                Row {
                  id: proxyRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Rectangle {
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: Style.space(3)
                    color: backend.proxyRunning ? root.catppuccin.green : root.catppuccin.subtext0
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: backend.togglingProxy ? "切换中..." : (backend.proxyRunning ? "反代 :8045" : "启动反代")
                    color: backend.proxyRunning ? root.catppuccin.green : root.catppuccin.subtext0
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: backend.proxyRunning
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // Add Account Button
              Rectangle {
                id: addAccountBtn
                height: Style.space(28)
                width: addAccountRow.implicitWidth + Style.space(14)
                radius: Style.space(6)
                color: root.showAddSection
                  ? Qt.rgba(137/255, 180/255, 250/255, 0.25)
                  : (addAccountArea.containsMouse ? root.catppuccin.surface1 : root.catppuccin.surface0)
                border.color: root.showAddSection ? root.catppuccin.blue : root.catppuccin.surface1
                border.width: 1

                MouseArea {
                  id: addAccountArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showAddSection = !root.showAddSection
                }

                Row {
                  id: addAccountRow
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  Text {
                    text: "+"
                    color: root.catppuccin.blue
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "添加账号"
                    color: root.catppuccin.blue
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // Refresh Button
              Rectangle {
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.space(6)
                color: refreshArea.containsMouse ? root.catppuccin.surface1 : root.catppuccin.surface0
                border.color: root.catppuccin.surface1
                border.width: 1

                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: backend.refresh(true)
                }

                Text {
                  anchors.centerIn: parent
                  text: root.loading ? "⏳" : "↻"
                  color: root.loading ? root.catppuccin.peach : root.catppuccin.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              // Close Button
              Rectangle {
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.space(6)
                color: closeArea.containsMouse ? Qt.rgba(243/255, 139/255, 168/255, 0.2) : root.catppuccin.surface0
                border.color: closeArea.containsMouse ? root.catppuccin.red : root.catppuccin.surface1
                border.width: 1

                MouseArea {
                  id: closeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.close()
                }

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  color: closeArea.containsMouse ? root.catppuccin.red : root.catppuccin.overlay0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          // =================================================================
          // 2. Add Account Expandable Section (Catppuccin Themed)
          // =================================================================
          Rectangle {
            id: addSectionRect
            visible: root.showAddSection || backend.addingAccount
            width: parent.width
            implicitHeight: addSectionCol.implicitHeight + Style.space(20)
            radius: Style.space(8)
            color: root.catppuccin.mantle
            border.color: root.catppuccin.blue
            border.width: 1

            Column {
              id: addSectionCol
              width: parent.width - Style.space(24)
              anchors.centerIn: parent
              spacing: Style.space(10)

              // Title and Mode Switcher
              Item {
                width: parent.width
                height: Style.space(26)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "添加 Antigravity 账号"
                  color: root.catppuccin.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                // Mode Tabs
                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Rectangle {
                    height: Style.space(24)
                    width: oauthTabTxt.implicitWidth + Style.space(12)
                    radius: Style.space(4)
                    color: root.addMode === "oauth" ? root.catppuccin.surface1 : root.catppuccin.surface0
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.addMode = "oauth"
                    }
                    Text {
                      id: oauthTabTxt
                      anchors.centerIn: parent
                      text: "网页授权"
                      color: root.addMode === "oauth" ? root.catppuccin.blue : root.catppuccin.subtext0
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: root.addMode === "oauth"
                    }
                  }

                  Rectangle {
                    height: Style.space(24)
                    width: manualTabTxt.implicitWidth + Style.space(12)
                    radius: Style.space(4)
                    color: root.addMode === "manual" ? root.catppuccin.surface1 : root.catppuccin.surface0
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.addMode = "manual"
                    }
                    Text {
                      id: manualTabTxt
                      anchors.centerIn: parent
                      text: "手动 Token"
                      color: root.addMode === "manual" ? root.catppuccin.blue : root.catppuccin.subtext0
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: root.addMode === "manual"
                    }
                  }
                }
              }

              // Mode 1: OAuth Web Browser Login
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.addMode === "oauth"

                Text {
                  width: parent.width
                  text: "将在系统浏览器中打开 Google 授权页面，授权后自动完成添加并同步配额。"
                  color: root.catppuccin.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Item {
                  width: parent.width
                  height: Style.space(32)

                  Rectangle {
                    visible: !backend.addingAccount
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(30)
                    width: startOAuthTxt.implicitWidth + Style.space(20)
                    radius: Style.space(6)
                    color: startOAuthArea.containsMouse ? root.catppuccin.blue : root.catppuccin.sapphire

                    MouseArea {
                      id: startOAuthArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: backend.startAddAccount()
                    }

                    Text {
                      id: startOAuthTxt
                      anchors.centerIn: parent
                      text: "打开浏览器授权登录"
                      color: root.catppuccin.crust
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Row {
                    visible: backend.addingAccount
                    anchors.fill: parent
                    spacing: Style.space(8)

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(30)
                      width: authBannerRow.implicitWidth + Style.space(16)
                      radius: Style.space(6)
                      color: Qt.rgba(137/255, 180/255, 250/255, 0.15)
                      border.color: root.catppuccin.blue
                      border.width: 1

                      Row {
                        id: authBannerRow
                        anchors.centerIn: parent
                        spacing: Style.space(6)
                        Text {
                          text: "⏳"
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                          text: backend.addAccountStatus || "正在等待浏览器授权..."
                          color: root.catppuccin.blue
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(30)
                      width: Style.space(56)
                      radius: Style.space(6)
                      color: cancelOAuthArea.containsMouse ? Qt.rgba(243/255, 139/255, 168/255, 0.25) : Qt.rgba(243/255, 139/255, 168/255, 0.15)
                      border.color: root.catppuccin.red
                      border.width: 1

                      MouseArea {
                        id: cancelOAuthArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: backend.cancelAddAccount()
                      }

                      Text {
                        anchors.centerIn: parent
                        text: "取消"
                        color: root.catppuccin.red
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }

                // Fallback Callback URL Input
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: backend.addingAccount || backend.addAccountError !== ""

                  Rectangle {
                    width: parent.width
                    height: 1
                    color: root.catppuccin.surface0
                  }

                  Text {
                    width: parent.width
                    text: "若浏览器跳转后无法自动回调，请粘贴地址栏完整 URL:"
                    color: root.catppuccin.overlay0
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    TextField {
                      id: callbackUrlInput
                      width: parent.width - submitCallbackBtn.width - Style.space(6)
                      height: Style.space(28)
                      placeholderText: "http://localhost:51121/oauth-callback?code=..."
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: root.catppuccin.text
                      selectionColor: root.catppuccin.surface2
                      selectedTextColor: root.catppuccin.text
                      placeholderTextColor: root.catppuccin.overlay0
                      background: Rectangle {
                        radius: Style.space(4)
                        color: root.catppuccin.surface0
                        border.color: callbackUrlInput.activeFocus ? root.catppuccin.blue : root.catppuccin.surface1
                        border.width: 1
                      }
                    }

                    Rectangle {
                      id: submitCallbackBtn
                      width: submitCallbackTxt.implicitWidth + Style.space(16)
                      height: Style.space(28)
                      radius: Style.space(4)
                      color: submitCallbackArea.containsMouse ? root.catppuccin.blue : root.catppuccin.surface1

                      MouseArea {
                        id: submitCallbackArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          backend.submitCallbackUrl(callbackUrlInput.text)
                          callbackUrlInput.text = ""
                        }
                      }

                      Text {
                        id: submitCallbackTxt
                        anchors.centerIn: parent
                        text: "确定"
                        color: root.catppuccin.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }
              }

              // Mode 2: Manual Token Form
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: root.addMode === "manual"

                Text {
                  text: "Google 账号邮箱:"
                  color: root.catppuccin.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: manualEmailInput
                  width: parent.width
                  height: Style.space(28)
                  placeholderText: "example@gmail.com"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.catppuccin.text
                  placeholderTextColor: root.catppuccin.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.catppuccin.surface0
                    border.color: manualEmailInput.activeFocus ? root.catppuccin.blue : root.catppuccin.surface1
                    border.width: 1
                  }
                }

                Text {
                  text: "OAuth Refresh Token:"
                  color: root.catppuccin.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: manualTokenInput
                  width: parent.width
                  height: Style.space(28)
                  placeholderText: "1//0..."
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  echoMode: TextInput.Password
                  color: root.catppuccin.text
                  placeholderTextColor: root.catppuccin.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.catppuccin.surface0
                    border.color: manualTokenInput.activeFocus ? root.catppuccin.blue : root.catppuccin.surface1
                    border.width: 1
                  }
                }

                Item {
                  width: parent.width
                  height: Style.space(30)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(28)
                    width: submitManualTxt.implicitWidth + Style.space(20)
                    radius: Style.space(4)
                    color: submitManualArea.containsMouse ? root.catppuccin.blue : root.catppuccin.surface1

                    MouseArea {
                      id: submitManualArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (manualEmailInput.text && manualTokenInput.text) {
                          backend.addAccountManual(manualEmailInput.text, manualTokenInput.text)
                        }
                      }
                    }

                    Text {
                      id: submitManualTxt
                      anchors.centerIn: parent
                      text: "保存并添加"
                      color: root.catppuccin.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }
              }
            }
          }

          // =================================================================
          // 3. Accounts Grid: 2 Accounts Per Row with Ring Progress & Weekly Limit
          // =================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)

            // Grid Section Header
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "账号配额矩阵"
                color: root.catppuccin.subtext0
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: "(左侧圆环为 Gemini 5h 剩余额度 · 点击卡片切换活跃账号)"
                color: root.catppuccin.overlay0
                font.family: Style.font.family
                font.pixelSize: Style.font.caption * 0.9
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Empty State
            Rectangle {
              visible: root.accounts.length === 0 && !root.loading
              width: parent.width
              height: Style.space(100)
              radius: Style.space(8)
              color: root.catppuccin.mantle
              border.color: root.catppuccin.surface0
              border.width: 1

              Column {
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "暂未配置 Antigravity 账号"
                  color: root.catppuccin.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "请点击右上角「+ 添加账号」开始使用"
                  color: root.catppuccin.overlay0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // 2-Column Grid for Accounts
            Grid {
              id: accountsGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(10)
              rowSpacing: Style.space(10)

              Repeater {
                model: root.accounts

                Rectangle {
                  id: cardRoot
                  required property var modelData
                  required property int index

                  // 活跃状态由全局唯一的 activeEmail 决定
                  readonly property bool isActive: (backend.activeEmail !== "" ? modelData.email === backend.activeEmail : (index === 0))
                  readonly property bool hasError: !!modelData.error

                  // Claude 模型组额度
                  readonly property double cRem: modelData.claudeFiveHourRemaining !== undefined
                    ? modelData.claudeFiveHourRemaining : 1.0
                  readonly property double cPct: modelData.claudeFiveHourPercent !== undefined
                    ? modelData.claudeFiveHourPercent : 100.0
                  readonly property string cReset: modelData.claudeFiveHourResetFormatted || "充裕"
                  readonly property double cWRem: modelData.claudeWeeklyRemaining !== undefined
                    ? modelData.claudeWeeklyRemaining : 1.0
                  readonly property double cWPct: modelData.claudeWeeklyPercent !== undefined
                    ? modelData.claudeWeeklyPercent : 100.0
                  readonly property string cWReset: modelData.claudeWeeklyResetFormatted || "充裕"

                  // Gemini 模型组额度
                  readonly property double gRem: modelData.geminiFiveHourRemaining !== undefined
                    ? modelData.geminiFiveHourRemaining : 1.0
                  readonly property double gPct: modelData.geminiFiveHourPercent !== undefined
                    ? modelData.geminiFiveHourPercent : 100.0
                  readonly property string gReset: modelData.geminiFiveHourResetFormatted || "充裕"
                  readonly property double gWRem: modelData.geminiWeeklyRemaining !== undefined
                    ? modelData.geminiWeeklyRemaining : 1.0
                  readonly property double gWPct: modelData.geminiWeeklyPercent !== undefined
                    ? modelData.geminiWeeklyPercent : 100.0
                  readonly property string gWReset: modelData.geminiWeeklyResetFormatted || "充裕"

                  // 瓶颈与综合状态
                  readonly property double bottleneckRem: Math.min(gRem, gWRem)
                  readonly property double bottleneckPct: Math.min(gPct, gWPct)
                  readonly property double minRem: Math.min(gRem, cRem, gWRem, cWRem)

                  // 删除确认状态
                  property bool showConfirmDelete: false

                  width: (accountsGrid.width - accountsGrid.columnSpacing) / 2
                  implicitHeight: cardContent.implicitHeight + Style.space(20)
                  radius: Style.space(10)
                  opacity: (cardRoot.modelData.enabled !== false ? 1.0 : 0.65)

                  Behavior on opacity {
                    NumberAnimation { duration: 150 }
                  }

                  // Catppuccin Card Background
                  color: isActive
                    ? Qt.rgba(137/255, 180/255, 250/255, 0.08)
                    : (cardMouse.containsMouse ? root.catppuccin.surface0 : root.catppuccin.mantle)

                  // Catppuccin Card Border
                  border.color: isActive
                    ? root.catppuccin.blue
                    : (cardMouse.containsMouse ? root.catppuccin.surface1 : root.catppuccin.surface0)
                  border.width: isActive ? 1.5 : 1

                  Behavior on color {
                    ColorAnimation { duration: 150 }
                  }
                  Behavior on border.color {
                    ColorAnimation { duration: 150 }
                  }

                  MouseArea {
                    id: cardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (!cardRoot.showConfirmDelete) {
                        backend.switchAccount(cardRoot.modelData.email)
                      }
                    }
                  }

                  // Card Content Container
                  Column {
                    id: cardContent
                    width: parent.width - Style.space(20)
                    anchors.centerIn: parent
                    spacing: Style.space(10)

                    // 1. Card Top Bar: Email, Active Badge, Delete Icon
                    Item {
                      width: parent.width
                      height: Style.space(22)

                      Row {
                        anchors.left: parent.left
                        anchors.right: cardActionsRow.left
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        // Status Dot
                        Rectangle {
                          width: Style.space(6)
                          height: Style.space(6)
                          radius: Style.space(3)
                          color: cardRoot.isActive ? root.catppuccin.blue : root.quotaColor(cardRoot.minRem)
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        // Email
                        Text {
                          text: cardRoot.modelData.email
                          color: cardRoot.isActive ? root.catppuccin.text : root.catppuccin.subtext0
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: cardRoot.isActive
                          elide: Text.ElideMiddle
                          width: Math.min(implicitWidth, parent.width - Style.space(14))
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      // Right Badges & Actions
                      Row {
                        id: cardActionsRow
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        // Active Pill Badge
                        Rectangle {
                          visible: cardRoot.isActive
                          height: Style.space(18)
                          width: activePillText.implicitWidth + Style.space(10)
                          radius: Style.space(9)
                          color: Qt.rgba(137/255, 180/255, 250/255, 0.22)
                          border.color: root.catppuccin.blue
                          border.width: 1
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            id: activePillText
                            anchors.centerIn: parent
                            text: "活跃"
                            color: root.catppuccin.blue
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption * 0.85
                            font.bold: true
                          }
                        }

                        // Enable / Disable in Proxy Pool
                        Rectangle {
                          id: enableToggleBtn
                          height: Style.space(18)
                          width: enableToggleText.implicitWidth + Style.space(10)
                          radius: Style.space(9)
                          color: (cardRoot.modelData.enabled !== false)
                            ? Qt.rgba(148/255, 226/255, 213/255, 0.18)
                            : Qt.rgba(108/255, 112/255, 134/255, 0.20)
                          border.color: (cardRoot.modelData.enabled !== false)
                            ? root.catppuccin.teal
                            : root.catppuccin.overlay0
                          border.width: 1
                          anchors.verticalCenter: parent.verticalCenter

                          MouseArea {
                            id: enableToggleArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              backend.toggleAccount(cardRoot.modelData.email)
                            }
                          }

                          Text {
                            id: enableToggleText
                            anchors.centerIn: parent
                            text: (cardRoot.modelData.enabled !== false) ? "池:开" : "池:关"
                            color: (cardRoot.modelData.enabled !== false)
                              ? root.catppuccin.teal
                              : root.catppuccin.overlay1
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption * 0.82
                            font.bold: true
                          }
                        }

                        // Delete / Remove Account Button
                        Rectangle {
                          id: deleteIconBtn
                          width: Style.space(18)
                          height: Style.space(18)
                          radius: Style.space(4)
                          color: deleteArea.containsMouse ? Qt.rgba(243/255, 139/255, 168/255, 0.25) : "transparent"
                          anchors.verticalCenter: parent.verticalCenter

                          MouseArea {
                            id: deleteArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: cardRoot.showConfirmDelete = true
                          }

                          Text {
                            anchors.centerIn: parent
                            text: "✕"
                            color: deleteArea.containsMouse ? root.catppuccin.red : root.catppuccin.overlay0
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption * 0.85
                          }
                        }
                      }
                    }

                    // 2. Card Middle: Ring Progress Chart + Quota Details (5h & Weekly)
                    Row {
                      width: parent.width
                      spacing: Style.space(12)

                      // Left: Dual Concentric Ring Chart (Canvas based, 5h Outer + Weekly Inner)
                      Item {
                        id: ringContainer
                        width: Style.space(58)
                        height: Style.space(58)
                        anchors.verticalCenter: parent.verticalCenter

                        Canvas {
                          id: ringCanvas
                          anchors.fill: parent
                          antialiasing: true

                          readonly property double fraction5h: Math.max(0.0, Math.min(1.0, cardRoot.gRem))
                          readonly property double fractionWeekly: Math.max(0.0, Math.min(1.0, cardRoot.gWRem))
                          readonly property color stroke5h: root.quotaColor(cardRoot.gRem)
                          readonly property color strokeWeekly: root.quotaColor(cardRoot.gWRem)

                          onFraction5hChanged: ringCanvas.requestPaint()
                          onFractionWeeklyChanged: ringCanvas.requestPaint()
                          onStroke5hChanged: ringCanvas.requestPaint()
                          onStrokeWeeklyChanged: ringCanvas.requestPaint()
                          Component.onCompleted: ringCanvas.requestPaint()

                          onPaint: {
                            var ctx = getContext("2d")
                            ctx.reset()
                            ctx.clearRect(0, 0, width, height)

                            var cx = width / 2
                            var cy = height / 2

                            // 1. Outer Ring: 5-Hour Limit
                            var lwOuter = Style.space(3.6)
                            var rOuter = (Math.min(width, height) - lwOuter) / 2 - 1

                            // Outer Track
                            ctx.beginPath()
                            ctx.arc(cx, cy, rOuter, 0, Math.PI * 2, false)
                            ctx.strokeStyle = root.catppuccin.surface0
                            ctx.lineWidth = lwOuter
                            ctx.stroke()

                            // Outer Progress Arc
                            var startAngle = -Math.PI / 2
                            var sweepOuter = ringCanvas.fraction5h * Math.PI * 2
                            if (sweepOuter > 0.005) {
                              ctx.beginPath()
                              ctx.arc(cx, cy, rOuter, startAngle, startAngle + sweepOuter, false)
                              ctx.strokeStyle = ringCanvas.stroke5h
                              ctx.lineWidth = lwOuter
                              ctx.lineCap = "round"
                              ctx.stroke()
                            }

                            // 2. Inner Ring: Weekly Limit
                            var lwInner = Style.space(2.6)
                            var rInner = rOuter - (lwOuter / 2) - Style.space(2.4) - (lwInner / 2)

                            // Inner Track
                            ctx.beginPath()
                            ctx.arc(cx, cy, rInner, 0, Math.PI * 2, false)
                            ctx.strokeStyle = root.catppuccin.surface0
                            ctx.lineWidth = lwInner
                            ctx.stroke()

                            // Inner Progress Arc
                            var sweepInner = ringCanvas.fractionWeekly * Math.PI * 2
                            if (sweepInner > 0.005) {
                              ctx.beginPath()
                              ctx.arc(cx, cy, rInner, startAngle, startAngle + sweepInner, false)
                              ctx.strokeStyle = ringCanvas.strokeWeekly
                              ctx.lineWidth = lwInner
                              ctx.lineCap = "round"
                              ctx.stroke()
                            }
                          }
                        }

                        // Center Percentage Label & Bottleneck Indicator
                        Column {
                          anchors.centerIn: parent
                          spacing: 0

                          Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: Math.round(cardRoot.bottleneckPct) + "%"
                            color: root.quotaColor(cardRoot.bottleneckRem)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption * 0.92
                            font.bold: true
                          }

                          Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: (cardRoot.bottleneckPct === cardRoot.gWPct && cardRoot.gWPct < cardRoot.gPct) ? "周瓶颈" : "5h·周"
                            color: (cardRoot.bottleneckPct === cardRoot.gWPct && cardRoot.gWPct < 50) ? root.catppuccin.peach : root.catppuccin.overlay1
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption * 0.65
                            font.bold: true
                          }
                        }
                      }

                      // Right: Gemini and Claude Breakdown
                      Column {
                        width: parent.width - ringContainer.width - Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        // Row 1: Gemini Models (Primary)
                        Column {
                          width: parent.width
                          spacing: Style.space(2)

                          Item {
                            width: parent.width
                            height: Math.max(geminiTitle.implicitHeight, geminiValue.implicitHeight)

                            Row {
                              id: geminiTitle
                              anchors.left: parent.left
                              anchors.verticalCenter: parent.verticalCenter
                              spacing: Style.space(4)

                              Rectangle {
                                width: Style.space(4)
                                height: Style.space(8)
                                radius: Style.space(2)
                                color: root.catppuccin.sapphire
                                anchors.verticalCenter: parent.verticalCenter
                              }

                              Text {
                                text: "Gemini"
                                color: root.catppuccin.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption * 0.85
                                font.bold: true
                              }
                            }

                            Text {
                              id: geminiValue
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              text: (cardRoot.gPct < 99.9 ? ("5h " + cardRoot.gPct.toFixed(0) + "% (" + cardRoot.gReset + ")") : "5h 100%") + " · 周 " + cardRoot.gWPct.toFixed(0) + "%"
                              color: root.quotaColor(Math.min(cardRoot.gRem, cardRoot.gWRem))
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption * 0.82
                              font.bold: true
                            }
                          }

                          // Gemini Mini Progress Bar
                          Rectangle {
                            width: parent.width
                            height: Style.space(4)
                            radius: Style.space(2)
                            color: root.catppuccin.surface0

                            Rectangle {
                              height: parent.height
                              width: Math.max(0, Math.min(parent.width, parent.width * cardRoot.gRem))
                              radius: Style.space(2)
                              color: root.quotaColor(cardRoot.gRem)
                              Behavior on width {
                                NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
                              }
                            }
                          }
                        }

                        // Row 2: Claude & GPT Models
                        Column {
                          width: parent.width
                          spacing: Style.space(2)

                          Item {
                            width: parent.width
                            height: Math.max(claudeTitle.implicitHeight, claudeValue.implicitHeight)

                            Row {
                              id: claudeTitle
                              anchors.left: parent.left
                              anchors.verticalCenter: parent.verticalCenter
                              spacing: Style.space(4)

                              Rectangle {
                                width: Style.space(4)
                                height: Style.space(8)
                                radius: Style.space(2)
                                color: root.catppuccin.mauve
                                anchors.verticalCenter: parent.verticalCenter
                              }

                              Text {
                                text: "Claude"
                                color: root.catppuccin.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption * 0.85
                                font.bold: true
                              }
                            }

                            Text {
                              id: claudeValue
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              text: (cardRoot.cPct < 99.9 ? ("5h " + cardRoot.cPct.toFixed(0) + "% (" + cardRoot.cReset + ")") : "5h 100%") + " · 周 " + cardRoot.cWPct.toFixed(0) + "%"
                              color: root.quotaColor(Math.min(cardRoot.cRem, cardRoot.cWRem))
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption * 0.82
                              font.bold: true
                            }
                          }

                          // Claude Mini Progress Bar
                          Rectangle {
                            width: parent.width
                            height: Style.space(4)
                            radius: Style.space(2)
                            color: root.catppuccin.surface0

                            Rectangle {
                              height: parent.height
                              width: Math.max(0, Math.min(parent.width, parent.width * cardRoot.cRem))
                              radius: Style.space(2)
                              color: root.quotaColor(cardRoot.cRem)
                              Behavior on width {
                                NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
                              }
                            }
                          }
                        }
                      }
                    }
                  }

                  // Delete Confirmation Overlay
                  Rectangle {
                    visible: cardRoot.showConfirmDelete
                    anchors.fill: parent
                    radius: Style.space(10)
                    color: root.catppuccin.base
                    border.color: root.catppuccin.red
                    border.width: 1

                    Column {
                      anchors.centerIn: parent
                      spacing: Style.space(8)

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "确定移除此账号？"
                        color: root.catppuccin.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(8)

                        Rectangle {
                          width: Style.space(50)
                          height: Style.space(24)
                          radius: Style.space(4)
                          color: root.catppuccin.red

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              backend.removeAccount(cardRoot.modelData.email)
                              cardRoot.showConfirmDelete = false
                            }
                          }

                          Text {
                            anchors.centerIn: parent
                            text: "移除"
                            color: root.catppuccin.crust
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }
                        }

                        Rectangle {
                          width: Style.space(50)
                          height: Style.space(24)
                          radius: Style.space(4)
                          color: root.catppuccin.surface0

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: cardRoot.showConfirmDelete = false
                          }

                          Text {
                            anchors.centerIn: parent
                            text: "取消"
                            color: root.catppuccin.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // =================================================================
          // 4. Clean Catppuccin Footer
          // =================================================================
          Item {
            width: parent.width
            height: Style.space(32)

            Text {
              anchors.centerIn: parent
              text: "单击卡片切换活跃账号 · R 刷新 · Esc 关闭"
              color: root.catppuccin.overlay0
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Status bar widget for Antigravity AI multi-account quota monitoring.
// Displays active account remaining quota, health status dot, and
// provides instant access to detailed usage panel and in-panel account management.
BarWidget {
  id: root
  moduleName: "antigravity.usage"

  readonly property string glyph: "🤖"  // Robot glyph

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
  readonly property double remainingFraction: activeAcc && activeAcc.overallRemaining !== undefined
    ? activeAcc.overallRemaining : 1.0
  readonly property string percentLabel: activeAcc && activeAcc.overallPercent !== undefined
    ? Math.round(activeAcc.overallPercent) + "%" : "--%"
  readonly property string resetLabel: activeAcc && activeAcc.overallResetFormatted
    ? activeAcc.overallResetFormatted : ""

  readonly property color statusColor: {
    if (!activeAcc) return Color.muted
    if (activeAcc.error) return "#EF5350"
    if (remainingFraction >= 0.5) return "#4CAF50"
    if (remainingFraction >= 0.2) return "#FFA726"
    return "#EF5350"
  }

  function quotaColor(fraction) {
    if (fraction === undefined || fraction === null) return Color.muted
    if (fraction >= 0.5) return "#4CAF50"
    if (fraction >= 0.2) return "#FFA726"
    return "#EF5350"
  }

  readonly property string tooltipInfo: {
    var lines = ["Antigravity 配额监控"]
    if (activeAcc) {
      lines.push("账号: " + activeAcc.email)
      lines.push("最低剩余: " + percentLabel + " (" + resetLabel + ")")
      if (backend.accounts && backend.accounts.length > 1) {
        lines.push("共 " + backend.accounts.length + " 个账号已配置")
      }
    } else {
      lines.push("正在加载或未配置账号...")
    }
    lines.push("左键: 查看详情 · 中键: 切换查看账号 · 右键: 刷新")
    return lines.join("\n")
  }

  // Panel state
  property bool panelOpen: false
  readonly property bool opened: root.panelOpen
  property bool showAddSection: false
  property string addMode: "oauth"  // "oauth" or "manual"
  property bool confirmDelete: false

  onActiveAccChanged: {
    root.confirmDelete = false
  }

  function open() { root.panelOpen = true }
  function close() {
    root.panelOpen = false
    root.confirmDelete = false
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

    // Vertical layout (if placed on a vertical bar)
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
    color: Color.accent
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
  // Detailed Popup Panel (Native KeyboardPanel)
  // =========================================================================
  KeyboardPanel {
    id: popupPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    focusTarget: keyCatcher
    contentWidth: popupPanel.fittedContentWidth(Style.space(480))
    contentHeight: popupPanel.fittedContentHeight(panelColumn.implicitHeight, Style.space(660))

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
        anchors.margins: Style.space(4)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // =================================================================
          // 1. Header: Title, Count Badge, Add Account, Refresh & Close
          // =================================================================
          Item {
            width: parent.width
            height: Style.space(32)

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
                text: "Antigravity Quota"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                height: Style.space(20)
                width: accountBadgeText.implicitWidth + Style.space(12)
                radius: Style.space(10)
                color: Qt.rgba(1, 1, 1, 0.08)
                border.color: Qt.rgba(1, 1, 1, 0.15)
                border.width: 1
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: accountBadgeText
                  anchors.centerIn: parent
                  text: root.accounts.length + " 账号"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Header Action Buttons
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              // Add Account Button
              Rectangle {
                id: addAccountBtn
                height: Style.space(28)
                width: addAccountRow.implicitWidth + Style.space(16)
                radius: Style.space(6)
                color: root.showAddSection ? Qt.rgba(0.3, 0.6, 1.0, 0.35) : (addAccountArea.containsMouse ? Qt.rgba(0.3, 0.6, 1.0, 0.22) : Qt.rgba(0.3, 0.6, 1.0, 0.12))
                border.color: root.showAddSection ? "#64B5F6" : "#4A90E2"
                border.width: 1

                MouseArea {
                  id: addAccountArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.showAddSection = !root.showAddSection
                    root.confirmDelete = false
                  }
                }

                Row {
                  id: addAccountRow
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  Text {
                    text: "+"
                    color: "#64B5F6"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "添加账号"
                    color: "#64B5F6"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // Refresh Button
              MouseArea {
                id: refreshBtn
                width: Style.space(28)
                height: Style.space(28)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: backend.refresh(true)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(6)
                  color: refreshBtn.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.04)

                  Text {
                    anchors.centerIn: parent
                    text: root.loading ? "\u231b" : "\u21bb"
                    color: root.loading ? Color.accent : Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
              }

              // Close Button
              MouseArea {
                id: closeBtn
                width: Style.space(28)
                height: Style.space(28)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(6)
                  color: closeBtn.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.04)

                  Text {
                    anchors.centerIn: parent
                    text: "\u2715"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }
          }

          // =================================================================
          // 2. Add Account Expandable Section
          // =================================================================
          Rectangle {
            id: addSectionRect
            visible: root.showAddSection || backend.addingAccount
            width: parent.width
            implicitHeight: addSectionCol.implicitHeight + Style.space(24)
            radius: Style.space(8)
            color: Qt.rgba(1, 1, 1, 0.04)
            border.color: Qt.rgba(0.3, 0.6, 1.0, 0.3)
            border.width: 1

            Column {
              id: addSectionCol
              width: parent.width - Style.space(24)
              anchors.centerIn: parent
              spacing: Style.space(12)

              // Title and Mode Switcher
              Row {
                width: parent.width
                height: Style.space(26)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "添加 Antigravity 账号"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                // Mode Tabs (OAuth vs Manual)
                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Rectangle {
                    height: Style.space(24)
                    width: oauthTabTxt.implicitWidth + Style.space(12)
                    radius: Style.space(4)
                    color: root.addMode === "oauth" ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.04)
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.addMode = "oauth"
                    }
                    Text {
                      id: oauthTabTxt
                      anchors.centerIn: parent
                      text: "网页授权"
                      color: root.addMode === "oauth" ? Color.foreground : Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: root.addMode === "oauth"
                    }
                  }

                  Rectangle {
                    height: Style.space(24)
                    width: manualTabTxt.implicitWidth + Style.space(12)
                    radius: Style.space(4)
                    color: root.addMode === "manual" ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.04)
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.addMode = "manual"
                    }
                    Text {
                      id: manualTabTxt
                      anchors.centerIn: parent
                      text: "手动 Token"
                      color: root.addMode === "manual" ? Color.foreground : Color.muted
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
                  text: "点击下方按钮将在系统浏览器中打开 Google 授权页面，授权完成后自动添加该账号。"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                // Action / Status
                Item {
                  width: parent.width
                  height: Style.space(34)

                  // Trigger Button (when not in flight)
                  Rectangle {
                    visible: !backend.addingAccount
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(32)
                    width: startOAuthTxt.implicitWidth + Style.space(24)
                    radius: Style.space(6)
                    color: startOAuthArea.containsMouse ? "#1E88E5" : "#1976D2"

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
                      color: "#FFFFFF"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  // In-flight authorization banner
                  Row {
                    visible: backend.addingAccount
                    anchors.fill: parent
                    spacing: Style.space(8)

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(32)
                      width: authBannerRow.implicitWidth + Style.space(16)
                      radius: Style.space(6)
                      color: Qt.rgba(0.2, 0.6, 1.0, 0.15)
                      border.color: "#4A90E2"
                      border.width: 1

                      Row {
                        id: authBannerRow
                        anchors.centerIn: parent
                        spacing: Style.space(6)
                        Text {
                          text: "\u231b"
                          color: "#64B5F6"
                          font.pixelSize: Style.font.body
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                          text: backend.addAccountStatus || "正在等待浏览器授权..."
                          color: "#64B5F6"
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(32)
                      width: Style.space(60)
                      radius: Style.space(6)
                      color: cancelOAuthArea.containsMouse ? Qt.rgba(1, 0.3, 0.3, 0.25) : Qt.rgba(1, 0.3, 0.3, 0.15)
                      border.color: "#EF5350"
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
                        color: "#EF5350"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }

                // Error Text
                Text {
                  visible: backend.addAccountError !== ""
                  text: backend.addAccountError
                  color: "#EF5350"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                // Fallback: Paste Callback URL / Code directly
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: backend.addingAccount || backend.addAccountError !== ""

                  Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.rgba(1, 1, 1, 0.08)
                  }

                  Text {
                    width: parent.width
                    text: "若浏览器跳转后提示拒绝连接或未自动回调，请复制地址栏完整 URL 粘贴至此处:"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    TextField {
                      id: callbackUrlInput
                      width: parent.width - submitCallbackBtn.width - Style.space(6)
                      height: Style.space(30)
                      placeholderText: "http://localhost:51121/oauth-callback?code=..."
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Color.foreground
                      selectionColor: Style.selectionFillFor(Color.foreground, Color.accent)
                      selectedTextColor: Color.foreground
                      placeholderTextColor: Color.muted
                      background: Rectangle {
                        radius: Style.space(6)
                        color: Qt.rgba(1, 1, 1, 0.06)
                        border.color: callbackUrlInput.activeFocus ? "#4A90E2" : Qt.rgba(1, 1, 1, 0.15)
                        border.width: 1
                      }
                    }

                    Rectangle {
                      id: submitCallbackBtn
                      width: submitCallbackTxt.implicitWidth + Style.space(16)
                      height: Style.space(30)
                      radius: Style.space(6)
                      color: submitCallbackArea.containsMouse ? "#1E88E5" : "#1976D2"

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
                        text: "完成添加"
                        color: "#FFFFFF"
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
                spacing: Style.space(8)
                visible: root.addMode === "manual"

                Text {
                  text: "Google 账号邮箱:"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: manualEmailInput
                  width: parent.width
                  height: Style.space(32)
                  placeholderText: "example@gmail.com"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: Color.foreground
                  selectionColor: Style.selectionFillFor(Color.foreground, Color.accent)
                  selectedTextColor: Color.foreground
                  placeholderTextColor: Color.muted
                  background: Rectangle {
                    radius: Style.space(6)
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border.color: manualEmailInput.activeFocus ? "#4A90E2" : Qt.rgba(1, 1, 1, 0.15)
                    border.width: 1
                  }
                }

                Text {
                  text: "OAuth Refresh Token:"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: manualTokenInput
                  width: parent.width
                  height: Style.space(32)
                  placeholderText: "1//0..."
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  echoMode: TextInput.Password
                  color: Color.foreground
                  selectionColor: Style.selectionFillFor(Color.foreground, Color.accent)
                  selectedTextColor: Color.foreground
                  placeholderTextColor: Color.muted
                  background: Rectangle {
                    radius: Style.space(6)
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border.color: manualTokenInput.activeFocus ? "#4A90E2" : Qt.rgba(1, 1, 1, 0.15)
                    border.width: 1
                  }
                }

                Item {
                  width: parent.width
                  height: Style.space(32)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(30)
                    width: submitManualTxt.implicitWidth + Style.space(24)
                    radius: Style.space(6)
                    color: submitManualArea.containsMouse ? "#1E88E5" : "#1976D2"

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
                      color: "#FFFFFF"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: submitManualTxt.implicitWidth + Style.space(36)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: backend.addAccountError !== "" || backend.addAccountStatus !== ""
                    text: backend.addAccountError || backend.addAccountStatus
                    color: backend.addAccountError ? "#EF5350" : "#4CAF50"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // =================================================================
          // 3. Multi-Account Switcher Tabs
          // =================================================================
          Flickable {
            width: parent.width
            height: Style.space(34)
            contentWidth: accountRow.implicitWidth
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: root.accounts.length > 0

            Row {
              id: accountRow
              spacing: Style.space(8)

              Repeater {
                model: root.accounts

                Rectangle {
                  required property var modelData
                  readonly property bool isSelected: root.activeAcc && root.activeAcc.email === modelData.email

                  width: tabContent.implicitWidth + Style.space(20)
                  height: Style.space(32)
                  radius: Style.space(16)
                  color: isSelected ? Qt.rgba(0.3, 0.6, 1.0, 0.22) : (tabArea.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03))
                  border.width: 1
                  border.color: isSelected ? "#4A90E2" : Qt.rgba(1, 1, 1, 0.12)

                  MouseArea {
                    id: tabArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: backend.selectAccount(modelData.email)
                  }

                  Row {
                    id: tabContent
                    anchors.centerIn: parent
                    spacing: Style.space(6)

                    Rectangle {
                      width: Style.space(6)
                      height: Style.space(6)
                      radius: Style.space(3)
                      color: isSelected ? "#4A90E2" : Color.muted
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.email
                      color: isSelected ? Color.foreground : Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: isSelected
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }
          }

          // =================================================================
          // 4. Current Account Details & Family Quotas
          // =================================================================
          Rectangle {
            width: parent.width
            implicitHeight: currentAccountColumn.implicitHeight + Style.space(24)
            radius: Style.space(10)
            color: Qt.rgba(1, 1, 1, 0.04)
            border.color: Qt.rgba(1, 1, 1, 0.08)
            border.width: 1

            Column {
              id: currentAccountColumn
              width: parent.width - Style.space(24)
              anchors.centerIn: parent
              spacing: Style.space(12)

              // Top Info: Email + Tier + Delete Action
              Item {
                width: parent.width
                height: Style.space(32)

                Column {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    text: root.activeAcc ? root.activeAcc.email : "未选择账号"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    text: root.activeAcc ? (root.activeAcc.tier + " · 最低剩余: " + root.activeAcc.overallPercent + "%") : ""
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                // In-panel Delete / Remove Account Button with confirmation
                Item {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !!root.activeAcc
                  width: root.confirmDelete ? confirmRow.implicitWidth : deleteBtn.implicitWidth
                  height: Style.space(28)

                  // Normal state: Delete button
                  Rectangle {
                    id: deleteBtn
                    visible: !root.confirmDelete
                    implicitWidth: deleteBtnRow.implicitWidth + Style.space(16)
                    height: Style.space(28)
                    radius: Style.space(6)
                    color: deleteBtnArea.containsMouse ? Qt.rgba(1, 0.3, 0.3, 0.18) : Qt.rgba(1, 1, 1, 0.04)
                    border.color: deleteBtnArea.containsMouse ? "#EF5350" : Qt.rgba(1, 1, 1, 0.1)
                    border.width: 1

                    MouseArea {
                      id: deleteBtnArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.confirmDelete = true
                    }

                    Row {
                      id: deleteBtnRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text {
                        text: "\uD83D\uDDD1"
                        font.pixelSize: Style.font.caption
                        color: deleteBtnArea.containsMouse ? "#EF5350" : Color.muted
                      }
                      Text {
                        text: "移除账号"
                        color: deleteBtnArea.containsMouse ? "#EF5350" : Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  // Confirmation state
                  Row {
                    id: confirmRow
                    visible: root.confirmDelete
                    spacing: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      text: "确认移除？"
                      color: "#EF5350"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                      width: Style.space(46)
                      height: Style.space(26)
                      radius: Style.space(4)
                      color: "#D32F2F"
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          if (root.activeAcc) {
                            backend.removeAccount(root.activeAcc.email)
                          }
                          root.confirmDelete = false
                        }
                      }
                      Text {
                        anchors.centerIn: parent
                        text: "确定"
                        color: "#FFFFFF"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Rectangle {
                      width: Style.space(46)
                      height: Style.space(26)
                      radius: Style.space(4)
                      color: Qt.rgba(1, 1, 1, 0.1)
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.confirmDelete = false
                      }
                      Text {
                        anchors.centerIn: parent
                        text: "取消"
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              // Separator
              Rectangle {
                width: parent.width
                height: 1
                color: Qt.rgba(1, 1, 1, 0.08)
              }

              // Family Quota Rows (Claude, Gemini Pro, Gemini Flash, GPT-OSS)
              Column {
                width: parent.width
                spacing: Style.space(10)

                Repeater {
                  model: [
                    { key: "claude", defaultName: "Claude 4.6 (Thinking)" },
                    { key: "gemini_pro", defaultName: "Gemini 3 Pro" },
                    { key: "gemini_flash", defaultName: "Gemini 3 Flash" },
                    { key: "gpt_oss", defaultName: "GPT-OSS 120B" }
                  ]

                  Column {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(4)

                    readonly property var famMap: root.activeAcc ? root.activeAcc.families : null
                    readonly property var itemData: famMap ? famMap[modelData.key] : null
                    readonly property double remFraction: itemData && itemData.remaining !== undefined
                      ? itemData.remaining : 1.0
                    readonly property double remPercent: itemData && itemData.remainingPercent !== undefined
                      ? itemData.remainingPercent : 100.0
                    readonly property string resetStr: itemData && itemData.resetFormatted
                      ? itemData.resetFormatted : "100% 充裕"
                    readonly property string nameStr: itemData && itemData.name
                      ? itemData.name : modelData.defaultName

                    Item {
                      width: parent.width
                      height: Math.max(nameLabel.implicitHeight, valueRow.implicitHeight)

                      Text {
                        id: nameLabel
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: nameStr
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Row {
                        id: valueRow
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                          text: remPercent.toFixed(1) + "%"
                          color: root.quotaColor(remFraction)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        Text {
                          text: "(" + resetStr + ")"
                          color: Color.muted
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    // Progress Track
                    Rectangle {
                      width: parent.width
                      height: Style.space(6)
                      radius: Style.space(3)
                      color: Qt.rgba(1, 1, 1, 0.1)

                      Rectangle {
                        height: parent.height
                        width: Math.max(0, Math.min(parent.width, parent.width * remFraction))
                        radius: Style.space(3)
                        color: root.quotaColor(remFraction)

                        Behavior on width {
                          NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // =================================================================
          // 5. Multi-Account Comparison Summary (if > 1 account)
          // =================================================================
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.accounts.length > 1

            Text {
              text: "多账号配额一览"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: root.accounts

              Rectangle {
                required property var modelData
                width: parent.width
                height: Style.space(32)
                radius: Style.space(6)
                color: Qt.rgba(1, 1, 1, 0.03)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: backend.selectAccount(modelData.email)
                }

                Item {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.email
                    color: (root.activeAcc && root.activeAcc.email === modelData.email) ? "#64B5F6" : Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: (root.activeAcc && root.activeAcc.email === modelData.email)
                    width: Style.space(180)
                    elide: Text.ElideMiddle
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)

                    // Mini Bar
                    Rectangle {
                      width: Style.space(120)
                      height: Style.space(6)
                      radius: Style.space(3)
                      color: Qt.rgba(1, 1, 1, 0.08)
                      anchors.verticalCenter: parent.verticalCenter

                      Rectangle {
                        height: parent.height
                        width: Math.max(0, Math.min(parent.width, parent.width * (modelData.overallRemaining !== undefined ? modelData.overallRemaining : 1.0)))
                        radius: Style.space(3)
                        color: root.quotaColor(modelData.overallRemaining)
                      }
                    }

                    Text {
                      text: (modelData.overallPercent !== undefined ? modelData.overallPercent.toFixed(0) : "0") + "%"
                      color: root.quotaColor(modelData.overallRemaining)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }
          }

          // =================================================================
          // 6. Clean Footer: ONLY Keyboard Shortcuts (NO CLI HINTS)
          // =================================================================
          Item {
            width: parent.width
            height: Style.space(22)

            Text {
              anchors.centerIn: parent
              text: "R 刷新 · Esc 关闭"
              color: Qt.rgba(1, 1, 1, 0.35)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}

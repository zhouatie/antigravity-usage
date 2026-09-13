import QtQuick
import Quickshell
import Quickshell.Io

// Backend controller for Antigravity multi-account quota polling,
// caching, and in-panel account management.
Item {
  id: root

  readonly property string fetchScriptPath: {
    var u = Qt.resolvedUrl("scripts/fetch_quota.py").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }

  readonly property string accountsScriptPath: {
    var u = Qt.resolvedUrl("scripts/accounts.py").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }

  property var quotaData: null
  property bool loading: false
  property string activeEmail: ""
  property var accounts: []
  property string selectedEmail: ""
  property var currentAccount: null
  property string lastError: ""
  property double lastUpdated: 0

  // Account addition state
  property bool addingAccount: false
  property string addAccountStatus: ""
  property string addAccountError: ""
  property bool removingAccount: false

  // Refresh interval in seconds (default 300s = 5m)
  property int refreshIntervalSec: 300

  // Proxy state
  property bool proxyRunning: false
  property int proxyPort: 8045
  property bool togglingProxy: false

  signal quotaUpdated()

  function updateCurrentAccount() {
    if (!root.accounts || root.accounts.length === 0) {
      root.currentAccount = null
      return
    }

    var targetEmail = root.activeEmail
    var matched = null
    for (var i = 0; i < root.accounts.length; i++) {
      if (root.accounts[i].email === targetEmail) {
        matched = root.accounts[i]
        break
      }
    }
    root.currentAccount = matched || root.accounts[0]
  }

  function selectAccount(email) {
    root.switchAccount(email)
  }

  function switchAccount(email) {
    if (!email) return
    root.activeEmail = email
    root.updateCurrentAccount()
    switchProc.command = ["python3", root.accountsScriptPath, "switch", email]
    switchProc.running = true
  }

  function refresh(force) {
    if (root.loading) return
    root.loading = true
    root.lastError = ""

    var cmd = ["python3", root.fetchScriptPath, "--json"]
    if (force) {
      cmd.push("--force")
    }
    fetchProc.command = cmd
    fetchProc.running = true
  }

  function cycleAccount() {
    if (!root.accounts || root.accounts.length <= 1) return
    var curIdx = -1
    var current = root.activeEmail || (root.currentAccount ? root.currentAccount.email : "")
    for (var i = 0; i < root.accounts.length; i++) {
      if (root.accounts[i].email === current) {
        curIdx = i
        break
      }
    }
    var nextIdx = (curIdx + 1) % root.accounts.length
    var nextAccount = root.accounts[nextIdx]
    if (nextAccount && nextAccount.email) {
      root.switchAccount(nextAccount.email)
    }
  }

  function startAddAccount() {
    if (root.addingAccount) {
      root.cancelAddAccount()
    }
    root.addingAccount = true
    root.addAccountStatus = "正在等待浏览器授权... 请在打开的网页中完成 Google 登录"
    root.addAccountError = ""
    addProc.command = ["python3", root.accountsScriptPath, "add"]
    addProc.running = true
  }

  function cancelAddAccount() {
    if (addProc.running) {
      addProc.running = false
    }
    cancelPendingProc.command = ["python3", root.accountsScriptPath, "cancel-pending"]
    cancelPendingProc.running = true
    root.addingAccount = false
    root.addAccountStatus = ""
    root.addAccountError = ""
  }

  function submitCallbackUrl(url) {
    if (!url || !url.trim()) return
    root.addAccountStatus = "正在解析回调并保存账号..."
    root.addAccountError = ""
    pasteCallbackProc.command = ["python3", root.accountsScriptPath, "paste-callback", url.trim()]
    pasteCallbackProc.running = true
  }

  function addAccountManual(email, token) {
    if (!email || !token || root.addingAccount) return
    root.addingAccount = true
    root.addAccountStatus = "正在验证并保存账号..."
    root.addAccountError = ""
    addManualProc.targetEmail = email.trim()
    addManualProc.command = ["python3", root.accountsScriptPath, "add-token", email.trim(), token.trim()]
    addManualProc.running = true
  }

  function removeAccount(email) {
    if (!email || root.removingAccount) return
    root.removingAccount = true
    removeProc.targetEmail = email.trim()
    removeProc.command = ["python3", root.accountsScriptPath, "remove", email.trim()]
    removeProc.running = true
  }

  function checkProxyStatus() {
    proxyStatusProc.running = false
    proxyStatusProc.command = ["python3", root.accountsScriptPath, "proxy", "status", "--json"]
    proxyStatusProc.running = true
  }

  function toggleProxy() {
    if (root.togglingProxy) return
    root.togglingProxy = true
    var action = root.proxyRunning ? "stop" : "start"
    root.proxyRunning = !root.proxyRunning
    proxyToggleProc.running = false
    proxyToggleProc.command = ["python3", root.accountsScriptPath, "proxy", action]
    proxyToggleProc.running = true
  }

  function toggleAccount(email) {
    if (!email) return
    if (root.accounts) {
      for (var i = 0; i < root.accounts.length; i++) {
        if (root.accounts[i].email === email) {
          root.accounts[i].enabled = !(root.accounts[i].enabled !== false)
          break
        }
      }
      root.accounts = root.accounts.slice()
    }
    toggleAccountProc.running = false
    toggleAccountProc.command = ["python3", root.accountsScriptPath, "toggle", email]
    toggleAccountProc.running = true
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      id: fetchOut
      waitForEnd: true
    }
    onExited: function(code) {
      root.loading = false
      if (code !== 0) {
        root.lastError = "Fetch exited with code " + code
        console.warn("[antigravity.manager] Fetch error:", code)
        return
      }

      var text = fetchOut.text.trim()
      if (!text) {
        root.lastError = "Empty quota output"
        return
      }

      try {
        var parsed = JSON.parse(text)
        root.quotaData = parsed
        root.accounts = parsed.accounts || []
        root.activeEmail = parsed.activeEmail || ""
        root.lastUpdated = Date.now()
        root.updateCurrentAccount()
        root.quotaUpdated()
      } catch (err) {
        root.lastError = "JSON parse error: " + err
        console.error("[antigravity.manager] Parse error:", err, text)
      }
    }
  }

  Process {
    id: addProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      root.addingAccount = false
      if (code === 0) {
        root.addAccountStatus = "账号添加成功！"
        root.addAccountError = ""
        root.refresh(true)
      } else {
        if (!root.addAccountStatus || root.addAccountStatus.indexOf("成功") === -1) {
          root.addAccountError = "授权已取消或失败"
          root.addAccountStatus = ""
        }
      }
    }
  }

  Process {
    id: pasteCallbackProc
    stdout: StdioCollector {
      id: pasteOut
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0) {
        root.addingAccount = false
        if (addProc.running) {
          addProc.running = false
        }
        root.addAccountStatus = "账号添加成功！"
        root.addAccountError = ""
        root.refresh(true)
        try {
          var res = JSON.parse(pasteOut.text.trim())
          if (res && res.email) {
            root.selectAccount(res.email)
          }
        } catch (e) {}
      } else {
        root.addAccountError = "解析回调失败，请确认粘贴了包含 code= 的完整 URL"
      }
    }
  }

  Process {
    id: cancelPendingProc
    stdout: StdioCollector {
      waitForEnd: true
    }
  }

  Process {
    id: addManualProc
    property string targetEmail: ""
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      root.addingAccount = false
      if (code === 0) {
        root.addAccountStatus = "账号添加成功！"
        root.addAccountError = ""
        root.refresh(true)
        if (addManualProc.targetEmail) {
          root.selectAccount(addManualProc.targetEmail)
        }
      } else {
        root.addAccountError = "Token 验证失败，请确认填写正确"
        root.addAccountStatus = ""
      }
    }
  }

  Process {
    id: removeProc
    property string targetEmail: ""
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      root.removingAccount = false
      if (code === 0) {
        if (root.selectedEmail === removeProc.targetEmail) {
          root.selectedEmail = ""
        }
        root.refresh(true)
      } else {
        root.lastError = "移除账号失败"
      }
    }
  }

  Process {
    id: switchProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0) {
        root.refresh(false)
      }
    }
  }

  Process {
    id: proxyStatusProc
    stdout: StdioCollector {
      id: proxyStatusOut
      waitForEnd: true
    }
    onExited: function(code) {
      try {
        var txt = proxyStatusOut.text.trim()
        var lastBrace = txt.lastIndexOf("{")
        if (lastBrace !== -1) {
          var parsed = JSON.parse(txt.slice(lastBrace))
          root.proxyRunning = !!parsed.running
          root.proxyPort = parsed.port || 8045
          return
        }
      } catch (e) {}
      root.proxyRunning = (code === 0)
    }
  }

  Process {
    id: proxyToggleProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      root.togglingProxy = false
      root.checkProxyStatus()
    }
  }

  Process {
    id: toggleAccountProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function(code) {
      root.refresh(false)
      root.checkProxyStatus()
    }
  }

  Timer {
    id: pollTimer
    interval: Math.max(60, root.refreshIntervalSec) * 1000
    repeat: true
    running: true
    onTriggered: {
      root.refresh(false)
      root.checkProxyStatus()
    }
  }

  Component.onCompleted: {
    root.refresh(false)
    root.checkProxyStatus()
  }
}

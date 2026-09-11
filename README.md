# Antigravity Usage for Omarchy

专为 [Omarchy](https://omarchy.org/) 打造的 **Antigravity 多账号用量与配额监控插件**。实时在顶部状态栏居中显示 Antigravity 配额剩余百分比与重置倒计时，并支持在面板中直接添加、管理与切换多个 Google Antigravity 账号。

---

## ✨ 核心特性

- 🤖 **多账号配额监控与横向对比**：
  - 支持配置任意数量的 Google Antigravity 账号。
  - 面板顶部 Tab 快速切换查看各账号详细用量。
  - 多账号存在时提供直观的对比列表，快速找到额度最充裕的账号。
- ➕ **面板内原生可视化添加账号**：
  - 面板内直接提供 **`+ 添加账号`** 按钮，无需接触终端或命令行。
  - **网页授权登录**：一键在系统默认浏览器中打开 Google 官方授权页面，完成授权后自动入库并展示。
  - **双重兜底机制**：若因代理或防火墙未能直接连通本地回环，支持直接复制浏览器地址栏的回调 URL 粘贴完成添加。
  - **手动输入 Token**：支持直接粘贴 OAuth Refresh Token 快速录入。
- 🗑️ **面板内安全移除账号**：
  - 当前选中账号卡片右上角提供移除按钮，附带二次确认防误触保护。
- ⚡ **四大主力模型家族深度覆盖**：
  - **Claude 4.6 (Thinking)**（Claude Opus 4.6 / Claude Sonnet 4.6）
  - **Gemini 3 Pro**
  - **Gemini 3 Flash**
  - **GPT-OSS 120B**
  - 实时显示各模型家族剩余百分比进度条与 5 小时滚动窗口重置倒计时（例如 `in 1h 45m`）。
- 🎨 **Omarchy 原生质感与系统联动**：
  - 基于 Omarchy Quattro 原生组件体系（`KeyboardPanel`、`Style`、`Color`）开发，自适应系统深浅主题与高分屏缩放。
  - 状态栏配额健康度圆点指示（绿色 ≥50%，琥珀色 20%~50%，红色 <20%）。
  - 支持联动系统内置的 `omarchy.agents` 面板。
- 🚀 **纯标准库实现，零第三方依赖**：
  - 后端全部使用 Python 3.10+ 原生标准库编写，**无需安装任何 pip 依赖**。
  - 具备 5 分钟智能缓存与防抖机制，避免触发 Google API 速率限制。

---

## 📦 安装与启用

### 方式 1：通过 Omarchy 插件命令直接安装（推荐）

```bash
omarchy plugin add git@github.com:zhouatie/antigravity-usage.git --enable
```

安装后移动至状态栏居中位置：
```bash
omarchy bar move antigravity.usage --section center
```

### 方式 2：本地克隆 / 开发安装

```bash
git clone git@github.com:zhouatie/antigravity-usage.git ~/my/omarchy-plugin/antigravity-usage
ln -sf ~/my/omarchy-plugin/antigravity-usage ~/.config/omarchy/plugins/antigravity.usage

# 启用插件并放入状态栏中间
omarchy plugin enable antigravity.usage center
```

---

## 🖱️ 交互与快捷键

### 状态栏交互
| 操作 | 响应行为 |
|---|---|
| **鼠标左键点击** | 打开 / 收起详细用量弹窗面板 |
| **鼠标中键点击** | 快速循环轮换查看下一个账号 |
| **鼠标右键点击** | 强制跳过本地缓存，立即向 Google API 刷新最新用量 |

### 面板快捷键（面板处于打开状态时）
- `R`：立即强制刷新配额
- `Esc`：快速关闭面板

---

## ⚙️ 账号管理

### 1. 图形界面操作（推荐）
- 点击面板右上角 **`+ 添加账号`**：
  - **网页授权**：点击“打开浏览器授权登录”，在浏览器中完成登录即可自动保存并刷新展示。
  - **手动 Token**：输入邮箱与 Refresh Token 即可保存。
- 选中任意账号，可点击右上角 **`🗑️ 移除账号`** 进行安全清理。

### 2. 命令行辅助（可选）
```bash
cd ~/.config/omarchy/plugins/antigravity.usage

# 查看已配置账号列表
python3 scripts/accounts.py list

# 命令行添加账号（开启本地授权服务器）
python3 scripts/accounts.py add

# 直接指定 Refresh Token 添加
python3 scripts/accounts.py add-token user@gmail.com "1//0xxxx..."

# 移除指定账号
python3 scripts/accounts.py remove user@gmail.com
```

---

## 🔒 隐私与安全性

- **无隐私上传**：所有凭证和配额数据仅保存在本地设备，不经过任何第三方服务器。
- **本地存储位置**：
  - 账号凭据：`~/.config/omarchy/antigravity-accounts.json`（文件权限设为 `0600`，仅当前用户可读写）。
  - 配额缓存：`~/.cache/omarchy/agent-usage/antigravity-multi-quota.json`。
  - 系统代理状态：`~/.local/state/omarchy/agents/usage/antigravity.json`。

---

## 📄 License

[MIT](LICENSE)

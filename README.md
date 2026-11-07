# dsh-multi-window

把任意 DSH 会话放进**独立的原生窗口**，同时看多个会话。

> English: [README.en.md](./README.en.md)

## 这是什么

DSH 桌面壳只管理一个主窗口。本插件在会话右键菜单里加一项「在独立窗口中打开」，
点击后由 Host 进程启动一个独立的 Electron 窗口，窗口里加载的仍是**同一个 Web UI**，
只是通过 URL 的 `#dsh-window=<会话 id>` 直接定位到你点的那条会话。

独立窗口有自己的进程和独立的浏览器配置目录，关掉它不影响主窗口，反之亦然。

## 特性

- 窗口里是**完整可交互的 DSH 界面**：左侧栏、插件、技能、自动化任务、上下文洞察，
  所有按钮齐全，零裁剪 —— 它加载的就是同一个 Web 前端。
- **窗口标题 = 会话标题**：客户端从 `sessions.list` 取 `displayTitle`，经 URL hash 的
  `title` 参数传给窗口；页面自己改标题会被 `page-title-updated` 挡回去。
- **多窗口自动错开**：按 sessionId 做 FNV-1a 哈希，落到 6×6 档、每档 40px，并夹在屏内。
- **每个窗口独立 `--user-data-dir`**，localStorage、登录态、滚动位置互不干扰。
- 同一会话重复点击不会开第二个窗口，而是把已有窗口提到前面。
- 窗口内点开的外链交给系统默认浏览器。

### 定位不是「打开时设一次」

新窗口没有自己的本地选中记录，启动时的 boot 导航可能把选中态覆盖回默认会话。
客户端做的是**有界校正**：8 秒内每 300ms 复查一次，看到目标会话连续保持 3 秒即停止；
一旦在窗口里点击或按键就立刻让位，之后不再抢回。
对应 `lib/client.js` 的 `CORRECT_DEADLINE_MS` / `CORRECT_INTERVAL_MS` / `CORRECT_HOLD_MS`。

## 安装

要求：**Windows 桌面客户端**（Windows 10 / 11）、**DSH 桌面客户端 0.2.1-rc.5 及以上**、
Node.js 20+（DSH 自带，无需单独安装）。

### 方式 A：插件市场（推荐）

在 DSH 插件市场里搜索 `dsh-multi-window`，一键安装。

### 方式 B：命令行

```powershell
dsh plugin add dsh-multi-window
```

若 `dsh` 命令不可用，包内的 `scripts/install.ps1` 会退回为直接改 profile 的
`package.json` 并建 junction：

```powershell
.\scripts\install.ps1                 # 装到 desktop profile
.\scripts\install.ps1 -DryRun         # 只打印计划，不改任何东西
```

脚本不写死任何路径：DSH 命令优先取 `DSH_CLI`，其次 PATH；DSH 数据目录优先取
`DSH_HOME`，其次 `%USERPROFILE%\.dsh`，都可以用 `-Profile` / `-DshHome` 覆盖。

**安装后重启 DSH 桌面应用**，插件才会被加载。

> 插件靠 `process.execPath` 指向 DSH 安装目录来定位 Electron 载荷，因此
> **命令行 `dsh web` 模式不适用**——那个模式下进程不是桌面客户端，没有可链接的载荷。

### 窗口运行时：不需要预生成

本包**不含任何二进制**，也不需要构建步骤。DSH 的 Host 进程本身就跑在
`ELECTRON_RUN_AS_NODE=1 <应用 exe>` 下，所以 `dirname(process.execPath)` 已经是完整的
Electron 载荷。第一次开窗时，插件把它硬链接到系统临时目录：

```
%TEMP%\dsh-multi-window-runtime\
  dsh-window.exe          <- 硬链接到 DSH 的 exe
  *.pak *.dll *.dat ...   <- 硬链接到同一份载荷
  locales\                <- junction
  resources\app\main.js   <- 由本包的 lib/window-main.js 写出
```

所以包只有几十 KB，换任何机器都能用，磁盘上也不额外占空间（硬链接不复制数据）。
若某个文件系统或安全策略拒绝硬链接，会退化为复制，窗口照常工作。

## 卸载

```powershell
dsh plugin remove dsh-multi-window
# 或
.\scripts\uninstall.ps1                    # 只卸插件
.\scripts\uninstall.ps1 -RemoveRuntime     # 顺带删 %TEMP%\dsh-multi-window-runtime
.\scripts\uninstall.ps1 -RemoveProfiles    # 顺带删 %TEMP%\dsh-multi-window（每个会话一个子目录）
```

运行时与临时配置**默认保留**：运行时可以重建，但每次都值得复用。

## 验证

1. 重启 DSH，设置 → 插件列表里应能看到 `dsh-multi-window`。
2. 右键任意会话，菜单里应出现「在独立窗口中打开」。
3. 点击后弹出独立窗口，标题栏是那条会话的标题，窗口内就是那条会话。
4. 再开另一条会话，两个窗口位置应错开、标题各不相同。
5. 关掉独立窗口，主窗口不受影响。

命令行直接验证后端接口（token 从主窗口地址栏复制）：

```powershell
curl.exe "http://127.0.0.1:<port>/api/multi-window.open?session=<sessionId>&title=<标题>&token=<token>"
# 成功: {"url":"...", "session":"...", "pid":1234, "focused":false}
# 同一会话再请求一次: {"...", "focused":true}（把已有窗口提到前面）
```

## 实现原理

1. **Node 半**（`lib/index.js`）注册 `GET /api/multi-window.open`：校验参数、用
   `connection.authenticatedUrl()` 生成带 token 的本机 URL、把 `dsh-window` 和 `title`
   写进 hash、确保运行时存在、`spawn` 侧车进程，返回 `{url, session, pid, focused}`。
   `spawn` 时带 `--no-sandbox --user-data-dir=<profile>`，并删掉继承来的
   `ELECTRON_RUN_AS_NODE`（原因见故障排查）。
2. **侧车**（`lib/window-main.js`，运行时被写成 `resources\app\main.js`）是极简 Electron
   主进程：解析 URL、按 hash 设标题、按哈希算位置、构建菜单、跟随页面主题，然后加载 URL。
3. **客户端**（`lib/client.js`）在会话右键菜单加一项，点击时请求上面的接口；
   新窗口按 hash 里的 `dsh-window` 做有界校正，把自己切到该会话。

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 窗口一闪就退出 | 侧车必须带 `--no-sandbox`，且父进程的 `ELECTRON_RUN_AS_NODE` 必须删掉。Host 自身跑在该变量下，子进程会继承它并以 Node 模式启动。`spawnWindow` 已处理；手工起 exe 时也要照做。**这是宿主环境约束，不是可选项** |
| 503 `the window runtime is unavailable` | 运行时没建起来。看返回里的 `hint`；通常是临时目录不可写，或 `DSH_MULTI_WINDOW_EXE` 指向了不存在的文件 |
| 窗口起来但一片空白 | 侧车连不上 Host。确认返回里的 `pid` 还在，且主窗口能用同一台机器访问 |
| 窗口标题是 `DSH Window` | URL hash 里没有 `title`（会话还没有标题）。窗口随后被页面标题覆盖，关掉重开即可 |
| 窗口都叠在屏幕中间附近 | 位置按 sessionId 哈希错开，只有 36 档；撞档时拖动一下即可 |
| 主程序升级后窗口样式对不上 | 运行时是**硬链接**，跟着主程序走，一般不用动。若主程序换了安装目录，删掉 `%TEMP%\dsh-multi-window-runtime` 重开窗口即可重建 |
| 想用别处的运行时 | 设 `DSH_MULTI_WINDOW_EXE` 指向任意 Electron exe，优先级最高 |

## 已知限制

- **空白会话**打开后停在「探索未至之境」欢迎页，这是 DSH 对空会话的正确渲染，不是定位失败。
- 窗口默认 **1280×820，最小 520×600**；多显示器下按**主屏**定位。
- 重启 DSH 后 token 会重新生成，**已开着的旧窗口需要关掉重开**。
- 「同一窗口内并排多个对话」尚未实现。

## 发布到 npm

源码仓库：[github.com/JohnshyCY/dsh-multi-window](https://github.com/JohnshyCY/dsh-multi-window)。

```powershell
npm publish
```

## 许可证

[MIT](./LICENSE)

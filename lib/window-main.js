// DSH 独立窗口外壳。
//
// 这是一个只做一件事的 Electron 主进程：把已认证的 DSH 页面装进一个原生窗口。
// 页面里的所有元素、按钮、交互都由 DSH 前端自己提供，本文件不做任何裁剪或改写。
//
// 用法：dsh-window.exe --user-data-dir=<per-window profile> "http://127.0.0.1:<port>/?token=<...>#dsh-window=<id>&title=<标题>"
// 首次导航带 token，Host 回 303 并把会话 cookie 种进本窗口自己的 Chromium 分区，
// 之后的 HTTP 与 WebSocket 都靠这份 cookie 自动鉴权。
//
// 窗口标题取 hash 里的 title（没有就沿用页面标题）；多个窗口按会话 id 哈希错开位置；
// 菜单栏、标题栏、底色都跟随页面自己的深浅色（DSH 主题运行时贴在 body 上），不跟操作系统。
const WINDOW_WIDTH = 1280;
const WINDOW_HEIGHT = 820;
const MIN_WIDTH = 520;
const MIN_HEIGHT = 600;
const STAGGER_STEP = 40;
const STAGGER_SLOTS = 6;
const DEFAULT_TITLE = "DSH Window";
// DSH 深色的 --dsw-static-neutral-bluish-950 / --dsw-alias-bg-base 就是 #151517。
// 建窗时先按它铺底（用户多数开的是深色），页面加载完再由页面真实状态纠正。
const DARK_BACKGROUND = "#151517";
const LIGHT_BACKGROUND = "#ffffff";
// 主题是异步 adopt 的，可能晚于 did-finish-load，所以加载完成后再补几次探测；
// 不提前停：boot restore 也要过一会儿才把 body 上的属性定下来。
const THEME_PROBE_DELAYS = [500, 1500, 3000];
// 补完上面几次之后，可能还有更晚的 adopt：用低频轮询兜底，连读两次不变就停。
const THEME_POLL_INTERVAL_MS = 2000;
const THEME_POLL_MAX_TICKS = 5;
const THEME_POLL_STABLE_TICKS = 2;

// 菜单栏：设了 nativeTheme.themeSource 之后，Windows 标题栏确认会变深（已实测），
// 菜单栏走的是同一套原生主题，预期一起变深，所以保持常显（Alt 之外随时可见）。
// 万一某个 Electron 构建的菜单栏不吃 themeSource、仍是白条，把它改成 true 走退路：
// 菜单默认隐藏，按 Alt 呼出；呼出时是浮层，不占标题栏高度。
const HIDE_MENU_BAR = false;

// ---------------------------------------------------------------- 纯函数（可脱离 Electron 单测）

// 在命令行里找第一个 http(s) 参数；参数顺序不固定，--no-sandbox 等开关会被跳过。
function parseWindowTarget(argv) {
  const list = Array.isArray(argv) ? argv : [];
  for (const value of list) {
    if (typeof value !== "string") continue;
    if (!value.startsWith("http://") && !value.startsWith("https://")) continue;
    try {
      return new URL(value);
    } catch {
      // 形态像 URL 但解析不了，继续找下一个
    }
  }
  return undefined;
}

// URL 的 hash 就是 Host 拼出来的一串 URLSearchParams：#dsh-window=<id>&title=<标题>
function anchorParams(target) {
  if (target === undefined || target === null) return new URLSearchParams();
  const hash = target.hash.startsWith("#") ? target.hash.slice(1) : target.hash;
  return new URLSearchParams(hash);
}

function anchorValue(target, name) {
  const value = anchorParams(target).get(name);
  if (value === null) return undefined;
  const text = value.trim();
  return text === "" ? undefined : text;
}

// 会话 id：决定窗口位置错开的种子，也用来核对窗口身份。
function sessionOf(target) {
  return anchorValue(target, "dsh-window");
}

// 会话标题：有就固定成窗口标题，没有就沿用页面自己的标题。
function titleOf(target) {
  return anchorValue(target, "title");
}

// FNV-1a，稳定且与进程无关：同一会话每次开窗落在同一档。
function hashOf(seed) {
  let hash = 2166136261;
  for (const character of String(seed)) {
    hash ^= character.codePointAt(0);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash >>> 0;
}

// 哈希的两个不同位段分别出 x/y 偏移，凑成 6x6 的错开格位（36 档），
// 比单用 (n % 6) 的对角线排列更不容易让两个窗口正好叠死。
function offsetFor(seed) {
  const hash = hashOf(seed);
  return {
    x: (hash % STAGGER_SLOTS) * STAGGER_STEP,
    y: (Math.floor(hash / STAGGER_SLOTS) % STAGGER_SLOTS) * STAGGER_STEP,
  };
}

// 以工作区中心为基准，按哈希错开（每档 40px），并夹在工作区内不跑出屏幕。
function positionFor(workArea, seed) {
  const offset = offsetFor(seed);
  const baseX = workArea.x + Math.round((workArea.width - WINDOW_WIDTH) / 2) - STAGGER_STEP;
  const baseY = workArea.y + Math.round((workArea.height - WINDOW_HEIGHT) / 2) - STAGGER_STEP;
  const maxX = workArea.x + Math.max(0, workArea.width - WINDOW_WIDTH);
  const maxY = workArea.y + Math.max(0, workArea.height - WINDOW_HEIGHT);
  return {
    x: Math.round(Math.min(Math.max(baseX + offset.x, workArea.x), maxX)),
    y: Math.round(Math.min(Math.max(baseY + offset.y, workArea.y), maxY)),
  };
}

// ---------------------------------------------------------------- 主进程

// 显式给一份最小可用菜单。
// 用 role 拿行为（重新加载、缩放、最小化、关闭…），label 自己写中文，
// 不依赖 Electron 默认菜单是否存在——Windows 上默认菜单并不是每个构建都有。
const MENU_TEMPLATE = [
  {
    label: "文件",
    submenu: [
      { label: "关闭窗口", role: "close" },
      { type: "separator" },
      { label: "退出", role: "quit" },
    ],
  },
  {
    label: "编辑",
    submenu: [
      { label: "撤销", role: "undo" },
      { label: "重做", role: "redo" },
      { type: "separator" },
      { label: "剪切", role: "cut" },
      { label: "复制", role: "copy" },
      { label: "粘贴", role: "paste" },
      { label: "全选", role: "selectAll" },
    ],
  },
  {
    label: "视图",
    submenu: [
      { label: "重新加载", role: "reload" },
      { label: "强制重新加载", role: "forceReload" },
      { label: "开发者工具", role: "toggleDevTools" },
      { type: "separator" },
      { label: "实际大小", role: "resetZoom" },
      { label: "放大", role: "zoomIn" },
      { label: "缩小", role: "zoomOut" },
      { type: "separator" },
      { label: "全屏", role: "togglefullscreen" },
    ],
  },
  {
    label: "窗口",
    submenu: [
      { label: "最小化", role: "minimize" },
      { label: "关闭", role: "close" },
    ],
  },
];

function applyMenu(Menu, window) {
  try {
    Menu.setApplicationMenu(Menu.buildFromTemplate(MENU_TEMPLATE));
  } catch (error) {
    // 菜单失败不该挡住开窗。
    console.error("dsh-window: cannot build the menu", error);
  }
  if (HIDE_MENU_BAR && window !== undefined && !window.isDestroyed()) {
    window.setAutoHideMenuBar(true);
    window.setMenuBarVisibility(false);
  }
}

// 读页面自己的主题状态，据此设置原生外框（标题栏、菜单栏）和未绘制区域的底色。
//
// 为什么不能直接用 nativeTheme.shouldUseDarkColors：它跟的是操作系统主题，而 DSH 的
// ui-theme 可以强制深色（desktop profile 就是 preference: dark）。用户系统是浅色时，
// 页面是深色、外框却是白的，正是这个错位。
//
// 注入的探测器返回页面当前是不是深色；页面还没 ready 时 executeJavaScript 会抛，
// 交给下一次探测。
const DARK_PROBE = "document.body.hasAttribute('data-ds-dark-theme')";

async function readPageDark(window) {
  try {
    const dark = await window.webContents.executeJavaScript(DARK_PROBE, true);
    return dark === true;
  } catch {
    // 页面还没准备好，或是导航中被销毁：这次不算数，留给下一次探测。
    return undefined;
  }
}

// 把"页面是深色"落到原生层。themeSource 会连带决定 Windows 标题栏与菜单栏的明暗。
// 注意不要再用 shouldUseDarkColors 判断：themeSource 一设，它也跟着变，就是拿自己的
// 输出当输入的回环。
function applyPageTheme(window, nativeTheme, dark) {
  if (window.isDestroyed()) return;
  nativeTheme.themeSource = dark ? "dark" : "light";
  window.setBackgroundColor(dark ? DARK_BACKGROUND : LIGHT_BACKGROUND);
}

// 主题是异步 adopt 的，可能晚于 did-finish-load，所以：加载完成后先探一次，
// 再按 THEME_PROBE_DELAYS 补几次；之后用有界轮询兜住更晚的 adopt —— 轮询连读两次
// 都是同一状态就收工，最多 THEME_POLL_MAX_TICKS 次。
// 返回一个清理函数，窗口关闭时调用，避免定时器留在已销毁的窗口上。
function watchPageTheme(window, nativeTheme) {
  const timers = [];
  let poller;
  let lastDark;

  const probe = async () => {
    if (window.isDestroyed()) return undefined;
    const dark = await readPageDark(window);
    if (dark === undefined) return undefined;
    if (dark !== lastDark) {
      lastDark = dark;
      applyPageTheme(window, nativeTheme, dark);
    }
    return dark;
  };

  const stopPolling = () => {
    if (poller === undefined) return;
    clearInterval(poller);
    poller = undefined;
  };

  const startPolling = () => {
    if (poller !== undefined || window.isDestroyed()) return;
    let last = lastDark;
    let stable = 0;
    let ticks = 0;
    poller = setInterval(async () => {
      ticks += 1;
      const dark = await probe();
      if (dark !== undefined && dark === last) {
        stable += 1;
        if (stable >= THEME_POLL_STABLE_TICKS) stopPolling();
      } else if (dark !== undefined) {
        last = dark;
        stable = 0;
      }
      if (ticks >= THEME_POLL_MAX_TICKS) stopPolling();
    }, THEME_POLL_INTERVAL_MS);
  };

  window.webContents.on("did-finish-load", () => {
    lastDark = undefined;
    stopPolling();
    for (const timer of timers) clearTimeout(timer);
    timers.length = 0;
    probe();
    for (const delay of THEME_PROBE_DELAYS) {
      timers.push(setTimeout(probe, delay));
    }
    startPolling();
  });

  return () => {
    for (const timer of timers) clearTimeout(timer);
    timers.length = 0;
    stopPolling();
  };
}

function start() {
  const { app, BrowserWindow, Menu, nativeTheme, screen, shell } = require("electron");

  // 独立的应用名，避免与主安装共用同一份 userData / 单实例锁。
  app.setName("DSH Window");

  // 单实例锁按 user-data-dir 生效：每个会话有自己的 profile 目录，所以不同会话
  // 各自拿到锁、各开一个窗口；同一会话再点一次时，新进程把参数交给已有实例后退出。
  // 拿到锁的是「已有窗口」那一个，requestSingleInstanceLock() 返回 false 的直接退场。
  const primary = app.requestSingleInstanceLock();
  if (!primary) {
    app.quit();
    return;
  }

  let currentWindow;
  let focusWhenReady = false;

  app.on("second-instance", () => {
    // 启动竞态：新进程的参数可能在窗口建好之前就送到，这里不能假定 currentWindow 存在。
    if (currentWindow === undefined || currentWindow.isDestroyed()) {
      focusWhenReady = true;
      return;
    }
    if (currentWindow.isMinimized()) currentWindow.restore();
    if (!currentWindow.isVisible()) currentWindow.show();
    currentWindow.focus();
  });

  const target = parseWindowTarget(process.argv.slice(1));

  function createWindow(url) {
    const customTitle = titleOf(url);
    // 优先用会话 id：同一会话重复开窗位置一致，不同会话必然错开。没有会话 id 时退回进程 pid。
    const seed = sessionOf(url) || "pid:" + process.pid;

    const window = new BrowserWindow({
      width: WINDOW_WIDTH,
      height: WINDOW_HEIGHT,
      minWidth: MIN_WIDTH,
      minHeight: MIN_HEIGHT,
      show: false,
      title: customTitle || DEFAULT_TITLE,
      // 先铺深色底：多数用户开的是深色主题，避免加载期白闪；页面加载完由实际状态纠正。
      backgroundColor: DARK_BACKGROUND,
      // 不加 autoHideMenuBar：菜单栏常显，用户有重新加载、缩放、最小化、关闭这些基础手段。
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        sandbox: true,
        webSecurity: true,
      },
    });

    // 位置错开：窗口尚未 show，这里设置不会被看到移动。
    const point = positionFor(screen.getPrimaryDisplay().workArea, seed);
    window.setPosition(point.x, point.y);

    currentWindow = window;
    window.on("closed", () => {
      if (currentWindow === window) currentWindow = undefined;
    });

    // 会话标题优先：页面自己改 document.title 时拦下来，不让它覆盖我们设的标题。
    // 没有 title 参数时不注册这个监听，页面标题照常生效。
    if (customTitle !== undefined) {
      window.setTitle(customTitle);
      window.webContents.on("page-title-updated", (event) => {
        event.preventDefault();
        if (!window.isDestroyed()) window.setTitle(customTitle);
      });
    }

    // 原生外框（标题栏、菜单栏）和底色跟随页面主题，不跟随操作系统。
    const stopWatchingTheme = watchPageTheme(window, nativeTheme);
    window.on("closed", stopWatchingTheme);

    // 页面内真正的 http(s) 新窗口请求交给系统浏览器，与本窗口无关。
    window.webContents.setWindowOpenHandler(({ url: requested }) => {
      try {
        if (["http:", "https:"].includes(new URL(requested).protocol)) shell.openExternal(requested);
      } catch {}
      return { action: "deny" };
    });

    applyMenu(Menu, window);

    window.once("ready-to-show", () => {
      window.show();
      // 窗口建好之前就收到过聚焦请求的话，补上一次。
      if (focusWhenReady) {
        focusWhenReady = false;
        if (!window.isDestroyed()) window.focus();
      }
    });
    window.loadURL(url.href).catch((error) => {
      console.error("dsh-window: cannot load", url.href, error);
    });
  }

  if (target === undefined) {
    console.error("dsh-window: no http(s) URL given");
    app.whenReady().then(() => app.quit());
    return;
  }

  app.whenReady().then(() => {
    createWindow(target);
  });
  app.on("window-all-closed", () => app.quit());
}

module.exports = {
  parseWindowTarget,
  anchorParams,
  sessionOf,
  titleOf,
  hashOf,
  offsetFor,
  positionFor,
  readPageDark,
  watchPageTheme,
};

// 单测用 `DSH_WINDOW_SELFTEST=1` 载入本文件，只测纯函数，不碰 Electron。
if (process.env.DSH_WINDOW_SELFTEST !== "1") start();

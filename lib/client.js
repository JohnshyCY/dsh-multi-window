window.__ModuleLoader__.load({
  id: "dsh-multi-window",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    let react = require("react");
    let react_jsx_runtime = require("react/jsx-runtime");
    let primitives = require("@deepseek-ai/dsh-client-ui-primitives");
    /** Dictionary namespace owned by this plugin. */
    const NS = "multi-window";
    /** The Chinese dictionary is the key-set source of truth; English mirrors it. */
    const zh = {
      "menu.openInWindow": "在独立窗口中打开",
      "toast.openFailed": "无法打开独立窗口，请稍后再试"
    };
    const en = {
      "menu.openInWindow": "Open in new window",
      "toast.openFailed": "Could not open the window. Try again."
    };
    /** Exact Fetch route the Node half serves to raise one window. */
    const OPEN_ROUTE = "/api/multi-window.open";
    /** URL hash key carrying the Session a window was opened for. */
    const ANCHOR_KEY = "dsh-window";
    /** How long one window keeps correcting a selection its own boot navigation overwrote. */
    const CORRECT_DEADLINE_MS = 8e3;
    /** Spacing between those corrections. */
    const CORRECT_INTERVAL_MS = 300;
    /**
     * How long the anchored Session must stay selected before correcting stops.
     *
     * Boot restore awaits Workspace initialization and Session connection, so its
     * overwrite can land well after this window's first switch; stopping at the
     * first match would hand the window straight back to it.
     */
    const CORRECT_HOLD_MS = 3e3;
    /** Current failure notice, or null when the last gesture succeeded or was dismissed. */
    let failure = null;
    let failureSeq = 0;
    const failureListeners = new Set();
    function publishFailure(notice) {
      failure = notice;
      for (const listener of failureListeners) listener();
    }
    function subscribeFailure(listener) {
      failureListeners.add(listener);
      return () => {
        failureListeners.delete(listener);
      };
    }
    function readFailure() {
      return failure;
    }
    /**
     * Show one failed window gesture above the whole shell.
     *
     * The Workspace notice channel renders only the notice kinds its own plugin
     * declares, so a kind owned by this plugin would be dropped without a
     * recipe — the banner is therefore owned here, as the other per-control
     * failure banners in this app are.
     */
    function FailureToast() {
      const notice = react.useSyncExternalStore(subscribeFailure, readFailure);
      if (notice === null) return null;
      return react_jsx_runtime.jsx(primitives.Toast, {
        text: notice.text,
        icon: react_jsx_runtime.jsx(primitives.IconWarningOutlineRegular, {}),
        holdMs: 6e3,
        onDone: () => publishFailure(null)
      }, notice.seq);
    }
    /** The Session id this window was opened for, or undefined for a plain window. */
    function anchoredSessionId() {
      return new URLSearchParams(location.hash.slice(1)).get(ANCHOR_KEY) ?? void 0;
    }
    /**
     * Select the anchored Session, and keep it selected while this window boots.
     *
     * The main view retains Sessions and retaining an id the list has not pulled
     * yet throws, so the first `ready` snapshot holding the id is the first legal
     * moment to navigate. An id the Host never lists — the Session was deleted
     * while the window loaded — is dropped without a dialog.
     *
     * Selecting once is not enough. A window raised by the row action carries no
     * stored selection, so boot navigation restores a default Workspace Session
     * *after* this window's first switch and overwrites it; the correction
     * therefore repeats while the anchored id is not selected. It stops as soon
     * as the target has held for CORRECT_HOLD_MS, on the first real user gesture
     * — a deliberate switch must never be taken back — and at
     * CORRECT_DEADLINE_MS regardless, so a window that can never hold the target
     * gives up quietly instead of fighting forever.
     */
    function followAnchor(ctx, sessionId) {
      const sessions = ctx.get("sessions");
      const workspace = ctx.get("uiWorkspace");
      let unsubList;
      let unsubSelection;
      let timer;
      let done = false;
      /** The list has surfaced the id, so switching to it is legal now. */
      let armed = false;
      /** When the anchored id last became the selection, if it currently is. */
      let stableSince;
      let startedAt = 0;
      let running = false;
      const release = () => {
        if (timer !== void 0) clearTimeout(timer);
        timer = void 0;
        unsubList?.();
        unsubList = void 0;
        unsubSelection?.();
        unsubSelection = void 0;
      };
      const finish = () => {
        if (done) return;
        done = true;
        release();
      };
      const schedule = () => {
        if (done) return;
        if (timer !== void 0) clearTimeout(timer);
        timer = setTimeout(step, CORRECT_INTERVAL_MS);
      };
      const selected = () => workspace.selection.getSnapshot().sessionId === sessionId;
      const step = () => {
        if (done || running || !armed) return;
        running = true;
        try {
          const now = Date.now();
          if (selected()) {
            if (stableSince === void 0) stableSince = now;
            // A match that has held long enough is settled; the deadline also
            // ends it, so a window never corrects for longer than its budget.
            if (now - stableSince >= CORRECT_HOLD_MS || now - startedAt >= CORRECT_DEADLINE_MS) {
              finish();
              return;
            }
          } else {
            stableSince = void 0;
            if (now - startedAt >= CORRECT_DEADLINE_MS) {
              console.warn(`multi-window: could not hold session ${sessionId} selected`);
              finish();
              return;
            }
            workspace.openSession(sessionId);
          }
        } catch (error) {
          console.warn(`multi-window: cannot open session ${sessionId}`, error);
          finish();
          return;
        } finally {
          running = false;
        }
        schedule();
      };
      const arm = () => {
        if (done || armed) return;
        const list = sessions.list.getSnapshot();
        if (list.phase !== "ready") return;
        if (list.byId[sessionId] === void 0) {
          console.warn(`multi-window: unknown session ${sessionId}`);
          finish();
          return;
        }
        armed = true;
        startedAt = Date.now();
        // The list gate is done; from here the selection is what has to be watched.
        unsubList?.();
        unsubList = void 0;
        step();
      };
      // A boot overwrite is one `selection.set`, so react to it instead of waiting
      // for the next tick; `running` keeps the switch made from inside `step` from
      // re-entering it.
      unsubSelection = workspace.selection.subscribe(() => {
        if (armed && !selected()) step();
      });
      unsubList = sessions.list.subscribe(arm);
      // A store may call back before handing back its disposer, in which case the
      // release inside `arm` ran too early; this settles the subscription either way.
      if (armed) {
        unsubList();
        unsubList = void 0;
      }
      arm();
      // This window is born unfocused on a restored Session, so any press or key
      // here is the reader choosing something themselves: correcting must stop at
      // once rather than drag them back.
      const yieldToReader = () => finish();
      if (typeof document !== "undefined") {
        document.addEventListener("pointerdown", yieldToReader, { capture: true, once: true });
        document.addEventListener("keydown", yieldToReader, { capture: true, once: true });
      }
      return () => {
        release();
        if (typeof document !== "undefined") {
          document.removeEventListener("pointerdown", yieldToReader, { capture: true });
          document.removeEventListener("keydown", yieldToReader, { capture: true });
        }
      };
    }
    /** Required services: the slot registry, dictionaries, navigation, Session state. */
    const inject = ["slots", "locale", "uiWorkspace", "sessions"];
    /** Menu row (order 500): open the row's Session in its own window. */
    function OpenInWindowMenuItem(props) {
      const { sessionId, useMenuOpenState, openInWindow, t } = props;
      const [, setMenuOpen] = useMenuOpenState();
      return react_jsx_runtime.jsx(primitives.MenuItemButton, {
        icon: react_jsx_runtime.jsx(primitives.IconRightUpOutlineRegular, {}),
        onSelect: () => {
          setMenuOpen(false);
          void openInWindow(sessionId);
        },
        children: t("menu.openInWindow")
      });
    }
    /**
     * Client plugin body: dictionaries, the Session row action, its failure
     * banner, and — in a window raised by that action — the Session the window
     * was raised for. Such a window is an ordinary second window of the same
     * app: same chrome, same controls, only starting on a different Session.
     */
    function apply(ctx) {
      ctx.effect(() => ctx.locale.register(NS, { zh, en }), "multi-window: dictionaries");
      const t = ctx.locale.bind(NS);
      /**
       * Ask the Node half for a window showing one Session.
       *
       * The Node half owns the window: it resolves this Host's authenticated URL
       * and starts a separate window process on it, so nothing here depends on
       * the browser's popup rules. The title rides along so the window can name
       * itself before its Session list has loaded.
       */
      const openInWindow = async (sessionId) => {
        const query = new URLSearchParams({ session: sessionId });
        const title = ctx.get("sessions").list.getSnapshot().byId[sessionId]?.displayTitle;
        if (typeof title === "string" && title !== "") query.set("title", title);
        try {
          const response = await fetch(`${OPEN_ROUTE}?${query}`);
          if (!response.ok) {
            const body = await response.json().catch(() => ({}));
            throw new Error(body.error ?? `multi-window: open route failed (${response.status})`);
          }
        } catch (error) {
          console.error("multi-window: cannot open the window", error);
          publishFailure({ text: t("toast.openFailed"), seq: ++failureSeq });
        }
      };
      ctx.slots.inject("shell.overlay", () => ctx.slots.register({
        name: "shell.overlay",
        id: "multi-window.failure-toast",
        inject: () => ({})
      }, FailureToast));
      ctx.slots.inject("sidebar.workspaces.session.menu.item", () => ctx.slots.register({
        name: "sidebar.workspaces.session.menu.item",
        id: "open-window",
        order: 500,
        locale: NS,
        inject: () => ({ openInWindow })
      }, OpenInWindowMenuItem));
      const anchored = anchoredSessionId();
      if (anchored !== void 0) {
        ctx.effect(() => followAnchor(ctx, anchored), "multi-window: anchored session");
      }
    }
    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  }
});

//# sourceMappingURL=client.js.map

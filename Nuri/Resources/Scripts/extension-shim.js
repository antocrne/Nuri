// Chrome extensions in WebKit: what they need that Chrome gives and WebKit doesn't. Nuri loads
// this file first in each of an extension's contexts — background script, extension pages,
// content scripts (ExtensionFiles.addShims).
(() => {
  const done = Symbol.for("nuri.extension-shim");
  if (globalThis[done]) return;
  globalThis[done] = true;

  const native = globalThis.browser || globalThis.chrome;
  if (!native || !native.runtime) return;

  // requestIdleCallback: in Chrome and Firefox, not in WebKit. Proton Pass detects login forms
  // from it: without it, no icon or dropdown in the fields.
  if (typeof globalThis.requestIdleCallback !== "function") {
    globalThis.requestIdleCallback = (callback) => {
      const start = Date.now();
      return setTimeout(() => callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) }), 1);
    };
    globalThis.cancelIdleCallback = (id) => clearTimeout(id);
  }

  // WebKit finds the context to send an event to (a message, a port, onStartup…) through its
  // `browser` / `chrome` globals. Some extensions replace them once started, to hide the API from
  // other scripts (Proton Pass puts a Proxy that answers nothing in their place): in Chrome that
  // changes nothing, in WebKit the extension then never hears anything again. So they stay
  // WebKit's objects; a replacement is ignored (the extension keeps its own references).
  // It also holds the objects: WebKit's wrappers that nobody holds can be collected and rebuilt,
  // losing what is added to them below.
  for (const name of ["browser", "chrome"]) {
    const value = globalThis[name];
    if (!value) continue;
    try {
      Object.defineProperty(globalThis, name, { get: () => value, set: () => {}, configurable: true, enumerable: true });
    } catch {}
  }
  const runtime = native.runtime;
  try {
    Object.defineProperty(native, "runtime", { value: runtime, configurable: true, writable: true, enumerable: true });
  } catch {}

  // chrome.storage: Chrome runs an area's calls in the order they were made, so a get right after
  // a set nobody waited for sees the new value. WebKit doesn't (never, in 20 tries on 2026-11-02),
  // and Proton VPN, which checks its service that way when it starts, then says the network blocks
  // it. Each area's calls wait here for the one before.
  const areas = native.storage;
  if (areas) {
    for (const name of ["local", "session", "sync"]) {
      const area = areas[name];
      if (!area) continue;
      try {
        Object.defineProperty(areas, name, { value: area, configurable: true, writable: true, enumerable: true });
      } catch {}
      let last = Promise.resolve();
      for (const method of ["get", "getKeys", "getBytesInUse", "set", "remove", "clear", "setAccessLevel"]) {
        if (typeof area[method] !== "function") continue;
        const original = area[method].bind(area);
        const ordered = (...args) => {
          const callback = typeof args[args.length - 1] === "function" ? args.pop() : undefined;
          const run = last.then(() => original(...args));
          // A call WebKit never answered doesn't hold the next ones for more than 3 s.
          last = Promise.race([run.catch(() => {}), new Promise((done) => setTimeout(done, 3000))]);
          if (!callback) return run;
          run.then((value) => callback(value), () => callback());
        };
        try {
          Object.defineProperty(area, method, { value: ordered, configurable: true, writable: true, enumerable: true });
        } catch {}
      }
    }
  }

  // Content scripts run in web pages: the rest is for the extension's own contexts.
  if (globalThis.location && globalThis.location.protocol !== "webkit-extension:") return;

  // WebKit's user agent names no browser in an extension's contexts, and packages made for Chrome
  // read the browser from it (Bitwarden gets no device type, and its whole background stops).
  try {
    if (!/ (Chrome|Safari)\//.test(navigator.userAgent)) {
      const agent = navigator.userAgent + " Chrome/140.0.0.0 Safari/537.36";
      Object.defineProperty(Object.getPrototypeOf(navigator), "userAgent", { get: () => agent, configurable: true });
    }
  } catch {}

  const inBackground = (typeof ServiceWorkerGlobalScope === "function" && globalThis instanceof ServiceWorkerGlobalScope)
    || (() => { try { return native.extension.getBackgroundPage() === globalThis; } catch { return false; } })();

  // Nuri's questions to the background, sent from a blank page of the extension's own: whether it
  // is there (ExtensionHost.backgroundAnswers; what WebKit tells of a service worker isn't
  // reliable), and for chrome.proxy below. Registered before the extension's own listeners: the
  // answer comes first. They never see the question, in any of its contexts, which some would
  // choke on (uBlock Origin Lite reads a field every message of its own has).
  const answers = { nuriPing: () => ({ nuriPong: true }) };
  {
    try {
      const question = (message) => (message && typeof message === "object" ? Object.keys(answers).find((key) => key in message) : undefined);
      const onMessage = runtime.onMessage;
      Object.defineProperty(runtime, "onMessage", { value: onMessage, configurable: true, writable: true, enumerable: true });
      const add = onMessage.addListener.bind(onMessage);
      const remove = onMessage.removeListener.bind(onMessage);
      const has = onMessage.hasListener.bind(onMessage);
      if (inBackground) {
        add((message, sender, sendResponse) => {
          const key = question(message);
          if (!key || !sender || sender.id !== runtime.id) return;
          const reply = answers[key](message[key]);
          if (!reply || typeof reply.then !== "function") return sendResponse(reply);
          reply.then(sendResponse, () => sendResponse(null));
          return true;
        });
      }
      const wrappers = new Map();
      const wrapper = (listener) => {
        if (!wrappers.has(listener)) wrappers.set(listener, (message, ...rest) => (question(message) ? undefined : listener(message, ...rest)));
        return wrappers.get(listener);
      };
      for (const [name, value] of [
        ["addListener", (listener) => add(wrapper(listener))],
        ["removeListener", (listener) => remove(wrapper(listener))],
        ["hasListener", (listener) => wrappers.has(listener) && has(wrappers.get(listener))],
      ]) Object.defineProperty(onMessage, name, { value, configurable: true, writable: true, enumerable: true });
    } catch {}
  }

  // Chrome APIs WebKit doesn't have, which extensions touch as soon as their background script
  // starts: one missing (chrome.runtime.onUpdateAvailable.addListener…) and the whole script
  // stops. Inert stand-ins, only where WebKit has nothing.
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (listener) => { listeners.add(listener); },
      removeListener: (listener) => { listeners.delete(listener); },
      hasListener: (listener) => listeners.has(listener),
      hasListeners: () => listeners.size > 0,
    };
  };
  const unsupported = (name) => () => Promise.reject(new Error(`${name} n'est pas pris en charge par Nuri`));
  // An answer for the promise and the callback styles of Chrome's APIs.
  const settle = (promise, callback) => {
    if (typeof callback !== "function") return promise;
    promise.then((value) => callback(value), () => callback());
  };
  const define = (target, name, make) => {
    if (!target || target[name] !== undefined) return;
    try {
      Object.defineProperty(target, name, { value: make(), configurable: true, writable: true, enumerable: true });
    } catch {}
  };

  for (const name of ["onUpdateAvailable", "onRestartRequired", "onBrowserUpdateAvailable", "onSuspend",
                      "onSuspendCanceled", "onMessageExternal", "onConnectExternal"]) {
    define(runtime, name, event);
  }
  define(runtime, "requestUpdateCheck", () => () => Promise.resolve({ status: "no_update" }));
  // tabs.getCurrent(): in Chrome, the tab showing this very page, and nothing in a popup. WebKit
  // gives a popup the tab it was opened over; extensions then take their popup for a page in a
  // tab (Proton Pass sizes it to 100% of the window, and WebKit, which sizes the popup to its
  // content, shrinks it to nothing).
  const tabs = native.tabs;
  if (tabs && typeof tabs.getCurrent === "function") {
    try {
      Object.defineProperty(native, "tabs", { value: tabs, configurable: true, writable: true, enumerable: true });
    } catch {}
    const getCurrent = tabs.getCurrent.bind(tabs);
    const page = (url) => String(url || "").split("#")[0];
    const current = () => getCurrent().then((tab) => (tab && page(tab.url) === page(location.href) ? tab : undefined));
    try {
      Object.defineProperty(tabs, "getCurrent", {
        value: (callback) => {
          if (typeof callback !== "function") return current();
          current().then(callback, () => callback(undefined));
        },
        configurable: true, writable: true, enumerable: true,
      });
    } catch {}
  }
  // webNavigation: WebKit has five of its events; the others never happen here. A missing one read
  // at start stops the whole background (1Password's onCreatedNavigationTarget).
  const navigation = native.webNavigation;
  if (navigation) {
    try {
      Object.defineProperty(native, "webNavigation", { value: navigation, configurable: true, writable: true, enumerable: true });
    } catch {}
    for (const name of ["onCreatedNavigationTarget", "onHistoryStateUpdated", "onReferenceFragmentUpdated", "onTabReplaced"]) {
      define(navigation, name, event);
    }
  }
  // Chrome answers « no » about a permission it can't give; WebKit throws, and Bitwarden's popup,
  // which asks while it draws, stays blank. « privacy » is granted: Nuri has no password manager of
  // its own for an extension to take over from, so that step of theirs is done from the start.
  // « proxy » too, when the manifest asks for it, as Chrome grants it at install: WebKit doesn't
  // know it, and Proton VPN stops at its « Allow VPN permissions » screen. Nuri asks the user when
  // the extension first sets a server (ExtensionProxy).
  // Sites: WebKit keeps only the http and https patterns of a manifest, and Chrome gives the
  // others at install too. A WebSocket goes with its site's http(s) access; ftp, which Chrome no
  // longer has either, with nothing.
  const granted = new Set(["privacy"]);
  if (((runtime.getManifest() || {}).permissions || []).includes("proxy")) granted.add("proxy");
  const asWebKit = (origins) => (origins || []).flatMap((origin) => {
    const scheme = String(origin).split(":")[0].toLowerCase();
    if (scheme === "ftp") return [];
    return [scheme === "ws" || scheme === "wss" ? String(origin).replace(/^ws/i, "http") : origin];
  });
  const permissions = native.permissions;
  if (permissions && typeof permissions.contains === "function") {
    try {
      Object.defineProperty(native, "permissions", { value: permissions, configurable: true, writable: true, enumerable: true });
    } catch {}
    for (const name of ["contains", "request"]) {
      const original = permissions[name].bind(permissions);
      const answer = (details) => new Promise((done) => {
        const others = ((details && details.permissions) || []).filter((permission) => !granted.has(permission));
        const origins = asWebKit(details && details.origins);
        done(others.length || origins.length ? original({ ...details, permissions: others, origins }) : true);
      }).catch(() => false);
      try {
        Object.defineProperty(permissions, name, {
          value: (details, callback) => settle(answer(details), callback),
          configurable: true, writable: true, enumerable: true,
        });
      } catch {}
    }
  }
  // What password managers look at when they start, and WebKit doesn't have.
  const scripting = native.scripting;
  if (scripting) {
    try {
      Object.defineProperty(native, "scripting", { value: scripting, configurable: true, writable: true, enumerable: true });
    } catch {}
    define(scripting, "ExecutionWorld", () => ({ ISOLATED: "ISOLATED", MAIN: "MAIN" }));
  }
  const storage = native.storage;
  if (storage) {
    try {
      Object.defineProperty(native, "storage", { value: storage, configurable: true, writable: true, enumerable: true });
    } catch {}
    // Settings a company's administrator pushes: none here.
    define(storage, "managed", () => ({
      onChanged: event(),
      get: (keys, callback) => settle(Promise.resolve({}), typeof keys === "function" ? keys : callback),
      getBytesInUse: (keys, callback) => settle(Promise.resolve(0), typeof keys === "function" ? keys : callback),
    }));
  }
  define(native, "idle", () => ({
    IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" },
    onStateChanged: event(),
    queryState: (interval, callback) => settle(Promise.resolve("active"), callback),
    setDetectionInterval: () => {},
    getAutoLockDelay: (callback) => settle(Promise.resolve(0), callback),
  }));
  define(native, "management", () => ({
    onEnabled: event(), onDisabled: event(), onInstalled: event(), onUninstalled: event(),
    getAll: (callback) => settle(Promise.resolve([]), callback),
    getSelf: (callback) => settle(Promise.resolve({ id: runtime.id, enabled: true, installType: "normal", ...runtime.getManifest() }), callback),
  }));
  // Browser settings an extension may ask to control (the browser's own password saving…): Nuri has
  // none of them, off from the start, as if the extension had just turned them off.
  const setting = () => ({
    onChange: event(),
    get: (details, callback) => settle(Promise.resolve({ value: false, levelOfControl: "controlled_by_this_extension" }), callback),
    set: (details, callback) => settle(Promise.resolve(), callback),
    clear: (details, callback) => settle(Promise.resolve(), callback),
  });
  const settings = () => new Proxy({}, { get: (target, name) => (target[name] ??= setting()) });
  define(native, "privacy", () => ({ network: settings(), services: settings(), websites: settings() }));
  define(native, "downloads", () => ({
    onCreated: event(), onChanged: event(), onErased: event(), onDeterminingFilename: event(),
    download: unsupported("chrome.downloads"),
    search: (query, callback) => settle(Promise.resolve([]), callback),
    setUiOptions: (options, callback) => settle(Promise.resolve(), callback),
  }));
  // Tab groups: Nuri has none. Their constants are read as soon as some extensions start (Claude
  // lists the group colors at load); every tab is outside any group, grouping is refused.
  if (native.tabs) {
    define(native, "tabGroups", () => ({
      TAB_GROUP_ID_NONE: -1,
      Color: Object.fromEntries(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
        .map((color) => [color.toUpperCase(), color])),
      onCreated: event(), onUpdated: event(), onRemoved: event(), onMoved: event(),
      query: (info, callback) => settle(Promise.resolve([]), callback),
      get: unsupported("chrome.tabGroups"),
      update: unsupported("chrome.tabGroups"),
      move: unsupported("chrome.tabGroups"),
    }));
    define(native.tabs, "group", () => unsupported("chrome.tabs.group"));
    define(native.tabs, "ungroup", () => unsupported("chrome.tabs.ungroup"));
    define(native.tabs, "TAB_ID_NONE", () => -1);
  }
  // The debugger (Chrome DevTools Protocol): WebKit has none. Its events are listened to at
  // start; attaching is refused, so what drives pages through it says it can't.
  define(native, "debugger", () => ({
    onEvent: event(), onDetach: event(),
    attach: unsupported("chrome.debugger"),
    detach: () => Promise.resolve(),
    sendCommand: unsupported("chrome.debugger"),
    getTargets: (callback) => settle(Promise.resolve([]), callback),
  }));
  // System notifications: not shown (WebKit has no API for them), accepted silently.
  define(native, "notifications", () => ({
    onClicked: event(), onClosed: event(), onButtonClicked: event(), onShowSettings: event(),
    create: (...args) => settle(Promise.resolve(typeof args[0] === "string" ? args[0] : ""), args.find((a) => typeof a === "function")),
    update: (id, options, callback) => settle(Promise.resolve(false), callback),
    clear: (id, callback) => settle(Promise.resolve(false), callback),
    getAll: (callback) => settle(Promise.resolve({}), callback),
  }));
  // declarativeNetRequest: WebKit has the rules, not Chrome's named constants for them.
  const constants = (values) => Object.fromEntries(values.map((value) => [value.replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), value]));
  const rules = native.declarativeNetRequest;
  if (rules) {
    define(rules, "RuleActionType", () => constants(["block", "redirect", "allow", "upgradeScheme", "modifyHeaders", "allowAllRequests"]));
    define(rules, "HeaderOperation", () => constants(["append", "set", "remove"]));
    define(rules, "ResourceType", () => constants(["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
      "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"]));
    define(rules, "DomainType", () => constants(["firstParty", "thirdParty"]));
    define(rules, "RequestMethod", () => constants(["connect", "delete", "get", "head", "options", "patch", "post", "put", "other"]));
  }
  // chrome.proxy (VPN extensions): WebKit has none. Nuri routes pages through the server the
  // extension sets (ExtensionProxy), reached by runtime.sendNativeMessage, which Nuri answers
  // itself for an extension asking for "proxy" and never passes to an app of the Mac. The
  // server's password comes from the extension's webRequest.onAuthRequired: WebKit never calls
  // it, so the listeners are kept here and called when Nuri asks, in the background.
  const manifest = runtime.getManifest() || {};
  if ((manifest.permissions || []).includes("proxy") && native.proxy === undefined) {
    const toNuri = (message) => {
      if (typeof runtime.sendNativeMessage !== "function") return Promise.reject(new Error("chrome.proxy n'est pas pris en charge par Nuri"));
      return runtime.sendNativeMessage("app.nuri.proxy", message).then((reply) => {
        if (reply && reply.error) throw new Error(reply.error);
        return reply || {};
      });
    };
    const changeListeners = new Set();
    const changed = {
      addListener: (listener) => { changeListeners.add(listener); },
      removeListener: (listener) => { changeListeners.delete(listener); },
      hasListener: (listener) => changeListeners.has(listener),
      hasListeners: () => changeListeners.size > 0,
    };
    define(native, "proxy", () => ({
      settings: {
        get: (details, callback) => settle(toNuri({ get: true }), typeof details === "function" ? details : callback),
        set: (details, callback) => settle(toNuri({ set: (details && details.value) || {} }).then(() => undefined), callback),
        clear: (details, callback) => settle(toNuri({ clear: true }).then(() => undefined), typeof details === "function" ? details : callback),
        onChange: changed,
      },
      onProxyError: event(),
    }));
    answers.nuriProxyChanged = (details) => {
      for (const listener of [...changeListeners]) { try { listener(details); } catch {} }
      return true;
    };

    // WebKit's event keeps its place (a new one put there is ignored): its methods are replaced,
    // as for runtime.onMessage above.
    const authListeners = [];
    const authMethods = {
      addListener: (listener, filter, extraInfo) => {
        if (!authListeners.some((entry) => entry.listener === listener)) authListeners.push({ listener, extraInfo: extraInfo || [] });
      },
      removeListener: (listener) => {
        const index = authListeners.findIndex((entry) => entry.listener === listener);
        if (index >= 0) authListeners.splice(index, 1);
      },
      hasListener: (listener) => authListeners.some((entry) => entry.listener === listener),
      hasListeners: () => authListeners.length > 0,
    };
    const webRequest = native.webRequest;
    const onAuthRequired = webRequest && webRequest.onAuthRequired;
    if (onAuthRequired) {
      try {
        Object.defineProperty(native, "webRequest", { value: webRequest, configurable: true, writable: true, enumerable: true });
        Object.defineProperty(webRequest, "onAuthRequired", { value: onAuthRequired, configurable: true, writable: true, enumerable: true });
        for (const [name, value] of Object.entries(authMethods)) {
          Object.defineProperty(onAuthRequired, name, { value, configurable: true, writable: true, enumerable: true });
        }
      } catch {}
    } else if (!webRequest) {
      define(native, "webRequest", () => ({ onAuthRequired: authMethods }));
    }
    // As Chrome asks when the server answers 407: each listener in turn, until one gives a
    // password. A new request each time (some count the requests they were asked for twice).
    let requests = 0;
    answers.nuriProxyAuth = (server) => new Promise((done) => {
      const scheme = server.scheme === "https" ? "https" : "http";
      const details = {
        requestId: `nuri-proxy-${++requests}`, url: `${scheme}://${server.host}:${server.port}/`, method: "GET",
        frameId: 0, parentFrameId: -1, tabId: -1, type: "other", timeStamp: Date.now(),
        isProxy: true, scheme: "basic", realm: "", statusCode: 407, statusLine: "HTTP/1.1 407 Proxy Authentication Required",
        challenger: { host: server.host, port: server.port },
      };
      const listeners = [...authListeners];
      let index = 0;
      const next = () => {
        const entry = listeners[index++];
        if (!entry) return done(null);
        let answered = false;
        const answer = (response) => {
          if (answered) return;
          answered = true;
          const credentials = response && response.authCredentials;
          if (credentials && typeof credentials.username === "string") done({ username: credentials.username, password: String(credentials.password ?? "") });
          else next();
        };
        try {
          const asynchronous = entry.extraInfo.includes("asyncBlocking");
          const result = entry.listener(details, asynchronous ? answer : undefined);
          if (!asynchronous) Promise.resolve(result).then(answer, () => answer());
        } catch {
          answer();
        }
      };
      next();
    });
  }
  // runtime.getContexts (which pages of the extension are open): none known.
  define(runtime, "ContextType", () => ({ TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL" }));
  define(runtime, "getContexts", () => (filter, callback) => settle(Promise.resolve([]), callback));
  // Offscreen documents (clipboard, audio…): refused, the way Chrome refuses a bad request, so
  // that extensions fall back on something else instead of stopping.
  define(native, "offscreen", () => ({
    Reason: {},
    createDocument: unsupported("chrome.offscreen"),
    hasDocument: () => Promise.resolve(false),
    closeDocument: () => Promise.resolve(),
  }));
  // Side panel (Claude, Perplexity…): Nuri has no panel beside the page, its page opens in a tab.
  // The settings live in the context that sets them, usually the background, which also opens it.
  const panel = {
    path: ((runtime.getManifest() || {}).side_panel || {}).default_path || "",
    paths: new Map(),
    disabled: new Set(),
    onAction: false,
  };
  const openPanel = (options) => {
    const tabId = options && options.tabId;
    const path = (tabId != null && panel.paths.get(tabId)) || panel.path;
    if (!path || (tabId != null && panel.disabled.has(tabId))) {
      return Promise.reject(new Error("Aucun panneau latéral pour cet onglet"));
    }
    const create = { url: runtime.getURL(path.replace(/^\//, "")), active: true };
    if (tabId != null) create.openerTabId = tabId;
    if (options && options.windowId != null) create.windowId = options.windowId;
    return native.tabs.create(create).then(() => undefined, () => undefined);
  };
  const ownPanel = native.sidePanel === undefined;
  define(native, "sidePanel", () => ({
    setPanelBehavior: (behavior, callback) => {
      if (behavior && "openPanelOnActionClick" in behavior) panel.onAction = !!behavior.openPanelOnActionClick;
      return settle(Promise.resolve(), callback);
    },
    getPanelBehavior: (callback) => settle(Promise.resolve({ openPanelOnActionClick: panel.onAction }), callback),
    setOptions: (options, callback) => {
      const { tabId, path, enabled } = options || {};
      if (tabId != null) {
        if (path) panel.paths.set(tabId, path);
        if (enabled === false) panel.disabled.add(tabId); else if (enabled === true) panel.disabled.delete(tabId);
      } else if (path) {
        panel.path = path;
      }
      return settle(Promise.resolve(), callback);
    },
    getOptions: (options, callback) => {
      const tabId = options && options.tabId;
      const path = (tabId != null && panel.paths.get(tabId)) || panel.path;
      return settle(Promise.resolve({ path, enabled: !!path && !(tabId != null && panel.disabled.has(tabId)) }), callback);
    },
    open: (options, callback) => settle(openPanel(options), callback),
  }));
  // setPanelBehavior({ openPanelOnActionClick: true }): the button opens the panel. Heard in the
  // background only (a service worker, or an older extension's background page).
  const action = native.action || native.browserAction;
  if (ownPanel && inBackground && action && action.onClicked) {
    try {
      action.onClicked.addListener((tab) => {
        if (panel.onAction) openPanel({ tabId: tab && tab.id, windowId: tab && tab.windowId }).catch(() => {});
      });
    } catch {}
  }
})();

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

  // A WebSocket opened in an extension's service worker ends the worker at once in WebKit (Claude's
  // bridge to claude.ai, opened as soon as one is signed in): the extension's background is gone,
  // and its pages, which go through the worker, never load again. There it fails the way a refused
  // connection does, and the extension carries on without it. Its pages keep real WebSockets.
  if (typeof ServiceWorkerGlobalScope === "function" && globalThis instanceof ServiceWorkerGlobalScope && typeof EventTarget === "function") {
    class RefusedWebSocket extends EventTarget {
      constructor(address, protocols) {
        super();
        this.url = String(address);
        this.protocol = "";
        this.extensions = "";
        this.binaryType = "blob";
        this.bufferedAmount = 0;
        this.readyState = RefusedWebSocket.CONNECTING;
        this.onopen = this.onerror = this.onclose = this.onmessage = null;
        setTimeout(() => {
          this.readyState = RefusedWebSocket.CLOSED;
          const error = new Event("error");
          this.dispatchEvent(error);
          if (typeof this.onerror === "function") this.onerror(error);
          const close = Object.assign(new Event("close"), { code: 1006, reason: "", wasClean: false });
          this.dispatchEvent(close);
          if (typeof this.onclose === "function") this.onclose(close);
        }, 0);
      }
      send() { throw new DOMException("WebSocket is not open", "InvalidStateError"); }
      close() { this.readyState = RefusedWebSocket.CLOSED; }
    }
    Object.assign(RefusedWebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
    Object.assign(RefusedWebSocket.prototype, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
    try {
      Object.defineProperty(globalThis, "WebSocket", { value: RefusedWebSocket, configurable: true, writable: true });
    } catch {}
  }

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
  const replace = (target, name, value) => {
    try {
      Object.defineProperty(target, name, { value, configurable: true, writable: true, enumerable: true });
    } catch {}
  };
  const manifest = runtime.getManifest() || {};

  // Chrome's two styles: a promise, or a callback. On failure Chrome's callback runs with
  // runtime.lastError set; WebKit's runtime ignores any change to that property (and never sets it
  // itself), so the callback runs with no value.
  const answer = (promise, callback) => {
    if (typeof callback !== "function") return promise;
    promise.then((value) => callback(value), () => callback());
  };
  const failure = (message) => Promise.reject(new Error(message));

  // Nuri itself, through runtime.sendNativeMessage to one of its own names: Nuri answers them and
  // never passes them to an app of the Mac (ExtensionHost, ExtensionNative). What has to be shared
  // by all of an extension's contexts (its side panel, its tab groups) or reach Nuri's windows
  // (chrome.debugger, chrome.identity) is answered there.
  const toNuri = (app, message) => {
    if (typeof runtime.sendNativeMessage !== "function") return failure(`Nuri n'est pas joignable (${app})`);
    return runtime.sendNativeMessage(`app.nuri.${app}`, message).then((reply) => {
      if (reply && reply.error) throw new Error(reply.error);
      return reply || {};
    });
  };

  for (const name of ["onUpdateAvailable", "onRestartRequired", "onBrowserUpdateAvailable", "onSuspend",
                      "onSuspendCanceled", "onMessageExternal", "onConnectExternal"]) {
    define(runtime, name, event);
  }
  // Chrome's named values, read without a second thought (Claude's onInstalled stops at the first).
  define(runtime, "OnInstalledReason", () => ({ INSTALL: "install", UPDATE: "update", CHROME_UPDATE: "chrome_update", SHARED_MODULE_UPDATE: "shared_module_update" }));
  define(runtime, "OnRestartRequiredReason", () => ({ APP_UPDATE: "app_update", OS_UPDATE: "os_update", PERIODIC: "periodic" }));
  define(runtime, "PlatformOs", () => ({ MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" }));
  define(runtime, "PlatformArch", () => ({ ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" }));
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
  // An event this file fires itself.
  const firing = () => {
    const listeners = new Set();
    return {
      api: {
        addListener: (listener) => { listeners.add(listener); },
        removeListener: (listener) => { listeners.delete(listener); },
        hasListener: (listener) => listeners.has(listener),
        hasListeners: () => listeners.size > 0,
      },
      fire: (...args) => { for (const listener of [...listeners]) { try { listener(...args); } catch {} } },
    };
  };

  // Tab groups (Claude gathers the tabs it works in into one): WebKit has none. Nuri keeps them,
  // for all of the extension's contexts at once, by the tab identifiers WebKit gives it; tabs.get
  // and tabs.query tell each tab's group, as Chrome does. Nuri draws none of them.
  if (tabs && native.tabGroups === undefined) {
    const NONE = -1;
    const groups = (message) => toNuri("tabgroups", message);
    const created = firing(), updated = firing(), removed = firing();
    const told = (reply) => {
      for (const group of reply.created || []) created.fire(group);
      for (const group of reply.updated || []) updated.fire(group);
      for (const group of reply.removed || []) removed.fire(group);
      return reply;
    };
    const withGroups = async (list) => {
      const { members = {} } = await groups({ members: true }).catch(() => ({}));
      return list.map((tab) => (tab && typeof tab === "object" ? { ...tab, groupId: members[tab.id] ?? NONE } : tab));
    };
    const get = tabs.get.bind(tabs);
    const query = tabs.query.bind(tabs);
    replace(tabs, "get", (tabId, callback) => answer(get(tabId).then(async (tab) => (await withGroups([tab]))[0]), callback));
    replace(tabs, "query", (info, callback) => {
      if (typeof info === "function") { callback = info; info = {}; }
      const { groupId, ...rest } = info || {};
      return answer(query(rest).then(withGroups).then((list) => (groupId === undefined ? list : list.filter((tab) => tab.groupId === groupId))), callback);
    });
    replace(tabs, "group", (options, callback) => answer((async () => {
      const ids = [].concat((options && options.tabIds) ?? []);
      if (!ids.length) throw new Error("No tabs specified.");
      let windowId = options.createProperties && options.createProperties.windowId;
      if (windowId == null) windowId = (await get(ids[0])).windowId;
      return told(await groups({ group: ids, groupId: options.groupId ?? null, windowId: windowId ?? NONE })).groupId;
    })(), callback));
    replace(tabs, "ungroup", (tabIds, callback) => answer(groups({ ungroup: [].concat(tabIds ?? []) }).then((reply) => { told(reply); }), callback));
    define(tabs, "TAB_ID_NONE", () => NONE);
    // A closed tab leaves its group; an empty group goes.
    if (inBackground && tabs.onRemoved) {
      try { tabs.onRemoved.addListener((tabId) => { groups({ ungroup: [tabId] }).then(told, () => {}); }); } catch {}
    }
    replace(native, "tabGroups", {
      TAB_GROUP_ID_NONE: NONE,
      Color: Object.fromEntries(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
        .map((color) => [color.toUpperCase(), color])),
      onCreated: created.api, onUpdated: updated.api, onRemoved: removed.api, onMoved: event(),
      get: (groupId, callback) => answer(groups({ get: groupId }).then((reply) => reply.group), callback),
      query: (info, callback) => answer(groups({ query: info || {} }).then((reply) => reply.groups || []), callback),
      update: (groupId, properties, callback) => answer(groups({ update: groupId, properties: properties || {} }).then((reply) => told(reply).group), callback),
      move: (groupId, properties, callback) => answer(groups({ get: groupId }).then((reply) => reply.group), callback),
    });
  }

  // The debugger (Chrome DevTools Protocol): WebKit has none. Nuri answers what extensions that
  // drive pages ask of it (screenshots, the pointer, the keyboard, running a script in the page;
  // ExtensionDebugger), on the tab WebKit names. Commands go one after the other, in the order
  // given: a word typed is a series of keys sent all at once.
  if (native.debugger === undefined) {
    const attached = new Set();
    const target = async (debuggee) => {
      const tabId = debuggee && debuggee.tabId;
      if (tabId == null) throw new Error("Nuri ne débogue que des onglets");
      const tab = await tabs.get(tabId);
      let frame = null;
      try {
        const window = await native.windows.get(tab.windowId);
        frame = { left: window.left, top: window.top, width: window.width, height: window.height };
      } catch {}
      return { tabId, index: tab.index, url: tab.url || "", frame };
    };
    let queue = Promise.resolve();
    const inTurn = (work) => {
      const run = queue.then(work);
      queue = run.catch(() => {});
      return run;
    };
    replace(native, "debugger", {
      onEvent: event(), onDetach: event(),
      attach: (debuggee, version, callback) => answer(inTurn(async () => {
        await toNuri("debugger", { attach: await target(debuggee) });
        attached.add(debuggee.tabId);
      }), callback),
      detach: (debuggee, callback) => answer(Promise.resolve().then(() => { attached.delete(debuggee && debuggee.tabId); }), callback),
      sendCommand: (debuggee, method, params, callback) => {
        if (typeof params === "function") { callback = params; params = undefined; }
        return answer(inTurn(async () => (await toNuri("debugger", { command: method, params: params || {}, target: await target(debuggee) })).result ?? {}), callback);
      },
      getTargets: (callback) => answer(tabs.query({}).then((list) => list.map((tab) => ({
        id: String(tab.id), tabId: tab.id, type: "page", title: tab.title || "", url: tab.url || "",
        attached: attached.has(tab.id), faviconUrl: tab.favIconUrl,
      }))), callback),
    });
  }

  // chrome.identity: an extension signs in through a page that comes back to its own address at
  // chromiumapp.org. Nuri opens that page with the cookies of the window's space (out of sight,
  // or in a window when it may ask something) and gives back the address it lands on.
  if (native.identity === undefined) {
    const redirect = (path) => `https://${runtime.id}.chromiumapp.org/${String(path || "").replace(/^\//, "")}`;
    replace(native, "identity", {
      getRedirectURL: redirect,
      launchWebAuthFlow: (details, callback) => answer(toNuri("identity", {
        url: String((details && details.url) || ""), interactive: !!(details && details.interactive), redirect: redirect(),
        timeout: (details && details.timeoutMsForNonInteractive) || 0,
        abortOnLoad: !!(details && details.abortOnLoadForNonInteractive),
      }).then((reply) => reply.url), callback),
      getAuthToken: (details, callback) => answer(failure("chrome.identity.getAuthToken n'est pas pris en charge par Nuri"), typeof details === "function" ? details : callback),
      removeCachedAuthToken: (details, callback) => answer(Promise.resolve(), callback),
      clearAllCachedAuthTokens: (callback) => answer(Promise.resolve(), callback),
      getProfileUserInfo: (details, callback) => answer(Promise.resolve({ email: "", id: "" }), typeof details === "function" ? details : callback),
      getAccounts: (callback) => answer(Promise.resolve([]), callback),
      onSignInChanged: event(),
    });
  }
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
    // Held, so that what is added below stays (WebKit may rebuild an object nobody holds).
    replace(native, "declarativeNetRequest", rules);
    define(rules, "RuleActionType", () => constants(["block", "redirect", "allow", "upgradeScheme", "modifyHeaders", "allowAllRequests"]));
    define(rules, "HeaderOperation", () => constants(["append", "set", "remove"]));
    define(rules, "ResourceType", () => constants(["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
      "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"]));
    define(rules, "DomainType", () => constants(["firstParty", "thirdParty"]));
    define(rules, "RequestMethod", () => constants(["connect", "delete", "get", "head", "options", "patch", "post", "put", "other"]));

    // WebKit's modifyHeaders only knows standard headers: a rule setting one of the site's own
    // (Claude's anthropic-client-platform, for its API) makes the whole call fail, and Claude's
    // start stops there. Such headers are taken out of the rule, which WebKit then accepts, and
    // added here to the extension's own requests (Nuri keeps them for all of its contexts). Pages'
    // requests don't get them.
    const refused = /header `([^`]+)` is not recognized/i;
    const pattern = (condition) => {
      if (condition.regexFilter) return condition.regexFilter;
      let filter = condition.urlFilter || "*";
      let start = "", end = "";
      if (filter.startsWith("||")) { start = "^[a-z][a-z0-9+.-]*://([^/]*\\.)?"; filter = filter.slice(2); }
      else if (filter.startsWith("|")) { start = "^"; filter = filter.slice(1); }
      if (filter.endsWith("|")) { end = "$"; filter = filter.slice(0, -1); }
      const body = filter.split("").map((c) => (c === "*" ? ".*" : c === "^" ? "([^a-zA-Z0-9_.%-]|$)" : c.replace(/[.+?${}()|[\]\\/]/g, "\\$&"))).join("");
      return start + body + end;
    };
    for (const name of ["updateSessionRules", "updateDynamicRules"]) {
      if (typeof rules[name] !== "function") continue;
      const original = rules[name].bind(rules);
      replace(rules, name, (options, callback) => answer((async () => {
        const given = options || {};
        let added = (given.addRules || []).map((rule) => JSON.parse(JSON.stringify(rule)));
        const moved = [];
        for (let attempt = 0; ; attempt++) {
          try {
            await original({ ...given, addRules: added });
            break;
          } catch (error) {
            const found = refused.exec(String((error && error.message) || error));
            if (!found || attempt > 30) throw error;
            const header = found[1].toLowerCase();
            let changed = false;
            added = added.flatMap((rule) => {
              const action = rule.action || {};
              const own = (action.requestHeaders || []).filter((entry) => String(entry.header).toLowerCase() === header);
              if (!own.length) return [rule];
              changed = true;
              moved.push({ id: rule.id, regex: pattern(rule.condition || {}), headers: own });
              const kept = (action.requestHeaders || []).filter((entry) => !own.includes(entry));
              if (!kept.length && !(action.responseHeaders || []).length) return [];
              return [{ ...rule, action: { ...action, requestHeaders: kept } }];
            });
            if (!changed) throw error;
          }
        }
        await toNuri("headers", { remove: given.removeRuleIds || [], add: moved }).catch(() => {});
        loadHeaders();
      })(), callback));
    }
  }

  // Its own requests leave with the Origin Chrome gives them, chrome-extension://<id>, not WebKit's
  // webkit-extension://: services that know an extension by its origin refuse the other
  // (Anthropic's API answers Claude "CORS requests are not allowed for this Organization"). Only
  // what the extension itself sends: pages' requests are left alone. Set once, by its background.
  const permissionNames = manifest.permissions || [];
  if (rules && inBackground && typeof rules.updateSessionRules === "function"
      && (permissionNames.includes("declarativeNetRequest") || permissionNames.includes("declarativeNetRequestWithHostAccess"))) {
    const originRule = 2147480001;
    rules.updateSessionRules({ removeRuleIds: [originRule], addRules: [{ id: originRule, priority: 1,
      action: { type: "modifyHeaders", requestHeaders: [{ header: "Origin", operation: "set", value: `chrome-extension://${runtime.id}` }] },
      condition: { initiatorDomains: [runtime.id], resourceTypes: ["xmlhttprequest", "websocket", "other"] } }] }).catch(() => {});
  }

  // The headers kept above, on the extension's own fetch() calls.
  let headerRules = Promise.resolve([]);
  const loadHeaders = () => {
    headerRules = toNuri("headers", { get: true }).then((reply) => (reply.rules || []).flatMap((rule) => {
      try { return [{ pattern: new RegExp(rule.regex), headers: rule.headers }]; } catch { return []; }
    }), () => []);
  };
  if (typeof globalThis.fetch === "function") {
    loadHeaders();
    const fetchFirst = globalThis.fetch.bind(globalThis);
    globalThis.fetch = async (input, init) => {
      const list = await headerRules;
      if (!list.length) return fetchFirst(input, init);
      let address = "";
      try { address = new URL(input instanceof Request ? input.url : String(input), globalThis.location && globalThis.location.href).href; } catch {}
      const wanted = list.filter((rule) => rule.pattern.test(address));
      if (!wanted.length) return fetchFirst(input, init);
      const headers = new Headers((init && init.headers) || (input instanceof Request ? input.headers : undefined));
      for (const rule of wanted) {
        for (const entry of rule.headers) {
          const operation = String(entry.operation || "set").toLowerCase();
          if (operation === "remove") headers.delete(entry.header);
          else if (operation === "append") headers.append(entry.header, entry.value ?? "");
          else headers.set(entry.header, entry.value ?? "");
        }
      }
      return fetchFirst(input, { ...(init || {}), headers });
    };
  }
  // chrome.proxy (VPN extensions): WebKit has none. Nuri routes pages through the server the
  // extension sets (ExtensionProxy), reached by runtime.sendNativeMessage, which Nuri answers
  // itself for an extension asking for "proxy" and never passes to an app of the Mac. The
  // server's password comes from the extension's webRequest.onAuthRequired: WebKit never calls
  // it, so the listeners are kept here and called when Nuri asks, in the background.
  if ((manifest.permissions || []).includes("proxy") && native.proxy === undefined) {
    const toProxy = (message) => toNuri("proxy", message);
    const changeListeners = new Set();
    const changed = {
      addListener: (listener) => { changeListeners.add(listener); },
      removeListener: (listener) => { changeListeners.delete(listener); },
      hasListener: (listener) => changeListeners.has(listener),
      hasListeners: () => changeListeners.size > 0,
    };
    define(native, "proxy", () => ({
      settings: {
        get: (details, callback) => settle(toProxy({ get: true }), typeof details === "function" ? details : callback),
        set: (details, callback) => settle(toProxy({ set: (details && details.value) || {} }).then(() => undefined), callback),
        clear: (details, callback) => settle(toProxy({ clear: true }).then(() => undefined), typeof details === "function" ? details : callback),
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
  // Offscreen documents (clipboard, audio…): refused, the way Chrome refuses a bad request, so
  // that extensions fall back on something else instead of stopping.
  define(native, "offscreen", () => ({
    Reason: Object.fromEntries(["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA",
      "DISPLAY_MEDIA", "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"].map((name) => [name, name])),
    createDocument: unsupported("chrome.offscreen"),
    hasDocument: () => Promise.resolve(false),
    closeDocument: () => Promise.resolve(),
  }));

  // Side panel (Claude, Perplexity…): Nuri shows the page in a card beside the page
  // (ExtensionSidePanel). It is asked for as a new tab with Nuri's mark in its address, which Nuri
  // takes away: the panel's page sees its own address. Its settings live in the context that sets
  // them, usually the background, which also opens it.
  const panelMark = "nuri-side-panel";
  const panel = {
    path: (manifest.side_panel || {}).default_path || "",
    paths: new Map(),
    disabled: new Set(),
    onAction: false,
  };
  const panelPath = (tabId) => (tabId != null && panel.paths.get(tabId)) || panel.path;
  const openPanel = async (options) => {
    const tabId = options && options.tabId;
    const path = panelPath(tabId);
    if (!path || (tabId != null && panel.disabled.has(tabId))) throw new Error("No active side panel for this tab.");
    const url = new URL(runtime.getURL(path.replace(/^\//, "")));
    url.searchParams.set(panelMark, "1");
    const create = { url: url.href, active: true };
    if (options && options.windowId != null) create.windowId = options.windowId;
    else if (tabId != null) {
      try { create.windowId = (await tabs.get(tabId)).windowId; } catch {}
    }
    await native.tabs.create(create).catch(() => {});
  };
  const ownPanel = native.sidePanel === undefined;
  if (ownPanel) {
    replace(native, "sidePanel", {
      setPanelBehavior: (behavior, callback) => {
        if (behavior && "openPanelOnActionClick" in behavior) panel.onAction = !!behavior.openPanelOnActionClick;
        return answer(Promise.resolve(), callback);
      },
      getPanelBehavior: (callback) => answer(Promise.resolve({ openPanelOnActionClick: panel.onAction }), callback),
      setOptions: (options, callback) => {
        const { tabId, path, enabled } = options || {};
        if (tabId != null) {
          if (path) panel.paths.set(tabId, path);
          if (enabled === false) panel.disabled.add(tabId); else if (enabled === true) panel.disabled.delete(tabId);
        } else if (path) {
          panel.path = path;
        }
        return answer(Promise.resolve(), callback);
      },
      getOptions: (options, callback) => {
        const tabId = options && options.tabId;
        const path = panelPath(tabId);
        return answer(Promise.resolve({ path, enabled: !!path && !(tabId != null && panel.disabled.has(tabId)) }), callback);
      },
      open: (options, callback) => answer(openPanel(options), callback),
      close: (options, callback) => answer(toNuri("panel", { close: true }).then(() => undefined), callback),
    });
  }
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

  // runtime.getContexts: which of the extension's pages are open. The side panels are Nuri's (a
  // panel's page asks it to know it is one: Claude's shows nothing otherwise); WebKit, when it
  // knows the API, tells the rest.
  define(runtime, "ContextType", () => ({ TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL" }));
  {
    const webKitContexts = typeof runtime.getContexts === "function" ? runtime.getContexts.bind(runtime) : null;
    const wanted = (filter, context) => {
      const among = (list, value) => !Array.isArray(list) || list.includes(value);
      return among(filter.contextTypes, context.contextType) && among(filter.documentUrls, context.documentUrl)
        && among(filter.documentOrigins, context.documentOrigin) && among(filter.tabIds, context.tabId)
        && among(filter.windowIds, context.windowId) && among(filter.contextIds, context.contextId)
        && among(filter.frameIds, context.frameId) && (filter.incognito === undefined || filter.incognito === context.incognito);
    };
    replace(runtime, "getContexts", (filter, callback) => {
      if (typeof filter === "function") { callback = filter; filter = {}; }
      return answer((async () => {
        const criteria = filter || {};
        const panels = ownPanel ? ((await toNuri("panel", { contexts: true }).catch(() => ({}))).contexts || []) : [];
        const shown = new Set(panels.map((context) => context.documentUrl));
        const theirs = webKitContexts ? await webKitContexts(criteria).catch(() => []) : [];
        return [...theirs.filter((context) => !shown.has(context.documentUrl)), ...panels.filter((context) => wanted(criteria, context))];
      })(), callback);
    });
  }

  // Claude's panel frames claude.ai/cic, a page that only lets Chrome's extension pages show it:
  // here it stays blank, and the panel waits for it forever. The panel is told what that page says
  // when it can't serve there, and goes on with the conversation it carries itself.
  if (!inBackground && typeof document !== "undefined" && typeof MutationObserver === "function") {
    const blocked = /^https:\/\/(preview\.)?claude\.ai\/cic(\/|\?|$)/;
    const seen = new WeakSet();
    const tell = (frame) => {
      const source = frame.getAttribute("src") || "";
      if (seen.has(frame) || !blocked.test(source)) return;
      seen.add(frame);
      const origin = new URL(source).origin;
      for (const delay of [0, 60, 300, 1000, 3000]) {
        setTimeout(() => {
          try { window.dispatchEvent(new MessageEvent("message", { origin, data: { type: "cic_sidepanel_cowork_unavailable" } })); } catch {}
        }, delay);
      }
    };
    const look = (root) => {
      if (root.tagName === "IFRAME") tell(root);
      if (root.querySelectorAll) root.querySelectorAll("iframe").forEach(tell);
    };
    new MutationObserver((changes) => {
      for (const change of changes) {
        if (change.type === "attributes") look(change.target);
        else change.addedNodes.forEach((node) => { if (node.nodeType === 1) look(node); });
      }
    }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ["src"] });
  }

  // What goes wrong in an extension's pages, written in Nuri's log when it is asked for (the
  // `extensionConsoleLog` default): an extension's own inspector isn't always at hand.
  toNuri("log", { enabled: true }).then((reply) => {
    if (!reply.enabled) return;
    let sent = 0;
    const where = (globalThis.location && globalThis.location.pathname) || "background";
    const send = (kind, parts) => {
      if (sent++ > 600) return;
      const text = parts.map((part) => {
        if (part instanceof Error) return `${part.name}: ${part.message}\n${part.stack || ""}`;
        if (typeof part === "object") { try { return JSON.stringify(part); } catch { return String(part); } }
        return String(part);
      }).join(" ").slice(0, 2000);
      toNuri("log", { log: `${kind} ${where}: ${text}` }).catch(() => {});
    };
    for (const kind of ["error", "warn"]) {
      const original = console[kind].bind(console);
      console[kind] = (...parts) => { send(kind, parts); original(...parts); };
    }
    for (const kind of ["log", "info"]) {
      const original = console[kind].bind(console);
      console[kind] = (...parts) => { send(kind, parts); original(...parts); };
    }
    globalThis.addEventListener("error", (event) => send("exception", [event.error || event.message, event.filename || "", event.lineno || ""]));
    globalThis.addEventListener("unhandledrejection", (event) => send("rejection", [event.reason]));
    send("start", [inBackground ? "arrière-plan" : "page"]);

    // What hangs: a call to the browser that is still unanswered after 10 s.
    const describe = (args) => {
      try { return JSON.stringify(args.filter((arg) => typeof arg !== "function")).slice(0, 300); } catch { return ""; }
    };
    const watch = (object, label) => {
      if (!object || typeof object !== "object") return;
      const names = new Set();
      for (let owner = object; owner && owner !== Object.prototype; owner = Object.getPrototypeOf(owner)) {
        for (const name of Object.getOwnPropertyNames(owner)) names.add(name);
      }
      for (const name of names) {
        if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
        let original;
        try { original = object[name]; } catch { continue; }
        if (typeof original !== "function") continue;
        replace(object, name, function (...args) {
          const result = original.apply(object, args);
          if (result && typeof result.then === "function") {
            let settled = false;
            const started = Date.now();
            result.then(() => { settled = true; }, () => { settled = true; });
            setTimeout(() => {
              if (settled) return;
              send("slow", [`${label}.${name} sans réponse depuis 10 s`, describe(args)]);
              result.then(() => send("slow", [`${label}.${name} répondu après ${Math.round((Date.now() - started) / 1000)} s`]), () => {});
            }, 10000);
          }
          return result;
        });
      }
    };
    for (const name of ["runtime", "tabs", "windows", "scripting", "tabGroups", "sidePanel", "debugger", "identity", "alarms",
                        "permissions", "action", "declarativeNetRequest", "webNavigation", "offscreen", "notifications"]) {
      watch(native[name], name);
    }
    if (native.storage) for (const area of ["local", "session", "sync"]) watch(native.storage[area], `storage.${area}`);
    // In the background, what it reaches out to, in order: the last line before it goes silent.
    if (inBackground) {
      const where = (address) => { try { const url = new URL(String(address)); return url.origin + url.pathname; } catch { return String(address).slice(0, 120); } };
      const fetchBefore = globalThis.fetch;
      if (typeof fetchBefore === "function") {
        globalThis.fetch = (input, init) => {
          const target = where(input instanceof Request ? input.url : input);
          send("net", [`fetch ${target}`]);
          return fetchBefore(input, init).then((response) => { send("net", [`fetch ${target} → ${response.status}`]); return response; },
            (error) => { send("net", [`fetch ${target} échec ${error && error.message}`]); throw error; });
        };
      }
      const Socket = globalThis.WebSocket;
      if (typeof Socket === "function") {
        globalThis.WebSocket = function (address, protocols) {
          send("net", [`WebSocket ${where(address)}`]);
          const socket = protocols === undefined ? new Socket(address) : new Socket(address, protocols);
          socket.addEventListener("open", () => send("net", [`WebSocket ouvert ${where(address)}`]));
          socket.addEventListener("close", (event) => send("net", [`WebSocket fermé ${where(address)} ${event.code}`]));
          return socket;
        };
        globalThis.WebSocket.prototype = Socket.prototype;
        Object.assign(globalThis.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
      }
      if (typeof runtime.connectNative === "function") {
        const connectNative = runtime.connectNative.bind(runtime);
        replace(runtime, "connectNative", (application) => { send("net", [`connectNative ${application}`]); return connectNative(application); });
      }
      for (const name of ["onStartup", "onInstalled"]) {
        try { runtime[name].addListener(() => send("event", [name])); } catch {}
      }
    }
    // In the background, a beat: it stops when its thread is held.
    if (inBackground) {
      let beats = 0;
      const beat = setInterval(() => {
        send("alive", [`${++beats * 15} s`]);
        if (beats >= 60) clearInterval(beat);
      }, 15000);
    }
  }, () => {});
})();

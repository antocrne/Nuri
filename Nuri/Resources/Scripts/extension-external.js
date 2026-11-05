// Sites an extension lets talk to it (externally_connectable: claude.ai for Claude's sign-in) reach
// it in Chrome through chrome.runtime. WebKit gives those pages `browser.runtime` only, and answers
// nothing at all for an extension that isn't installed, which such sites take for a yes (they try
// several identifiers in turn). Nuri's copy of the extension runs this in the page's own world on
// those sites (ExtensionFiles.addShims), with its identifier in place of the placeholder; each
// extension adds itself, and Chrome's error comes back for the others.
(() => {
  const id = "__NURI_EXTENSION_ID__";
  const api = globalThis.browser && globalThis.browser.runtime;
  if (!api || typeof api.sendMessage !== "function") return;
  const mark = Symbol.for("nuri.external-extensions");
  const installed = globalThis[mark] || (globalThis[mark] = new Set());
  installed.add(id);
  if (globalThis.chrome && globalThis.chrome.runtime && globalThis.chrome.runtime[mark]) return;

  const absent = () => new Error("Could not establish connection. Receiving end does not exist.");
  let lastError;
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (listener) => { listeners.add(listener); },
      removeListener: (listener) => { listeners.delete(listener); },
      hasListener: (listener) => listeners.has(listener),
      fire: (...args) => { for (const listener of [...listeners]) { try { listener(...args); } catch {} } },
    };
  };
  const runtime = {
    [mark]: true,
    get lastError() { return lastError; },
    sendMessage(extensionId, message, options, callback) {
      if (typeof options === "function") { callback = options; options = undefined; }
      const reply = installed.has(extensionId) ? Promise.resolve().then(() => api.sendMessage(extensionId, message)) : Promise.reject(absent());
      if (typeof callback !== "function") return reply;
      reply.then((value) => callback(value), (error) => {
        lastError = { message: String((error && error.message) || error) };
        try { callback(); } finally { lastError = undefined; }
      });
    },
    connect(extensionId, info) {
      if (installed.has(extensionId) && typeof api.connect === "function") return api.connect(extensionId, info);
      // As in Chrome for an extension that isn't there: a port that closes at once.
      const onDisconnect = event();
      const port = {
        name: (info && info.name) || "",
        onMessage: event(),
        onDisconnect,
        postMessage() {},
        disconnect() {},
      };
      setTimeout(() => {
        lastError = { message: absent().message };
        try { onDisconnect.fire(port); } finally { lastError = undefined; }
      }, 0);
      return port;
    },
  };
  const chrome = globalThis.chrome || {};
  try {
    Object.defineProperty(chrome, "runtime", { value: runtime, configurable: true, writable: true, enumerable: true });
    if (!globalThis.chrome) Object.defineProperty(globalThis, "chrome", { value: chrome, configurable: true, writable: true, enumerable: false });
  } catch {}
})();

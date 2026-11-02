// Nuri — core helpers, injected at document start in every frame (isolated world).
(() => {
  if (window.__nuriCore) return;
  window.__nuriCore = true;

  // 1. Remember the link / image under a right-click so the native context menu can offer
  //    "Open in background tab" and "Open in private tab". The message is sent while the
  //    event is dispatched, i.e. before WebKit asks the app to show the menu.
  document.addEventListener('contextmenu', (event) => {
    let link = null;
    let image = null;
    for (const el of event.composedPath ? event.composedPath() : []) {
      if (!link && el.tagName === 'A' && el.href) link = el;
      if (!image && el.tagName === 'IMG') image = el;
    }
    // Selected text, for "Send to Nuri Notes" (never what is selected in a password field).
    let selection = '';
    try {
      const active = document.activeElement;
      const secret = active && active.tagName === 'INPUT' && active.type === 'password';
      if (!secret) selection = String(window.getSelection() || '').slice(0, 20000);
    } catch (_) {}
    try {
      window.webkit.messageHandlers.nuriContext.postMessage({
        href: link ? String(link.href) : '',
        image: image ? (image.currentSrc || image.src || '') : '',
        selection
      });
    } catch (_) {}
  }, true);

  // 2. Embedded players (YouTube, Vimeo… in iframes) often lack allow="picture-in-picture".
  //    Add it as soon as an iframe is inserted, before its document is created. Fullscreen only
  //    for known video players: any other frame (an ad…) keeps what the site decided.
  const PLAYERS = /(^|\.)(youtube\.com|youtube-nocookie\.com|vimeo\.com|dailymotion\.com|twitch\.tv|streamable\.com|wistia\.(com|net)|jwplayer\.com|brightcove\.net|arte\.tv|francetv\.fr|ina\.fr|peertube\.[a-z.]+)$/i;
  const isPlayer = (frame) => {
    try { return PLAYERS.test(new URL(frame.getAttribute('src') || '', location.href).hostname); } catch (_) { return false; }
  };
  const patch = (frame) => {
    const player = isPlayer(frame);
    let allow = frame.getAttribute('allow') || '';
    const add = [];
    if (!/picture-in-picture/.test(allow)) add.push('picture-in-picture');
    if (player && !/fullscreen/.test(allow)) add.push('fullscreen');
    if (add.length) frame.setAttribute('allow', (allow ? allow.replace(/;?\s*$/, '; ') : '') + add.join('; '));
    if (player && !frame.hasAttribute('allowfullscreen')) frame.setAttribute('allowfullscreen', '');
  };
  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType !== 1) continue;
        if (node.tagName === 'IFRAME') patch(node);
        else if (node.firstElementChild) node.querySelectorAll('iframe').forEach(patch);
      }
    }
  });
  observer.observe(document, { childList: true, subtree: true });
})();

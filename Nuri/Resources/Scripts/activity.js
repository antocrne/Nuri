// Nuri — page activity for the tab UI, injected at document start in every frame (isolated world).
//  1. Reading progress (main frame only): how far the page is scrolled, 0…1, throttled.
//  2. Typed text (every frame): the first trusted input into a text field marks the tab as
//     "in use", so it is never put to sleep automatically while the text could be lost.
(() => {
  if (window.__nuriActivity) return;
  window.__nuriActivity = true;

  const post = (message) => {
    try { window.webkit.messageHandlers.nuriActivity.postMessage(message); } catch (_) {}
  };

  if (window === window.top) {
    let last = -1;
    let timer = null;
    const report = () => {
      timer = null;
      const root = document.scrollingElement || document.documentElement;
      if (!root) return;
      const max = root.scrollHeight - window.innerHeight;
      const value = max > 40 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
      if (Math.abs(value - last) < 0.004 && !(value === 1 && last !== 1)) return;
      last = value;
      post({ type: 'scroll', value });
    };
    const schedule = () => { if (!timer) timer = setTimeout(report, 100); };
    addEventListener('scroll', schedule, { passive: true });
    addEventListener('resize', schedule, { passive: true });
    addEventListener('load', schedule);
    // Back/forward cache: the page comes back without reloading this script.
    addEventListener('pageshow', () => { last = -1; schedule(); });
  }

  // A notification shown by the page, on a site the user allowed (notification-page.js).
  addEventListener('nurinotification', (event) => {
    try { post(Object.assign(JSON.parse(event.detail), { type: 'notification' })); } catch (_) {}
  });

  // A press of the mouse, with the link pressed (or none): a window the page opens from it is
  // judged by that (PopupGuard). Heard before the page's own listeners, which come after this
  // script: an ad opening its window from this very press finds it already said.
  addEventListener('pointerdown', (event) => {
    if (!event.isTrusted) return;
    const path = event.composedPath ? event.composedPath() : [];
    let link = path.find((node) => node && (node.tagName === 'A' || node.tagName === 'AREA') && node.href);
    // A link laid over the page to catch any click (see-through, or covering most of the window)
    // is no link the user chose: an ad's.
    if (link && link.tagName === 'A') {
      const box = link.getBoundingClientRect();
      const style = getComputedStyle(link);
      const covering = box.width * box.height > 0.5 * innerWidth * innerHeight;
      if (covering || Number(style.opacity) < 0.05 || style.visibility === 'hidden') link = null;
    }
    // A button (or what says it is one): made to be pressed, unlike text, a picture or a blank area.
    const control = !link && path.some((node) => node && node.nodeType === 1 && (node.tagName === 'BUTTON'
      || (node.tagName === 'INPUT' && /^(button|submit|image)$/i.test(node.type || ''))
      || /^(button|menuitem|link)$/i.test(node.getAttribute('role') || '')));
    post({ type: 'press', link: link ? String(link.href) : '', control });
  }, true);

  const nonText = /^(checkbox|radio|range|color|file|submit|button|reset|image|hidden)$/i;
  let typed = false;
  addEventListener('input', (event) => {
    if (typed || !event.isTrusted) return;
    const target = event.composedPath ? event.composedPath()[0] : event.target;
    if (!target) return;
    const editable = target.isContentEditable || target.tagName === 'TEXTAREA'
      || (target.tagName === 'INPUT' && !nonText.test(target.type || ''));
    if (!editable) return;
    typed = true;
    post({ type: 'input' });
  }, true);
})();

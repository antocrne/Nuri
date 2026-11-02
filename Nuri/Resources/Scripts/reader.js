// Nuri — reader mode extraction. Evaluated on demand in the main frame (isolated world).
// Returns { title, byline, site, published, html, text, words, lang, url } or null.
// The returned HTML is rebuilt from an allow-list of tags/attributes in an inert document,
// and is later displayed in a web view with JavaScript disabled.
(() => {
  const doc = document;
  const meta = (...names) => {
    for (const n of names) {
      const m = doc.querySelector(`meta[property="${n}"], meta[name="${n}"]`);
      if (m && m.content) return m.content.trim();
    }
    return '';
  };
  const text = (el) => (el && el.textContent ? el.textContent.trim() : '');

  const title = meta('og:title', 'twitter:title') || text(doc.querySelector('h1')) || doc.title;
  const byline = (meta('author', 'article:author', 'parsely-author') ||
                  text(doc.querySelector('[rel=author], .byline, [itemprop=author]'))).slice(0, 120);
  const site = meta('og:site_name', 'application-name') || location.hostname.replace(/^www\./, '');
  const published = meta('article:published_time', 'date', 'pubdate');

  const POSITIVE = /article|body|content|entry|main|page|post|text|blog|story|prose|markdown/i;
  const NEGATIVE = /comment|meta|foot|sidebar|sponsor|\bads?\b|advert|promo|related|share|social|nav|menu|widget|banner|cookie|newsletter|subscribe|popup|modal|breadcrumb|pagination|recommend|outbrain|taboola/i;
  const signature = (el) => (typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '');
  const classWeight = (el) => {
    const s = signature(el);
    let w = 0;
    if (POSITIVE.test(s)) w += 25;
    if (NEGATIVE.test(s)) w -= 25;
    if (el.tagName === 'ARTICLE') w += 20;
    if (el.tagName === 'MAIN') w += 10;
    return w;
  };
  const linkDensity = (el) => {
    const total = text(el).length || 1;
    let links = 0;
    el.querySelectorAll('a').forEach((a) => { links += text(a).length; });
    return links / total;
  };

  // 1. Pick the container that holds most of the prose.
  let root = doc.querySelector('[itemprop=articleBody]');
  if (!root) {
    const scores = new Map();
    const add = (el, s) => {
      if (!el || el === doc.documentElement) return;
      if (!scores.has(el)) scores.set(el, classWeight(el));
      scores.set(el, scores.get(el) + s);
    };
    doc.querySelectorAll('p, pre, blockquote').forEach((p) => {
      const len = text(p).length;
      if (len < 25 || p.closest('nav, aside, footer, form')) return;
      const s = 1 + text(p).split(/[,،，]/).length + Math.min(Math.floor(len / 100), 3);
      add(p.parentElement, s);
      if (p.parentElement) add(p.parentElement.parentElement, s / 2);
      if (p.parentElement && p.parentElement.parentElement) add(p.parentElement.parentElement.parentElement, s / 3);
    });
    let bestScore = 0;
    scores.forEach((score, el) => {
      const adjusted = score * (1 - linkDensity(el));
      if (adjusted > bestScore) { bestScore = adjusted; root = el; }
    });
  }
  if (!root) return null;

  // 2. Resolve lazy-loaded images on a copy.
  const clone = root.cloneNode(true);
  const lastSrcsetURL = (srcset) => srcset.split(',').pop().trim().split(/\s+/)[0];
  clone.querySelectorAll('img').forEach((img) => {
    const lazy = img.getAttribute('data-src') || img.getAttribute('data-lazy-src') ||
                 img.getAttribute('data-original') || img.getAttribute('data-url');
    if (lazy) img.setAttribute('src', lazy);
    const src = img.getAttribute('src') || '';
    const srcset = img.getAttribute('data-srcset') || img.getAttribute('srcset');
    if ((!src || src.startsWith('data:')) && srcset) img.setAttribute('src', lastSrcsetURL(srcset));
  });
  clone.querySelectorAll('picture').forEach((picture) => {
    const img = picture.querySelector('img');
    const source = picture.querySelector('source[srcset], source[data-srcset]');
    if (img && source && (!img.getAttribute('src') || img.getAttribute('src').startsWith('data:'))) {
      img.setAttribute('src', lastSrcsetURL(source.getAttribute('srcset') || source.getAttribute('data-srcset')));
    }
  });
  clone.querySelectorAll('noscript').forEach((ns) => {
    const m = /<img[^>]+src=["']([^"']+)/i.exec(ns.textContent || '');
    if (m) { const img = doc.createElement('img'); img.setAttribute('src', m[1]); ns.replaceWith(img); }
  });

  // 3. Rebuild a clean tree from an allow-list, in an inert document.
  const ALLOWED = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'IMG', 'FIGURE', 'FIGCAPTION', 'BLOCKQUOTE',
    'PRE', 'CODE', 'UL', 'OL', 'LI', 'A', 'EM', 'STRONG', 'B', 'I', 'U', 'S', 'SUB', 'SUP', 'BR', 'HR', 'TABLE',
    'THEAD', 'TBODY', 'TR', 'TH', 'TD', 'DL', 'DT', 'DD', 'DIV', 'SECTION', 'ARTICLE', 'MARK', 'SMALL', 'TIME',
    'ABBR', 'Q', 'CITE', 'CAPTION', 'SPAN']);
  const DROP = new Set(['SCRIPT', 'STYLE', 'IFRAME', 'FORM', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'NAV',
    'ASIDE', 'FOOTER', 'SVG', 'CANVAS', 'OBJECT', 'EMBED', 'VIDEO', 'AUDIO', 'LINK', 'META', 'NOSCRIPT',
    'TEMPLATE', 'DIALOG']);
  const out = doc.implementation.createHTMLDocument('');
  const walk = (node, parent) => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === 3) { parent.appendChild(out.createTextNode(child.textContent)); continue; }
      if (child.nodeType !== 1) continue;
      const tag = child.tagName;
      if (DROP.has(tag) || child.hidden || child.getAttribute('aria-hidden') === 'true') continue;
      if (tag !== 'IMG' && NEGATIVE.test(signature(child)) && (text(child).length < 300 || linkDensity(child) > 0.4)) continue;
      if (!ALLOWED.has(tag)) { walk(child, parent); continue; }
      const blockish = tag === 'DIV' || tag === 'SECTION' || tag === 'ARTICLE';
      const el = out.createElement(blockish ? 'div' : tag.toLowerCase());
      if (tag === 'A' && child.href && /^https?:/.test(child.href)) el.setAttribute('href', child.href);
      if (tag === 'IMG') {
        const raw = child.getAttribute('src');
        if (!raw) continue;
        let abs;
        try { abs = new URL(raw, location.href).href; } catch (_) { continue; }
        const width = parseInt(child.getAttribute('width') || '0', 10);
        if (!/^https?:/.test(abs) || (width && width < 48)) continue;
        el.setAttribute('src', abs);
        if (child.alt) el.setAttribute('alt', child.alt);
      }
      if (tag === 'TD' || tag === 'TH') {
        ['colspan', 'rowspan'].forEach((a) => { if (child.getAttribute(a)) el.setAttribute(a, child.getAttribute(a)); });
      }
      walk(child, el);
      if (!el.childNodes.length && !['IMG', 'BR', 'HR'].includes(tag)) continue;
      parent.appendChild(el);
    }
  };
  const container = out.createElement('div');
  walk(clone, container);

  const firstHeading = container.querySelector('h1');
  if (firstHeading && firstHeading.textContent.trim() === title.trim()) firstHeading.remove();

  const words = (container.textContent || '').trim().split(/\s+/).filter(Boolean).length;
  if (words < 60) return null;

  // 4. Plain text of the same tree (sent to Nuri Notes): one blank line between blocks.
  const BLOCKS = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'LI', 'BLOCKQUOTE', 'PRE', 'FIGCAPTION', 'TR',
    'DT', 'DD', 'DIV', 'HR', 'CAPTION']);
  let plain = '';
  const flatten = (node, pre) => {
    for (const child of node.childNodes) {
      if (child.nodeType === 3) {
        let piece = pre ? child.textContent : child.textContent.replace(/\s+/g, ' ');
        if (!pre && (!plain || plain.endsWith('\n'))) piece = piece.replace(/^ /, '');
        plain += piece;
      } else if (child.nodeType === 1) {
        if (child.tagName === 'BR') { plain += '\n'; continue; }
        flatten(child, pre || child.tagName === 'PRE');
        if (BLOCKS.has(child.tagName) && plain) plain = plain.trimEnd() + '\n\n';
      }
    }
  };
  flatten(container, false);

  return { title, byline, site, published, html: container.innerHTML, text: plain.trim(), words,
           lang: doc.documentElement.lang || '', url: location.href };
})()

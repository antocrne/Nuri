// Nuri — video detection and Picture in Picture, injected at document start in every frame
// (isolated world). Reports media state to the app and exposes window.__nuriMedia.
(() => {
  if (window.__nuriMedia) return;

  // One id per document: the app keys its media state by it. A frame's URL isn't stable
  // (sites change it without reloading, e.g. from one video to the next), and an entry
  // stored under an old URL would stay "playing" forever.
  const frameId = Math.random().toString(36).slice(2);
  const post = (msg) => {
    try { window.webkit.messageHandlers.nuriMedia.postMessage(Object.assign({ frame: frameId }, msg)); } catch (_) {}
  };
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const EVENTS = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'volumechange',
                  'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'];

  // Media events don't leave a shadow root: players built as web components (Reddit…) are
  // listened to directly, as they are found.
  const bound = new WeakSet();
  const bind = (list) => {
    for (const v of list) {
      if (bound.has(v) || v.getRootNode() === document) continue;
      bound.add(v);
      EVENTS.forEach((name) => v.addEventListener(name, () => report(name)));
    }
    return list;
  };

  // <video> elements, including those in open shadow roots (searched only if needed).
  const collect = (root, out, depth) => {
    root.querySelectorAll('video').forEach((v) => out.push(v));
    if (depth > 0) {
      root.querySelectorAll('*').forEach((el) => { if (el.shadowRoot) collect(el.shadowRoot, out, depth - 1); });
    }
    return out;
  };
  const videos = () => {
    const light = collect(document, [], 0);
    return light.length ? light : bind(collect(document, [], 3));
  };

  // A video that seeks or buffers has no data for a moment but is still playing: reporting it
  // stopped would make the tab's indicators blink at every jump in the video.
  const isPlaying = (v) => !v.paused && !v.ended && (v.readyState > 2 || v.seeking || v.currentTime > 0);
  const area = (el) => { const r = el.getBoundingClientRect(); return Math.max(0, r.width) * Math.max(0, r.height); };
  const inPiP = (v) => document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture';
  const audible = (v) => !v.muted && v.volume > 0;

  // The "main" video: playing first, then the largest one.
  const best = () => {
    const list = videos().filter((v) => v.readyState > 0 || v.currentSrc || v.src);
    list.sort((a, b) => (Number(isPlaying(b)) - Number(isPlaying(a))) || (area(b) - area(a)));
    return list[0] || null;
  };

  const state = () => {
    const all = videos();
    const main = best();
    const playing = all.filter((v) => isPlaying(v) && (area(v) > 0 || inPiP(v)));
    return {
      hasVideo: !!main && (main.duration > 0 || isPlaying(main)),
      playing: playing.length > 0,
      audible: playing.some(audible),
      inPiP: all.some(inPiP),
      currentTime: main ? main.currentTime : 0,
      paused: main ? main.paused : true,
      isMainFrame: window === window.top
    };
  };

  // While a video is reported playing, the state is checked again every few seconds: a playing
  // video removed from the page (feeds that recycle their posts, a closed player) pauses away
  // from the document, so its "pause" never reaches the listeners below, and the tab would stay
  // "playing" (never put to sleep, kept attached to the window) until the next page load.
  let timer = 0;
  let watchdog = 0;
  const signature = (s) => [s.hasVideo, s.playing, s.audible, s.inPiP].join();
  const NOTHING = signature({ hasVideo: false, playing: false, audible: false, inPiP: false });
  let last = NOTHING;
  let reported = false;
  const send = (type) => {
    reported = true;
    const current = state();
    last = signature(current);
    post(Object.assign({ type }, current));
    const active = current.playing || current.audible || current.inPiP;
    if (active && !watchdog) {
      watchdog = setInterval(() => {
        if (signature(state()) !== last) send('watchdog');
      }, 3000);
    } else if (!active && watchdog) {
      clearInterval(watchdog);
      watchdog = 0;
    }
  };
  const report = (type) => {
    clearTimeout(timer);
    const immediate = /picture|presentation/.test(type);
    timer = setTimeout(() => send(type), immediate ? 0 : 120);
  };
  EVENTS.forEach((name) => document.addEventListener(name, () => report(name), true));

  // After a click or a key, look again: a player created in a shadow root since the last look
  // (feeds) gets its listeners, and a change nobody reported is sent.
  let rescan = 0;
  const onInteraction = () => {
    clearTimeout(rescan);
    rescan = setTimeout(() => { if (signature(state()) !== last) send('interaction'); }, 600);
  };
  ['pointerup', 'keyup'].forEach((name) => document.addEventListener(name, onInteraction, true));

  // The page goes away (navigation, iframe removed, back/forward cache): its entry is dropped
  // in the app, and nothing more is sent until it's shown again.
  addEventListener('pagehide', () => {
    clearTimeout(timer);
    clearTimeout(rescan);
    clearInterval(watchdog);
    watchdog = 0;
    last = NOTHING;
    if (reported) post({ type: 'gone', hasVideo: false, playing: false, audible: false, inPiP: false });
  });
  addEventListener('pageshow', (event) => { if (event.persisted && reported) report('pageshow'); });

  async function enterPiP() {
    const v = best();
    if (!v) return 'fail:no-video';
    if (inPiP(v)) return 'ok:already';
    // Sites can opt out with disablePictureInPicture; the user explicitly asked, so lift it.
    if (v.hasAttribute('disablepictureinpicture')) v.removeAttribute('disablepictureinpicture');
    try { v.disablePictureInPicture = false; } catch (_) {}

    let error = '';
    if (typeof v.requestPictureInPicture === 'function' && document.pictureInPictureEnabled !== false) {
      try {
        await v.requestPictureInPicture();
        return 'ok:standard';
      } catch (e) { error = 'standard:' + (e && e.name); }
    }
    if (typeof v.webkitSetPresentationMode === 'function' &&
        (!v.webkitSupportsPresentationMode || v.webkitSupportsPresentationMode('picture-in-picture'))) {
      try {
        v.webkitSetPresentationMode('picture-in-picture');
        for (let i = 0; i < 15; i++) {
          await wait(100);
          if (inPiP(v)) return 'ok:webkit';
        }
        error += ' webkit:timeout';
      } catch (e) { error += ' webkit:' + (e && e.name); }
    }
    return 'fail:' + (error || 'unsupported');
  }

  async function exitPiP() {
    try { if (document.pictureInPictureElement) await document.exitPictureInPicture(); } catch (_) {}
    videos().forEach((v) => {
      try { if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline'); } catch (_) {}
    });
    return 'ok';
  }

  async function play(volume) {
    const v = best() || videos()[0];
    if (!v) return 'fail:no-video';
    try {
      if (typeof volume === 'number') { v.muted = false; v.volume = volume; }
      // play() can stay pending while buffering: don't wait for it forever.
      const result = await Promise.race([v.play().then(() => 'ok'), wait(3000).then(() => 'pending')]);
      return result;
    } catch (e) { return 'fail:' + (e && e.name); }
  }

  // Announce frames that contain a <video> even before playback (embedded players create
  // it early but load it on click), so ⌘⇧P / the app can target that frame.
  let announced = false;
  const announce = () => {
    if (announced || !videos().length) return false;
    announced = true;
    report('present');
    return true;
  };
  const watchForVideo = () => {
    if (announce() || !document.documentElement) return;
    const observer = new MutationObserver(() => { if (announce()) observer.disconnect(); });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    setTimeout(() => observer.disconnect(), 30000);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchForVideo, { once: true });
  else watchForVideo();

  // Plan B: make the video (or the iframe holding it) fill the viewport, so the web view
  // itself can be shown in Nuri's floating window. Everything else is hidden, not removed.
  let floated = null;
  function float(on) {
    const STYLE_ID = '__nuri_float_style';
    if (!on) {
      const style = document.getElementById(STYLE_ID);
      if (style) style.remove();
      document.querySelectorAll('.__nuri_fl_anc, .__nuri_fl_target')
        .forEach((el) => el.classList.remove('__nuri_fl_anc', '__nuri_fl_target'));
      if (floated && floated.video) floated.video.controls = floated.controls;
      floated = null;
      return 'ok';
    }
    let target = best();
    if (target) {
      floated = { video: target, controls: target.controls };
      target.controls = true;
    } else {
      target = [...document.querySelectorAll('iframe')].sort((a, b) => area(b) - area(a))[0];
      if (!target) return 'fail:no-target';
      floated = { video: null };
    }
    target.classList.add('__nuri_fl_target');
    for (let p = target.parentElement; p; p = p.parentElement) p.classList.add('__nuri_fl_anc');
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      html, body { overflow: hidden !important; background: #000 !important; }
      .__nuri_fl_anc { transform: none !important; filter: none !important; contain: none !important;
                        overflow: visible !important; visibility: visible !important; animation: none !important; }
      body *:not(.__nuri_fl_anc):not(.__nuri_fl_target) { visibility: hidden !important; }
      .__nuri_fl_target { visibility: visible !important; position: fixed !important; inset: 0 !important;
                          width: 100vw !important; height: 100vh !important; max-width: none !important;
                          max-height: none !important; margin: 0 !important; transform: none !important;
                          z-index: 2147483647 !important; object-fit: contain !important; background: #000 !important; }`;
    (document.head || document.documentElement).appendChild(style);
    return 'ok';
  }

  window.__nuriMedia = { state, enterPiP, exitPiP, play, float };
})();

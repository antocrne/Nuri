// Nuri — sound in screen sharing, injected at document start in every frame (isolated world).
// The frame that shares its screen: answers shareaudio-page.js with an audio track, fed by the
// app with the sound of the other apps and of Nuri's other tabs (window.__nuriShareAudio.play).
// Every other frame: while a share with sound is on, the sound of its <video> and <audio> goes
// to the app (window.__nuriShareAudio.capture), which passes it on to the sharing frame.
// Sound travels as 16-bit stereo PCM in base64.
(() => {
  if (window.__nuriShareAudio) return;
  const ask = (msg) => {
    try { return window.webkit.messageHandlers.nuriShareAudio.postMessage(msg); } catch (_) { return Promise.resolve(null); }
  };

  // MARK: The frame that shares its screen

  let receiver = null;

  const stopReceiving = (tell) => {
    if (!receiver) return;
    clearInterval(receiver.timer);
    receiver.track.stop();
    receiver.context.close().catch(() => {});
    receiver = null;
    if (tell) ask({ type: 'stop' });
  };

  // The track lives as long as the picture: stopped by the page, the user or macOS.
  const startReceiving = (video) => {
    stopReceiving(true);
    const context = new AudioContext();
    const destination = context.createMediaStreamDestination();
    const track = destination.stream.getAudioTracks()[0];
    const r = { context, destination, track, next: new Map() };
    const check = () => {
      if (receiver === r && (video.readyState === 'ended' || track.readyState === 'ended')) stopReceiving(true);
    };
    video.addEventListener('ended', check);
    r.timer = setInterval(check, 1000);
    receiver = r;
    return destination.stream;
  };

  document.addEventListener('nurishareaudio', async (event) => {
    const holder = event.target;
    if (!(holder instanceof HTMLAudioElement)) return;
    const given = holder.srcObject;
    const video = given && given.getVideoTracks && given.getVideoTracks()[0];
    let stream = null;
    if (video && video.readyState === 'live' && await ask({ type: 'start' }) === true) {
      stream = startReceiving(video);
    }
    if (stream) holder.srcObject = stream;
    holder.dispatchEvent(new Event('nurishareaudioready'));
  }, true);

  // `source`: who sent it (another tab, the other apps), each scheduled after its previous chunk.
  const play = (source, rate, data) => {
    if (!receiver) return false;
    const bytes = atob(data);
    const frames = bytes.length >> 2;
    if (!frames) return true;
    const { context } = receiver;
    const buffer = context.createBuffer(2, frames, rate);
    const left = buffer.getChannelData(0), right = buffer.getChannelData(1);
    for (let i = 0, o = 0; i < frames; i++, o += 4) {
      const l = bytes.charCodeAt(o) | (bytes.charCodeAt(o + 1) << 8);
      const r = bytes.charCodeAt(o + 2) | (bytes.charCodeAt(o + 3) << 8);
      left[i] = (l > 32767 ? l - 65536 : l) / 32768;
      right[i] = (r > 32767 ? r - 65536 : r) / 32768;
    }
    const node = context.createBufferSource();
    node.buffer = buffer;
    node.connect(receiver.destination);
    // A little ahead, so that chunks arriving unevenly still follow each other without a gap;
    // too far behind or ahead (a pause, a drifting clock), it starts again from now.
    const now = context.currentTime;
    let at = receiver.next.get(source) || 0;
    if (at < now + 0.01 || at > now + 0.5) at = now + 0.12;
    node.start(at);
    stats.played++;
    receiver.next.set(source, at + buffer.duration);
    return true;
  };

  // MARK: The other frames

  let context = null;
  let tap = null;
  let sending = false;
  let announced = false;
  // For the self-tests.
  const stats = { hooked: 0, sent: 0, played: 0, calls: 0 };
  const hooked = new WeakSet();

  // Once in a Web Audio graph, an element is only heard through it: an element whose sound the
  // page can't read (another site's file without CORS, a protected video) would fall silent.
  // Those are left alone, as are calls (an element showing a MediaStream) and looping elements
  // (WebKit stops them for good at the end of a turn once they are in a graph).
  const eligible = (el) => {
    if (el.srcObject || el.mediaKeys || el.webkitKeys || el.loop) return false;
    const src = el.currentSrc || el.src;
    if (!src) return false;
    if (el.crossOrigin !== null) return true;
    try {
      const url = new URL(src, location.href);
      return url.protocol === 'blob:' || url.protocol === 'data:' || url.origin === location.origin;
    } catch (_) {
      return false;
    }
  };

  const toBase64 = (bytes) => {
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };

  const send = (event) => {
    stats.calls++;
    if (!sending) return;
    const input = event.inputBuffer;
    const left = input.getChannelData(0);
    const right = input.numberOfChannels > 1 ? input.getChannelData(1) : left;
    const pcm = new Int16Array(left.length * 2);
    let heard = false;
    for (let i = 0; i < left.length; i++) {
      const l = Math.max(-1, Math.min(1, left[i])), r = Math.max(-1, Math.min(1, right[i]));
      if (l || r) heard = true;
      pcm[2 * i] = l * 32767;
      pcm[2 * i + 1] = r * 32767;
    }
    if (!heard) return;
    stats.sent++;
    ask({ type: 'chunk', rate: input.sampleRate, data: toBase64(new Uint8Array(pcm.buffer)) });
  };

  const hook = (el) => {
    if (hooked.has(el) || !eligible(el) || !context || context.state !== 'running') return;
    try {
      const source = context.createMediaElementSource(el);
      source.connect(context.destination);
      source.connect(tap);
      hooked.add(el);
      stats.hooked++;
    } catch (_) {}
  };

  // WebKit only starts a context for a page on screen: a tab in the background is taken once
  // shown (a running context goes on in the background). A suspended context would mute the
  // elements it took: nothing is taken until it runs.
  let resuming = null;
  let retry = 0;
  const running = async () => {
    if (context.state !== 'running') {
      resuming = resuming || context.resume().catch(() => {}).finally(() => { resuming = null; });
      await Promise.race([resuming, new Promise((resolve) => setTimeout(resolve, 500))]);
    }
    return sending && context.state === 'running';
  };
  const hookAll = () => document.querySelectorAll('video, audio').forEach(hook);

  const capture = async (on) => {
    sending = on;
    clearInterval(retry);
    retry = 0;
    if (!on) return;
    if (!context) {
      context = new AudioContext();
      tap = context.createScriptProcessor(4096, 2, 2);
      tap.onaudioprocess = send;
      tap.connect(context.destination);
    }
    if (await running()) return hookAll();
    if (!sending || retry) return;
    retry = setInterval(async () => {
      if (!sending || await running()) {
        clearInterval(retry);
        retry = 0;
        if (sending) hookAll();
      }
    }, 1500);
  };

  // The app only asks the frames that have played something (a frame can't be reached otherwise).
  document.addEventListener('play', (event) => {
    const el = event.target;
    if (!(el instanceof HTMLMediaElement)) return;
    if (!announced) {
      announced = true;
      ask({ type: 'media' });
    }
    if (sending) hook(el);
  }, true);

  window.__nuriShareAudio = { play, capture, eligible,
    stats: () => JSON.stringify(Object.assign({ context: context && context.state, receiver: receiver && receiver.context.state,
      media: [...document.querySelectorAll('video, audio')].map((el) => `${el.paused ? 'pause' : 'lecture'}@${el.currentTime.toFixed(2)}`).join() }, stats)) };
})();

// Nuri — sound in screen sharing, on the page's side. WebKit's getDisplayMedia only ever gives
// the picture (Safari's too): when the user ticked « Partager aussi le son » in Nuri's question,
// the stream gets an audio track made by Nuri (shareaudio.js). Injected in the page's own world,
// at document start in every frame, so that the page's scripts only ever see the wrapped
// function. The track comes from Nuri's isolated world through an <audio> element: the only
// object both worlds see.
(() => {
  const proto = window.MediaDevices && MediaDevices.prototype;
  const original = proto && proto.getDisplayMedia;
  if (typeof original !== 'function') return;

  const withSound = (stream) => {
    const video = stream.getVideoTracks()[0];
    if (!video || stream.getAudioTracks().length) return stream;
    const holder = document.createElement('audio');
    holder.hidden = true;
    holder.srcObject = new MediaStream([video]);
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        const given = holder.srcObject;
        holder.srcObject = null;
        holder.remove();
        const audio = given && given.getAudioTracks()[0];
        if (audio) stream.addTrack(audio);
        resolve(stream);
      };
      holder.addEventListener('nurishareaudioready', finish, { once: true });
      // Nuri answers at once; if its script is missing, the page still gets its picture.
      setTimeout(finish, 4000);
      (document.documentElement || document).appendChild(holder);
      holder.dispatchEvent(new Event('nurishareaudio', { bubbles: true }));
    });
  };

  const getDisplayMedia = {
    getDisplayMedia(...args) { return original.apply(this, args).then(withSound); }
  }.getDisplayMedia;
  Object.defineProperty(proto, 'getDisplayMedia', { value: getDisplayMedia, writable: true, configurable: true, enumerable: true });
})();

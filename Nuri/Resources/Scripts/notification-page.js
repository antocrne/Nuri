// Nuri — web notifications, on the page's side. WebKit tells a page it may notify but shows nothing
// by itself. Run in the page's own world, and only on a site the user allowed (WebNotifications):
// what the page shows goes to Nuri's isolated world (activity.js), the only way out of this one, and
// macOS shows it. A click on it comes back as the notification's own click event.
(() => {
  const Native = window.Notification;
  if (!Native || Native.nuriWrapped) return;
  const shown = new Map();
  let next = 1;

  function Notification(title, options) {
    if (!new.target) throw new TypeError("Notification must be called with new");
    const made = new Native(title, options);
    if (Native.permission === "granted") {
      const id = String(next++);
      shown.set(id, made);
      const detail = JSON.stringify({ id, title: String(title), body: String((options && options.body) || ""), tag: String((options && options.tag) || "") });
      window.dispatchEvent(new CustomEvent("nurinotification", { detail }));
      setTimeout(() => made.dispatchEvent(new Event("show")), 0);
    }
    return made;
  }
  Notification.prototype = Native.prototype;
  Object.setPrototypeOf(Notification, Native);
  Object.defineProperty(Notification, "nuriWrapped", { value: true });
  window.Notification = Notification;

  window.addEventListener("nurinotificationclick", (event) => {
    const made = shown.get(event.detail);
    if (made) made.dispatchEvent(new Event("click"));
  });
})();

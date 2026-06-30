window.LifeOS = {
  track(type, label, value) {
    fetch("/api/events", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        type,
        label: label || "",
        value: value || "",
        path: location.pathname,
        source: new URLSearchParams(location.search).get("utm_source") || document.referrer || "direct"
      })
    }).catch(() => {});
  },
  async post(url, data) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(data)
    });
    return res.json();
  },
  async get(url) {
    const res = await fetch(url, { credentials: "same-origin" });
    return res.json();
  }
};

document.addEventListener("click", e => {
  const a = e.target.closest("a[data-track]");
  if (a) window.LifeOS.track("cta_click", a.dataset.track, a.getAttribute("href"));
});

window.addEventListener("load", () => {
  window.LifeOS.track("page_loaded", document.title, location.pathname);
});

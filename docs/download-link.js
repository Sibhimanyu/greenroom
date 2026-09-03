// Prefer the DMG. The Download buttons are committed pointing at whatever the
// release script built (release.sh -> scripts/site-download-link.sh). A DMG is
// sometimes uploaded by hand hours later, so at view time ask GitHub for the
// latest release once and, if it carries a .dmg, point every button at it.
// No JS, no API, or no DMG: the committed link stands.
(function () {
  var buttons = document.querySelectorAll('a.btn[href*="/releases/download/"]');
  if (!buttons.length || !window.fetch) return;
  fetch("https://api.github.com/repos/Sibhimanyu/greenroom/releases/latest", {
    headers: { Accept: "application/vnd.github+json" }
  })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (release) {
      if (!release || !release.assets) return;
      var dmg = release.assets.filter(function (a) { return /\.dmg$/.test(a.name); })[0];
      if (!dmg) return;
      buttons.forEach(function (b) { b.href = dmg.browser_download_url; });
    })
    .catch(function () {});
})();

// The Download buttons point at the newest DMG, not the newest release: a
// disk image is the friendlier first install, and Sparkle brings a fresh
// install up to the current version on first launch anyway. The buttons are
// committed pointing at the newest DMG the release script knew about
// (release.sh -> scripts/site-download-link.sh); at view time, ask GitHub
// for recent releases and, if a newer one carries a .dmg, point at that.
// No JS, no API, or no DMG anywhere: the committed link stands.
(function () {
  var buttons = document.querySelectorAll('a.btn[href*="/releases/download/"]');
  if (!buttons.length || !window.fetch) return;
  fetch("https://api.github.com/repos/Sibhimanyu/greenroom/releases?per_page=15", {
    headers: { Accept: "application/vnd.github+json" }
  })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (releases) {
      if (!Array.isArray(releases)) return;
      // Newest first, skipping drafts and prereleases.
      for (var i = 0; i < releases.length; i++) {
        var release = releases[i];
        if (release.draft || release.prerelease || !release.assets) continue;
        var dmg = release.assets.filter(function (a) { return /\.dmg$/.test(a.name); })[0];
        if (dmg) {
          buttons.forEach(function (b) { b.href = dmg.browser_download_url; });
          return;
        }
      }
    })
    .catch(function () {});
})();

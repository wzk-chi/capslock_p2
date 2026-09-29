/* Shared Lucide adapter for every local WebView2 page. Keep the library
   itself vendored so panels remain fully usable without network access. */
(function () {
  'use strict';

  const SAFE_ICON_NAME = /^[a-z0-9-]+$/i;

  function createIcon(name, className = '') {
    const icon = document.createElement('i');
    icon.setAttribute('data-lucide', SAFE_ICON_NAME.test(String(name)) ? String(name) : 'circle');
    icon.setAttribute('aria-hidden', 'true');
    if (className) icon.className = className;
    return icon;
  }

  function refreshIcons() {
    if (!window.lucide || typeof window.lucide.createIcons !== 'function')
      return;
    if (window.WindowBar && typeof window.WindowBar.debug === 'function')
      window.WindowBar.debug('icons:refresh:start');
    try {
      window.lucide.createIcons({
        attrs: {
          'aria-hidden': 'true',
          focusable: 'false'
        }
      });
      if (window.WindowBar && typeof window.WindowBar.debug === 'function')
        window.WindowBar.debug('icons:refresh:done');
    } catch {
      // Icons are decorative; a missing icon must not stop page behavior.
      if (window.WindowBar && typeof window.WindowBar.debug === 'function')
        window.WindowBar.debug('icons:refresh:error');
    }
  }

  window.createIcon = createIcon;
  window.refreshIcons = refreshIcons;

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', refreshIcons, { once: true });
  else
    refreshIcons();
})();

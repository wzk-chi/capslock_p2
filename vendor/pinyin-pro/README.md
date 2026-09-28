# pinyin-pro runtime asset

This directory contains the official browser distribution of `pinyin-pro`
3.29.4. Qbar loads the file locally from the installed application directory;
it does not use a CDN and does not download a dependency at runtime.

- Upstream: https://github.com/zh-lx/pinyin-pro
- Package: https://www.npmjs.com/package/pinyin-pro/v/3.29.4
- Browser file: `dist/index.js`
- Download source: https://cdn.jsdelivr.net/npm/pinyin-pro@3.29.4/dist/index.js
- SHA-256: `1F660D2A52B762A291E219994777FF7CD3A38C841863F556B46ECD06955096A7`
- License: `LICENSE` (MIT)

The vendored file is used only for Qbar's local pinyin index. To upgrade it,
replace the file with the same official package path, update the version and
hash above, and review the browser global/API before packaging.

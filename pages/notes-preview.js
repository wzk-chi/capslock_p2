/* capslock_p2 — notes list preview rows.
 *
 * The list card used to be built by a hand-written Markdown parser in AHK
 * (NotesStorePreviewBlocks), which had to re-implement inline Markdown rules
 * that the renderer already knows. This module starts from Markdown rendered by
 * Vditor and walks the resulting DOM instead:
 *
 *   - the plain text a row copies is just its textContent, so "# 一级标题"
 *     already copies as "一级标题" with no stripping rules to keep in sync;
 *   - the row budget is spent on the rendered blocks, so the preview shows what
 *     the note actually looks like (images, code, tables) rather than
 *     placeholders.
 *
 * Pure DOM walking with no Vditor dependency, so it can be exercised against a
 * plain DOM.
 */
(function (global) {
  'use strict';

  var DEFAULTS = { maxRows: 12, maxCodeLines: 6, imageRows: 4 };

  // Vditor decorates its output with its own chrome (copy buttons, code
  // language labels, heading anchors). None of that is note content, so it is
  // dropped before the text is read.
  //
  // `stripChrome` covers chrome nested inside the block being read; `isChrome`
  // covers chrome that IS the block. Only leaf-ish chrome is listed here:
  // div.vditor-code is a wrapper around the real <pre> and is descended into.
  var CHROME_SELF = /(^|\s)vditor-(copy|anchor|tooltipped|panel|tip|resize)(\s|$)/;

  function isChrome(node) {
    return CHROME_SELF.test(node.getAttribute('class') || '');
  }

  function stripChrome(node) {
    var clone = node.cloneNode(true);
    var junk = clone.querySelectorAll('[class^="vditor-"],[class*=" vditor-"]');
    for (var i = 0; i < junk.length; i++) junk[i].remove();
    return clone;
  }

  function normalise(text) {
    return String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  }

  function plainText(node) {
    return normalise(stripChrome(node).textContent);
  }

  // Code keeps its line structure, so it is read from the code element rather
  // than from collapsed text.
  function codeText(node) {
    var clone = stripChrome(node);
    var code = clone.querySelector('code') || clone;
    return String(code.textContent == null ? '' : code.textContent)
      .replace(/\r\n/g, '\n').replace(/\n+$/, '');
  }

  function imageOf(node) {
    var clone = stripChrome(node);
    var img = clone.querySelector('img');
    if (!img) return null;
    // A paragraph that holds nothing but the image is an image row; text next
    // to it makes it a normal row that happens to contain an image.
    return normalise(clone.textContent) === '' ? img : null;
  }

  function headingLevel(tag) {
    return /^H[1-6]$/.test(tag) ? Number(tag.slice(1)) : 0;
  }

  function isBlockTag(tag) {
    return /^(P|DIV|SECTION|ARTICLE|PRE|BLOCKQUOTE|TABLE|UL|OL|H[1-6]|HR)$/.test(tag);
  }

  function rowsFor(node, marker, out) {
    var tag = node.tagName;
    if (isChrome(node)) return;
    if (tag === 'HR') { out.push({ kind: 'rule', cost: 1 }); return; }
    if (tag === 'UL' || tag === 'OL') {
      for (var i = 0; i < node.children.length; i++) {
        var li = node.children[i];
        if (li.tagName !== 'LI') continue;
        rowsFor(li, tag === 'OL' ? (i + 1) + '.' : '•', out);
      }
      return;
    }
    if (tag === 'BLOCKQUOTE') {
      var kids = node.children;
      var any = false;
      for (var j = 0; j < kids.length; j++) {
        if (isBlockTag(kids[j].tagName)) { rowsFor(kids[j], '▏', out); any = true; }
      }
      if (!any) out.push({ kind: 'text', node: node, marker: '▏', copy: plainText(node), cost: 1 });
      return;
    }
    if (tag === 'PRE') {
      var code = codeText(node);
      if (code === '') return;
      var lines = code.split('\n');
      var shown = Math.min(lines.length, DEFAULTS.maxCodeLines);
      out.push({
        kind: 'code', node: node, copy: code, cost: shown,
        display: lines.slice(0, shown).join('\n') + (lines.length > shown ? '\n…' : '')
      });
      return;
    }
    if (tag === 'TABLE') {
      out.push({ kind: 'table', node: node, copy: plainText(node), cost: 1 });
      return;
    }
    var img = imageOf(node);
    if (img) {
      out.push({ kind: 'image', node: node, img: img, src: img.getAttribute('src') || '',
                 alt: normalise(img.getAttribute('alt')), cost: DEFAULTS.imageRows });
      return;
    }
    // Vditor wraps some blocks in its own containers (a code block can arrive as
    // div.vditor-code holding the <pre>), so a wrapper with block children is
    // descended into instead of being flattened into one text row.
    if (/^(DIV|SECTION|ARTICLE)$/.test(tag)) {
      var inner = [];
      for (var k = 0; k < node.children.length; k++) {
        if (isBlockTag(node.children[k].tagName)) inner.push(node.children[k]);
      }
      if (inner.length) {
        for (var m = 0; m < inner.length; m++) rowsFor(inner[m], marker, out);
        return;
      }
    }
    var text = plainText(node);
    if (text === '') return;
    var level = headingLevel(tag);
    out.push({
      kind: level ? 'heading' : 'text', node: node, marker: marker, copy: text,
      level: level, cost: 1
    });
  }

  // Flattens rendered Markdown into individually copyable rows.
  function collect(rendered) {
    var out = [];
    var kids = rendered.children;
    for (var i = 0; i < kids.length; i++) rowsFor(kids[i], '', out);
    return out;
  }

  // Keeps whole rows until the budget is spent. A row that does not fit is
  // dropped rather than partly rendered, matching what the AHK parser did.
  function budget(rows, options) {
    var opts = options || {};
    var maxRows = opts.maxRows == null ? DEFAULTS.maxRows : opts.maxRows;
    var kept = [], used = 0;
    for (var i = 0; i < rows.length; i++) {
      var cost = rows[i].cost || 1;
      if (used + cost > maxRows) return { rows: kept, used: used, truncated: true };
      kept.push(rows[i]);
      used += cost;
    }
    return { rows: kept, used: used, truncated: false };
  }

  global.NotesPreview = {
    defaults: DEFAULTS,
    collect: collect,
    budget: budget,
    plainText: plainText,
    codeText: codeText
  };
})(typeof window !== 'undefined' ? window : globalThis);

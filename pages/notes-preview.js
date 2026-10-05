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

  // Reads a rendered table into plain rows of cell text. The Markdown separator
  // row is gone by the time the renderer is done, so the header is whichever row
  // it marked up with <th>.
  function tableGrid(node) {
    var rows = [], header = false;
    var trs = node.querySelectorAll('tr');
    for (var i = 0; i < trs.length; i++) {
      var cells = [], isHeader = false;
      var kids = trs[i].children;
      for (var j = 0; j < kids.length; j++) {
        var cell = kids[j];
        if (cell.tagName === 'TH') isHeader = true;
        if (cell.tagName !== 'TD' && cell.tagName !== 'TH') continue;
        cells.push(plainText(cell));
      }
      if (!cells.length) continue;
      if (rows.length === 0 && isHeader) header = true;
      rows.push(cells);
    }
    return { rows: rows, header: header };
  }

  function isBlockTag(tag) {
    return /^(P|DIV|SECTION|ARTICLE|PRE|BLOCKQUOTE|TABLE|UL|OL|H[1-6]|HR)$/.test(tag);
  }

  function addRow(out, row, budget) {
    if (budget.stopped) return;
    var cost = row.cost || 1;
    if (budget.used + cost > budget.maxRows) {
      budget.stopped = true;
      budget.truncated = true;
      return;
    }
    out.push(row);
    budget.used += cost;
  }

  function rowsFor(node, marker, out, budget) {
    if (budget.stopped) return;
    var tag = node.tagName;
    if (isChrome(node)) return;
    if (budget.used >= budget.maxRows) {
      budget.stopped = true;
      budget.truncated = true;
      return;
    }
    if (tag === 'HR') { addRow(out, { kind: 'rule', cost: 1 }, budget); return; }
    if (tag === 'UL' || tag === 'OL') {
      for (var i = 0; i < node.children.length; i++) {
        if (budget.stopped) break;
        var li = node.children[i];
        if (li.tagName !== 'LI') continue;
        rowsFor(li, tag === 'OL' ? (i + 1) + '.' : '•', out, budget);
      }
      return;
    }
    if (tag === 'BLOCKQUOTE') {
      var kids = node.children;
      var any = false;
      for (var j = 0; j < kids.length; j++) {
        if (budget.stopped) break;
        if (isBlockTag(kids[j].tagName)) { rowsFor(kids[j], '▏', out, budget); any = true; }
      }
      if (!any) addRow(out, { kind: 'text', node: node, marker: '▏', copy: plainText(node), cost: 1 }, budget);
      return;
    }
    if (tag === 'PRE') {
      var code = codeText(node);
      if (code === '') return;
      var lines = code.split('\n');
      var shown = Math.min(lines.length, DEFAULTS.maxCodeLines);
      addRow(out, {
        kind: 'code', node: node, copy: code, cost: shown,
        display: lines.slice(0, shown).join('\n') + (lines.length > shown ? '\n…' : '')
      }, budget);
      return;
    }
    if (tag === 'TABLE') {
      var grid = tableGrid(node);
      if (!grid.rows.length) return;
      addRow(out, {
        kind: 'table', node: node, grid: grid.rows, header: grid.header,
        // Tab separated so it can be pasted straight into a spreadsheet, and one
        // line per row so it stays readable anywhere else.
        copy: grid.rows.map(function (cells) { return cells.join('\t'); }).join('\n'),
        // A rendered table takes one line per row, so that is what it spends of
        // the preview budget. A table that does not fit is dropped whole, like
        // every other block.
        cost: Math.min(grid.rows.length, DEFAULTS.maxRows)
      }, budget);
      return;
    }
    var img = imageOf(node);
    if (img) {
      addRow(out, { kind: 'image', node: node, img: img, src: img.getAttribute('src') || '',
                    alt: normalise(img.getAttribute('alt')), cost: DEFAULTS.imageRows }, budget);
      return;
    }
    // Descend into Vditor wrappers without collecting blocks after the row budget.
    if (/^(DIV|SECTION|ARTICLE)$/.test(tag)) {
      var hasBlockChildren = false;
      for (var k = 0; k < node.children.length; k++) {
        if (!isBlockTag(node.children[k].tagName)) continue;
        hasBlockChildren = true;
        rowsFor(node.children[k], marker, out, budget);
        if (budget.stopped) break;
      }
      if (hasBlockChildren) return;
    }
    var text = plainText(node);
    if (text === '') return;
    var level = headingLevel(tag);
    addRow(out, {
      kind: level ? 'heading' : 'text', node: node, marker: marker, copy: text,
      level: level, cost: 1
    }, budget);
  }

  // Flattens only as much rendered Markdown as the preview can display.
  function collect(rendered, options) {
    var opts = options || {};
    var requestedMax = opts.maxRows == null ? DEFAULTS.maxRows : Number(opts.maxRows);
    var budget = {
      maxRows: Number.isFinite(requestedMax) ? Math.max(0, requestedMax) : DEFAULTS.maxRows,
      used: 0,
      truncated: false,
      stopped: false
    };
    var out = [];
    var kids = rendered.children;
    for (var i = 0; i < kids.length; i++) {
      if (budget.stopped) break;
      rowsFor(kids[i], '', out, budget);
    }
    return { rows: out, used: budget.used, truncated: budget.truncated };
  }

  global.NotesPreview = {
    defaults: DEFAULTS,
    collect: collect,
    plainText: plainText,
    codeText: codeText
  };
})(typeof window !== 'undefined' ? window : globalThis);

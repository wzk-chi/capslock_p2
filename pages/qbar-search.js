/* Qbar's local search-key builder.
 *
 * pinyin-pro is loaded before this file by qbar.html. The module only turns
 * display names into immutable search keys; matching and execution stay in
 * the AHK index so the existing command semantics remain authoritative.
 */
(function (root) {
  'use strict';

  const HAN_RE = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]/;
  const ASCII_WORD_RE = /[A-Za-z]+/g;
  const ASCII_QUERY_RE = /^[A-Za-z]+$/;
  const BATCH_SIZE = 50;
  let activeJob = null;

  function isHan(value) {
    return HAN_RE.test(value);
  }

  function normalizeKey(value) {
    return String(value || '')
      .toLowerCase()
      .replace(/ü/g, 'v')
      .replace(/[^a-z]/g, '');
  }

  function unique(values) {
    return Array.from(new Set(values.filter(Boolean)));
  }

  function chineseSegments(label) {
    const chars = Array.from(String(label || ''));
    const segments = [];
    let current = '';
    for (const char of chars) {
      if (isHan(char)) {
        current += char;
      } else if (current) {
        segments.push(current);
        current = '';
      }
    }
    if (current) segments.push(current);
    return segments;
  }

  function pinyinKeys(label) {
    const full = [];
    const initials = [];
    const converter = root.pinyinPro && root.pinyinPro.pinyin;
    if (typeof converter !== 'function') {
      return { full, initials, missing: true };
    }

    for (const segment of chineseSegments(label)) {
      try {
        const syllables = converter(segment, {
          toneType: 'none',
          type: 'array',
        });
        if (!Array.isArray(syllables) || syllables.length !== Array.from(segment).length)
          continue;
        const normalized = syllables.map(normalizeKey);
        if (normalized.some(value => !value)) continue;
        full.push(normalized.join(''));
        initials.push(normalized.map(value => value[0]).join(''));
      } catch (_) {
        // A bad or unsupported segment should not prevent other candidates
        // from being indexed. The original label remains searchable.
      }
    }
    return { full: unique(full), initials: unique(initials), missing: false };
  }

  function wordInitials(label) {
    // Split camel case and acronym-to-word boundaries before extracting the
    // first ASCII letter of each word. This makes both "Visual Studio Code"
    // and "VisualStudioCode" produce "vsc".
    const separated = String(label || '')
      .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
      .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2');
    const words = separated.match(ASCII_WORD_RE) || [];
    if (words.length < 2) return '';
    return words.map(word => word[0].toLowerCase()).join('');
  }

  function buildItem(item) {
    const label = item && typeof item.label === 'string' ? item.label : '';
    const pinyin = pinyinKeys(label);
    return {
      id: item && Number.isInteger(item.id) ? item.id : 0,
      pinyinFull: pinyin.full,
      pinyinInitials: pinyin.initials,
      wordInitials: wordInitials(label),
      missing: pinyin.missing,
    };
  }

  function finish(job, ok, items, error) {
    if (activeJob !== job) return;
    activeJob = null;
    job.post({
      type: 'searchKeysReady',
      generation: job.generation,
      ok: !!ok,
      items: ok ? items : [],
      error: error || '',
    });
  }

  function start(payload, post) {
    if (activeJob) activeJob.cancelled = true;
    const generation = payload && Number.isInteger(payload.generation)
      ? payload.generation : 0;
    const source = payload && Array.isArray(payload.items) ? payload.items : null;
    const job = { generation, post, cancelled: false };
    activeJob = job;

    if (!source || !Number.isInteger(generation) || generation <= 0) {
      finish(job, false, [], 'invalid_payload');
      return;
    }
    if (!root.pinyinPro || typeof root.pinyinPro.pinyin !== 'function') {
      finish(job, false, [], 'dependency_missing');
      return;
    }

    const output = [];
    let offset = 0;
    const step = () => {
      if (activeJob !== job || job.cancelled) return;
      const end = Math.min(offset + BATCH_SIZE, source.length);
      for (; offset < end; offset += 1)
        output.push(buildItem(source[offset]));
      if (offset < source.length) {
        setTimeout(step, 0);
      } else {
        finish(job, true, output, '');
      }
    };
    setTimeout(step, 0);
  }

  root.QbarSearchKeys = {
    start,
    isAsciiQuery(value) {
      return ASCII_QUERY_RE.test(String(value || ''));
    },
  };
})(window);

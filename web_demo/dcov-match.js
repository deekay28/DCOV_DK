/* dcov-match.js — offline port of backend/app/services/matching.py
 * Kept deliberately line-for-line comparable with the Python original: if the
 * two ever disagree about how a marking is interpreted, an inspector working
 * offline would get a different verdict from one working online, which is the
 * one failure this system cannot tolerate.
 */
(function (global) {
  'use strict';

  const NON_ALNUM = /[^A-Z0-9]/g;
  const NOISE_PREFIXES = ['DCOV:', 'URN:DCOV:', 'HTTP://', 'HTTPS://'];

  const CONFUSIONS = { O:'0', Q:'0', D:'0', I:'1', L:'1', '|':'1', T:'7',
                       Z:'2', S:'5', B:'8', G:'6', U:'V', C:'G', E:'F' };
  const REVERSE = Object.fromEntries(Object.entries(CONFUSIONS).map(([k, v]) => [v, k]));
  const FOLD = { O:'0', Q:'0', I:'1', L:'1', S:'5', B:'8', Z:'2', G:'6', T:'7' };

  function normalize(v) {
    if (!v) return '';
    let s = String(v).trim().toUpperCase();
    for (const p of NOISE_PREFIXES) if (s.startsWith(p)) s = s.slice(p.length);
    return s.replace(NON_ALNUM, '');
  }

  function foldKey(v) {
    return normalize(v).split('').map(c => FOLD[c] || c).join('');
  }

  function ocrVariants(text, max = 64) {
    const base = normalize(text);
    const out = [base];
    for (let i = 0; i < base.length; i++) {
      for (const table of [CONFUSIONS, REVERSE]) {
        const rep = table[base[i]];
        if (!rep) continue;
        const cand = base.slice(0, i) + rep + base.slice(i + 1);
        if (!out.includes(cand)) { out.push(cand); if (out.length >= max) return out; }
      }
    }
    return out;
  }

  function truncations(key, floor = 6) {
    const out = [];
    for (let i = key.length - 1; i >= floor; i--) out.push(key.slice(0, i));
    return out;
  }

  function damerauLevenshtein(a, b) {
    if (a === b) return 0;
    if (!a) return b.length;
    if (!b) return a.length;
    let prev2 = [], prev = Array.from({ length: b.length + 1 }, (_, i) => i);
    for (let i = 1; i <= a.length; i++) {
      const cur = new Array(b.length + 1); cur[0] = i;
      for (let j = 1; j <= b.length; j++) {
        const cost = a[i - 1] === b[j - 1] ? 0 : 1;
        let val = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
        if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1])
          val = Math.min(val, prev2[j - 2] + cost);
        cur[j] = val;
      }
      prev2 = prev; prev = cur;
    }
    return prev[b.length];
  }

  function similarity(a, b) {
    if (!a || !b) return 0;
    if (a === b) return 100;
    const dist = damerauLevenshtein(a, b);
    const longest = Math.max(a.length, b.length);
    const base = (1 - dist / longest) * 100;
    let prefix = 0;
    while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
    return Math.round((base * 0.75 + (prefix / longest) * 100 * 0.25) * 100) / 100;
  }

  /* ---------------------------------------------------------------- index */
  function ComponentIndex(rows) {
    this.rows = rows;
    this.byKey = new Map(); this.byFold = new Map();
    this.byBarcode = new Map(); this.byQr = new Map();
    this.blocks = new Map();
    rows.forEach((c, i) => {
      const key = c.search_key || normalize(c.chip_number || c.part_number);
      c.search_key = key;
      if (key) {
        if (!this.byKey.has(key)) this.byKey.set(key, []);
        this.byKey.get(key).push(c);
        const f = foldKey(key);
        if (!this.byFold.has(f)) this.byFold.set(f, []);
        this.byFold.get(f).push(c);
        for (const g of grams(key)) {
          if (!this.blocks.has(g)) this.blocks.set(g, new Set());
          this.blocks.get(g).add(i);
        }
      }
      if (c.barcode) this.byBarcode.set(String(c.barcode).trim().toUpperCase(), c);
      if (c.qr_code) this.byQr.set(String(c.qr_code).trim().toUpperCase(), c);
    });
  }

  function grams(key, n = 3) {
    const out = new Set();
    for (let i = 0; i < Math.max(1, key.length - n + 1); i++) out.add(key.slice(i, i + n));
    return out;
  }

  ComponentIndex.prototype.byPrefix = function (key) {
    const out = [];
    for (const [k, rows] of this.byKey) if (k.startsWith(key) || key.startsWith(k)) out.push(...rows);
    return out;
  };

  ComponentIndex.prototype.candidates = function (key, limit = 200) {
    const counts = new Map();
    for (const g of grams(key)) {
      const bucket = this.blocks.get(g);
      if (!bucket) continue;
      for (const i of bucket) counts.set(i, (counts.get(i) || 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit)
      .map(([i]) => this.rows[i]);
  };

  /* -------------------------------------------------------------- matcher */
  const THRESHOLD = 82, LOW_CONFIDENCE_FLOOR = 60;

  function resolve(hits, key, method, score, notes) {
    const seen = new Map();
    hits.forEach(h => seen.set(h.component_id, h));
    hits = [...seen.values()];
    if (hits.length === 1)
      return { matched: true, method, score, component: hits[0], suggestions: [],
               normalized_input: key, notes };

    const definite = hits.filter(h => (h.is_chinese || 'UNKNOWN').toUpperCase() !== 'UNKNOWN');
    if (definite.length && definite.length < hits.length) {
      notes.push(`${hits.length - definite.length} record(s) with unestablished origin superseded by verified record(s)`);
      hits = definite;
    }
    const verdicts = new Set(hits.map(h => (h.is_chinese || 'UNKNOWN').toUpperCase()));
    if (verdicts.size === 1) {
      const best = hits.reduce((a, b) =>
        (parseFloat(b.confidence_score) || 0) > (parseFloat(a.confidence_score) || 0) ? b : a);
      notes.push(`${hits.length} records share this marking; all agree on origin`);
      return { matched: true, method, score, component: best,
               suggestions: hits.filter(h => h !== best).map(h => ({ score, payload: h })),
               normalized_input: key, notes };
    }
    notes.push(`CONFLICT: ${hits.length} records share this marking with differing origin verdicts (${[...verdicts].sort().join(', ')}). Manual adjudication required.`);
    return { matched: false, method: 'conflict', score, component: null,
             suggestions: hits.map(h => ({ score, payload: h })),
             normalized_input: key, notes };
  }

  function match(raw, index) {
    raw = (raw || '').trim();
    const key = normalize(raw);
    const notes = [];
    const trace = [];
    const step = (layer, hit, detail) => { trace.push({ layer, hit, detail: detail || '' }); };

    if (!key) return { matched: false, method: 'none', score: 0, component: null,
                       suggestions: [], normalized_input: '', notes: ['empty input'], trace };

    let hit = index.byBarcode.get(raw.trim().toUpperCase()) || index.byQr.get(raw.trim().toUpperCase());
    step('Coded payload', !!hit, hit ? 'barcode or QR matched verbatim' : 'not a stored barcode or QR payload');
    if (hit) return { matched: true, method: 'exact_code', score: 100, component: hit,
                      suggestions: [], normalized_input: key, notes, trace };

    let hits = index.byKey.get(key) || [];
    step('Normalised key', hits.length > 0, key);
    if (hits.length) return Object.assign(resolve(hits, key, 'normalized', 100, notes), { trace });

    for (const t of truncations(key)) {
      hits = index.byKey.get(t) || [];
      if (hits.length) {
        notes.push(`trailing lot/date code discarded: ${key} → ${t}`);
        step('Lot-code strip', true, `${key} → ${t}`);
        return Object.assign(resolve(hits, t, 'lot_code_stripped', 96, notes), { trace });
      }
    }
    step('Lot-code strip', false, 'no shorter leading substring is a known part number');

    for (const v of ocrVariants(key).slice(1)) {
      hits = index.byKey.get(v) || [];
      if (hits.length) {
        notes.push(`OCR correction applied: ${key} → ${v}`);
        step('Single-glyph repair', true, `${key} → ${v}`);
        return Object.assign(resolve(hits, v, 'ocr_corrected', 94, notes), { trace });
      }
    }
    step('Single-glyph repair', false, 'no single character substitution reaches a known part');

    const folded = foldKey(key);
    hits = index.byFold.get(folded) || [];
    if (hits.length) {
      notes.push(`resolved through glyph-class folding (${key} ~ ${folded}) — verify the marking by eye before accepting`);
      step('Glyph-class fold', true, `${key} ~ ${folded}`);
      return Object.assign(resolve(hits, key, 'ocr_folded', 90, notes), { trace });
    }
    for (const t of truncations(folded)) {
      hits = index.byFold.get(t) || [];
      if (hits.length) {
        notes.push(`glyph-class folding after discarding a trailing code (${key})`);
        step('Glyph-class fold', true, `${folded} → ${t}`);
        return Object.assign(resolve(hits, key, 'ocr_folded_stripped', 87, notes), { trace });
      }
    }
    step('Glyph-class fold', false, `folded form ${folded} is unknown`);

    if (key.length >= 5) {
      const pref = index.byPrefix(key);
      if (pref.length) {
        const longest = Math.max(...pref.map(p => p.search_key.length));
        const best = pref.filter(p => p.search_key.length === longest);
        const distinct = new Set(best.map(p => p.search_key));
        notes.push('matched on partial marking (prefix)');
        step('Partial marking', true, `${best.length} record(s) at the most specific prefix`);
        if (distinct.size === 1)
          return Object.assign(resolve(best, key, 'prefix', 88, notes), { trace });
        notes[notes.length - 1] = `${distinct.size} distinct part numbers share this prefix — confirm manually`;
        return { matched: false, method: 'ambiguous_prefix', score: 0, component: null,
                 suggestions: best.slice(0, 10).map(c => ({ score: 85, payload: c })),
                 normalized_input: key, notes, trace };
      }
      step('Partial marking', false, 'no stored part number shares this prefix');
    }

    const cands = [];
    for (const comp of index.candidates(key, 200)) {
      const ck = comp.search_key || normalize(comp.chip_number || comp.part_number);
      if (!ck) continue;
      const s = similarity(key, ck);
      if (s >= 55) cands.push({ score: s, payload: comp });
    }
    cands.sort((a, b) => b.score - a.score);
    const top = cands.slice(0, 25);
    if (top.length && top[0].score >= THRESHOLD) {
      if (top.length > 1 && top[1].score >= top[0].score - 2) {
        notes.push('two near-equal fuzzy candidates — inspector confirmation required');
        step('Fuzzy', false, `${top[0].score}% vs ${top[1].score}% — too close to call`);
        return { matched: false, method: 'ambiguous_fuzzy', score: top[0].score,
                 component: null, suggestions: top.slice(0, 5), normalized_input: key, notes, trace };
      }
      step('Fuzzy', true, `closest stored part number at ${top[0].score}%`);
      return { matched: true, method: 'fuzzy', score: top[0].score, component: top[0].payload,
               suggestions: top.slice(1, 5), normalized_input: key, notes, trace };
    }
    step('Fuzzy', false, top.length ? `best candidate only ${top[0].score}%, below the ${THRESHOLD}% floor`
                                     : 'nothing in the catalogue is close');
    return { matched: false, method: 'none', score: top.length ? top[0].score : 0,
             component: null, suggestions: top.slice(0, 5), normalized_input: key, notes, trace };
  }

  /* ------------------------------------------------------------- verdict */
  // Mirrors verdict_for() in backend/app/services/matching.py - see
  // ORIGIN_VERIFICATION_LOGIC.md for the rules.
  const UNCERTAIN_METHODS = new Set(['fuzzy', 'prefix', 'ocr_folded', 'ocr_folded_stripped']);
  const UNKNOWN_COUNTRY = new Set(['UNKNOWN', 'UNK', 'N/A', 'NA', '-', '?', 'TBD', 'NONE']);

  function originEvidence(c) {
    if (!c) return ['none', ''];
    const src = (c.verification_source || '').trim();
    const country = (c.country_of_origin || '').trim();
    const isCn = (c.is_chinese || 'UNKNOWN').toUpperCase();
    if ((isCn !== 'YES' && isCn !== 'NO') || !country || country.toUpperCase() === 'UNKNOWN')
      return ['none', 'The catalogue record has no documented country of origin.'];
    if ((c.category || '').trim().toUpperCase() === 'OEM / LRU' || src.toUpperCase().includes('OEM LANDSCAPE'))
      return ['manufacturer', `Manufacturer/OEM home country only (${country}); source: ${src || 'not recorded'}.`];
    return ['component', `Catalogue record: ${country}; source: ${src || 'not recorded'}.`];
  }

  function verdictFor(component, score, method) {
    if (score === undefined) score = 100;
    if (!component)
      return { result: 'not_found', banner: 'GREY', headline: 'COMPONENT NOT FOUND',
               action: 'Capture images and save for review', confidence: 0,
               origin_evidence: 'none', review_required: true };

    const isCn = (component.is_chinese || 'UNKNOWN').toUpperCase();
    let origin = (component.country_of_origin || '').trim();
    if (UNKNOWN_COUNTRY.has(origin.toUpperCase())) origin = '';
    const crit = (component.criticality || 'REVIEW').toUpperCase();
    const conf = parseFloat(component.confidence_score) || 0;
    const effective = Math.min(conf, score);
    const [tier, detail] = originEvidence(component);
    const uncertain = UNCERTAIN_METHODS.has(method || '');
    let res;

    if (isCn === 'YES') {
      res = { result: 'chinese', banner: 'RED', headline: 'CHINESE COMPONENT DETECTED',
              alert: true, vibrate: true, sound: 'warning' };
    } else if (isCn === 'NO' && origin) {
      res = { result: 'non_chinese', banner: 'GREEN', headline: 'NON-CHINESE COMPONENT', alert: false };
    } else {
      res = { result: 'unknown_origin', banner: 'YELLOW', headline: 'ORIGIN NOT FOUND',
              action: 'Needs verification — refer to database manager', alert: false };
    }

    if (effective < LOW_CONFIDENCE_FLOOR && res.result === 'non_chinese') {
      res = { result: 'unknown_origin', banner: 'YELLOW', headline: 'ORIGIN NOT CONFIRMED',
              action: `Match confidence ${effective.toFixed(0)}% is below the ${LOW_CONFIDENCE_FLOOR}% floor — verify manually`,
              alert: false };
    }
    if (res.result === 'non_chinese' && tier === 'manufacturer') {
      res = { result: 'unknown_origin', banner: 'YELLOW',
              headline: 'OEM NON-CHINESE - COMPONENT ORIGIN NOT DOCUMENTED',
              action: 'Only the manufacturer\'s home country is on record. Confirm the component\'s country of manufacture.',
              alert: false };
    }
    if (res.result === 'chinese' && tier === 'manufacturer') {
      res.headline = 'CHINESE MANUFACTURER - COMPONENT ORIGIN PRESUMED CHINESE';
    }
    if (uncertain && res.result === 'non_chinese') {
      res = { result: 'unknown_origin', banner: 'YELLOW',
              headline: 'IDENTITY UNCERTAIN - REQUIRES MANUAL REVIEW',
              action: `Matched by '${method}' at ${score.toFixed(0)}%. Compare the marking before accepting.`,
              alert: false };
    } else if (uncertain && res.result === 'chinese') {
      res.headline = 'PROBABLE CHINESE COMPONENT - CONFIRM MARKING';
    }
    res.criticality = crit;
    res.confidence = Math.round(effective * 10) / 10;
    res.origin_evidence = tier;
    res.evidence_detail = detail;
    res.review_required = uncertain || res.result !== 'non_chinese';
    if (res.result === 'chinese' && crit === 'CRITICAL') {
      res.escalate = true;
      res.escalation_note = component.criticality_policy || 'Chinese origin not acceptable in this subsystem';
    }
    return res;
  }

  global.DCOVMatch = { normalize, foldKey, ocrVariants, similarity, damerauLevenshtein,
                       ComponentIndex, match, verdictFor, THRESHOLD, LOW_CONFIDENCE_FLOOR };
})(typeof window !== 'undefined' ? window : globalThis);

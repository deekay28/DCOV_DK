require(require('path').resolve(process.argv[2]));
const M = globalThis.DCOVMatch;
const rows = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
const methods = ['normalized','exact_code','ocr_corrected','lot_code_stripped','fuzzy','prefix','ocr_folded','ocr_folded_stripped'];
const out = [];
for (const r of rows) for (const m of methods) for (const sc of [100, 88, 50]) {
  const v = M.verdictFor(r, sc, m); out.push([r.component_id, m, sc, v.banner, v.headline, v.origin_evidence, v.review_required]);
}
const idx = new M.ComponentIndex(JSON.parse(JSON.stringify(rows)));
const probes = ['STM32F302C8T6','stm32 f3o2-c8t6','STM32G4A1KCU6 GQ23J 1B9U','ADIN13OOBCPZ','ATMEGA16U2','MX2SLI2833F','STM32F3','ADF4350','Doodle Labs','6901234567892','SN74LVC1G08','EFR32FG13P231HG','HOLYBRO'];
const mo = probes.map(p => { const r = M.match(p, idx); return [p, r.method, Math.round(r.score*100)/100, (r.component||{}).component_id || null]; });
console.log(JSON.stringify({verdicts: out, matches: mo}));

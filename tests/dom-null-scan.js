// Findet DOM-Aufrufe (append/replaceChildren/prepend/before/after), deren Argumente null/undefined/false sein können.
const fs = require('fs');
const BS = String.fromCharCode(92);
function splitArgs(src, start) {
  let i = start, depth = 1, args = [], cur = '', q = null;
  for (; i < src.length && depth; i++) {
    const c = src[i];
    if (q) { cur += c; if (c === BS) { cur += src[++i]; continue; } if (c === q) q = null; continue; }
    if (c === "'" || c === '"' || c === '`') { q = c; cur += c; continue; }
    if ('([{'.includes(c)) depth++;
    if (')]}'.includes(c)) { depth--; if (!depth) break; }
    if (c === ',' && depth === 1) { args.push(cur); cur = ''; continue; }
    cur += c;
  }
  args.push(cur);
  return args;
}
function topLevel(a) {
  let o = '', d = 0, q = null;
  for (let k = 0; k < a.length; k++) {
    const c = a[k];
    if (q) { if (c === BS) { k++; continue; } if (c === q) q = null; continue; }
    if (c === "'" || c === '"' || c === '`') { q = c; o += 'S'; continue; }
    if ('([{'.includes(c)) { d++; continue; }
    if (')]}'.includes(c)) { d--; continue; }
    if (!d) o += c;
  }
  return o;
}
for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const re = /\.(append|replaceChildren|prepend|before|after)\(/g;
  let m;
  while ((m = re.exec(src))) {
    const args = splitArgs(src, m.index + m[0].length);
    const bad = args.filter(a => /\?|&&|\|\|/.test(topLevel(a)) || /^\s*(null|undefined|false)\s*$/.test(a));
    if (bad.length) {
      const line = src.slice(0, m.index).split('\n').length;
      console.log(file + ':' + line + ': .' + m[1] + '  ->  ' + bad.map(b => b.trim().replace(/\s+/g, ' ').slice(0, 120)).join('  ||  '));
    }
  }
}

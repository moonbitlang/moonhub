export function maskText(text, masks) {
  let masked = text;
  // Union overlapping occurrences so partially overlapping masks cannot leak.
  const spans = [];
  for (const mask of masks) if (mask) for (let i = masked.indexOf(mask); i >= 0; i = masked.indexOf(mask, i + 1)) spans.push([i, i + mask.length]);
  spans.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const span of spans) { const last = merged.at(-1); if (last && span[0] <= last[1]) last[1] = Math.max(last[1], span[1]); else merged.push(span); }
  for (const [start, end] of merged.reverse()) masked = masked.slice(0, start) + '***' + masked.slice(end);
  return masked;
}

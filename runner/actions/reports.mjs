import { maskText } from './masking.mjs';
export const summaryLimit = 1048576;
const annotationLimit = 262144;
// Match the server's delivered-secret policy before any report is clipped,
// including individual lines and decoded strings inside credential files.
function reportMasks(masks) {
  const values = new Set(masks);
  for (const mask of masks) {
    for (const line of mask.split('\n')) { const value = line.replace(/\r+$/, ''); if (value) values.add(value); }
    let value; try { value = JSON.parse(mask); } catch { continue; }
    const pending = [value];
    while (pending.length) {
      const item = pending.pop();
      if (typeof item === 'string' && item) values.add(item);
      else if (item && typeof item === 'object') for (const value of Object.values(item)) pending.push(value);
    }
  }
  return [...values];
}
export function boundedText(value, bytes) {
  const text = String(value ?? '').replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');
  if (Buffer.byteLength(text) <= bytes) return text;
  return Buffer.from(text).subarray(0, bytes).toString('utf8').replace(/\uFFFD$/, '');
}
export function annotation(severity, message, props, state = { masks: [] }) {
  // Normalize only after masking complete values: cutting a credential first
  // leaves a prefix that neither runner nor server masking can recognize.
  const masks = reportMasks(state.masks);
  const field = (value, bytes) => {
    const masked = maskText(String(value ?? ''), masks);
    if (Buffer.byteLength(masked) > bytes) state.report_truncated = true;
    return boundedText(masked, bytes);
  };
  const position = value => /^[1-9]\d{0,9}$/.test(value || '') && Number(value) <= 2147483647 ? Number(value) : 0;
  const line = position(props.line), endLine = line ? Math.max(line, position(props.endLine)) : 0, column = line ? position(props.col) : 0;
  return { severity, message: field(message, 16384), title: field(props.title, 200),
    file: field(props.file, 1024).replace(/[\r\n\t]/g, ''), line,
    end_line: endLine,
    column, end_column: column ? (endLine > line ? position(props.endColumn) || column : Math.max(column, position(props.endColumn))) : 0 };
}
export function captureReport(state, stepId, summary, annotations) {
  if (!stepId) return;
  const entries = state.reports ||= [];
  let entry = entries.find(item => item.step_id === stepId);
  if (!entry) { if (entries.length >= 64) { state.report_truncated = true; return; } entries.push(entry = { step_id: stepId, summary: '', annotations: [] }); }
  const masks = reportMasks(state.masks);
  const used = entries.reduce((n, item) => n + Buffer.byteLength(item.summary), 0);
  const maskedSummary = maskText(summary, masks);
  const text = boundedText(maskedSummary, Math.max(0, summaryLimit - used));
  if (Buffer.byteLength(maskedSummary) > summaryLimit - used) state.report_truncated = true;
  entry.summary += text;
  let count = entries.reduce((n, item) => n + item.annotations.length, 0);
  let size = entries.reduce((n, item) => n + item.annotations.reduce((n, a) => n + Buffer.byteLength(JSON.stringify(a)), 0), 0);
  for (const value of annotations) {
    const a = { ...value };
    for (const [key, limit] of [['message', 16384], ['title', 200], ['file', 1024]]) {
      const masked = maskText(value[key], masks);
      a[key] = boundedText(masked, limit);
      if (Buffer.byteLength(masked) > limit) state.report_truncated = true;
    }
    const bytes = Buffer.byteLength(JSON.stringify(a));
    if (count >= 200 || size + bytes > annotationLimit) { state.report_truncated = true; break; }
    entry.annotations.push(a); count++; size += bytes;
  }
}
export function reportSnapshot(state) {
  // Later invocations can add short masks that expand earlier content. Reapply
  // every wire limit after masking, using the same aggregation policy.
  const snapshot = { masks: state.masks, reports: [], report_truncated: Boolean(state.report_truncated) };
  for (const entry of state.reports || []) captureReport(snapshot, entry.step_id, entry.summary, entry.annotations);
  const entries = snapshot.reports.filter(e => e.summary || e.annotations.length);
  state.report_truncated = snapshot.report_truncated;
  if (!entries.length && !state.report_truncated) return null;
  const revision = (state.report_revision || 0) + 1;
  if (revision > 256) throw new Error('Report revision limit exceeded');
  state.report_revision = revision;
  return { revision, entries, truncated: Boolean(state.report_truncated) };
}

import { maskText } from './masking.mjs';
export const summaryLimit = 1048576;
const annotationLimit = 262144;
export function boundedText(value, bytes) {
  const text = String(value ?? '').replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');
  if (Buffer.byteLength(text) <= bytes) return text;
  return Buffer.from(text).subarray(0, bytes).toString('utf8').replace(/\uFFFD$/, '');
}
export function annotation(severity, message, props) {
  const position = value => /^[1-9]\d{0,9}$/.test(value || '') && Number(value) <= 2147483647 ? Number(value) : 0;
  const line = position(props.line), endLine = line ? Math.max(line, position(props.endLine)) : 0, column = line ? position(props.col) : 0;
  return { severity, message: boundedText(message, 16384), title: boundedText(props.title, 200),
    file: boundedText(props.file, 1024).replace(/[\r\n\t]/g, ''), line,
    end_line: endLine,
    column, end_column: column ? (endLine > line ? position(props.endColumn) || column : Math.max(column, position(props.endColumn))) : 0 };
}
export function captureReport(state, stepId, summary, annotations) {
  if (!stepId) return;
  const entries = state.reports ||= [];
  let entry = entries.find(item => item.step_id === stepId);
  if (!entry) { if (entries.length >= 64) { state.report_truncated = true; return; } entries.push(entry = { step_id: stepId, summary: '', annotations: [] }); }
  const used = entries.reduce((n, item) => n + Buffer.byteLength(item.summary), 0);
  const text = boundedText(maskText(summary, state.masks), Math.max(0, summaryLimit - used));
  if (text !== summary) state.report_truncated ||= Buffer.byteLength(summary) > summaryLimit - used;
  entry.summary += text;
  let count = entries.reduce((n, item) => n + item.annotations.length, 0);
  let size = entries.reduce((n, item) => n + item.annotations.reduce((n, a) => n + Buffer.byteLength(JSON.stringify(a)), 0), 0);
  for (const value of annotations) {
    const a = { ...value, message: maskText(value.message, state.masks), title: maskText(value.title, state.masks), file: maskText(value.file, state.masks) };
    const bytes = Buffer.byteLength(JSON.stringify(a));
    if (count >= 200 || size + bytes > annotationLimit) { state.report_truncated = true; break; }
    entry.annotations.push(a); count++; size += bytes;
  }
}
export function reportSnapshot(state) {
  const entries = (state.reports || []).filter(e => e.summary || e.annotations.length).map(e => ({ ...e,
    summary: maskText(e.summary, state.masks), annotations: e.annotations.map(a => ({ ...a,
      message: maskText(a.message, state.masks), title: maskText(a.title, state.masks), file: maskText(a.file, state.masks) })) }));
  if (!entries.length && !state.report_truncated) return null;
  const revision = (state.report_revision || 0) + 1;
  if (revision > 256) throw new Error('Report revision limit exceeded');
  state.report_revision = revision;
  return { revision, entries, truncated: Boolean(state.report_truncated) };
}

import { windows } from './platform.mjs';
// A small, parsed Actions expression language; never evaluates JavaScript.
const forbidden = new Set(['__proto__', 'prototype', 'constructor']);
export function evaluate(source, context = {}, implicitSuccess = false) {
  source = source.trim();
  if (source.startsWith('${{') && source.endsWith('}}')) source = source.slice(3, -2);
  const tokens = [];
  const pattern = /\s*(?:('(?:[^']|'')*')|(\d+(?:\.\d+)?)|([a-zA-Z_][\w-]*)|(==|!=|&&|\|\||[!().,\[\]]))/gy;
  let offset = 0;
  while (offset < source.length && source.slice(offset).trim()) {
    pattern.lastIndex = offset;
    const match = pattern.exec(source);
    if (!match) throw new Error('Unsupported Actions expression');
    tokens.push(match[1] ? ['value', match[1].slice(1, -1).replaceAll("''", "'")] :
      match[2] ? ['value', Number(match[2])] : match[3] ? ['name', match[3]] : [match[4], match[4]]);
    offset = pattern.lastIndex;
    if (tokens.length > 2048) throw new Error('Actions expression is too large');
  }
  let index = 0;
  const take = (type) => tokens[index]?.[0] === type ? tokens[index++] : undefined;
  const expect = (type) => { if (!take(type)) throw new Error('Invalid Actions expression'); };
  const atom = (depth = 0) => {
    if (depth > 32) throw new Error('Actions expression nesting exceeds 32 levels');
    if (take('!')) return ['not', atom(depth + 1)];
    if (take('(')) { const value = binary(0, depth + 1); expect(')'); return value; }
    const literal = take('value');
    if (literal) return ['value', literal[1]];
    const name = take('name')?.[1]?.toLowerCase();
    if (!name) throw new Error('Expected Actions expression value');
    if (['true', 'false', 'null'].includes(name)) return ['value', { true: true, false: false, null: null }[name]];
    if (take('(')) {
      const args = [];
      if (!take(')')) { do { args.push(binary(0, depth + 1)); } while (take(',')); expect(')'); }
      return ['call', name, args];
    }
    const path = [name];
    while (true) {
      if (take('.')) { const part = take('name')?.[1]; if (!part) throw new Error('Invalid context field'); path.push(part); }
      else if (take('[')) { const part = take('value')?.[1]; if (typeof part !== 'string') throw new Error('Only literal field indexes are supported'); path.push(part); expect(']'); }
      else break;
    }
    if (path.some(part => forbidden.has(part.toLowerCase()))) throw new Error('Invalid context field');
    return ['path', path];
  };
  const precedence = { '||': 1, '&&': 2, '==': 3, '!=': 3 };
  const binary = (minimum, depth = 0) => {
    let left = atom(depth);
    while (precedence[tokens[index]?.[0]] >= minimum && precedence[tokens[index]?.[0]]) {
      const op = tokens[index++][0];
      left = [op, left, binary(precedence[op] + 1, depth + 1)];
    }
    return left;
  };
  const tree = binary(0);
  if (index !== tokens.length) throw new Error('Unexpected Actions expression tokens');
  const visit = (node) => {
    const [type, a, b] = node;
    if (type === 'value') return a;
    if (type === 'path') {
      const root = Object.keys(context).find(key => key.toLowerCase() === a[0]);
      if (root === undefined) throw new Error(`Unsupported Actions context: ${a[0]}`);
      return a.slice(1).reduce((value, key) => {
        if (value == null) return '';
        const field = root === 'env' && !windows ? key : Object.keys(Object(value)).find(name => name.toLowerCase() === key.toLowerCase());
        return field !== undefined && Object.hasOwn(Object(value), field) ? value[field] : '';
      }, context[root]);
    }
    if (type === 'not') return !truthy(visit(a));
    if (type === '&&') { const value = visit(a); return truthy(value) ? visit(b) : value; }
    if (type === '||') { const value = visit(a); return truthy(value) ? value : visit(b); }
    if (type === '==' || type === '!=') { const same = equal(visit(a), visit(b)); return type === '==' ? same : !same; }
    const args = b.map(visit);
    if (type === 'call') {
      if (['success', 'failure', 'cancelled', 'always'].includes(a) && args.length === 0) {
        return a === 'always' || (a === 'success' ? !context.failure && !context.cancelled : Boolean(context[a]));
      }
      if (a === 'tojson' && args.length === 1) return JSON.stringify(args[0]);
      if (a === 'fromjson' && args.length === 1) return JSON.parse(args[0]);
      if (a === 'contains' && args.length === 2) return Array.isArray(args[0]) ? args[0].some(x => equal(x, args[1])) : String(args[0]).toLowerCase().includes(String(args[1]).toLowerCase());
      if (a === 'startswith' && args.length === 2) return String(args[0]).toLowerCase().startsWith(String(args[1]).toLowerCase());
      if (a === 'endswith' && args.length === 2) return String(args[0]).toLowerCase().endsWith(String(args[1]).toLowerCase());
      if (a === 'format' && args.length) return String(args[0]).replace(/\{(\d+)\}/g, (_, i) => string(args[Number(i) + 1]));
      throw new Error(`Unsupported Actions function: ${a}`);
    }
    throw new Error('Unsupported Actions expression');
  };
  const hasStatus = node => Array.isArray(node) && ((node[0] === 'call' && ['always', 'success', 'failure', 'cancelled'].includes(node[1])) || node.some(hasStatus));
  return implicitSuccess && !hasStatus(tree) && (context.failure || context.cancelled) ? false : visit(tree);
}
export function truthy(value) { return value !== false && value !== null && value !== undefined && value !== '' && value !== 0 && !Number.isNaN(value); }
function equal(a, b) {
  if (typeof a === typeof b) return typeof a === 'string' ? a.toLowerCase() === b.toLowerCase() : a === b;
  const number = value => value === null || value === '' ? 0 : Number(value);
  return number(a) === number(b);
}
export function string(value) { return value === null || value === undefined ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value); }
export function interpolate(value, context) {
  if (typeof value !== 'string') return string(value);
  let rest = value, output = '';
  while (rest.includes('${{')) {
    const start = rest.indexOf('${{');
    output += rest.slice(0, start);
    let end = start + 3, quoted = false;
    for (; end < rest.length; end++) {
      if (rest[end] === "'") { if (quoted && rest[end + 1] === "'") { end++; continue; } quoted = !quoted; }
      if (!quoted && rest.slice(end, end + 2) === '}}') break;
    }
    if (end >= rest.length) throw new Error('Unterminated Actions expression');
    output += string(evaluate(rest.slice(start + 3, end), context));
    rest = rest.slice(end + 2);
  }
  return output + rest;
}

import { windows } from './platform.mjs';
import { hashFiles } from './hash-files.mjs';
// A small, parsed Actions expression language; never evaluates JavaScript.
const forbidden = new Set(['__proto__', 'prototype', 'constructor']);
function* expression(source, context = {}, implicitSuccess = false) {
  source = source.trim();
  if (source.startsWith('${{') && source.endsWith('}}')) source = source.slice(3, -2);
  const tokens = [];
  const pattern = /\s*(?:('(?:[^']|'')*')|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([a-zA-Z_][\w-]*)|(==|!=|<=|>=|&&|\|\||[!<>().,\[\]]))/gy;
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
  const precedence = { '||': 1, '&&': 2, '==': 3, '!=': 3, '<': 4, '<=': 4, '>': 4, '>=': 4 };
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
  const visit = function* (node) {
    const [type, a, b] = node;
    if (type === 'value') return a;
    if (type === 'path') {
      const root = Object.keys(context).find(key => key.toLowerCase() === a[0]);
      if (root === undefined) throw new Error(`Unsupported Actions context: ${a[0]}`);
      const missing = a[0] === 'matrix' ? null : '';
      return a.slice(1).reduce((value, key) => {
        if (value == null) return missing;
        const field = root === 'env' && !windows ? key : Object.keys(Object(value)).find(name => name.toLowerCase() === key.toLowerCase());
        return field !== undefined && Object.hasOwn(Object(value), field) ? value[field] : missing;
      }, context[root]);
    }
    if (type === 'not') return !truthy(yield* visit(a));
    if (type === '&&') { const value = yield* visit(a); return truthy(value) ? yield* visit(b) : value; }
    if (type === '||') { const value = yield* visit(a); return truthy(value) ? value : yield* visit(b); }
    if (precedence[type]) {
      const left = yield* visit(a);
      const right = yield* visit(b);
      if (type === '==') return equal(left, right);
      if (type === '!=') return !equal(left, right);
      return compare(type, left, right);
    }
    if (type === 'call') {
      if (a === 'join' && (b.length === 1 || b.length === 2)) {
        const items = yield* visit(b[0]);
        if (!Array.isArray(items)) return isPrimitive(items) ? string(items) : '';
        const separator = items.length > 1 && b.length === 2 ? yield* visit(b[1]) : ',';
        const delimiter = isPrimitive(separator) ? string(separator) : ',';
        const values = items.map(item => {
          if (isPrimitive(item)) return string(item);
          return Array.isArray(item) ? 'Array' : 'Object';
        });
        let bytes = Buffer.byteLength(delimiter) * Math.max(0, values.length - 1);
        for (const value of values) bytes += Buffer.byteLength(value);
        if (bytes > 1048576) throw new Error('join() output exceeds 1 MiB');
        return values.join(delimiter);
      }
      const args = [];
      for (const argument of b) args.push(yield* visit(argument));
      if (['success', 'failure', 'cancelled', 'always'].includes(a) && args.length === 0) {
        return a === 'always' || (a === 'success' ? !context.failure && !context.cancelled : Boolean(context[a]));
      }
      if (a === 'hashfiles') return yield () => hashFiles(context.github?.workspace, args);
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
  return implicitSuccess && !hasStatus(tree) && (context.failure || context.cancelled) ? false : yield* visit(tree);
}
export function evaluate(source, context = {}, implicitSuccess = false) {
  const result = expression(source, context, implicitSuccess).next();
  if (!result.done) throw new Error('hashFiles requires asynchronous expression evaluation');
  return result.value;
}
export async function evaluateAsync(source, context = {}, implicitSuccess = false) {
  const iterator = expression(source, context, implicitSuccess);
  let result = iterator.next();
  while (!result.done) result = iterator.next(await result.value());
  return result.value;
}
export function truthy(value) { return value !== false && value !== null && value !== undefined && value !== '' && value !== 0 && !Number.isNaN(value); }
function isPrimitive(value) {
  return value == null || ['boolean', 'number', 'string'].includes(typeof value);
}
function comparisonNumber(value) {
  if (typeof value !== 'string') return Number(value);
  const text = value.replace(/^\p{White_Space}+|(?<!\p{White_Space})\p{White_Space}+$/gu, '');
  if (text === '') return 0;
  // Double.TryParse accepts trailing NULs after the decimal number.
  const decimal = /^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\0*$/.exec(text);
  if (decimal) return Number(decimal[1]);
  if (/^[+-]?infinity$/i.test(text)) return text.startsWith('-') ? -Infinity : Infinity;
  if (/^(?:0x[0-9a-fA-F]+|0o[0-7]+)$/.test(text)) {
    const integer = Number(text);
    return integer <= 0xffffffff ? integer | 0 : NaN;
  }
  return NaN;
}

function ordinalUppercase(character) {
  const codePoint = character.codePointAt(0);
  // Ordinal casing excludes dotless i and long s from the ASCII mappings.
  if (codePoint === 0x0131 || codePoint === 0x017f) return codePoint;
  // The simple Greek iota-subscript mappings preserve a single code point.
  if (codePoint >= 0x1f80 && codePoint <= 0x1fa7 && (codePoint & 0xf) < 8) return codePoint + 8;
  if (codePoint === 0x1fb3 || codePoint === 0x1fc3 || codePoint === 0x1ff3) return codePoint + 9;
  const uppercase = character.toUpperCase();
  const mapped = uppercase.codePointAt(0);
  return uppercase.length === (mapped > 0xffff ? 2 : 1) ? mapped : codePoint;
}

function compareOrdinalIgnoreCase(left, right) {
  const rightCharacters = right[Symbol.iterator]();
  for (const leftCharacter of left) {
    const next = rightCharacters.next();
    if (next.done) return 1;
    if (leftCharacter === next.value) continue;
    const difference = ordinalUppercase(leftCharacter) - ordinalUppercase(next.value);
    if (difference !== 0) return difference;
  }
  return rightCharacters.next().done ? 0 : -1;
}

function compare(operator, left, right) {
  if (typeof left === 'string' && typeof right === 'string') {
    left = compareOrdinalIgnoreCase(left, right);
    right = 0;
  } else if (isPrimitive(left) && isPrimitive(right)) {
    left = comparisonNumber(left);
    right = comparisonNumber(right);
  } else {
    return left === right && (operator === '<=' || operator === '>=');
  }
  switch (operator) {
    case '<': return left < right;
    case '<=': return left <= right;
    case '>': return left > right;
    case '>=': return left >= right;
  }
}
function equal(a, b) {
  if (typeof a === typeof b) return typeof a === 'string' ? a.toLowerCase() === b.toLowerCase() : a === b;
  const number = value => value === null || value === '' ? 0 : Number(value);
  return number(a) === number(b);
}
export function string(value) { return value === null || value === undefined ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value); }
function* interpolation(value, context) {
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
    output += string(yield* expression(rest.slice(start + 3, end), context));
    rest = rest.slice(end + 2);
  }
  return output + rest;
}

export function interpolate(value, context) {
  const result = interpolation(value, context).next();
  if (!result.done) throw new Error('hashFiles requires asynchronous expression evaluation');
  return result.value;
}
export async function interpolateAsync(value, context) {
  const iterator = interpolation(value, context);
  let result = iterator.next();
  while (!result.done) result = iterator.next(await result.value());
  return result.value;
}

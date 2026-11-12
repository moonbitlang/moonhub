import { readFileSync, writeFileSync } from 'node:fs';
import * as lucide from 'lucide';

const icons = {
  bold: 'Bold', heading: 'Heading', quote: 'Quote', list: 'List', 'list-ordered': 'ListOrdered', link: 'Link', undo: 'Undo2', redo: 'Redo2',
  'book-open': 'BookOpen', 'chevron-down': 'ChevronDown',
  'chevron-right': 'ChevronRight', 'chevrons-up-down': 'ChevronsUpDown',
  check: 'Check', 'circle-check': 'CircleCheck', 'circle-dot': 'CircleDot',
  code: 'Code', contact: 'Contact', copy: 'Copy', download: 'Download',
  ellipsis: 'Ellipsis', file: 'File', folder: 'Folder', folders: 'Folders',
  'tag': 'Tag',
  'git-branch': 'GitBranch', 'git-commit': 'GitCommitHorizontal',
  'git-pull-request': 'GitPullRequest', globe: 'Globe', grid: 'Grid2X2',
  key: 'KeyRound', lock: 'Lock', 'log-out': 'LogOut', mail: 'Mail', menu: 'Menu',
  moon: 'Moon', 'panel-left-close': 'PanelLeftClose', 'panel-left-open': 'PanelLeftOpen',
  plus: 'Plus', search: 'Search', send: 'Send', settings: 'Settings', terminal: 'Terminal',
  user: 'User', 'user-plus': 'UserPlus', users: 'Users', x: 'X',
};

const escapeAttribute = value => String(value).replace(/[&"<>]/g, character => ({
  '&': '&amp;', '"': '&quot;', '<': '&lt;', '>': '&gt;',
})[character]);

const variables = [];
const selectors = [];
for (const [name, exportName] of Object.entries(icons)) {
  const nodes = lucide[exportName];
  if (!Array.isArray(nodes)) throw new Error(`Missing Lucide icon: ${exportName}`);
  const contents = nodes.map(([tag, attributes]) => {
    const attrs = Object.entries(attributes).map(([key, value]) => `${key}="${escapeAttribute(value)}"`).join(' ');
    return `<${tag} ${attrs}/>`;
  }).join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">${contents}</svg>`;
  variables.push(`  --icon-${name}: url("data:image/svg+xml,${encodeURIComponent(svg)}");`);
  selectors.push(`[data-icon="${name}"] { --ui-icon: var(--icon-${name}); }`);
}

const license = readFileSync(new URL('../node_modules/lucide/LICENSE', import.meta.url), 'utf8');
writeFileSync(new URL('../src/icons.generated.css', import.meta.url),
  `/* Generated from Lucide by scripts/generate-icons.mjs. Do not edit. */\n/*!\n${license}\n*/\n:root {\n${variables.join('\n')}\n}\n${selectors.join('\n')}\n`);

import { start } from '../../_build/js/release/build/hackwaly/moonhub/web/client/client.js';
import { mountShell } from './page-shell';
import { mountMarkdownEditors } from './markdown-editor';
import { mountRepoClone } from './repo-clone';
import { mountPipelineLogs } from './pipeline-logs';

const pageType = 'application/vnd.moonhub.page+json';
let lifetime = new AbortController();
let request: AbortController | undefined;
let serial = 0;
let submitting = false;
let committing = false;
let restoringHistory: number | undefined;
let currentURL = new URL(location.href);
let historyIndex = 0;
const positions = new Map<number, [number, number]>();

function enhance() {
  const { signal } = lifetime;
  mountShell(signal);
  mountMarkdownEditors(signal);
  mountRepoClone(signal);
  mountPipelineLogs(signal);
  // Custom elements own their children and unmount themselves on disconnection.
  if (document.querySelector('moonhub-file-view, moonhub-commit-diff')) {
    void import('./custom-elements').catch(error => console.error('Code view unavailable', error));
  }
}

function mayLeave() {
  return document.dispatchEvent(new Event('moonhub:before-navigate', { cancelable: true }));
}

function feedback(message: string) {
  let notice = document.getElementById('navigation-error');
  if (!notice) {
    notice = document.createElement('p'); notice.id = 'navigation-error';
    notice.className = 'error'; notice.setAttribute('role', 'alert');
    document.querySelector('main')?.prepend(notice);
  }
  notice.textContent = message;
}

function finishForms() {
  document.querySelectorAll('form[aria-busy]').forEach(form => form.removeAttribute('aria-busy'));
  document.querySelectorAll<HTMLElement>('button[aria-disabled=true]').forEach(button => {
    button.removeAttribute('aria-disabled'); button.style.removeProperty('width');
  });
}

// Call only before a commit or mutation starts. Invalidate the sequence too:
// an already received response can still be waiting for its body.
function cancelNavigation() {
  request?.abort(); request = undefined;
  serial++;
  document.documentElement.removeAttribute('aria-busy');
  finishForms();
}

function scrollToPage(url: URL, position?: [number, number]) {
  const main = document.querySelector<HTMLElement>('#main-content');
  main?.focus({ preventScroll: true });
  if (position) { scrollTo(...position); return; }
  let target: HTMLElement | null = null;
  try { target = document.getElementById(decodeURIComponent(url.hash.slice(1))); } catch { /* Invalid escape in a user URL. */ }
  if (url.hash && target) target.scrollIntoView(); else scrollTo(0, 0);
}

function render(json: string) {
  return new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      document.removeEventListener('moonhub:rendered', done);
      reject(new Error('Page rendering timed out.'));
    }, 10000);
    function done() { clearTimeout(timeout); resolve(); }
    document.addEventListener('moonhub:rendered', done, { once: true });
    document.dispatchEvent(new CustomEvent('moonhub:page', { detail: json }));
  });
}

function restoreHistory(index: number) {
  if (index === historyIndex) return;
  restoringHistory = historyIndex;
  history.go(historyIndex - index);
}

async function navigate(url: URL, options: { body?: URLSearchParams; pop?: number } = {}) {
  if (submitting || committing) {
    if (options.pop !== undefined) restoreHistory(options.pop);
    return;
  }
  const mutation = options.body !== undefined;
  if (!mayLeave()) {
    if (options.pop !== undefined) restoreHistory(options.pop);
    finishForms(); return;
  }
  request?.abort();
  const controller = new AbortController(); request = controller;
  const sequence = ++serial;
  submitting = mutation;
  document.documentElement.setAttribute('aria-busy', 'true');
  positions.set(historyIndex, [scrollX, scrollY]);
  try {
    const response = await fetch(url, {
      method: mutation ? 'POST' : 'GET', body: options.body,
      headers: { Accept: pageType }, credentials: 'same-origin', cache: 'no-store',
      signal: controller.signal,
    });
    if (sequence !== serial) return;
    const destination = new URL(response.url || url.href);
    if (destination.origin !== location.origin) throw new Error('The page redirected to another site.');
    // Downloads, raw blobs and other non-page endpoints keep browser navigation.
    if (!(response.headers.get('content-type') ?? '').startsWith(pageType)) {
      location.assign(destination.href); return;
    }
    const json = await response.text();
    const page = JSON.parse(json) as { head?: unknown[]; body?: unknown[] };
    if (!Array.isArray(page.head) || !Array.isArray(page.body)) throw new Error('Invalid page response.');
    if (sequence !== serial) return;
    // A deployment may change the client protocol or assets mid-session.
    const shell = JSON.stringify(page.head).match(/app-shell-[A-Za-z0-9_-]+[.]mjs/);
    const activeShell = document.querySelector<HTMLScriptElement>('script[type=module][src*=app-shell-]');
    if (shell && activeShell && !activeShell.src.endsWith(shell[0])) { location.assign(destination.href); return; }
    if (destination.pathname === url.pathname && destination.search === url.search) destination.hash = url.hash;
    committing = true;
    lifetime.abort();
    if (options.pop !== undefined) historyIndex = options.pop;
    else {
      // A superseded popstate may have moved the browser without mounting it.
      historyIndex = history.state.moonhub + 1;
      history.pushState({ moonhub: historyIndex }, '', destination);
    }
    currentURL = destination;
    await render(json);
    lifetime = new AbortController();
    enhance();
    scrollToPage(destination, options.pop === undefined ? undefined : positions.get(historyIndex));
    document.dispatchEvent(new Event('moonhub:navigated'));
  } catch (error) {
    if (controller.signal.aborted) return;
    if (!mutation) { location.assign(url.href); return; }
    // A lost POST response is ambiguous: never replay a mutation automatically.
    feedback('The result could not be loaded. Check the page before submitting again; your text is preserved.');
    console.error('Navigation failed', error);
  } finally {
    if (sequence === serial) {
      submitting = false; committing = false; request = undefined;
      document.documentElement.removeAttribute('aria-busy'); finishForms();
    }
  }
}

function installNavigation() {
  history.replaceState({ moonhub: historyIndex }, '', location.href);
  history.scrollRestoration = 'manual';
  window.addEventListener('scroll', () => positions.set(historyIndex, [scrollX, scrollY]), { passive: true });
  document.addEventListener('click', event => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target instanceof Element ? event.target.closest<HTMLAnchorElement>('a[href]') : null;
    if (!link || link.hasAttribute('download') || link.hasAttribute('data-native-navigation') || link.target && link.target !== '_self') return;
    const url = new URL(link.href);
    if (url.origin !== location.origin || !['http:', 'https:'].includes(url.protocol)) return;

    if (submitting || committing) { event.preventDefault(); return; }
    event.preventDefault();
    if (url.pathname === currentURL.pathname && url.search === currentURL.search && url.hash) {
      cancelNavigation();
      positions.set(historyIndex, [scrollX, scrollY]);
      historyIndex = history.state.moonhub + 1;
      history.pushState({ moonhub: historyIndex }, '', url);
      currentURL = url;
      scrollToPage(url);
      return;
    }
    void navigate(url);
  });
  document.addEventListener('submit', event => {
    if (event.defaultPrevented || !(event.target instanceof HTMLFormElement)) return;
    const form = event.target;
    const submitter = (event as SubmitEvent).submitter;
    const button = submitter instanceof HTMLButtonElement || submitter instanceof HTMLInputElement ? submitter : null;
    const target = button?.getAttribute('formtarget') ?? form.target;
    const method = (button?.getAttribute('formmethod') ?? form.method).toLowerCase();
    const encoding = button?.getAttribute('formenctype') ?? form.enctype;
    const url = new URL(button?.getAttribute('formaction') ?? form.action, location.href);
    if (form.hasAttribute('data-native-navigation') || target && target !== '_self' || url.origin !== location.origin || !['get', 'post'].includes(method) || encoding !== 'application/x-www-form-urlencoded') return;
    event.preventDefault();
    if (submitting || committing) { finishForms(); return; }
    const data = new FormData(form, button);
    const body = new URLSearchParams();
    for (const [key, value] of data) { if (typeof value !== 'string') { feedback('This form requires a full page submission.'); finishForms(); return; } body.append(key, value); }
    if (method === 'get') { url.search = body.toString(); void navigate(url); }
    else void navigate(url, { body });
  });
  window.addEventListener('popstate', event => {
    if (typeof event.state?.moonhub !== 'number') { location.reload(); return; }
    if (restoringHistory === event.state.moonhub) { restoringHistory = undefined; return; }
    if (submitting || committing) { restoreHistory(event.state.moonhub); return; }
    // Returning to the mounted page also supersedes any pending page fetch.
    if (location.pathname === currentURL.pathname && location.search === currentURL.search) {
      cancelNavigation();
      historyIndex = event.state.moonhub;
      currentURL = new URL(location.href);
      scrollToPage(currentURL, positions.get(historyIndex));
      return;
    }
    void navigate(new URL(location.href), { pop: event.state.moonhub });
  });
  window.addEventListener('hashchange', () => {
    if (location.pathname === currentURL.pathname && location.search === currentURL.search) currentURL = new URL(location.href);
  });
}

const bootstrap = document.getElementById('moonhub-bootstrap');
try {
  if (!bootstrap?.textContent) throw new Error('Missing page state.');
  const result = start(bootstrap.textContent);
  if (result.$tag === 0) throw new Error('Invalid initial page state.');
  // Injected hydration scripts are not owned by the page VDOM. Do not retain
  // the initial authorized state (including one-time credentials) after use.
  bootstrap.remove();
  document.getElementById('__rabbita_transcript')?.remove();
  enhance();
  installNavigation();
  document.documentElement.dataset.hydrated = 'true';
} catch (error) {
  lifetime.abort();
  document.documentElement.removeAttribute('data-ui-enhanced');
  document.documentElement.removeAttribute('data-sidebar-collapsed');
  console.error('MoonHub hydration failed; server-rendered navigation remains available.', error);
}

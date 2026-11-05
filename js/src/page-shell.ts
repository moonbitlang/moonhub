export function mountShell(signal: AbortSignal) {
  const intervals: ReturnType<typeof setInterval>[] = [];
  signal.addEventListener("abort", () => { intervals.forEach(clearInterval); root.removeAttribute("data-navigation-open"); root.removeAttribute("data-ui-ready"); }, { once: true });

  const root = document.documentElement;
  const sidebar = document.querySelector<HTMLElement>("#app-sidebar");
  const main = document.querySelector<HTMLElement>("#main-content");
  const header = document.querySelector<HTMLElement>(".site-header");
  const openButton = document.querySelector<HTMLButtonElement>("[data-sidebar-open]");
  const collapseButton = document.querySelector<HTMLButtonElement>("[data-sidebar-collapse]");
  const scrim = document.querySelector<HTMLButtonElement>(".sidebar-scrim");
  const mobile = matchMedia("(max-width: 900px)");
  let returnFocus: HTMLElement | null = null;

  function syncCollapseButton() {
    if (!collapseButton) return;
    const collapsed = root.dataset.sidebarCollapsed === "true";
    const label = collapsed ? "Expand sidebar" : "Collapse sidebar";
    collapseButton.setAttribute("aria-expanded", String(!collapsed));
    collapseButton.setAttribute("aria-label", label);
    collapseButton.title = label;
    collapseButton.querySelector(".nav-label")!.textContent = label;
  }

  function setDrawer(open: boolean, restoreFocus = true) {
    if (!sidebar || !mobile.matches && open) return;
    if (open) returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    root.toggleAttribute("data-navigation-open", open);
    openButton?.setAttribute("aria-expanded", String(open));
    if (scrim) scrim.hidden = !open;
    if (main) main.inert = open;
    if (header) header.inert = open;
    if (mobile.matches) sidebar.inert = !open;
    if (open) {
      sidebar.setAttribute("role", "dialog");
      sidebar.setAttribute("aria-modal", "true");
      sidebar.querySelector<HTMLElement>("[data-sidebar-close]")?.focus();
    } else {
      sidebar.removeAttribute("role");
      sidebar.removeAttribute("aria-modal");
      if (restoreFocus) returnFocus?.focus();
    }
  }

  root.toggleAttribute("data-ui-enhanced", !!sidebar);
  if (sidebar) {
    try { root.dataset.sidebarCollapsed = String(localStorage.getItem("moonhub.sidebar") === "collapsed"); } catch { /* Storage can be disabled. */ }
    root.dataset.uiReady = "true";
    if (openButton) { openButton.hidden = false; openButton.inert = false; }
    if (collapseButton) {
      collapseButton.hidden = false;
      collapseButton.inert = false;
      collapseButton.addEventListener("click", () => {
        const collapsed = root.dataset.sidebarCollapsed !== "true";
        root.dataset.sidebarCollapsed = String(collapsed);
        try { localStorage.setItem("moonhub.sidebar", collapsed ? "collapsed" : "expanded"); } catch { /* Storage can be disabled. */ }
        syncCollapseButton();
      }, { signal });
    }
    syncCollapseButton();
    sidebar.inert = mobile.matches;
    sidebar.querySelectorAll<HTMLButtonElement>("[data-sidebar-close]").forEach(button => { button.hidden = false; });
    openButton?.addEventListener("click", () => setDrawer(!root.hasAttribute("data-navigation-open")), { signal });
    document.querySelectorAll("[data-sidebar-close]").forEach(button => button.addEventListener("click", () => setDrawer(false), { signal }));
    mobile.addEventListener("change", () => {
      setDrawer(false, false);
      sidebar.inert = mobile.matches;
    }, { signal });
    sidebar.addEventListener("keydown", event => {
      if (!root.hasAttribute("data-navigation-open") || event.key !== "Tab") return;
      const focusable = [...sidebar.querySelectorAll<HTMLElement>("a[href], button:not([disabled]), summary")]
        .filter(element => element.checkVisibility());
      const first = focusable[0], last = focusable.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    }, { signal });
  }

  if (!sidebar) root.removeAttribute("data-sidebar-collapsed");

  document.addEventListener("keydown", event => {
    if (event.key !== "Escape") return;
    const details = document.querySelector<HTMLDetailsElement>("[data-dismissable][open]");
    if (details) {
      details.open = false;
      details.querySelector("summary")?.focus();
      event.preventDefault();
    } else if (root.hasAttribute("data-navigation-open")) {
      setDrawer(false);
      event.preventDefault();
    }
  }, { signal });
  const menus = [...document.querySelectorAll<HTMLDetailsElement>("[data-dismissable]")];
  for (const menu of menus) {
    menu.addEventListener("toggle", () => {
      if (menu.open) {
        menus.filter(other => other !== menu).forEach(other => { other.open = false; });
        const panel = menu.querySelector<HTMLElement>(".row-menu-panel");
        if (panel) {
          menu.removeAttribute("data-open-up");
          menu.toggleAttribute("data-open-up", panel.getBoundingClientRect().bottom > innerHeight - 12);
        }
      }
    }, { signal });
  }
  document.addEventListener("click", event => {
    if (!(event.target instanceof Node)) return;
    for (const menu of menus) if (menu.open && !menu.contains(event.target)) menu.open = false;
  }, { signal });

  for (const list of document.querySelectorAll<HTMLElement>("[data-filter-list]")) {
    const input = list.querySelector<HTMLInputElement>("[data-list-filter]");
    if (!input) continue;
    const items = [...list.querySelectorAll<HTMLElement>("[data-filter-item]")];
    const total = list.querySelector<HTMLElement>("[data-list-total]");
    const empty = list.querySelector<HTMLElement>("[data-filter-empty]");
    const control = list.querySelector<HTMLElement>("[data-filter-control]");
    if (control) { control.hidden = false; control.inert = false; }
    if (total) { total.setAttribute("role", "status"); total.setAttribute("aria-live", "polite"); }
    input.addEventListener("input", () => {
      const query = input.value.trim().toLocaleLowerCase();
      let count = 0;
      for (const item of items) {
        item.hidden = !(item.dataset.filterText ?? item.textContent ?? "").toLocaleLowerCase().includes(query);
        if (!item.hidden) count++;
      }
      if (total) total.textContent = `${count} ${count === 1 ? "repository" : "repositories"}`;
      if (empty) empty.hidden = count !== 0;
    }, { signal });
  }

  // Native serialization still needs every field and the clicked submitter.
  for (const form of document.querySelectorAll<HTMLFormElement>("form[method=post]")) {
    form.addEventListener("submit", event => {
      if (form.getAttribute("aria-busy") === "true") { event.preventDefault(); return; }
      if (event.defaultPrevented) return;
      form.setAttribute("aria-busy", "true");
      const submitter = (event as SubmitEvent).submitter;
      if (submitter instanceof HTMLButtonElement) {
        submitter.style.width = `${submitter.getBoundingClientRect().width}px`;
        submitter.setAttribute("aria-disabled", "true");
      }
    }, { signal });
  }
  window.addEventListener("pageshow", () => {
    document.querySelectorAll("form[aria-busy]").forEach(form => form.removeAttribute("aria-busy"));
    document.querySelectorAll<HTMLButtonElement>("button[aria-disabled=true]").forEach(button => {
      button.removeAttribute("aria-disabled");
      button.style.removeProperty("width");
    });
  }, { signal });

  function syncSettingsAnchor() {
    const links = [...document.querySelectorAll<HTMLAnchorElement>(".context-navigation a[href*='/admin/settings/ssh#']")];
    const hash = location.hash || "#ssh-access";
    for (const link of links) {
      if (new URL(link.href).hash === hash) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
  }
  syncSettingsAnchor();
  window.addEventListener("hashchange", syncSettingsAnchor, { signal });

  const inboxCount = document.querySelector<HTMLElement>("[data-inbox-count]");
  if (inboxCount) {
    let refreshing = false;
    const refreshInbox = async () => {
      if (signal.aborted || document.hidden || refreshing) return;
      refreshing = true;
      try {
        const response = await fetch("/-/notifications/count", {
          credentials: "same-origin", cache: "no-store", redirect: "error",
          signal: AbortSignal.any([signal, AbortSignal.timeout(5000)]),
        });
        if (!response.ok) return;
        const value = (await response.text()).trim();
        if (!/^\d+$/.test(value)) return;
        const count = Number(value);
        inboxCount.textContent = count > 99 ? "99+" : value;
        inboxCount.hidden = count === 0;
        const link = inboxCount.closest("a");
        link?.setAttribute("aria-label", count > 0 ? `Inbox, ${value} unread notifications` : "Inbox");
      } catch { /* The server-rendered inbox link remains usable offline. */ }
      finally { refreshing = false; }
    };
    void refreshInbox();
    intervals.push(setInterval(() => { void refreshInbox(); }, 60000));
    document.addEventListener("visibilitychange", () => { void refreshInbox(); }, { signal });
  }

  // Server-rendered GET navigation remains the no-script fallback.
  for (const form of document.querySelectorAll<HTMLFormElement>('form[data-auto-submit]')) {
    form.dataset.enhanced = 'true';
    form.addEventListener('change', event => { if (event.target instanceof HTMLSelectElement) form.requestSubmit(); }, { signal });
  }
  for (const form of document.querySelectorAll<HTMLFormElement>('[data-branch-comparison]')) {
    const source = form.querySelector<HTMLSelectElement>('[name=source]')!, target = form.querySelector<HTMLSelectElement>('[name=target]')!;
    const warning = form.querySelector<HTMLElement>('[data-branch-warning]')!;
    const validate = () => { const invalid = source.value === target.value; source.setCustomValidity(invalid ? 'Choose different source and target branches.' : ''); warning.hidden = !invalid; };
    source.addEventListener('change', validate, { signal }); target.addEventListener('change', validate, { signal }); validate();
  }
  const actor = document.querySelector('.account-identity span')?.textContent ?? '';
  for (const form of document.querySelectorAll<HTMLFormElement>('.mr-form')) {
    const contentFields = [...form.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>('input[name=title], textarea[name=description], textarea[name=body]')];
    const fields: (HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement)[] = [...contentFields, ...(form.hasAttribute('data-inline-form') ? form.querySelectorAll<HTMLInputElement | HTMLSelectElement>('input[name=path], input[name=start_line], input[name=end_line], select[name=side], input[name=document_id], input[name=file_id], input[name=hunk_id], input[name=diff_page], input[name=mode], input[name=ignore_comments], input[name=ignore_tests]') : [])];
    if (!actor || !fields.length) continue;
    const version = form.querySelector<HTMLInputElement>('input[name=version]')?.value ?? document.querySelector<HTMLSelectElement>('#mr-version')?.value ?? '';
    const discussion = form.querySelector<HTMLInputElement>('input[name=discussion]')?.value;
    const key = `moonhub.draft:${actor}:${form.action || location.pathname}:${version}${discussion ? `:discussion:${discussion}` : ''}`;
    const draftKey = key + (form.hasAttribute('data-inline-form') ? ':commit:' + (form.querySelector<HTMLInputElement>('input[name=commit]')?.value ?? '') : '');
    let canStore = true, dirty = false;
    try {
      const raw = sessionStorage.getItem(draftKey);
      if (raw) {
        const draft = JSON.parse(raw) as { at: number; fields: Record<string, string>; pending: boolean };
        if (Date.now() - draft.at > 86400000 || draft.pending && contentFields.every(field => !field.value)) sessionStorage.removeItem(draftKey);
        else if (contentFields.every(field => !field.value)) {
          for (const field of fields) field.value = draft.fields[field.name] ?? '';
          const notice = document.createElement('p'); notice.className = 'draft-notice muted'; notice.setAttribute('role', 'status'); notice.textContent = 'Unsent draft restored for this version.'; form.prepend(notice);
        }
      }
    } catch { canStore = false; }
    const save = (pending = false) => {
      try { sessionStorage.setItem(draftKey, JSON.stringify({ at: Date.now(), pending, fields: Object.fromEntries(fields.map(field => [field.name, field.value])) })); }
      catch { canStore = false; }
    };
    form.addEventListener('input', () => { dirty = true; save(); }, { signal });
    form.addEventListener('submit', event => { if (!event.defaultPrevented && form.checkValidity()) { save(true); dirty = false; } }, { signal });
    document.addEventListener('moonhub:before-navigate', event => { if (dirty && !canStore) event.preventDefault(); }, { signal });
    window.addEventListener('beforeunload', event => { if (dirty && !canStore) { event.preventDefault(); event.returnValue = ''; } }, { signal });
  }
  document.querySelector('.logout-form')?.addEventListener('submit', () => {
    try { for (const key of Object.keys(sessionStorage)) if (key.startsWith('moonhub.draft:')) sessionStorage.removeItem(key); } catch { /* Private browsing may disallow storage. */ }
  }, { signal });
  const timeElements = [...document.querySelectorAll<HTMLTimeElement>('time[data-relative-time]')];
  function relativeTimes() {
    const formatter = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
    for (const element of timeElements) {
      const dateTime = element.dateTime.replace(' ', 'T');
      const timestamp = Date.parse(/[zZ]|[+-]\d\d:\d\d$/.test(dateTime) ? dateTime : dateTime + 'Z'); if (!Number.isFinite(timestamp)) continue;
      const seconds = (timestamp - Date.now()) / 1000, magnitude = Math.abs(seconds);
      const [unit, divisor] = magnitude < 60 ? ['second', 1] : magnitude < 3600 ? ['minute', 60] : magnitude < 86400 ? ['hour', 3600] : ['day', 86400];
      element.textContent = formatter.format(Math.round(seconds / divisor), unit as Intl.RelativeTimeFormatUnit);
    }
  }
  relativeTimes(); if (timeElements.length) intervals.push(setInterval(relativeTimes, 60000));
  for (const detail of document.querySelectorAll<HTMLDetailsElement>('[data-mobile-details]')) {
    const compact = matchMedia('(max-width: 700px)');
    if (compact.matches) detail.open = false;
    compact.addEventListener('change', () => { detail.open = !compact.matches; }, { signal });
  }

}

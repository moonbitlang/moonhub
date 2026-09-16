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

if (sidebar) {
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
    });
  }
  syncCollapseButton();
  sidebar.inert = mobile.matches;
  sidebar.querySelectorAll<HTMLButtonElement>("[data-sidebar-close]").forEach(button => { button.hidden = false; });
  openButton?.addEventListener("click", () => setDrawer(!root.hasAttribute("data-navigation-open")));
  document.querySelectorAll("[data-sidebar-close]").forEach(button => button.addEventListener("click", () => setDrawer(false)));
  mobile.addEventListener("change", () => {
    setDrawer(false, false);
    sidebar.inert = mobile.matches;
  });
  sidebar.addEventListener("keydown", event => {
    if (!root.hasAttribute("data-navigation-open") || event.key !== "Tab") return;
    const focusable = [...sidebar.querySelectorAll<HTMLElement>("a[href], button:not([disabled]), summary")]
      .filter(element => element.checkVisibility());
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  });
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
});
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
  });
}
document.addEventListener("click", event => {
  if (!(event.target instanceof Node)) return;
  for (const menu of menus) if (menu.open && !menu.contains(event.target)) menu.open = false;
});

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
  });
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
  });
}
window.addEventListener("pageshow", () => {
  document.querySelectorAll("form[aria-busy]").forEach(form => form.removeAttribute("aria-busy"));
  document.querySelectorAll<HTMLButtonElement>("button[aria-disabled=true]").forEach(button => {
    button.removeAttribute("aria-disabled");
    button.style.removeProperty("width");
  });
});

function syncSettingsAnchor() {
  const links = [...document.querySelectorAll<HTMLAnchorElement>(".context-navigation a[href*='/admin/settings/ssh#']")];
  const hash = location.hash || "#ssh-access";
  for (const link of links) {
    if (new URL(link.href).hash === hash) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
}
syncSettingsAnchor();
window.addEventListener("hashchange", syncSettingsAnchor);

import { Check, ChevronDown, Copy, createElement, type IconNode } from "lucide";

function icon(node: IconNode): SVGElement {
  return createElement(node, { width: 16, height: 16, "aria-hidden": "true", focusable: "false" });
}

for (const details of document.querySelectorAll<HTMLDetailsElement>("details.repo-clone")) {
  const summary = details.querySelector<HTMLElement>("summary")!;
  summary.querySelector("[data-clone-icon]")?.replaceChildren(icon(ChevronDown));
  const input = details.querySelector<HTMLInputElement>("[data-clone-url]");
  const copy = details.querySelector<HTMLButtonElement>("[data-clone-copy]");
  const status = details.querySelector<HTMLElement>("[data-clone-status]");
  let reset: ReturnType<typeof setTimeout> | undefined;
  if (input && copy && status) {
    copy.replaceChildren(icon(Copy));
    copy.disabled = false;
    input.addEventListener("click", () => input.select());
    copy.addEventListener("click", async () => {
      clearTimeout(reset);
      copy.disabled = true;
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(input.value);
        copy.replaceChildren(icon(Check));
        copy.title = "Copied";
        status.textContent = "SSH URL copied.";
      } catch {
        input.focus();
        input.select();
        status.textContent = "Clipboard unavailable. Address selected.";
      } finally {
        copy.disabled = false;
        reset = setTimeout(() => {
          copy.replaceChildren(icon(Copy));
          copy.title = "Copy SSH URL";
          status.textContent = "";
        }, 2500);
      }
    });
  }
  document.addEventListener("click", event => {
    if (details.open && event.target instanceof Node && !details.contains(event.target)) details.open = false;
  });
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && details.open) {
      details.open = false;
      summary.focus();
      event.preventDefault();
    }
  });
}

for (const form of document.querySelectorAll<HTMLFormElement>("[data-ssh-address-form]")) {
  const host = form.elements.namedItem("host") as HTMLInputElement;
  const port = form.elements.namedItem("port") as HTMLInputElement;
  const preview = form.querySelector<HTMLOutputElement>("[data-ssh-address-preview]")!;
  form.addEventListener("input", () => {
    const value = host.value.trim();
    if (!value) { preview.textContent = "Not configured"; return; }
    try {
      if (/[\s/@?#%\\]/.test(value) || !/^\d{1,5}$/.test(port.value) || +port.value < 1 || +port.value > 65535) throw new Error();
      const authority = value.includes(":") && !value.startsWith("[") ? `[${value}]` : value;
      const url = new URL(`ssh://git@${authority}:${port.value}/team/repository.git`);
      preview.textContent = url.href;
    } catch { preview.textContent = "Invalid SSH endpoint"; }
  });
}

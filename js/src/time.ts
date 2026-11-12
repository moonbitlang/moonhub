// All instants arrive with a UTC marker or explicit offset. Calendar dates stay
// server-rendered and must never shift when the viewer changes their time zone.
export function mountTimes(signal: AbortSignal) {
  const preference = document.querySelector<HTMLElement>('main[data-time-zone]')?.dataset.timeZone || undefined;
  const deviceZone = new Intl.DateTimeFormat().resolvedOptions().timeZone;
  const locales = navigator.languages.length ? [...navigator.languages] : navigator.language;
  function formatter(timeZone: string | undefined) {
    return new Intl.DateTimeFormat(locales, {
      timeZone, year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short',
    });
  }
  let absolute: Intl.DateTimeFormat;
  let zone = preference || deviceZone;
  try { absolute = formatter(zone); }
  catch { zone = 'UTC'; absolute = formatter(zone); }
  const relative = new Intl.RelativeTimeFormat(locales, { numeric: 'auto' });
  const elements = [...document.querySelectorAll<HTMLTimeElement>('time[data-local-time]')];
  function update() {
    for (const element of elements) {
      const instant = Date.parse(element.dateTime);
      if (!Number.isFinite(instant)) continue;
      const exact = `${absolute.format(instant)} (${zone})`;
      element.title = exact;
      if (element.hasAttribute('data-relative-time')) {
        const seconds = (instant - Date.now()) / 1000;
        const magnitude = Math.abs(seconds);
        const [unit, divisor]: [Intl.RelativeTimeFormatUnit, number] = magnitude < 60 ? ['second', 1]
          : magnitude < 3600 ? ['minute', 60] : magnitude < 86400 ? ['hour', 3600] : ['day', 86400];
        element.textContent = relative.format(Math.round(seconds / divisor), unit);
      } else element.textContent = exact;
    }
  }
  update();
  if (elements.some(element => element.hasAttribute('data-relative-time'))) {
    const timer = setInterval(update, 60000);
    signal.addEventListener('abort', () => clearInterval(timer), { once: true });
  }
  const select = document.querySelector<HTMLSelectElement>('#profile-time-zone');
  const preview = document.querySelector<HTMLElement>('[data-time-zone-preview]');
  function previewZone() {
    if (!select || !preview) return;
    const chosen = select.value || deviceZone;
    try { preview.textContent = `Current time: ${formatter(chosen).format(Date.now())} (${chosen}).`; }
    catch { preview.textContent = 'This browser does not support this time zone. Times will display in UTC; update your browser to use the selected zone.'; }
  }
  previewZone();
  select?.addEventListener('change', previewZone, { signal });
}

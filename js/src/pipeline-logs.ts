type StepUpdate = { step_id: string; state: string; exit_code: number };
type JobUpdate = { id: string; attempt_id: string; state: string; result: string; reason: string; steps: StepUpdate[] };
type RunUpdate = { state: string; result: string; jobs: JobUpdate[] };
type LogChunk = { id: string; text: string; step_id: string };
type LogPage = { chunks: LogChunk[]; next_cursor: string; has_more: boolean; complete: boolean };
class PollError extends Error {
  constructor(message: string, readonly permanent = false) { super(message); }
}
const label = (state: string) => ({ success: 'Passed', failure: 'Failed', timed_out: 'Timed out', lost: 'Runner lost', leased: 'Preparing' }[state] ?? state);
const terminalStep = (state: string) => ['success', 'failure', 'cancelled', 'timed_out', 'lost', 'completed'].includes(state);
const run = document.querySelector<HTMLElement>('[data-pipeline-run]');
if (run) {
  const base = run.dataset.runUrl!;
  const error = run.querySelector<HTMLElement>('[data-update-error]')!;
  const jobs = new Map([...run.querySelectorAll<HTMLElement>('[data-pipeline-job]')].map(element => {
    const panel = element.querySelector<HTMLElement>('.pipeline-logs')!;
    const log = panel.querySelector<HTMLPreElement>('pre')!;
    const job = {
      element, panel, log,
      chunks: [...log.querySelectorAll<HTMLElement>('[data-log-chunk]')].map(chunk => ({ id: chunk.dataset.logChunk!, step_id: chunk.dataset.logStep ?? '', text: chunk.textContent ?? '' })),
      step: '', query: '', match: 0, follow: false, errorFocused: false, expandedMiddle: 0,
    };
    return [element.dataset.pipelineJob!, job] as const;
  }));
  type Job = (typeof jobs extends Map<string, infer J> ? J : never);
  const navigation = [...run.querySelectorAll<HTMLAnchorElement>('[data-job-select]')];
  let selected = new URL(location.href).searchParams.get('job') ?? '';
  if (!jobs.has(selected)) selected = [...jobs].find(([, job]) => ['failure', 'timed_out', 'lost'].includes(job.element.querySelector<HTMLElement>('[data-job-state]')!.dataset.state!))?.[0]
    ?? [...jobs].find(([, job]) => job.element.querySelector<HTMLElement>('[data-job-state]')!.dataset.state === 'running')?.[0]
    ?? [...jobs.keys()][0] ?? '';
  let timer: ReturnType<typeof setTimeout> | undefined;
  let controller: AbortController | null = null;
  let away = false, stopped = false, retryDelay = 2000;
  const selectedStep = new URL(location.href).searchParams.get('step') ?? '';
  const initialJob = jobs.get(selected);
  if (initialJob) {
    initialJob.step = selectedStep || [...initialJob.element.querySelectorAll<HTMLElement>('[data-step-id]')].find(step => step.querySelector<HTMLElement>('[data-step-state]')?.dataset.state === 'failure')?.dataset.stepId || '';
  }

  function rawLog(job: Job) {
    return job.chunks.filter(chunk => !job.step || !chunk.step_id || chunk.step_id === job.step).map(chunk => chunk.text).join('');
  }
  function feedback(job: Job, text: string) {
    const element = job.element.querySelector<HTMLElement>('[data-log-feedback]')!;
    if (element.textContent !== text) element.textContent = text;
  }
  function renderLog(job: Job, reveal = false) {
    const top = window.scrollY;
    const text = rawLog(job);
    const lines = text.split('\n');
    let start = Math.max(0, lines.length - 5000);
    const matches: number[] = [];
    let limited = false;
    if (job.query) {
      const lower = text.toLocaleLowerCase(), query = job.query.toLocaleLowerCase();
      let cursor = 0;
      while ((cursor = lower.indexOf(query, cursor)) !== -1) {
        if (matches.length === 1000) { limited = true; break; }
        matches.push(cursor); cursor += Math.max(1, query.length);
      }
      job.match = matches.length ? (job.match + matches.length) % matches.length : 0;
      if (matches.length) {
        const matchLine = text.slice(0, matches[job.match]).split('\n').length - 1;
        start = Math.max(0, matchLine - 2000);
      }
    }
    const foldMiddle = job.panel.dataset.logComplete === 'true' && terminalStep(job.element.querySelector<HTMLElement>('[data-job-state]')!.dataset.state!) && !job.query && lines.length > 200;
    const leading = Math.min(20 + job.expandedMiddle, lines.length - 80);
    const tailStart = lines.length - 80;
    if (foldMiddle) start = 0;
    const end = foldMiddle ? lines.length : Math.min(lines.length, start + 5000);
    const fragment = document.createDocumentFragment();
    let offset = start === 0 ? 0 : lines.slice(0, start).join('\n').length + 1;
    let activeMark: HTMLElement | null = null;
    for (let i = start; i < end; i++) {
      if (foldMiddle && i === leading && leading < tailStart) {
        const count = Math.min(1000, tailStart - leading);
        const expand = document.createElement('button'); expand.type = 'button'; expand.className = 'log-middle-expand secondary-button';
        expand.textContent = `Show ${count} hidden lines${tailStart - leading > count ? ` (${tailStart - leading} remaining)` : ''}`;
        expand.addEventListener('click', () => { job.expandedMiddle += count; renderLog(job); job.log.querySelector<HTMLElement>(`[data-line="${leading + 1}"]`)?.scrollIntoView({ block: 'center' }); });
        fragment.append(expand); i = tailStart; offset = lines.slice(0, i).join('\n').length + 1;
      }
      const row = document.createElement('span'); row.className = 'log-line'; row.dataset.line = String(i + 1);
      const line = lines[i]; let cursor = 0;
      if (job.query) {
        const lower = line.toLocaleLowerCase(), query = job.query.toLocaleLowerCase();
        let at: number;
        while ((at = lower.indexOf(query, cursor)) !== -1) {
          row.append(document.createTextNode(line.slice(cursor, at)));
          const mark = document.createElement('mark'); mark.textContent = line.slice(at, at + query.length);
          if (offset + at === matches[job.match]) { mark.dataset.current = 'true'; activeMark = mark; }
          row.append(mark); cursor = at + query.length;
        }
      }
      row.append(document.createTextNode(line.slice(cursor) + (i < lines.length - 1 ? '\n' : '')));
      fragment.append(row); offset += line.length + 1;
    }
    job.log.replaceChildren(fragment);
    const windowText = foldMiddle && leading < tailStart ? `Showing the first ${leading} and last 80 lines of ${lines.length}. Middle output can be expanded. ` : !foldMiddle && lines.length > 5000 ? `Showing lines ${start + 1}–${end} of ${lines.length}. Copy/download includes all loaded output. ` : '';
    const matchText = job.query ? `${matches.length ? job.match + 1 : 0}/${matches.length}${limited ? '+' : ''} matches. ` : '';
    feedback(job, `${job.step ? `Step ${job.step}. ` : 'All steps. '}${windowText}${matchText}${job.panel.dataset.logComplete === 'true' ? 'Log complete.' : 'Loading live output…'}`);
    if (job.element.dataset.pipelineJob !== selected) return;
    if (job.follow) followEnd(job);
    else if (reveal && activeMark) activeMark.scrollIntoView({ block: 'center' });
    else window.scrollTo({ top });
  }
  function followEnd(job: Job) {
    window.scrollTo({ top: window.scrollY + job.log.getBoundingClientRect().bottom - window.innerHeight + 24 });
  }
  function saveSelection() {
    const url = new URL(location.href); url.searchParams.set('job', selected);
    const step = jobs.get(selected)?.step;
    if (step) url.searchParams.set('step', step); else url.searchParams.delete('step');
    history.replaceState(null, '', url);
  }
  function chooseJob(id: string, save = false) {
    if (!jobs.has(id)) return;
    selected = id;
    for (const [key, job] of jobs) job.element.hidden = key !== id;
    for (const link of navigation) {
      if (link.dataset.jobSelect === id) link.setAttribute('aria-current', 'true'); else link.removeAttribute('aria-current');
    }
    if (save) saveSelection();
  }
  for (const link of navigation) link.addEventListener('click', event => { event.preventDefault(); chooseJob(link.dataset.jobSelect!, true); });
  chooseJob(selected);
  let resizeFrame = 0;
  let viewportWidth = window.innerWidth;
  window.addEventListener('resize', () => {
    if (window.innerWidth === viewportWidth) return;
    viewportWidth = window.innerWidth;
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      const job = jobs.get(selected);
      if (job?.query) renderLog(job, true);
    });
  });
  for (const job of jobs.values()) {
    const toolbar = job.element.querySelector<HTMLElement>('.log-toolbar')!; toolbar.hidden = false;
    const search = job.element.querySelector<HTMLInputElement>('[data-log-search]')!;
    const follow = job.element.querySelector<HTMLInputElement>('[data-log-follow]')!;
    search.addEventListener('input', () => { job.errorFocused = true; job.query = search.value; job.match = 0; job.follow = false; follow.checked = false; renderLog(job, true); });
    for (const [selector, direction] of [['[data-log-previous]', -1], ['[data-log-next]', 1]] as const) {
      job.element.querySelector(selector)!.addEventListener('click', () => { job.match += direction; renderLog(job, true); });
    }
    job.element.querySelector('[data-log-wrap]')!.addEventListener('change', event => { job.log.dataset.wrap = String((event.target as HTMLInputElement).checked); if (job.query) renderLog(job, true); });
    follow.addEventListener('change', () => { job.follow = follow.checked; if (job.follow) followEnd(job); });
    window.addEventListener('scroll', () => { if (selected === job.element.dataset.pipelineJob && job.follow && job.log.getBoundingClientRect().bottom - window.innerHeight > 40) { job.follow = false; follow.checked = false; } });
    job.element.querySelector('[data-log-end]')!.addEventListener('click', () => { job.query = ''; search.value = ''; renderLog(job); followEnd(job); });
    job.element.querySelector('[data-log-all]')!.addEventListener('click', () => { job.step = ''; saveSelection(); renderLog(job); });
    job.element.querySelector('[data-log-error]')!.addEventListener('click', () => {
      job.errorFocused = true; const text = rawLog(job), words = [...text.matchAll(/\b(error|fatal|failed|exception)\b/gi)];
      const match = words.at(-1);
      if (!match) { feedback(job, 'No error keyword in the loaded output. Inspect the selected step and exit code.'); return; }
      job.query = match[0]; search.value = job.query;
      job.match = Math.min(999, [...text.slice(0, match.index).toLocaleLowerCase().matchAll(new RegExp(job.query.toLocaleLowerCase(), 'g'))].length);
      job.follow = false; follow.checked = false; renderLog(job, true);
    });
    job.element.addEventListener('click', event => {
      const button = (event.target as HTMLElement).closest<HTMLElement>('[data-select-step]');
      if (!button) return;
      job.step = button.dataset.selectStep!; saveSelection(); renderLog(job);
    });
    job.element.querySelector('[data-log-copy]')!.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(rawLog(job)); feedback(job, 'Loaded output copied.'); }
      catch { feedback(job, 'Copy unavailable. Use Download to save the loaded output.'); }
    });
    job.element.querySelector('[data-log-download]')!.addEventListener('click', () => {
      const url = URL.createObjectURL(new Blob([rawLog(job)], { type: 'text/plain;charset=utf-8' }));
      const link = document.createElement('a'); link.href = url; link.download = `pipeline-${base.split('/').at(-1)}-job-${job.element.dataset.pipelineJob}.log`;
      link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    });
    renderLog(job);
  }
  function settled() { return run!.dataset.runPhase === 'completed' && [...jobs.values()].every(job => !job.element.dataset.attemptId || job.panel.dataset.logComplete === 'true'); }
  function schedule(delay: number) { clearTimeout(timer); if (!stopped && !away && !document.hidden) timer = setTimeout(poll, delay); }
  async function read<T>(url: string, request: AbortController): Promise<T> {
    const timeout = setTimeout(() => request.abort(), 15000);
    try {
      const response = await fetch(url, { credentials: 'same-origin', cache: 'no-store', signal: request.signal, headers: { Accept: 'application/json' } });
      if (response.redirected || [401, 403, 404].includes(response.status)) throw new PollError('Updates stopped. Reload to check your session and repository access.', true);
      if (response.status === 400) throw new PollError('Updates stopped. Reload to refresh this pipeline.', true);
      if (!response.ok) throw new PollError('Connection interrupted. Retrying…');
      return await response.json() as T;
    } finally { clearTimeout(timeout); }
  }
  function updateBadge(badge: HTMLElement, value: string) { if (badge.dataset.state !== value) { badge.dataset.state = value; badge.textContent = label(value); } }
  function updateStatus(update: RunUpdate) {
    run!.dataset.runPhase = update.state;
    updateBadge(run!.querySelector<HTMLElement>('[data-run-state]')!, update.result);
    const cancel = run!.querySelector<HTMLElement>('[data-run-cancel]'), rerun = run!.querySelector<HTMLElement>('[data-run-rerun]');
    if (cancel) cancel.hidden = update.state === 'completed'; if (rerun) rerun.hidden = update.state !== 'completed';
    for (const status of update.jobs) {
      const job = jobs.get(status.id); if (!job) continue;
      updateBadge(job.element.querySelector<HTMLElement>('[data-job-state]')!, status.result);
      const nav = navigation.find(link => link.dataset.jobSelect === status.id)?.querySelector<HTMLElement>('[data-nav-job-state]'); if (nav) updateBadge(nav, status.result);
      const reason = job.element.querySelector<HTMLElement>('[data-queue-reason]')!; reason.textContent = status.reason; reason.hidden = !status.reason;
      const labels = job.element.querySelector<HTMLElement>('[data-required-labels]'); if (labels) labels.hidden = !status.reason;
      const list = job.element.querySelector<HTMLElement>('[data-job-steps]')!; list.hidden = status.steps.length === 0;
      if (job.element.dataset.attemptId !== status.attempt_id) {
        job.element.dataset.attemptId = status.attempt_id; job.panel.dataset.logCursor = '0'; job.panel.dataset.logComplete = String(!status.attempt_id); job.panel.dataset.logMore = 'false';
        job.chunks = []; job.log.replaceChildren(); job.panel.hidden = true; list.replaceChildren(); job.errorFocused = false; job.expandedMiddle = 0;
      }
      const steps = new Map([...list.querySelectorAll<HTMLElement>('[data-step-id]')].map(step => [step.dataset.stepId!, step]));
      for (const step of status.steps) {
        let item = steps.get(step.step_id);
        if (!item) {
          item = document.createElement('li'); item.dataset.stepId = step.step_id;
          const name = document.createElement('button'); name.type = 'button'; name.className = 'step-select secondary-button'; name.dataset.selectStep = step.step_id; name.textContent = step.step_id;
          const exit = document.createElement('span'); exit.className = 'muted'; exit.dataset.stepExit = '';
          const badge = document.createElement('span'); badge.className = 'mr-state'; badge.dataset.stepState = '';
          item.append(name, ' ', exit, ' ', badge); list.append(item);
        }
        const exit = item.querySelector<HTMLElement>('[data-step-exit]')!; exit.textContent = `exit ${step.exit_code}`; exit.hidden = !terminalStep(step.state);
        updateBadge(item.querySelector<HTMLElement>('[data-step-state]')!, step.state);
      }
    }
  }
  async function poll() {
    if (controller || stopped || away || document.hidden) return;
    if (settled()) { stopped = true; run!.dataset.polling = 'stopped'; return; }
    run!.dataset.polling = 'active'; const request = new AbortController(); controller = request; let delay = 2000;
    try {
      if (run!.dataset.runPhase !== 'completed') updateStatus(await read<RunUpdate>(`${base}/updates`, request));
      for (const job of jobs.values()) {
        const attempt = job.element.dataset.attemptId; if (!attempt || job.panel.dataset.logComplete === 'true') continue;
        const page = await read<LogPage>(`${base}/attempts/${encodeURIComponent(attempt)}/logs?after=${encodeURIComponent(job.panel.dataset.logCursor!)}`, request);
        job.chunks.push(...page.chunks); if (page.chunks.length) job.panel.hidden = false;
        job.panel.dataset.logCursor = page.next_cursor; job.panel.dataset.logComplete = String(page.complete); job.panel.dataset.logMore = String(page.has_more);
        if (page.chunks.length || page.complete) renderLog(job);
        if (page.has_more) delay = 0;
      }
      retryDelay = 2000; error.hidden = true;
      if (settled()) { stopped = true; run!.dataset.polling = 'stopped'; }
    } catch (failure) {
      if (!away && !document.hidden) {
        stopped = failure instanceof PollError && failure.permanent;
        error.textContent = failure instanceof PollError ? failure.message : 'Connection interrupted. Retrying…'; error.hidden = false;
        run!.dataset.polling = stopped ? 'stopped' : 'retrying'; delay = retryDelay; retryDelay = Math.min(retryDelay * 2, 30000);
      }
    } finally { controller = null; schedule(delay); }
  }
  document.addEventListener('visibilitychange', () => { if (document.hidden) { clearTimeout(timer); controller?.abort(); } else schedule(0); });
  window.addEventListener('pagehide', () => { away = true; clearTimeout(timer); controller?.abort(); });
  window.addEventListener('pageshow', () => { away = false; schedule(0); });
  schedule(0);
}

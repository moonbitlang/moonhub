type StepUpdate = { step_id: string; state: string; exit_code: number };
type JobUpdate = { id: string; attempt_id: string; state: string; result: string; reason: string; steps: StepUpdate[] };
type RunUpdate = { state: string; result: string; jobs: JobUpdate[] };
type LogPage = { chunks: { id: string; text: string }[]; next_cursor: string; has_more: boolean; complete: boolean };

class PollError extends Error {
  constructor(message: string, readonly permanent = false) { super(message); }
}

const run = document.querySelector<HTMLElement>("[data-pipeline-run]");
if (run) {
  const base = run.dataset.runUrl!;
  const error = run.querySelector<HTMLElement>("[data-update-error]")!;
  const jobs = new Map([...run.querySelectorAll<HTMLElement>("[data-pipeline-job]")].map(element => [element.dataset.pipelineJob!, {
    element,
    details: element.querySelector<HTMLDetailsElement>(".pipeline-logs")!,
    log: element.querySelector<HTMLPreElement>(".pipeline-logs pre")!,
  }]));
  let timer: ReturnType<typeof setTimeout> | undefined;
  let controller: AbortController | null = null;
  let away = false;
  let stopped = false;
  let retryDelay = 2000;

  function settled() {
    return run!.dataset.runPhase === "completed" && [...jobs.values()].every(job =>
      !job.element.dataset.attemptId || job.details.dataset.logComplete === "true");
  }

  function schedule(delay: number) {
    clearTimeout(timer);
    if (!stopped && !away && !document.hidden) timer = setTimeout(poll, delay);
  }

  async function read<T>(url: string, request: AbortController): Promise<T> {
    const timeout = setTimeout(() => request.abort(), 15000);
    try {
      const response = await fetch(url, {
        credentials: "same-origin", cache: "no-store", signal: request.signal,
        headers: { Accept: "application/json" },
      });
      if (response.redirected || [401, 403, 404].includes(response.status)) {
        throw new PollError("Updates stopped. Reload to check your session and repository access.", true);
      }
      if (response.status === 400) throw new PollError("Updates stopped. Reload to refresh this pipeline.", true);
      if (!response.ok) throw new PollError("Connection interrupted. Retrying...");
      return await response.json() as T;
    } finally { clearTimeout(timeout); }
  }

  function updateBadge(badge: HTMLElement, value: string) {
    if (badge.dataset.state === value) return;
    badge.dataset.state = value;
    badge.textContent = value;
  }

  function updateStatus(update: RunUpdate) {
    run!.dataset.runPhase = update.state;
    updateBadge(run!.querySelector<HTMLElement>("[data-run-state]")!, update.result);
    const cancel = run!.querySelector<HTMLElement>("[data-run-cancel]");
    const rerun = run!.querySelector<HTMLElement>("[data-run-rerun]");
    if (cancel) cancel.hidden = update.state === "completed";
    if (rerun) rerun.hidden = update.state !== "completed";
    for (const status of update.jobs) {
      const job = jobs.get(status.id);
      if (!job) continue;
      updateBadge(job.element.querySelector<HTMLElement>("[data-job-state]")!, status.result);
      const reason = job.element.querySelector<HTMLElement>("[data-queue-reason]")!;
      if (reason.textContent !== status.reason) reason.textContent = status.reason;
      reason.hidden = !status.reason;
      const labels = job.element.querySelector<HTMLElement>("[data-required-labels]");
      if (labels) labels.hidden = !status.reason;
      const list = job.element.querySelector<HTMLElement>("[data-job-steps]")!;
      list.hidden = status.steps.length === 0;
      if (job.element.dataset.attemptId !== status.attempt_id) {
        job.element.dataset.attemptId = status.attempt_id;
        job.details.dataset.logCursor = "0";
        job.details.dataset.logComplete = String(!status.attempt_id);
        job.details.dataset.logMore = "false";
        job.log.replaceChildren();
        job.details.hidden = true;
        list.replaceChildren();
      }
      const steps = new Map([...list.querySelectorAll<HTMLElement>("[data-step-id]")].map(step => [step.dataset.stepId!, step]));
      for (const step of status.steps) {
        let item = steps.get(step.step_id);
        if (!item) {
          item = document.createElement("li");
          item.dataset.stepId = step.step_id;
          const name = document.createElement("span");
          name.className = "path";
          name.textContent = step.step_id;
          const exit = document.createElement("span");
          exit.className = "muted";
          exit.dataset.stepExit = "";
          const badge = document.createElement("span");
          badge.className = "mr-state";
          badge.dataset.stepState = "";
          item.append(name, " ", exit, " ", badge);
          list.append(item);
        }
        const exit = item.querySelector<HTMLElement>("[data-step-exit]")!;
        const text = `exit ${step.exit_code}`;
        if (exit.textContent !== text) exit.textContent = text;
        updateBadge(item.querySelector<HTMLElement>("[data-step-state]")!, step.state);
      }
    }
  }

  async function poll() {
    if (controller || stopped || away || document.hidden) return;
    if (settled()) { stopped = true; run!.dataset.polling = "stopped"; return; }
    run!.dataset.polling = "active";
    const request = new AbortController();
    controller = request;
    let delay = 2000;
    try {
      if (run!.dataset.runPhase !== "completed") updateStatus(await read<RunUpdate>(`${base}/updates`, request));
      for (const job of jobs.values()) {
        const attempt = job.element.dataset.attemptId;
        if (!attempt || job.details.dataset.logComplete === "true") continue;
        const page = await read<LogPage>(`${base}/attempts/${encodeURIComponent(attempt)}/logs?after=${encodeURIComponent(job.details.dataset.logCursor!)}`, request);
        const follow = job.details.open && job.log.scrollHeight - job.log.scrollTop - job.log.clientHeight <= 24;
        const text = page.chunks.map(chunk => chunk.text).join("");
        if (text) {
          job.log.append(document.createTextNode(text));
          job.details.hidden = false;
          if (follow) job.log.scrollTop = job.log.scrollHeight;
        }
        job.details.dataset.logCursor = page.next_cursor;
        job.details.dataset.logComplete = String(page.complete);
        job.details.dataset.logMore = String(page.has_more);
        if (page.has_more) delay = 0;
      }
      retryDelay = 2000;
      error.hidden = true;
      if (settled()) { stopped = true; run!.dataset.polling = "stopped"; }
    } catch (failure) {
      if (!away && !document.hidden) {
        stopped = failure instanceof PollError && failure.permanent;
        error.textContent = failure instanceof PollError ? failure.message : "Connection interrupted. Retrying...";
        error.hidden = false;
        run!.dataset.polling = stopped ? "stopped" : "retrying";
        delay = retryDelay;
        retryDelay = Math.min(retryDelay * 2, 30000);
      }
    } finally {
      controller = null;
      schedule(delay);
    }
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { clearTimeout(timer); controller?.abort(); }
    else schedule(0);
  });
  window.addEventListener("pagehide", () => { away = true; clearTimeout(timer); controller?.abort(); });
  window.addEventListener("pageshow", () => { away = false; schedule(0); });
  schedule(0);
}

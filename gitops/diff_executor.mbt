///|
pub(all) suberror DiffFailure {
  DiffFailure(String)
}

///|
pub struct DiffExecutor {
  worker : String
  deadline_ms : Int32
  slots : @async.Semaphore
  priv observe : (Json) -> Unit
  priv mut waiting : Int32
  priv inflight : Map[String, (DiffInFlight, @async.Lazy[DiffCacheValue])]
  priv mut next_task_id : Int64
  priv mut coalesced_requests : Int64
  priv mut cache : Map[String, (DiffCacheValue, Int64)]
  priv mut cache_bytes : Int64
  priv cache_limit_bytes : Int64
  priv mut cache_evictions : Int64
  priv mut cache_skips : Int64
  mut completed : Int32
  mut cache_hits : Int32
  mut failures : Int32
  mut queued_ms : Int64
  mut execution_ms : Int64
  mut input_bytes : Int64
  mut output_bytes : Int64
  mut last_termination : String
}

///|
pub fn DiffExecutor::new(
  worker~ : String = "moonhub-diff-worker",
  concurrency~ : Int32 = 1,
  deadline_ms~ : Int32 = 5000,
  observe~ : (Json) -> Unit = _ => (),
  cache_limit_bytes~ : Int64 = @diff_protocol.cache_limit,
) -> DiffExecutor raise {
  guard !worker.is_empty() &&
    concurrency > 0 &&
    concurrency <= 64 &&
    deadline_ms > 0 &&
    deadline_ms <= 60000 &&
    cache_limit_bytes >= 0 else {
    raise DiffFailure("invalid diff executor configuration")
  }
  {
    worker,
    deadline_ms,
    observe,
    slots: @async.Semaphore(concurrency),
    waiting: 0,
    inflight: Map([]),
    next_task_id: 0L,
    coalesced_requests: 0L,
    cache: Map([]),
    cache_bytes: 0L,
    cache_limit_bytes,
    cache_evictions: 0L,
    cache_skips: 0L,
    completed: 0,
    cache_hits: 0,
    failures: 0,
    queued_ms: 0L,
    execution_ms: 0L,
    input_bytes: 0L,
    output_bytes: 0L,
    last_termination: "none",
  }
}

///|
// Read while the process is running. Never use collect_output for untrusted blobs
// or workers: its buffers have no limit. stderr is retained only up to 64 KiB
// and drained to EOF even when the retained buffer is full.
async fn bounded_process(
  command : String,
  args : Array[String],
  input : String,
  limit : Int32,
) -> Bytes {
  let (stdin, writer) = @process.write_to_process()
  defer writer.close()
  let (reader, stdout) = @process.read_from_process()
  defer reader.close()
  let (errors, stderr) = @process.read_from_process()
  defer errors.close()
  @async.with_task_group(group => {
    let child = @process.spawn(
      group,
      command,
      args,
      stdin~,
      stdout~,
      stderr~,
      cancel_handler=@process.hard_cancel(),
    )
    group.spawn_bg(() => {
      defer writer.close()
      writer.write(input)
    })
    group.spawn_bg(() => {
      let retained : Array[Byte] = []
      while errors.read_some(max_len=8192) is Some(chunk) {
        let remaining = @diff_protocol.stderr_limit - retained.length()
        if remaining > 0 {
          retained.append(
            chunk[:if remaining < chunk.length() {
              remaining
            } else {
              chunk.length()
            }].to_array(),
          )
        }
      }
    })
    let bytes : Array[Byte] = []
    while reader.read_some(max_len=8192) is Some(chunk) {
      guard bytes.length() + chunk.length() <= limit else {
        raise DiffFailure("output limit exceeded")
      }
      bytes.append(chunk.to_array())
    }
    guard child.wait() == 0 else {
      raise DiffFailure("diff subprocess failed; retry or select line mode")
    }
    Bytes::from_array(bytes)
  })
}

///|
pub async fn DiffExecutor::verify(self : DiffExecutor) -> Unit {
  let request : @diff_protocol.Request = {
    protocol: @diff_protocol.protocol_version,
    old_path: "",
    new_path: "",
    old_source: None,
    new_source: None,
    options: @diff_protocol.Options::new(mode="line"),
  }
  let _ = @async.with_timeout(
    self.deadline_ms,
    () => self.run_worker(request),
    error=DiffFailure("diff worker startup timed out"),
  )
}

///|
async fn DiffExecutor::run_worker(
  self : DiffExecutor,
  request : @diff_protocol.Request,
) -> @diff_protocol.Document {
  let input = Json(request).stringify()
  guard @utf8.encode(input).length() <= @diff_protocol.request_limit else {
    raise DiffFailure("input limit exceeded")
  }
  self.input_bytes += @utf8.encode(input).length().to_int64()
  let bytes = bounded_process(
    self.worker,
    [],
    input,
    @diff_protocol.result_limit,
  )
  self.output_bytes += bytes.length().to_int64()
  let output = diff_text(bytes)
  let response : @diff_protocol.Response = @json.from_json(@json.parse(output)) catch {
    _ => raise DiffFailure("invalid diff worker response")
  }
  guard response.protocol == @diff_protocol.protocol_version else {
    raise DiffFailure("incompatible diff worker protocol")
  }
  if response.error is Some(message) {
    raise DiffFailure(message)
  }
  guard response.document is Some(document) &&
    document.engine == @diff_protocol.engine_version &&
    document.protocol == @diff_protocol.protocol_version else {
    raise DiffFailure("incompatible diff engine")
  }
  document
}

///|
// JSON and file bodies are text. Git path records are decoded separately.
fn diff_text(bytes : BytesView) -> String raise {
  @utf8.decode(bytes) catch {
    _ => raise DiffFailure("non-UTF-8 content")
  }
}

///|
// Both stages share admission, deadlines, cancellation and the LRU budget.
// No Git/blob read or worker is started by a waiting task.
async fn DiffExecutor::compute_cached(
  self : DiffExecutor,
  key : String,
  phase : String,
  load : async () -> DiffCacheValue,
) -> DiffCacheValue {
  if self.cached(key, phase) is Some(value) {
    return value
  }
  let (state, result) = if self.inflight.get(key) is Some((state, result)) {
    guard self.waiting < @diff_protocol.queue_limit else {
      raise DiffFailure("diff queue is full; retry shortly")
    }
    self.waiting += 1
    state.waiters += 1
    self.coalesced_requests += 1L
    self.observe_diff({ "event": "diff", "phase": phase, "coalesced": true })
    (state, result)
  } else {
    let queued_at = @async.now()
    // Reserve admission synchronously, before Lazy starts its coroutine. Both
    // independent queued jobs and extra shared waiters consume waiting capacity.
    let admitted = self.slots.try_acquire()
    if !admitted {
      guard self.waiting < @diff_protocol.queue_limit else {
        raise DiffFailure("diff queue is full; retry shortly")
      }
      self.waiting += 1
    }
    self.next_task_id += 1L
    let state = {
      id: self.next_task_id,
      waiters: 1,
      finished: false,
      cleaned: @async.Semaphore(1, initial_value=0),
    }
    let result = @async.Lazy(() => {
      let mut acquired = admitted
      defer {
        if acquired {
          self.slots.release()
        }
        self.forget_inflight(key, state)
        state.finished = true
        state.cleaned.release()
      }
      if !admitted {
        defer {
          self.waiting -= 1
        }
        // Later joiners inherit the original admission deadline.
        let remaining = @diff_protocol.queue_wait_ms.to_int64() -
          (@async.now() - queued_at)
        guard remaining > 0L else {
          raise DiffFailure("diff queue wait exceeded; retry shortly")
        }
        @async.with_timeout(
          remaining.to_int(),
          () => {
            self.slots.acquire()
            // The timeout scope can still fail or be cancelled after acquire.
            acquired = true
          },
          error=DiffFailure("diff queue wait exceeded; retry shortly"),
        )
      }
      let started = if admitted { queued_at } else { @async.now() }
      self.compute(key, phase, queued_at, started, load)
    })
    self.inflight[key] = (state, result)
    (state, result)
  }
  defer {
    state.waiters -= 1
    // Any remaining caller takes the primary position when its predecessor
    // leaves, so cancelled callers never retain an extra waiting position.
    if state.waiters > 0 {
      self.waiting -= 1
    }
    if state.waiters == 0 && !state.finished {
      // Lazy.wait has already cancelled its worker. Detach before yielding so a
      // new caller cannot join the dying task, then wait for resource cleanup.
      self.forget_inflight(key, state)
      @async.protect_from_cancel(() => state.cleaned.acquire())
    }
  }
  result.wait()
}

///|
priv struct DiffInFlight {
  id : Int64
  mut waiters : Int32
  mut finished : Bool
  cleaned : @async.Semaphore
}

///|
fn DiffExecutor::forget_inflight(
  self : DiffExecutor,
  key : String,
  state : DiffInFlight,
) -> Unit {
  if self.inflight.get(key) is Some((current, _)) && current.id == state.id {
    self.inflight.remove(key)
  }
}

///|
// Only the shared computation records execution metrics and updates the LRU.
async fn DiffExecutor::compute(
  self : DiffExecutor,
  key : String,
  phase : String,
  queued_at : Int64,
  started : Int64,
  load : async () -> DiffCacheValue,
) -> DiffCacheValue {
  self.queued_ms += started - queued_at
  let mut termination = "cancelled"
  defer {
    self.execution_ms += @async.now() - started
    self.last_termination = termination
    self.observe_diff({
      "event": "diff",
      "phase": phase,
      "cache": "miss",
      "queue_ms": (started - queued_at).to_string(),
      "execution_ms": (@async.now() - started).to_string(),
      "input_bytes_total": self.input_bytes.to_string(),
      "output_bytes_total": self.output_bytes.to_string(),
      "termination": termination,
    })
  }
  errdefer {
    self.failures += 1
  }
  let (value, size) = try {
    // Admission may reserve a permit before Lazy gets scheduled. Include that
    // time in the execution deadline rather than granting a fresh deadline.
    let remaining = self.deadline_ms.to_int64() - (@async.now() - started)
    guard remaining > 0L else {
      raise DiffFailure("diff \{phase} timed out; retry shortly")
    }
    @async.with_timeout(
      remaining.to_int(),
      () => {
        let value = load()
        (value, value.retained_bytes())
      },
      error=DiffFailure("diff \{phase} timed out; retry shortly"),
    )
  } catch {
    DiffFailure(reason) => {
      termination = reason
      raise DiffFailure(reason)
    }
    err => {
      termination = "subprocess_error"
      raise err
    }
  }
  termination = "success"
  self.cache_result(key, value, size)
  self.completed += 1
  value
}

///|
pub async fn DiffExecutor::execute(
  self : DiffExecutor,
  cache_key : String,
  load : async () -> @diff_protocol.Request,
) -> @diff_protocol.Document {
  let value = self.compute_cached("file:" + cache_key, "file", () => {
    let document = self.run_worker(load())
    let serialized = Json(document).stringify()
    Document(serialized)
  })
  guard value is Document(serialized) else {
    raise DiffFailure("invalid diff cache entry")
  }
  @json.from_json(@json.parse(serialized))
}

///|
test "standby excludes busy stale draining and outdated execution environments" {
  let worker : @protocol.WorkerView = {
    id: "1",
    key: "mac",
    state: "ready",
    draining: false,
    applied_revision: "2",
    last_seen_ms: "1000",
    idle_since_ms: "1000",
    active_attempts: 0,
  }
  let workers = [
    worker,
    { ..worker, state: "starting", },
    { ..worker, applied_revision: "1", },
    { ..worker, state: "busy", active_attempts: 1, },
    { ..worker, draining: true, },
    { ..worker, last_seen_ms: "1", },
    { ..worker, state: "failed", },
  ]
  assert_eq(@protocol.standby_counts(workers, "2", 180500L), (1, 2))
}

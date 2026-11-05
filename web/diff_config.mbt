///|
// Both server startup and app-local fallback providers use the same boundary.
// Parse before verify() or database initialization, even with Web MoonDiff off.
fn diff_executor_from_env(
  observe~ : (Json) -> Unit = _ => (),
) -> @gitops.DiffExecutor raise {
  let cache_limit_bytes = @env.get_env_var("MOONHUB_DIFF_CACHE_BYTES").map(raw => {
    let value = @string.parse_int64(raw.trim(), base=10) catch {
      _ =>
        raise @domain.BadRequest(
          message="MOONHUB_DIFF_CACHE_BYTES must be a non-negative Int64 byte count",
        )
    }
    guard value >= 0 else {
      raise @domain.BadRequest(
        message="MOONHUB_DIFF_CACHE_BYTES must be a non-negative Int64 byte count",
      )
    }
    value
  })
  @gitops.DiffExecutor::new(
    worker=@config.env_value("MOONHUB_DIFF_WORKER").unwrap_or(
      "moonhub-diff-worker",
    ),
    concurrency=@string.parse_int(
      @config.env_value("MOONHUB_DIFF_CONCURRENCY").unwrap_or("1"),
    ),
    deadline_ms=@string.parse_int(
      @config.env_value("MOONHUB_DIFF_DEADLINE_MS").unwrap_or("5000"),
    ),
    cache_limit_bytes?,
    observe~,
  )
}

///|
// Both writes belong to the caller's transaction: cache capture must fail atomically.
fn insert_run_snapshot(
  tx : @database.DbTransaction,
  repository_id : Int64,
  actor_id : Int64,
  workflow_path : String,
  workflow_name : String,
  branch : String,
  sha : String,
  pin : String,
  source : String,
  definition : @workflow.Workflow,
  definition_version~ : Int32 = @workflow.format_version,
  context~ : @workflow.RunContext? = None,
  event_id~ : Int64 = 0L,
  workflow_event_id~ : Int64 = 0L,
  merge_check_id~ : Int64 = 0L,
  capture_variables~ : Bool = true,
  cache_scope_source~ : Int64 = 0L,
  failed_only~ : Bool = false,
) -> @runtime.Run raise {
  let run = @runtime.insert_run_snapshot(
    tx,
    repository_id,
    actor_id,
    workflow_path,
    workflow_name,
    branch,
    sha,
    pin,
    source,
    definition,
    definition_version~,
    context~,
    event_id~,
    workflow_event_id~,
    merge_check_id~,
    capture_variables~,
    rerun_source=cache_scope_source,
    failed_only~,
  )
  @results.snapshot_cache_scope(
    tx,
    run,
    merge_check_id,
    source=cache_scope_source,
  )
  run
}

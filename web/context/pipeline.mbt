///|
extenum @moonback.TypedBox += {
  PipelineCoordinator(@pipeline.Coordinator)
}

///|
pub let pipeline_coordinator_key : @moonback.TypedKey[@pipeline.Coordinator] = TypedKey(
  name="moonhub.pipeline_coordinator",
  box=value => PipelineCoordinator(value),
  unbox=value => {
    match value {
      PipelineCoordinator(value) => Some(value)
      _ => None
    }
  },
)

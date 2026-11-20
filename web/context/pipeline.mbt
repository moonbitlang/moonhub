///|
extenum @moonback.TypedBox += {
  PipelineCoordinator(@runtime.Coordinator)
}

///|
pub let pipeline_coordinator_key : @moonback.TypedKey[@runtime.Coordinator] = TypedKey(
  name="moonhub.pipeline_coordinator",
  box=value => PipelineCoordinator(value),
  unbox=value => {
    match value {
      PipelineCoordinator(value) => Some(value)
      _ => None
    }
  },
)

///|
extenum @moonback.TypedBox += {
  PipelineResults(@results.Service)
  PipelineOidc(@oidc.Service)
}

///|
pub let pipeline_results_key : @moonback.TypedKey[@results.Service] = TypedKey(
  name="moonhub.pipeline_results",
  box=value => PipelineResults(value),
  unbox=value => {
    match value {
      PipelineResults(value) => Some(value)
      _ => None
    }
  },
)

///|
pub let pipeline_oidc_key : @moonback.TypedKey[@oidc.Service] = TypedKey(
  name="moonhub.pipeline_oidc",
  box=value => PipelineOidc(value),
  unbox=value => {
    match value {
      PipelineOidc(value) => Some(value)
      _ => None
    }
  },
)

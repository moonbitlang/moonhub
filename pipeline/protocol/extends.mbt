// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend ClaimRequest with ToJson::{to_json}

///|
pub extend ClaimRequest with @json.FromJson::{from_json}

///|
pub extend VersionRequest with ToJson::{to_json}

///|
pub extend VersionRequest with @json.FromJson::{from_json}

///|
pub extend StartRequest with ToJson::{to_json}

///|
pub extend StartRequest with @json.FromJson::{from_json}

///|
pub extend StepRequest with @debug.Debug::{to_repr}

///|
pub extend StepRequest with ToJson::{to_json}

///|
pub extend StepRequest with @json.FromJson::{from_json}

///|
pub extend StepState with @debug.Debug::{to_repr}

///|
pub extend StepState with ToJson::{to_json}

///|
pub extend StepState with @json.FromJson::{from_json}

///|
pub extend LogRequest with ToJson::{to_json}

///|
pub extend LogRequest with @json.FromJson::{from_json}

///|
pub extend CompleteRequest with ToJson::{to_json}

///|
pub extend CompleteRequest with @json.FromJson::{from_json}

///|
pub extend LeaseState with @debug.Debug::{to_repr}

///|
pub extend LeaseState with ToJson::{to_json}

///|
pub extend LeaseState with @json.FromJson::{from_json}

///|
pub extend Assignment with @debug.Debug::{to_repr}

///|
pub extend Assignment with ToJson::{to_json}

///|
pub extend Assignment with @json.FromJson::{from_json}

///|
pub extend JobPlan with @debug.Debug::{to_repr}

///|
pub extend JobPlan with ToJson::{to_json}

///|
pub extend JobPlan with @json.FromJson::{from_json}

///|
pub extend StepPlan with @debug.Debug::{to_repr}

///|
pub extend StepPlan with ToJson::{to_json}

///|
pub extend StepPlan with @json.FromJson::{from_json}

///|
pub extend LogChunk with @debug.Debug::{to_repr}

///|
pub extend LogChunk with ToJson::{to_json}

///|
pub extend LogChunk with @json.FromJson::{from_json}

///|
pub extend SecretRequest with ToJson::{to_json}

///|
pub extend SecretRequest with @json.FromJson::{from_json}

///|
pub extend SecretResponse with ToJson::{to_json}

///|
pub extend SecretResponse with @json.FromJson::{from_json}

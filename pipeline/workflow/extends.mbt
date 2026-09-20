// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend InvalidWorkflow with @debug.Debug::{to_repr}

///|
pub extend Workflow with @debug.Debug::{to_repr}

///|
pub extend Workflow with ToJson::{to_json}

///|
pub extend Workflow with @json.FromJson::{from_json}

///|
pub extend Job with @debug.Debug::{to_repr}

///|
pub extend Job with ToJson::{to_json}

///|
pub extend Job with @json.FromJson::{from_json}

///|
pub extend Step with @debug.Debug::{to_repr}

///|
pub extend Step with ToJson::{to_json}

///|
pub extend Step with @json.FromJson::{from_json}

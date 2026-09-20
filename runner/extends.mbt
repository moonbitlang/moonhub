// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend Report with @debug.Debug::{to_repr}

///|
pub extend Report with ToJson::{to_json}

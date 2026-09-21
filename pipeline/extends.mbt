// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend Provider with @debug.Debug::{to_repr}

///|
pub extend ProviderScope with Eq::{not_equal, equal}

///|
pub extend ProviderScope with @debug.Debug::{to_repr}

///|
pub extend QueueReason with Eq::{not_equal, equal}

///|
pub extend QueueReason with @debug.Debug::{to_repr}

///|
pub extend RunState with Eq::{not_equal, equal}

///|
pub extend RunState with @debug.Debug::{to_repr}

///|
pub extend JobState with Eq::{not_equal, equal}

///|
pub extend JobState with @debug.Debug::{to_repr}

///|
pub extend Conclusion with Eq::{not_equal, equal}

///|
pub extend Conclusion with @debug.Debug::{to_repr}

///|
pub extend Run with @debug.Debug::{to_repr}

///|
pub extend JobRun with @debug.Debug::{to_repr}

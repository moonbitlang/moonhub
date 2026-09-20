// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend YamlError with @debug.Debug::{to_repr}

///|
pub extend Event with Eq::{not_equal, equal}

///|
pub extend Event with @debug.Debug::{to_repr}

///|
pub extend Marker with @debug.Debug::{to_repr}

///|
pub extend Marker with Eq::{not_equal, equal}

///|
pub extend TScalarStyle with Eq::{not_equal, equal}

///|
pub extend TScalarStyle with @debug.Debug::{to_repr}

///|
pub extend Tag with Eq::{not_equal, equal}

///|
pub extend Tag with @debug.Debug::{to_repr}

///|
pub extend Yaml with Eq::{not_equal, equal}

///|
pub extend Yaml with @debug.Debug::{to_repr}

///|
pub extend Yaml with ToJson::{to_json}

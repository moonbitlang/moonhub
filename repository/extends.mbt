// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend RepoOperation with Eq::{not_equal, equal}

///|
pub extend RepoOperation with @debug.Debug::{to_repr}

///|
pub extend SshEndpoint with Eq::{not_equal, equal}

///|
pub extend SshEndpoint with @debug.Debug::{to_repr}

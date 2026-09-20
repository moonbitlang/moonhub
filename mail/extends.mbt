// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend MailConfigError with @debug.Debug::{to_repr}

///|
pub extend MailDeliveryError with @debug.Debug::{to_repr}

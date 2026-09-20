// Preserve the public methods previously promoted implicitly from traits.

///|
pub extend GitError with Show::{to_string, output}

///|
pub extend GitOperationError with Show::{to_string, output}

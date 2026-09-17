///|
pub(all) suberror AppError {
  BadRequest(message~ : String)
  Unauthorized(message~ : String)
  Forbidden(message~ : String)
  NotFound(message~ : String)
}

///|
pub let internal_error_message : String = "Something went wrong. Please try again later."

///|
pub let email_delivery_error_message : String = "Email delivery failed. Please contact a site administrator or try resending later."

///|
pub let repository_error_message : String = "Repository operation failed. Please retry or contact a site administrator."

///|
pub let merge_error_message : String = "Merge operation failed. Please reload and retry or contact a site administrator."

///|
// Persisted diagnostics may predate error sanitization. Only known, actionable
// merge blockers can be shown; arbitrary stored text remains private.
pub fn public_merge_block_reason(reason : String) -> String {
  match reason {
    ""
    | "source commits are already included in the target branch"
    | "branches have conflicts; resolve them locally and push the source branch"
    | "Git output is too large; narrow the change or inspect it locally"
    | "Git operation timed out; try again or inspect the branches locally" =>
      reason
    _ => merge_error_message
  }
}

///|
pub fn public_merge_job_error(error : String) -> String {
  match error {
    ""
    | "branches changed; reload and review the new version"
    | "merge request version changed"
    | "merge result changed; refresh the comparison before merging"
    | "merge permission was revoked"
    | "the merging user is no longer active"
    | "source commits are already included in the target branch"
    | "branches have conflicts; resolve them locally and push the source branch" =>
      error
    _ => merge_error_message
  }
}

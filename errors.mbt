///|
suberror AppError {
  BadRequest(message~ : String)
  Unauthorized(message~ : String)
  Forbidden(message~ : String)
  NotFound(message~ : String)
}

///|
let internal_error_message : String = "Something went wrong. Please try again later."

///|
let email_delivery_error_message : String = "Email delivery failed. Please contact a site administrator or try resending later."

///|
let repository_error_message : String = "Repository operation failed. Please retry or contact a site administrator."

///|
let merge_error_message : String = "Merge operation failed. Please reload and retry or contact a site administrator."

///|
// Persisted diagnostics may predate error sanitization. Only known, actionable
// merge blockers can be shown; arbitrary stored text remains private.
fn public_merge_block_reason(reason : String) -> String {
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
fn public_merge_job_error(error : String) -> String {
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

///|
fn app_error_middleware(
  asset_path_map : Map[String, String],
) -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      let committed : Ref[Bool] = { val: false, }
      let tracked = @moonback.Responder((status, headers) => {
        let writer = res.respond(status~, headers~)
        committed.val = true
        writer
      })
      next(req, tracked) catch {
        err if @async.is_cancellation_error(err) => raise err
        err => {
          let (status, message) = match err {
            BadRequest(message~) | @gitops.Failure(message~) => (400, message)
            Unauthorized(message~) => (401, message)
            Forbidden(message~) => (403, message)
            NotFound(message~) => (404, message)
            _ => {
              println("request failed: \{err}")
              (500, internal_error_message)
            }
          }
          // A streaming response cannot be replaced once its headers are sent.
          guard !committed.val else { raise err }
          res.send_html(
            render_error(
              status,
              message,
              asset_path_map,
              current_user=current_user_from_request(req),
            ),
            status~,
            headers=private_page_headers(),
          )
        }
      }
    }
  })
}

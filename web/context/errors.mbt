///|
pub fn app_error_middleware(
  asset_path_map : Map[String, String],
) -> @moonback.Middleware {
  @web_ui.page_middleware().compose(
    Middleware(next => {
      (req, res) => {
        let committed : Ref[Bool] = { val: false, }
        let tracked = @moonback.Responder((status, headers) => {
          let writer = res.respond(status~, headers~)
          committed.val = true
          writer
        })
        next(req, tracked) catch {
          err => {
            let (status, message) = match err {
              @domain.BadRequest(message~) | @gitops.Failure(message~) =>
                (400, message)
              @domain.Unauthorized(message~) => (401, message)
              @domain.Forbidden(message~) => (403, message)
              @domain.NotFound(message~) => (404, message)
              _ => {
                println("request failed: \{err}")
                (500, @domain.internal_error_message)
              }
            }
            // A streaming response cannot be replaced once its headers are sent.
            guard !committed.val else { raise err }
            res.send_html(
              @web_ui.render_error(
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
    }),
  )
}

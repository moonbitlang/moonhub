///|
suberror AppError {
  BadRequest(message~ : String)
  Unauthorized(message~ : String)
  NotFound(message~ : String)
}

///|
fn app_error_middleware(
  asset_path_map : Map[String, String],
) -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      next(req, res) catch {
        BadRequest(message~) =>
          res.send_html(render_error(400, message, asset_path_map), status=400)
        Unauthorized(message~) =>
          res.send_html(render_error(401, message, asset_path_map), status=401)
        NotFound(message~) =>
          res.send_html(render_error(404, message, asset_path_map), status=404)
        err => raise err
      }
    }
  })
}

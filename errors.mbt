///|
suberror AppError {
  BadRequest(message~ : String)
  Unauthorized(message~ : String)
  Forbidden(message~ : String)
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
        Forbidden(message~) =>
          res.send_html(render_error(403, message, asset_path_map), status=403)
        NotFound(message~) =>
          res.send_html(render_error(404, message, asset_path_map), status=404)
        @moondb.ConnectError(err) =>
          res.send_html(
            render_error(500, "database error: \{err}", asset_path_map),
            status=500,
          )
        @moondb.QueryError(err) =>
          res.send_html(
            render_error(500, "database error: \{err}", asset_path_map),
            status=500,
          )
        @moondb.TypeError(err) =>
          res.send_html(
            render_error(500, "database error: \{err}", asset_path_map),
            status=500,
          )
        @moondb.Closed =>
          res.send_html(
            render_error(500, "database connection is closed", asset_path_map),
            status=500,
          )
        err => raise err
      }
    }
  })
}

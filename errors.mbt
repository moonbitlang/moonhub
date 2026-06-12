///|
suberror AppError {
  BadRequest(message~ : String)
  NotFound(message~ : String)
}

///|
fn app_error_middleware() -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      next(req, res) catch {
        BadRequest(message~) =>
          res.send_html(render_error(400, message), status=400)
        NotFound(message~) =>
          res.send_html(render_error(404, message), status=404)
        err => raise err
      }
    }
  })
}

///|
priv struct PageBuffer {
  bytes : @buffer.Buffer
}

///|
impl @io.Writer for PageBuffer with fn write_once(self, bytes, offset~, len~) {
  self.bytes.write_bytes(bytes[offset:offset + len])
  len
}

///|
impl @moonback.Flusher for PageBuffer with fn flush(_) {
  ()
}

///|
impl @moonback.WriteFlusher for PageBuffer

///|
/// The same authorized route resolves HTML for direct visits and a serializable
/// view tree for SPA navigation. Non-HTML bodies keep their streaming writer.
pub fn page_middleware() -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      let pending : Ref[(Int32, @moonback.Headers)?] = { val: None, }
      let buffer = PageBuffer::{ bytes: @buffer.Buffer(), }
      let responder = @moonback.Responder((status, headers) => {
        if headers.get("Content-Type").unwrap_or("").has_prefix("text/html") {
          pending.val = Some((status, headers))
          (buffer : &@moonback.WriteFlusher)
        } else {
          res.respond(status~, headers~)
        }
      })
      next(req, responder)
      guard pending.val is Some((status, headers)) else { return }
      let source = @utf8.decode(buffer.bytes.to_bytes())
      // Markdown preview and other fragments retain their original protocol.
      guard source.has_prefix("<!doctype html>") else {
        res.respond(status~, headers~).write(source)
        return
      }
      let page = @spa.parse_page(source)
      let headers = headers.to_mut()
      headers.remove("Content-Length")
      headers.add("Vary", "Accept")
      headers.set("Cache-Control", "no-store")
      if req.headers
        .get("Accept")
        .unwrap_or("")
        .contains("application/vnd.moonhub.page+json") {
        headers.set("Content-Type", "application/vnd.moonhub.page+json")
        res.respond(status~, headers~).write(page.to_json().stringify())
      } else {
        let app = @rabbita.new(() => {
          @rabbita.Val::constant(@spa.document(page, 0))
        })
        let output = app.render(url="http://moonhub.local/", head=[
          @html.node(
            "script",
            @html.Attrs::build()
            .id("moonhub-bootstrap")
            .type_("application/json"),
            [@html.text(@spa.bootstrap_json(page))],
          ),
        ])
        res.respond(status~, headers~).write(output)
      }
    }
  })
}

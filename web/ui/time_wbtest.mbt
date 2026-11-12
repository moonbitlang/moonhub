///|
async test "timestamps declare UTC or retain offsets and calendar dates stay dates" {
  let buffer = PageBuffer::{ bytes: @buffer.Buffer(), }
  let responder = @moonback.Responder((_, _) => {
    (buffer : &@moonback.WriteFlusher)
  })
  responder.send_html(
    Html(b => {
      b <+ "\{timestamp("2024-03-10 09:30:00", relative=true)}"
      b <+ "\{timestamp("2024-03-10T10:30:00+01:00")}"
      b <+ "<span>\{timestamp("2024-03-10")}</span>"
      b <+ "\{timestamp("<script>alert(1)</script>")}"
    }),
  )
  let html = @utf8.decode(buffer.bytes.to_bytes())
  assert_true(
    html.contains(
      "datetime=\"2024-03-10T09:30:00Z\" data-local-time data-relative-time",
    ),
  )
  assert_true(html.contains("2024-03-10 09:30:00 UTC</time>"))
  assert_true(html.contains("datetime=\"2024-03-10T10:30:00+01:00\""))
  assert_true(html.contains("<span>2024-03-10</span>"))
  assert_false(html.contains("<script>"))
}

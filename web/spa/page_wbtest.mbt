///|
test "template adapter preserves escaped data and form state" {
  let page = parse_page(
    (
      #|<!doctype html><html lang="en"><head><title>A &amp; B</title></head><body><form action="/save?a=1&amp;b=2"><input name="title" value="&quot;&lt;&amp;lt;&#39;" required><textarea name="body">&lt;/textarea&gt;&amp;lt;</textarea></form></body></html>
    ),
  )
  assert_eq(page.head, [Element("title", [], [Text("A & B")])])
  assert_eq(page.body, [
    Element("form", [("action", "/save?a=1&b=2")], [
      Element(
        "input",
        [("name", "title"), ("value", "\"<&lt;'"), ("required", "")],
        [],
      ),
      Element("textarea", [("name", "body")], [Text("</textarea>&lt;")]),
    ]),
  ])
  assert_eq(@json.from_json(page.to_json()), page)
}

///|
test "bootstrap cannot terminate its JSON script element" {
  let page : Page = {
    head: [],
    body: [Text("</script><script>alert('&')</script>")],
  }
  let json = bootstrap_json(page)
  assert_true(!json.contains("<"))
  assert_true(!json.contains("&"))
  assert_eq(@json.from_json(@json.parse(json)), page)
}

///|
test "template adapter handles raw script text and rejects malformed documents" {
  let page = parse_page(
    (
      #|<!doctype html><html><head><!--ignored--><script>if (a < 2 && b > 1) go()</script></head><body><br><hr></body></html>
    ),
  )
  assert_eq(page.head, [
    Element("script", [], [Text("if (a < 2 && b > 1) go()")]),
  ])
  assert_true(
    (Some(parse_page("<html><head></head><body><div></body></html>")) catch {
      _ => None
    })
    is None,
  )
  assert_true((Some(parse_page("<p>fragment</p>")) catch { _ => None }) is None)
}

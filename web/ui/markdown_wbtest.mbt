///|
test "Markdown inline content escapes HTML and excludes active URL schemes" {
  assert_eq(
    markdown_inline("<script>bad</script> & `x<y`"),
    "&lt;script&gt;bad&lt;/script&gt; &amp; <code>x&lt;y</code>",
  )
  assert_true(
    markdown_inline("[run](https://example.com/?x=1&y=2)").contains(
      "href=\"https://example.com/?x=1&amp;y=2\"",
    ),
  )
  for
    url in [
      "javascript:alert", "data:text/html,test", "//evil.example", "/\\evil.example",
      "https://example.com/\n",
    ] {
    assert_false(markdown_link(url))
    assert_true(!markdown_inline("[link](\{url})").contains("<a "))
  }
  assert_eq(markdown_inline("**Strong** 😀"), "<strong>Strong</strong> 😀")
}

///|
test "managed images render safely and reject arbitrary origins and data" {
  let id = "".pad_start(64, 'a')
  let html = markdown_inline("![<test>](/alice/demo/attachments/\{id})")
  assert_true(html.contains("<img src=\"/alice/demo/attachments/\{id}\""))
  assert_true(html.contains("alt=\"&lt;test&gt;\""))
  for
    url in [
      "data:image/svg+xml;base64,PHN2Zz4=", "https://outside.example/image.png",
      "/alice/demo/attachments/../secret",
    ] {
    assert_false(markdown_inline("![test](\{url})").contains("<img"))
  }
}

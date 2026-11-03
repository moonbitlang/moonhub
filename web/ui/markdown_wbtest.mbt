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

///|
test "Markdown links issue and MR references within the supplied repository" {
  let repo = Some(@domain.RepoId::{ owner: "alice", name: "demo", })
  assert_eq(
    markdown_inline("See #34, (!12).", repo~),
    "See <a href=\"/alice/demo/issues/34\" rel=\"nofollow noreferrer\">#34</a>, (<a href=\"/alice/demo/merge-requests/12\" rel=\"nofollow noreferrer\">!12</a>).",
  )
  assert_true(
    markdown_inline("参考#34，合并!12。😀 #2", repo~).contains(
      "href=\"/alice/demo/issues/34\"",
    ),
  )
  assert_true(
    markdown_inline("**#34 and !12**", repo~).has_prefix(
      "<strong><a href=\"/alice/demo/issues/34\"",
    ),
  )
  assert_eq(markdown_inline("#34 !12"), "#34 !12")
  assert_true(
    markdown_inline("#34", repo=Some({ owner: "workshop", name: "other", })).contains(
      "href=\"/workshop/other/issues/34\"",
    ),
  )
}

///|
test "Markdown references require standalone canonical positive Int64 numbers" {
  let repo = Some(@domain.RepoId::{ owner: "alice", name: "demo", })
  for
    value in [
      "#0 !0 #01 !012 # ! #-1 !-1", "#9223372036854775808 !999999999999999999999999999999",
      "abc#34 name!12 #34abc !12_branch #34/other #34-other", "https://example.com/#34 /files/#34 user@example.com!12",
      "https://example.com/?id=#34 https://example.com:1234 https://example.com/:#34",
      "HTTPS://example.com/:#34 HTTP://example.com/:!12 MAILTO:name:#34", "other/repo#34 other/repo!12 ##34 !!12 #34#56",
    ] {
    assert_false(markdown_inline(value, repo~).contains("<a "), msg=value)
  }
  assert_true(
    markdown_inline("#9223372036854775807", repo~).contains(
      "href=\"/alice/demo/issues/9223372036854775807\"",
    ),
  )
}

///|
test "Markdown references preserve inline code existing links images and escapes" {
  let repo = Some(@domain.RepoId::{ owner: "alice", name: "demo", })
  assert_eq(markdown_inline("`#34 !12`", repo~), "<code>#34 !12</code>")
  assert_eq(
    markdown_inline("[#34 **!12**](https://example.com/#34)", repo~),
    "<a href=\"https://example.com/#34\" rel=\"nofollow noreferrer\">#34 <strong>!12</strong></a>",
  )
  for value in ["``#34 ` !12``", "```#34 `` !12```"] {
    let html = markdown_inline(value, repo~)
    assert_true(html.has_prefix("<code>"))
    assert_false(html.contains("<a "))
  }
  assert_true(markdown_inline("`` #34", repo~).contains("/issues/34"))
  let id = "".pad_start(64, 'a')
  let image = markdown_inline(
    "![#34 !12](/alice/demo/attachments/\{id})",
    repo~,
  )
  assert_true(image.contains("alt=\"#34 !12\""))
  assert_false(image.contains("/issues/"))
  assert_false(image.contains("/merge-requests/"))
  assert_eq(markdown_inline("\\#34 \\!12", repo~), "#34 !12")
  assert_true(
    markdown_inline("<script>#34</script> &", repo~).has_prefix(
      "&lt;script&gt;",
    ),
  )
  assert_false(
    markdown_inline("<script>#34</script> &", repo~).contains("<script>"),
  )
}

///|
async test "Markdown block references share context and fenced code stays literal" {
  let buffer = PageBuffer::{ bytes: @buffer.Buffer(), }
  let responder = @moonback.Responder((_, _) => {
    (buffer : &@moonback.WriteFlusher)
  })
  responder.send_html(
    markdown(
      "# References #34\n\n- See !12\n\n> Related #56\n\n```text\n#78 !90\n```\n\nDone #21",
      repo=Some({ owner: "alice", name: "demo", }),
    ),
  )
  let html = @utf8.decode(buffer.bytes.to_bytes())
  for number in ["34", "56", "21"] {
    assert_true(html.contains("href=\"/alice/demo/issues/\{number}\""))
  }
  assert_true(html.contains("href=\"/alice/demo/merge-requests/12\""))
  assert_true(html.contains("<pre><code>#78 !90\n</code></pre>"))
  assert_false(html.contains("/issues/78"))
  assert_false(html.contains("/merge-requests/90"))
}

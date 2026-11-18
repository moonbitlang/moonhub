///|
test "Markdown inline content escapes HTML and excludes active URL schemes" {
  assert_eq(
    markdown_html("See <script>bad</script> & `x<y`"),
    "<p>See &lt;script&gt;bad&lt;/script&gt; &amp; <code>x&lt;y</code></p>\n",
  )
  assert_true(
    markdown_html("[run](https://example.com/?x=1&y=2)").contains(
      "href=\"https://example.com/?x=1&amp;y=2\"",
    ),
  )
  for
    url in [
      "javascript:alert", "data:text/html,test", "//evil.example", "/\\evil.example",
      "https://example.com/a b",
    ] {
    assert_false(markdown_link(url))
    assert_true(!markdown_html("[link](<\{url}>)").contains("<a "))
  }
  assert_eq(
    markdown_html("**Strong** 😀"),
    "<p><strong>Strong</strong> 😀</p>\n",
  )
}

///|
test "managed images render safely and reject arbitrary origins and data" {
  let id = "".pad_start(64, 'a')
  let html = markdown_html("![<test>](/alice/demo/attachments/\{id})")
  assert_true(html.contains("<img src=\"/alice/demo/attachments/\{id}\""))
  assert_true(html.contains("alt=\"&lt;test&gt;\""))
  for
    url in [
      "data:image/svg+xml;base64,PHN2Zz4=", "https://outside.example/image.png",
      "/alice/demo/attachments/../secret",
    ] {
    assert_false(markdown_html("![test](\{url})").contains("<img"))
  }
}

///|
test "Markdown links issue and MR references within the supplied repository" {
  let repo = Some(@domain.RepoId::{ owner: "alice", name: "demo", })
  assert_eq(
    markdown_html("See #34, (!12).", repo~),
    "<p>See <a href=\"/alice/demo/issues/34\" rel=\"nofollow noreferrer\">#34</a>, (<a href=\"/alice/demo/merge-requests/12\" rel=\"nofollow noreferrer\">!12</a>).</p>\n",
  )
  assert_true(
    markdown_html("参考#34，合并!12。😀 #2", repo~).contains(
      "href=\"/alice/demo/issues/34\"",
    ),
  )
  assert_true(
    markdown_html("**#34 and !12**", repo~).contains(
      "<strong><a href=\"/alice/demo/issues/34\"",
    ),
  )
  assert_eq(markdown_html("#34 !12"), "<p>#34 !12</p>\n")
  assert_true(
    markdown_html("#34", repo=Some({ owner: "workshop", name: "other", })).contains(
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
    assert_false(markdown_html(value, repo~).contains("<a "), msg=value)
  }
  assert_true(
    markdown_html("#9223372036854775807", repo~).contains(
      "href=\"/alice/demo/issues/9223372036854775807\"",
    ),
  )
}

///|
test "Markdown references preserve inline code existing links images and escapes" {
  let repo = Some(@domain.RepoId::{ owner: "alice", name: "demo", })
  assert_eq(markdown_html("`#34 !12`", repo~), "<p><code>#34 !12</code></p>\n")
  assert_eq(
    markdown_html("[#34 **!12**](https://example.com/#34)", repo~),
    "<p><a href=\"https://example.com/#34\" rel=\"nofollow noreferrer\">#34 <strong>!12</strong></a></p>\n",
  )
  for value in ["``#34 ` !12``", "```#34 `` !12```"] {
    let html = markdown_html(value, repo~)
    assert_true(html.has_prefix("<p><code>"))
    assert_false(html.contains("<a "))
  }
  assert_true(markdown_html("`` #34", repo~).contains("/issues/34"))
  let id = "".pad_start(64, 'a')
  let image = markdown_html("![#34 !12](/alice/demo/attachments/\{id})", repo~)
  assert_true(image.contains("alt=\"#34 !12\""))
  assert_false(image.contains("/issues/"))
  assert_false(image.contains("/merge-requests/"))
  assert_eq(markdown_html("\\#34 \\!12", repo~), "<p>#34 !12</p>\n")
  assert_true(
    markdown_html("<script>#34</script> &", repo~).has_prefix(
      "<p>&lt;script&gt;",
    ),
  )
  assert_false(
    markdown_html("<script>#34</script> &", repo~).contains("<script>"),
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
  assert_true(
    html.contains("<pre><code class=\"language-text\">#78 !90\n</code></pre>"),
  )
  assert_false(html.contains("/issues/78"))
  assert_false(html.contains("/merge-requests/90"))
}

///|
test "CommonMark renders setext headings, nested lists and reference links" {
  let source =
    #|Overview
    #|========
    #|
    #|- An _item_
    #|  - See _#23_ and [the guide][guide].
    #|
    #|[guide]: https://example.com/guide 'A "quoted" title'
  let html = markdown_html(source, repo=Some({ owner: "alice", name: "demo", }))
  assert_true(html.has_prefix("<h2>Overview</h2>\n"))
  assert_true(html.contains("<ul>\n<li>An <em>item</em>\n<ul>"))
  assert_true(
    html.contains(
      "<em><a href=\"/alice/demo/issues/23\" rel=\"nofollow noreferrer\">#23</a></em>",
    ),
  )
  assert_true(
    html.contains(
      "<a href=\"https://example.com/guide\" rel=\"nofollow noreferrer\" title=\"A &quot;quoted&quot; title\">the guide</a>",
    ),
  )
}

///|
test "CommonMark links and images retain MoonHub destination rules" {
  let source =
    #|[blocked][url] <javascript:example> ![remote][image]
    #|
    #|[url]: jav&#x61;script:example
    #|[image]: https://example.com/image.png
  assert_eq(markdown_html(source), "<p>blocked javascript:example remote</p>\n")
  let url = "/alice/demo/attachments/" + "".pad_start(64, 'a')
  assert_eq(
    markdown_html("[![**diagram**][image]](/alice/demo)\n\n[image]: \{url}"),
    "<p><a href=\"/alice/demo\" rel=\"nofollow noreferrer\"><img src=\"\{url}\" alt=\"diagram\" loading=\"lazy\" decoding=\"async\"></a></p>\n",
  )
}

///|
test "Repository references use literal source markers in CommonMark text" {
  let source = "参考😀 #34 &amp; \\!12 &#35;56 and !78"
  assert_eq(
    markdown_html(source, repo=Some({ owner: "alice", name: "demo", })),
    "<p>参考😀 <a href=\"/alice/demo/issues/34\" rel=\"nofollow noreferrer\">#34</a> &amp; !12 #56 and <a href=\"/alice/demo/merge-requests/78\" rel=\"nofollow noreferrer\">!78</a></p>\n",
  )
}

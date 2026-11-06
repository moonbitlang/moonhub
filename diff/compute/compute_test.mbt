///|
fn calculate(
  old : String?,
  new : String?,
  path~ : String = "a.mbt",
  mode~ : String = "lexical",
  ignore_comments~ : Bool = true,
  ignore_tests~ : Bool = true,
) -> @protocol.Document {
  let response = @compute.compute({
    protocol: @protocol.protocol_version,
    old_path: path,
    new_path: path,
    old_source: old,
    new_source: new,
    options: @protocol.Options::new(mode~, ignore_comments~, ignore_tests~),
  })
  response.document.unwrap()
}

///|
test "declaration pairing preserves both orders and original coordinates" {
  let old = "fn a() { 1 }\n\n///|\nfn b() { 2 }\n"
  let new = "fn b() { 3 }\n\n///|\nfn a() { 1 }\n"
  let doc = calculate(Some(old), Some(new))
  assert_true(doc.reordered)
  assert_true(doc.old_order != doc.new_order)
  let b = doc.sections
    .iter()
    .find_first(s => s.new_context.unwrap_or("").contains("fn b"))
    .unwrap()
  assert_eq(b.old.unwrap().start, 3)
  let changed = b.hunks[0].rows
    .iter()
    .find_first(r => r.kind == "change")
    .unwrap()
  assert_eq(changed.old.unwrap().number, 4)
  assert_eq(changed.new.unwrap().number, 1)
}

///|
test "filtering statuses are distinct from empty files and line mode disables filters" {
  let doc = calculate(
    Some("// one\nfn a() { 1 }\n"),
    Some("// two\nfn a() { 1 }\n"),
  )
  assert_eq(doc.status, "ignored_only")
  let test_file = calculate(
    None,
    Some("test { assert_true(true) }\n"),
    path="a_test.mbt",
  )
  assert_eq(test_file.status, "ignored_only")
  let text = calculate(
    None,
    Some("test { assert_true(true) }\n"),
    path="a_test.mbt",
    mode="line",
  )
  assert_eq(text.options.mode, "line")
  assert_true(!text.options.ignore_tests)
  assert_true(text.sections[0].hunks[0].rows[0].old is None)
  assert_eq(text.sections[0].hunks[0].rows[0].new.unwrap().number, 1)
}

///|
test "interface files use lines and newline changes remain metadata" {
  let doc = calculate(Some("α\r\n"), Some("α"), path="pkg.generated.mbti")
  assert_eq(doc.options.mode, "line")
  assert_eq(doc.old_eol, "crlf")
  assert_eq(doc.new_eol, "none")
  assert_true(doc.old_final_newline == Some(true))
  assert_true(doc.new_final_newline == Some(false))
  let ending = calculate(Some("same\n"), Some("same"), path="text")
  assert_eq(ending.status, "changed")
  assert_true(ending.sections[0].hunks.is_empty())
}

///|
test "syntax errors carry fallback and protocol/source limits are checked" {
  let doc = calculate(Some("fn a() { 1 }\n"), Some("fn a(\n"))
  assert_true(doc.sections.iter().any(s => !s.fallbacks.is_empty()))
  let response = @compute.compute({
    protocol: "wrong",
    old_path: "",
    new_path: "",
    old_source: None,
    new_source: None,
    options: @protocol.Options::new(),
  })
  assert_true(response.error is Some(_))
  let response = @compute.compute({
    protocol: @protocol.protocol_version,
    old_path: "",
    new_path: "",
    old_source: Some("\n".repeat(20001)),
    new_source: None,
    options: @protocol.Options::new(),
  })
  assert_true(response.error == Some("source limit exceeded"))
}

///|
test "UTF-8 byte size is bounded separately from the line count" {
  let response = @compute.compute({
    protocol: @protocol.protocol_version,
    old_path: "a.mbt",
    new_path: "a.mbt",
    old_source: None,
    new_source: Some("a".repeat(@protocol.source_limit + 1)),
    options: @protocol.Options::new(),
  })
  assert_true(response.error == Some("source limit exceeded"))
}

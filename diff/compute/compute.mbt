///|
fn lines(source : String) -> Array[String] {
  if source.is_empty() {
    return []
  }
  let result = source.split("\n").map(s => s.to_owned()).collect()
  if source.has_suffix("\n") {
    ignore(result.pop())
  }
  result
}

///|
fn line(value : @model.DiffLine) -> @protocol.Line {
  {
    number: value.index + 1,
    segments: value.segments.map(s => @protocol.Segment::{
      kind: match s.kind {
        Unchanged => "unchanged"
        Changed => "changed"
        Ignored => "ignored"
      },
      text: s.text,
    }),
    intraline: value.intraline is Computed,
  }
}

///|
fn section(
  id : String,
  kind : String,
  old : @model.LineRange?,
  new : @model.LineRange?,
  old_context : String?,
  new_context : String?,
  fragment : @model.DiffFragment,
) -> @protocol.Section {
  let document = fragment.document.rebase(
    old.map(r => r.start).unwrap_or(0),
    new.map(r => r.start).unwrap_or(0),
  )
  let hunks : Array[@protocol.Hunk] = []
  for i, hunk in document.hunks {
    let rows : Array[@protocol.Row] = []
    for block in hunk.blocks {
      match block {
        ContextBlock(context) =>
          for c in context {
            let segments : Array[@protocol.Segment] = [
              { kind: "unchanged", text: c.text, },
            ]
            rows.push({
              kind: "context",
              old: Some({ number: c.old_index + 1, segments, intraline: false, }),
              new: Some({ number: c.new_index + 1, segments, intraline: false, }),
            })
          }
        ChangeBlock(changes) | IgnoredBlock(changes) =>
          for row in changes {
            let (left, right) = match row {
              Paired(a, b) => (Some(line(a)), Some(line(b)))
              OldOnly(a) => (Some(line(a)), None)
              NewOnly(b) => (None, Some(line(b)))
            }
            rows.push({
              kind: if block is IgnoredBlock(_) {
                "ignored"
              } else {
                "change"
              },
              old: left,
              new: right,
            })
          }
      }
    }
    hunks.push({ id: "\{id}:\{i}", rows, })
  }
  {
    id,
    kind,
    old: old.map(r => { start: r.start + 1, length: r.len, }),
    new: new.map(r => { start: r.start + 1, length: r.len, }),
    old_context,
    new_context,
    hunks,
    fallbacks: fragment.fallbacks.map(reason => Repr(reason).to_string()),
  }
}

///|
fn eol(source : String?) -> String {
  guard source is Some(source) else { return "absent" }
  let crlf = source.contains("\r\n")
  let bare = source.replace(old="\r\n", new="").contains("\n")
  if crlf && bare {
    "mixed"
  } else if crlf {
    "crlf"
  } else if bare {
    "lf"
  } else {
    "none"
  }
}

///|
pub fn compute(request : @protocol.Request) -> @protocol.Response {
  let error = if request.protocol != @protocol.protocol_version {
    Some("unsupported diff protocol")
  } else if !["lexical", "ast", "line"].contains(request.options.mode) {
    Some("unsupported diff mode")
  } else {
    let mut problem : String? = None
    for source in [request.old_source, request.new_source] {
      if source is Some(source) {
        if @utf8.encode(source).length() > @protocol.source_limit ||
          lines(source).length() > @protocol.line_limit {
          problem = Some("source limit exceeded")
        }
      }
    }
    problem
  }
  if error is Some(_) {
    return { protocol: @protocol.protocol_version, document: None, error, }
  }
  let old = request.old_source.unwrap_or("")
  let new = request.new_source.unwrap_or("")
  let syntax = request.options.mode != "line" &&
    (request.old_path.has_suffix(".mbt") || request.new_path.has_suffix(".mbt"))
  let options = if syntax {
    request.options
  } else {
    @protocol.Options::new(
      mode="line",
      ignore_comments=false,
      ignore_tests=false,
    )
  }
  let (document, status, ignore_reason) = if syntax {
    let result = @mbtdiff.diff(
      old,
      new,
      old_name=request.old_path,
      new_name=request.new_path,
      options=@mbtdiff.DiffOptions(
        context_lines=@protocol.context_lines,
        graph_limit=@protocol.graph_limit,
        ignore_comments=options.ignore_comments,
        ignore_tests=options.ignore_tests,
        mode=if options.mode == "ast" { Ast } else { Lexical },
      ),
    )
    (
      result.document(),
      match result.status() {
        Identical => "identical"
        Changed => "changed"
        Reordered => "reordered"
        NoStructuralChanges => "no_structural_changes"
        IgnoredOnly => "ignored_only"
      },
      result.ignore_reason().map(r => Repr(r).to_string()),
    )
  } else {
    (
      @model.DiffDocument::Whole({
        document: @linediff.line_diff(
          old=lines(old)[:],
          new=lines(new)[:],
          context=@protocol.context_lines,
        ),
        fallbacks: [],
      }),
      if old == new {
        "identical"
      } else {
        "changed"
      },
      None,
    )
  }
  let sections : Array[@protocol.Section] = []
  let mut old_order = []
  let mut new_order = []
  let mut reordered = false
  let kind = match document {
    Whole(fragment) => {
      sections.push(section("0", "whole", None, None, None, None, fragment))
      "whole"
    }
    TopLevel(top) => {
      old_order = top.old_order.to_owned()
      new_order = top.new_order.to_owned()
      reordered = top.reordered
      for i, value in top.sections {
        sections.push(
          match value {
            Matched(old~, new~, old_context~, new_context~, diff~) =>
              section(
                i.to_string(),
                "matched",
                Some(old),
                Some(new),
                old_context,
                new_context,
                diff,
              )
            Deleted(old~, old_context~, diff~) =>
              section(
                i.to_string(),
                "deleted",
                Some(old),
                None,
                old_context,
                None,
                diff,
              )
            Inserted(new~, new_context~, diff~) =>
              section(
                i.to_string(),
                "inserted",
                None,
                Some(new),
                None,
                new_context,
                diff,
              )
          },
        )
      }
      "top_level"
    }
  }
  {
    protocol: @protocol.protocol_version,
    error: None,
    document: Some({
      protocol: @protocol.protocol_version,
      engine: @protocol.engine_version,
      options,
      status,
      kind,
      ignore_reason,
      reordered,
      old_order,
      new_order,
      old_eol: eol(request.old_source),
      new_eol: eol(request.new_source),
      old_final_newline: request.old_source.map(s => s.has_suffix("\n")),
      new_final_newline: request.new_source.map(s => s.has_suffix("\n")),
      sections,
    }),
  }
}

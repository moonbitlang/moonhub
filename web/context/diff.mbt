///|
extenum @moonback.TypedBox += {
  DiffExecutorDependency(@gitops.DiffExecutor)
  DiffEnabled(Bool)
}

///|
pub let diff_executor_key : @moonback.TypedKey[@gitops.DiffExecutor] = TypedKey(
  name="moonhub.diff_executor",
  box=value => DiffExecutorDependency(value),
  unbox=value => {
    match value {
      DiffExecutorDependency(executor) => Some(executor)
      _ => None
    }
  },
)

///|
pub let diff_enabled_key : @moonback.TypedKey[Bool] = TypedKey(
  name="moonhub.diff_enabled",
  box=value => DiffEnabled(value),
  unbox=value => {
    match value {
      DiffEnabled(enabled) => Some(enabled)
      _ => None
    }
  },
)

///|
pub fn structured_diff_options(
  req : @moonback.Request,
) -> @diff_protocol.Options raise {
  @gitops.diff_options(
    mode=req.query().get("mode").unwrap_or("lexical"),
    ignore_comments=req.query().get("ignore_comments").unwrap_or("true"),
    ignore_tests=req.query().get("ignore_tests").unwrap_or("true"),
  )
}

///|
pub fn diff_page(req : @moonback.Request) -> Int32 raise {
  let page = @string.parse_int(req.query().get("page").unwrap_or("1")) catch {
    _ => raise @domain.BadRequest(message="invalid diff page")
  }
  guard page > 0 && page <= 100000 else {
    raise @domain.BadRequest(message="invalid diff page")
  }
  page
}

///|
pub fn diff_selection(
  form : Map[String, String],
) -> @gitops.DiffSelection? raise {
  let document_id = form.get("document_id").unwrap_or("")
  if document_id.is_empty() {
    guard ["file_id", "hunk_id"].all(key => {
      form.get(key).unwrap_or("").is_empty()
    }) else {
      raise @domain.BadRequest(
        message="document_id is required for structured comments",
      )
    }
    return None
  }
  let file_id = form.get("file_id").unwrap_or("")
  let hunk_id = form.get("hunk_id").unwrap_or("")
  guard document_id.length() == 64 &&
    file_id.length() == 64 &&
    !hunk_id.is_empty() &&
    hunk_id.length() <= 64 else {
    raise @domain.BadRequest(message="invalid structured comment identity")
  }
  let page = @string.parse_int(form.get("diff_page").unwrap_or("1")) catch {
    _ => raise @domain.BadRequest(message="invalid diff page")
  }
  guard page > 0 && page <= 100000 else {
    raise @domain.BadRequest(message="invalid diff page")
  }
  Some({
    document_id,
    file_id,
    hunk_id,
    page,
    options: @gitops.diff_options(
      mode=form.get("mode").unwrap_or("lexical"),
      ignore_comments=form.get("ignore_comments").unwrap_or("true"),
      ignore_tests=form.get("ignore_tests").unwrap_or("true"),
    ),
  })
}

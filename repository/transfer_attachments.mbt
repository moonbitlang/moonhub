///|
// Use the same CommonMark parser as the browser and splice only destinations.
// Reprinting the AST would also change the author's formatting and code spans.
fn retarget_attachment_markdown(
  source : String,
  old_prefix : String,
  new_prefix : String,
  is_referenced : (String) -> Bool raise,
) -> String? raise {
  guard source.contains(old_prefix) else { return None }
  let positions : Array[(Int32, String)] = []
  let doc = @cmark.Doc::from_string(source, locs=true, strict=false)
  let reader : @cmark.Folder[Unit] = @cmark.Folder::new(inline=fn(
    _,
    _,
    inline,
  ) {
    if inline is (@cmark.Image({ v, .. }) | @cmark.Link({ v, .. })) &&
      v.reference is Inline({ v: { dest: Some({ v: url, meta, }), .. }, .. }) &&
      url.strip_prefix(old_prefix) is Some(id) &&
      id.length() == 64 {
      let { first_ccode: start, last_ccode, .. } = meta.loc
      let end = last_ccode + 1
      if start >= 0 &&
        start < end &&
        end <= source.length() &&
        source[start:end] == url[:] {
        positions.push((start, id.to_owned()))
      }
    }
    Default
  })
  reader.fold_doc((), doc)
  positions.sort_by_key(change => change.0)
  let out = StringBuilder()
  let mut offset = 0
  for (start, id) in positions {
    if start >= offset && is_referenced(id) {
      out.write_string(source[offset:start].to_owned())
      out.write_string(new_prefix)
      offset = start + old_prefix.length()
    }
  }
  guard offset > 0 else { return None }
  out.write_string(source[offset:].to_owned())
  Some(out.to_string())
}

///|
fn retarget_attachment_links(
  tx : @database.DbTransaction,
  repository_id : Int64,
  source : @domain.RepoId,
  target : @domain.RepoId,
) -> Unit raise {
  let old_prefix = "/\{source.path()}/attachments/"
  let new_prefix = "/\{target.path()}/attachments/"
  for
    (table, column, reference) in [
      ("issue", "description", "issue_id"),
      ("merge_request", "description", "merge_request_id"),
      ("issue_activity", "body", "issue_activity_id"),
      ("merge_activity", "body", "merge_activity_id"),
    ] {
    let mut after = 0L
    for ;; {
      let rows = tx.query_all(
        (
          $|SELECT d.id,d.\{column} AS markdown FROM \{table} d
          $|JOIN (SELECT DISTINCT ar.\{reference} AS id FROM attachment a
          $|      JOIN attachment_reference ar ON ar.attachment_id=a.id
          $|      WHERE a.repository_id=? AND ar.\{reference}>?
          $|      ORDER BY id LIMIT 100) refs ON refs.id=d.id ORDER BY d.id
        ),
        params=[repository_id, after],
      )
      for row in rows {
        let id : Int64 = row.get_name("id")
        after = id
        if retarget_attachment_markdown(
            row.get_name("markdown"),
            old_prefix,
            new_prefix,
            attachment => {
              tx.query_opt(
                "SELECT 1 AS linked FROM attachment_reference ar JOIN attachment a ON a.id=ar.attachment_id WHERE ar.attachment_id=? AND ar.\{reference}=? AND a.repository_id=?",
                params=[attachment, id, repository_id],
              )
              is Some(_)
            },
          )
          is Some(markdown) {
          ignore(
            tx.execute("UPDATE \{table} SET \{column}=? WHERE id=?", params=[
              markdown, id,
            ]),
          )
        }
      }
      guard rows.length() == 100 else { break }
    }
  }
}

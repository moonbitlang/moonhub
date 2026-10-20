///|
pub struct ImageLink {
  start : Int32
  end : Int32
  url : String
  image : Bool
}

///|
// Match supported image and file links, excluding code spans and fences.
pub fn attachment_links(markdown : String) -> Array[ImageLink] {
  let links : Array[ImageLink] = []
  let mut offset = 0
  let mut fenced = false
  for line in markdown.split("\n") {
    if line.trim_start().has_prefix("```") {
      fenced = !fenced
    } else if !fenced {
      let mut rest = line
      let mut column = 0
      while !rest.is_empty() {
        if rest.has_prefix("`") && rest[1:].find("`") is Some(end) {
          column = column + end + 2
          rest = rest[end + 2:]
        } else if rest.has_prefix("![") || rest.has_prefix("[") {
          guard rest.find("](") is Some(label_end) &&
            rest[label_end + 2:].find(")") is Some(url_end) else {
            break
          }
          let start = offset + column + label_end + 2
          links.push({
            start,
            end: start + url_end,
            url: rest[label_end + 2:label_end + 2 + url_end].to_owned(),
            image: rest.has_prefix("!["),
          })
          let length = label_end + 3 + url_end
          column = column + length
          rest = rest[length:]
        } else {
          let length = rest.iter().next().unwrap().to_string().length()
          column = column + length
          rest = rest[length:]
        }
      }
    }
    offset = offset + line.length() + 1
  }
  links
}

///|
// Data URI extraction only applies to embedded images, never ordinary links.
pub fn image_links(markdown : String) -> Array[ImageLink] {
  attachment_links(markdown).filter(link => link.image)
}

///|
pub fn markdown(attachment : Attachment) -> String {
  let label = attachment.filename
    .replace_all(old="[", new=" ")
    .replace_all(old="]", new=" ")
    .replace_all(old="\\", new=" ")
    .replace_all(old="\u{0060}", new=" ")
  let prefix = if attachment.media_type == "application/octet-stream" {
    ""
  } else {
    "!"
  }
  "\{prefix}[\{label}](\{attachment.url})"
}

///|
pub fn valid_id(id : String) -> Bool {
  id.length() == 64 &&
  id.iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f'))
}

///|
pub fn url(repo : @domain.RepoId, id : String) -> String {
  "/\{repo.path()}/attachments/\{id}"
}

///|
pub(all) enum ReferenceTarget {
  MergeRequest(Int64)
  Issue(Int64)
  MergeComment(Int64)
  IssueComment(Int64)
}

///|
// Content and reference claims commit together; deleted comments retain references.
pub fn replace_references(
  tx : @database.DbTransaction,
  repository_id : Int64,
  uploader_id : Int64,
  target : ReferenceTarget,
  markdown : String,
) -> Unit raise {
  let (column, owner_id, owner_scope) = match target {
    MergeRequest(id) =>
      (
        "merge_request_id", id, "SELECT id FROM merge_request WHERE id = ? AND repository_id = ?",
      )
    Issue(id) =>
      (
        "issue_id", id, "SELECT id FROM issue WHERE id = ? AND repository_id = ?",
      )
    MergeComment(id) =>
      (
        "merge_activity_id", id, "SELECT a.id FROM merge_activity a JOIN merge_request m ON m.id = a.merge_request_id WHERE a.id = ? AND m.repository_id = ?",
      )
    IssueComment(id) =>
      (
        "issue_activity_id", id, "SELECT a.id FROM issue_activity a JOIN issue i ON i.id = a.issue_id WHERE a.id = ? AND i.repository_id = ?",
      )
  }
  guard tx.query_opt(owner_scope, params=[owner_id, repository_id]) is Some(_) else {
    raise @domain.NotFound(message="attachment owner not found")
  }
  let repo_row = tx.query_one(
    "SELECT t.name_key AS owner, r.name AS name FROM repository r JOIN team t ON t.id = r.team_id WHERE r.id = ?",
    params=[repository_id],
  )
  let repo : @domain.RepoId = {
    owner: repo_row.get_name("owner"),
    name: repo_row.get_name("name"),
  }
  let ids : Array[String] = []
  for image in attachment_links(markdown) {
    if image.url.contains("/attachments/") && image.url.has_prefix("/") {
      let prefix = "/\{repo.path()}/attachments/"
      guard image.url.has_prefix(prefix) else {
        raise @domain.BadRequest(
          message="attachments must belong to this repository",
        )
      }
      let id = image.url[prefix.length():].to_owned()
      guard valid_id(id) else {
        raise @domain.BadRequest(message="invalid attachment URL")
      }
      guard tx.query_opt(
          "SELECT media_type FROM attachment a WHERE a.id = ? AND a.repository_id = ? AND a.ready = 1 AND (a.uploader_id = ? OR EXISTS (SELECT 1 FROM attachment_reference ar WHERE ar.attachment_id = a.id))",
          params=[id, repository_id, uploader_id],
        )
        is Some(row) else {
        raise @domain.BadRequest(message="attachment is unavailable")
      }
      let media_type : String = row.get_name("media_type")
      guard !image.image || media_type != "application/octet-stream" else {
        raise @domain.BadRequest(
          message="only supported images can be embedded; use a file link",
        )
      }
      if !ids.contains(id) {
        ids.push(id)
      }
    } else if image.image && image.url.has_prefix("data:") {
      raise @domain.BadRequest(
        message="inline image data must be uploaded before saving",
      )
    }
  }
  guard ids.length() <= 8 else {
    raise @domain.BadRequest(
      message="at most 8 managed attachments are allowed per body",
    )
  }
  ignore(
    tx.execute("DELETE FROM attachment_reference WHERE \{column} = ?", params=[
      owner_id,
    ]),
  )
  for id in ids {
    ignore(
      tx.execute(
        "INSERT INTO attachment_reference(attachment_id, \{column}) VALUES (?, ?)",
        params=[id, owner_id],
      ),
    )
    ignore(
      tx.execute("UPDATE attachment SET claimed = 1 WHERE id = ?", params=[id]),
    )
  }
}

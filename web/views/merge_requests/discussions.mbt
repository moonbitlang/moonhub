///|
fn render_discussion_comment(
  repo : @domain.RepoId,
  base : String,
  csrf : String,
  user : @domain.CurrentUser,
  item : @collaboration.MergeActivity,
  discussion : Int64,
  contributor : Bool,
  manager : Bool,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<div class=\"discussion-comment\" id=\"comment-\{item.id.to_string()}\"><div class=\"mr-event-heading\"><strong>\{item.actor}</strong>\{@web_ui.timestamp(item.created_at)}<a href=\"\{base}?discussion=\{discussion.to_string()}&amp;comment=\{item.id.to_string()}#comment-\{item.id.to_string()}\">#\{item.id.to_string()}</a></div>"
    if item.kind == "comment_deleted" {
      b <+ "<p class=\"muted\">Comment deleted.</p>"
    } else {
      if item.kind != "comment" {
        b <+ "<p class=\"muted\">\{item.kind.replace_all(old="_", new=" ")}</p>"
      }
      b <+
        "<div class=\"mr-comment markdown-body\">\{@web_ui.markdown(item.body, repo=Some(repo))}</div>"
    }
    if contributor &&
      (manager || item.actor_id == Some(user.id)) &&
      (item.kind == "comment" || item.kind == "comment_deleted") {
      let action = if item.kind == "comment_deleted" {
        "restore-comment"
      } else {
        "delete-comment"
      }
      b <+
        "<form method=\"post\" action=\"\{base}/\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"comment\" value=\"\{item.id.to_string()}\"><input type=\"hidden\" name=\"discussion\" value=\"\{discussion.to_string()}\"><input type=\"hidden\" name=\"version\" value=\"\{item.version.to_string()}\"><button class=\"secondary-button\" type=\"submit\">\{if item.kind == "comment_deleted" { "Restore comment" } else { "Delete comment" }}</button></form>"
    }
    b <+ "</div>"
  })
}

///|
fn render_merge_discussion(
  repo : @domain.RepoId,
  base : String,
  csrf : String,
  user : @domain.CurrentUser,
  discussion : @collaboration.MergeDiscussion,
  contributor : Bool,
  manager : Bool,
  selected : Bool,
  page : Int64,
) -> @moonback.Html {
  let id = discussion.id
  let preview = if discussion.root.kind == "comment_deleted" {
    "Comment deleted."
  } else {
    let text = StringBuilder()
    for ch in discussion.root.body.trim().iter().take(120) {
      text.write_char(
        if ch == '\n' || ch == '\r' || ch == '\t' {
          ' '
        } else {
          ch
        },
      )
    }
    text.to_string() +
    (if discussion.root.body.length() > 120 { "…" } else { "" })
  }
  Html(b => {
    b <+ "<details class=\"mr-discussion\" id=\"discussion-\{id.to_string()}\""
    if discussion.anchor is Some(anchor) {
      b <+ " data-discussion-anchor data-anchor=\"\{Json(anchor).stringify()}\""
    }
    if !discussion.resolved || selected {
      b <+ " open"
    }
    b <+
      "><summary><span>\{discussion.root.actor} · v\{discussion.version.to_string()}</span><span class=\"discussion-state\" data-resolved=\"\{discussion.resolved.to_string()}\">\{if discussion.resolved { "Resolved" } else { "Unresolved" }}</span><span class=\"muted\">\{discussion.reply_count.to_string()} \{if discussion.reply_count == 1L { "reply" } else { "replies" }}</span><span class=\"discussion-preview\">#\{id.to_string()} · \{preview}</span></summary><div class=\"discussion-content\">"
    if discussion.anchor is Some(anchor) {
      let path = if anchor.side == "old" {
        anchor.old_path
      } else {
        anchor.new_path
      }
      b <+
        "<p class=\"discussion-anchor\"><a href=\"\{base}?tab=changes&amp;version=\{discussion.version.to_string()}&amp;commit=\{anchor.commit_sha}&amp;discussion=\{id.to_string()}&amp;code=\{id.to_string()}&amp;mode=line&amp;ignore_comments=false&amp;ignore_tests=false#diff-code\">\{path} · \{anchor.side} L\{anchor.start_line.to_string()}–\{anchor.end_line.to_string()}</a> · \{if anchor.commit_sha.is_empty() { "All changes" } else { "Commit " + anchor.commit_sha[:12].to_owned() }}</p><pre class=\"anchor-context\">\{anchor.context}</pre>"
    }
    if !discussion.state_actor.is_empty() {
      b <+
        "<p class=\"muted\">\{if discussion.resolved { "Resolved" } else { "Reopened" }} by \{discussion.state_actor} · \{@web_ui.timestamp(discussion.state_changed_at)}</p>"
    }
    b <+
      "\{render_discussion_comment(repo, base, csrf, user, discussion.root, id, contributor, manager)}"
    if !selected && discussion.reply_count > 3L {
      b <+
        "<a href=\"\{base}?discussion=\{id.to_string()}#discussion-\{id.to_string()}\">View all \{discussion.reply_count.to_string()} replies</a><p class=\"muted\">Showing the latest 3 replies.</p>"
    }
    if selected && page > 1L {
      b <+ "<p class=\"muted\">Replies, page \{page.to_string()}</p>"
    }
    b <+ "<ol class=\"discussion-replies\">"
    for reply in discussion.replies {
      b <+
        "<li>\{render_discussion_comment(repo, base, csrf, user, reply, id, contributor, manager)}</li>"
    }
    b <+ "</ol><div class=\"mr-actions\">"
    if discussion.can_resolve {
      let action = if discussion.resolved {
        "reopen-discussion"
      } else {
        "resolve-discussion"
      }
      b <+
        "<form method=\"post\" action=\"\{base}/\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"discussion\" value=\"\{id.to_string()}\"><input type=\"hidden\" name=\"state_version\" value=\"\{discussion.state_version.to_string()}\"><button class=\"secondary-button\" type=\"submit\">\{if discussion.resolved { "Reopen discussion" } else { "Resolve discussion" }}</button></form>"
    }
    b <+ "</div>"
    if contributor {
      b <+
        "<details class=\"discussion-reply\"><summary>Reply</summary><form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}/reply\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"discussion\" value=\"\{id.to_string()}\"><input type=\"hidden\" name=\"version\" value=\"\{discussion.version.to_string()}\"><label class=\"field\"><span>Reply to discussion #\{id.to_string()}</span><textarea name=\"body\" rows=\"3\" maxlength=\"20000\" required></textarea></label>"
      if discussion.resolved {
        b <+
          "<p class=\"muted\">Replying keeps this discussion resolved. Use Reopen discussion to mark it unresolved.</p>"
      }
      b <+ "<button type=\"submit\">Send reply</button></form></details>"
    }
    b <+ "</div></details>"
  })
}

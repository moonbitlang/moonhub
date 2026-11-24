///|
pub fn secret_json(secret : @runtime.RepositorySecret) -> Json {
  {
    "name": secret.name,
    "branch": secret.branch,
    "workflow": secret.workflow_path,
    "version": secret.version.to_string(),
    "created_at": secret.created_at,
    "updated_at": secret.updated_at,
  }
}

///|
pub fn variable_json(variable : @runtime.RepositoryVariable) -> Json {
  {
    "name": variable.name,
    "value": variable.value,
    "version": variable.version.to_string(),
    "created_at": variable.created_at,
    "updated_at": variable.updated_at,
  }
}

///|
pub fn mr_json(mr : @collaboration.MergeRequest) -> Json {
  {
    "number": mr.number.to_string(),
    "title": mr.title,
    "description": mr.description,
    "closing_issue_numbers": @collaboration.closing_issue_numbers(
      mr.description,
    ).map(number => number.to_string()),
    "author": mr.author,
    "source": mr.source,
    "target": mr.target,
    "draft": mr.draft,
    "status": mr.status,
    "version": mr.version.to_string(),
    "edit_version": mr.edit_version.to_string(),
    "merged_sha": mr.merged_sha,
    "merge_status": mr.job_status,
    "merge_error": @domain.public_merge_job_error(mr.job_error),
  }
}

///|
pub fn issue_json(issue : @collaboration.Issue) -> Json {
  {
    "number": issue.number.to_string(),
    "title": issue.title,
    "description": issue.description,
    "author": issue.author,
    "assignee": issue.assignee,
    "assignee_id": issue.assignee_id.to_string(),
    "status": issue.status,
    "edit_version": issue.edit_version.to_string(),
    "updated_at": issue.updated_at,
  }
}

///|
pub fn run_json(run : @runtime.Run) -> Json {
  let status = match run.state {
    Queued => "queued"
    Running => "running"
    Completed => "completed"
  }
  let conclusion = conclusion_json(run.conclusion)
  {
    "number": run.number.to_string(),
    "run_id": run.public_id.to_string(),
    "run_attempt": run.run_attempt.to_string(),
    "workflow": run.workflow_path,
    "name": run.workflow_name,
    "branch": run.source_branch,
    "commit_sha": run.commit_sha,
    "context": run.context
    .map(value => ToJson::to_json(value))
    .unwrap_or(Json::null()),
    "status": status,
    "conclusion": conclusion,
    "created_at": run.created_at,
  }
}

///|
pub fn conclusion_json(conclusion : @runtime.Conclusion?) -> String {
  match conclusion {
    None => ""
    Some(Success) => "success"
    Some(Failure) => "failure"
    Some(Cancelled) => "cancelled"
    Some(TimedOut) => "timed_out"
    Some(Lost) => "lost"
    Some(Skipped) => "skipped"
  }
}

///|
pub fn check_json(check : @collaboration.MergeCheck) -> Json {
  {
    "workflow": check.workflow_path,
    "required": check.required,
    "status": check.state,
    "conclusion": check.conclusion,
    "run_number": check.run_number.map(id => id.to_string()).unwrap_or(""),
    "error": check.error,
  }
}

///|
pub fn activity_json(
  a : @collaboration.MergeActivity,
  preview~ : Bool = false,
) -> Json {
  // A 512-scalar preview stays below the CLI's 4 MiB budget even when JSON
  // escapes every character, across 50 roots and three replies per root.
  let body = if a.kind == "merge_failed" {
    @domain.merge_error_message
  } else {
    a.body
  }
  let excerpt = if preview {
    let text = StringBuilder()
    for ch in body.iter().take(512) {
      text.write_char(ch)
    }
    text.to_string()
  } else {
    body
  }
  {
    "id": a.id.to_string(),
    "actor_id": a.actor_id.map(id => id.to_string()).unwrap_or(""),
    "actor": a.actor,
    "kind": a.kind,
    "body": excerpt,
    "body_truncated": excerpt != body,
    "version": a.version.to_string(),
    "created_at": a.created_at,
    "discussion_id": a.discussion_id.map(id => id.to_string()).unwrap_or(""),
  }
}

///|
pub fn discussion_json(
  d : @collaboration.MergeDiscussion,
  preview~ : Bool = false,
) -> Json {
  {
    "id": d.id.to_string(),
    "version": d.version.to_string(),
    "resolved": d.resolved,
    "state_version": d.state_version.to_string(),
    "state_actor": d.state_actor,
    "state_changed_at": d.state_changed_at,
    "can_resolve": d.can_resolve,
    "root": activity_json(d.root, preview~),
    "replies": d.replies.map(reply => activity_json(reply, preview~)),
    "reply_count": d.reply_count.to_string(),
    "anchor": d.anchor
    .map(anchor => {
      let context = if preview {
        let text = StringBuilder()
        for ch in anchor.context.iter().take(512) {
          text.write_char(ch)
        }
        text.to_string()
      } else {
        anchor.context
      }
      (
        {
          "comparison": if anchor.commit_sha.is_empty() {
            "all"
          } else {
            "commit"
          },
          "commit_sha": if anchor.commit_sha.is_empty() {
            Json::null()
          } else {
            Json::string(anchor.commit_sha)
          },
          "base_sha": anchor.base_sha,
          "head_sha": anchor.head_sha,
          "old_path": anchor.old_path,
          "new_path": anchor.new_path,
          "side": anchor.side,
          "start_line": anchor.start_line.to_string(),
          "end_line": anchor.end_line.to_string(),
          "context": context,
          "context_truncated": preview && anchor.context.iter().count() > 512,
        } : Json)
    })
    .unwrap_or(Json::null()),
  }
}

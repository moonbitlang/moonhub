///|
fn required_result_selector(value : String) -> (String, String, String) raise {
  let parts = value.split("::").map(s => s.to_owned()).collect()
  if parts.length() == 1 {
    return (value, "", "")
  }
  guard parts.length() == 3 &&
    ["job", "check"].contains(parts[1]) &&
    !parts[2].trim().is_empty() &&
    parts[2].length() <= 200 &&
    !parts[2].iter().any(c => c.to_int() < 32) else {
    raise @domain.BadRequest(
      message="named results use workflow.yml::job::name or workflow.yml::check::name",
    )
  }
  (parts[0], parts[1], parts[2])
}

///|
fn required_result_strings(
  tx : @database.DbTransaction,
  repository : Int64,
  branch : String,
) -> Array[String] raise {
  tx
  .query_all(
    "SELECT workflow_path selector FROM branch_required_check WHERE repository_id=? AND branch=? AND whole_workflow=1 UNION ALL SELECT workflow_path || '::' || kind || '::' || name selector FROM branch_required_result WHERE repository_id=? AND branch=? ORDER BY selector",
    params=[repository, branch, repository, branch],
  )
  .map(r => r.get_name("selector"))
}

///|
fn named_results_blocker(
  client : @database.DbClient,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
) -> String raise {
  for
    rule in client.query_all(
      "SELECT * FROM branch_required_result WHERE repository_id=? AND branch=? ORDER BY workflow_path,kind,name",
      params=[scope.id, mr.target],
    ) {
    let path : String = rule.get_name("workflow_path")
    let kind : String = rule.get_name("kind")
    let name : String = rule.get_name("name")
    let label = path + " :: " + kind + " :: " + name
    // The current revision/generation and check's latest run identify the exact
    // candidate. Never accept an identically named result from a branch run.
    let run = client.query_opt(
      "SELECT r.id,r.commit_sha FROM merge_check c JOIN merge_request m ON m.id=c.merge_request_id JOIN pipeline_run r ON r.merge_check_id=c.id AND r.number=c.run_number AND r.repository_id=m.repository_id WHERE m.id=? AND c.version=m.current_version AND c.generation=m.check_generation AND c.workflow_path=?",
      params=[mr.id, path],
    )
    guard run is Some(run) else {
      return "Required result is missing: " + label
    }
    let run_id : Int64 = run.get_name("id")
    let rows = if kind == "job" {
      client.query_all(
        "SELECT j.status,COALESCE(j.conclusion,'') conclusion FROM pipeline_job j JOIN pipeline_run r ON r.id=j.run_id LEFT JOIN pipeline_job_definition d ON d.job_id=j.id WHERE j.run_id=? AND json_extract(COALESCE(d.definition_json,(SELECT value FROM json_each(r.definition_json,'$.jobs') WHERE json_extract(value,'$.id')=j.job_key)),'$.name')=?",
        params=[run_id, name],
      )
    } else {
      client.query_all(
        "SELECT CASE WHEN a.status='completed' AND a.conclusion NOT IN ('cancelled','lost','timed_out') THEN k.status ELSE 'pending' END status,k.conclusion FROM pipeline_check_run k JOIN pipeline_job_attempt a ON a.id=k.attempt_id WHERE k.repository_id=? AND k.run_id=? AND k.head_sha=? AND k.name=? AND a.number=(SELECT MAX(n.number) FROM pipeline_job_attempt n WHERE n.job_id=a.job_id)",
        params=[scope.id, run_id, (run.get_name("commit_sha") : String), name],
      )
    }
    if rows.is_empty() {
      return "Required result is missing: " + label
    }
    if rows.length() != 1 {
      return "Required result is ambiguous: " + label
    }
    if (rows[0].get_name("status") : String) != "completed" ||
      (rows[0].get_name("conclusion") : String) != "success" {
      return "Required result has not passed: " + label
    }
  }
  ""
}

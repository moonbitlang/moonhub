///|
test "job conditions use direct needs and status functions without matrix contexts" {
  let workflow = parse(
    (
      #|on: workflow_dispatch
      #|jobs:
      #|  prepare:
      #|    runs-on: self-hosted
      #|    outputs:
      #|      version: ${{ steps.release.outputs.version }}
      #|    steps: [{id: release, run: echo version}]
      #|  build:
      #|    needs: prepare
      #|    if: github.ref == 'refs/heads/main' && needs.prepare.outputs.version != ''
      #|    strategy: {matrix: {os: [linux, macos]}}
      #|    runs-on: [self-hosted, "${{ matrix.os }}"]
      #|    steps:
      #|      - run: echo ${{ needs.prepare.outputs.version }}
    ),
  ) catch {
    InvalidWorkflow(message) => fail(message)
  }
  assert_eq(workflow.jobs.length(), 3)
  assert_eq(
    workflow.jobs[0].outputs.get("version"),
    Some("${{ steps.release.outputs.version }}"),
  )
  let github : Map[String, Json] = { "ref": Json::string("refs/heads/main") }
  let needs : Map[String, Json] = {
    "prepare": { "outputs": { "version": "1.2.3" }, "result": "success" },
  }
  assert_true(
    job_condition(
      workflow.jobs[1].condition,
      github,
      needs,
      success=true,
      failure=false,
      cancelled=false,
    ),
  )
  assert_false(
    job_condition(
      "true",
      github,
      needs,
      success=false,
      failure=true,
      cancelled=false,
    ),
  )
  assert_true(
    job_condition(
      "failure()",
      github,
      needs,
      success=false,
      failure=true,
      cancelled=false,
    ),
  )
  assert_true(
    job_condition(
      "always() && !cancelled()",
      github,
      needs,
      success=false,
      failure=true,
      cancelled=false,
    ),
  )
  assert_false(
    job_condition(
      "!cancelled()",
      github,
      needs,
      success=false,
      failure=false,
      cancelled=true,
    ),
  )
  for
    condition in [
      "matrix.os == 'linux'", "secrets.TOKEN", "needs.other.result == 'success'",
      "hashFiles('**')", "always(1)",
    ] {
    try
      ignore(parse_job_condition(Some(@yaml.String(condition)), ["prepare"]))
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted invalid job condition: " + condition)
    }
  }
  try ignore(scheduling_expression("always()", { "github": {} })) catch {
    InvalidWorkflow(_) => ()
  } noraise {
    _ => fail("status functions leaked into concurrency")
  }
}

///|
test "job outputs reject secret references unknown contexts and invalid output names" {
  for
    source in [
      "token: ${{ secrets.TOKEN }}", "token: ${{ hashFiles('**') }}", "constructor: value",
      "value: ${{ unknown.version }}", "value: ${{ env.VERSION }}",
    ] {
    try ignore(parse_job_outputs(Some(read_yaml(source)))) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted invalid job outputs")
    }
  }
  let old : Job = @json.from_json(
    @json.parse(
      (
        #|{"id":"old","name":"Old","needs":[],"runs_on":["self-hosted","linux"],"timeout_minutes":1,"steps":[]}
      ),
    ),
  )
  assert_eq(old.condition, "success()")
  assert_true(old.outputs.is_empty())
}

///|
async test "openseek Desktop release dependency conditions and output templates remain unchanged" {
  let source = @fs.read_file(
    "pipeline/workflow/fixtures/openseek-release-dataflow.yml",
  ).text()
  let workflow = parse(source) catch {
    InvalidWorkflow(message) => fail(message)
  }
  assert_eq(workflow.jobs.length(), 6)
  let prepare = workflow.jobs
    .iter()
    .find_first(job => job.id == "release-needed")
    .unwrap()
  assert_eq(
    prepare.outputs.get("release"),
    Some("${{ steps.check.outputs.release }}"),
  )
  assert_eq(
    prepare.outputs.get("version"),
    Some("${{ steps.release.outputs.version }}"),
  )
  let github : Map[String, Json] = { "ref": "refs/heads/main" }
  for job in workflow.jobs {
    if job.id == "release-needed" {
      continue
    }
    assert_true(job.needs.contains("release-needed"))
    assert_eq(
      job.steps[0].templates.get("env:RELEASE_VERSION"),
      Some("${{ needs.release-needed.outputs.version }}"),
    )
    assert_true(
      job_condition(
        job.condition,
        github,
        { "release-needed": { "outputs": { "release": "true" } } },
        success=true,
        failure=false,
        cancelled=false,
      ),
    )
    assert_false(
      job_condition(
        job.condition,
        github,
        { "release-needed": { "outputs": { "release": "false" } } },
        success=true,
        failure=false,
        cancelled=false,
      ),
    )
    assert_false(
      job_condition(
        job.condition,
        github,
        { "release-needed": { "outputs": { "release": "true" } } },
        success=false,
        failure=true,
        cancelled=false,
      ),
    )
  }
  assert_eq(
    workflow.jobs.iter().find_first(job => job.id == "release-publish").unwrap().needs.length(),
    5,
  )
}

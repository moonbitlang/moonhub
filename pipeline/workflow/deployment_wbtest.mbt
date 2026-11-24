///|
test "deployment association supports the reusable deployment syntax and typed contexts" {
  let workflow = parse(
    (
      #|on: workflow_call
      #|jobs:
      #|  deploy:
      #|    environment: production
      #|    runs-on: ubuntu-latest
      #|    steps: [{run: echo deploy}]
    ),
  )
  assert_eq(workflow.jobs[0].deployment_environment, "production")
  let decoded : Workflow = @json.from_json(ToJson::to_json(workflow))
  assert_eq(decoded.jobs[0].deployment_environment, "production")
  let mapped = parse(
    (
      #|on: workflow_dispatch
      #|jobs:
      #|  deploy:
      #|    environment: {name: '${{ needs.build.outputs.target }}', url: 'https://example.test/${{ github.sha }}'}
      #|    needs: build
      #|    runs-on: self-hosted
      #|    steps: [{run: echo deploy}]
      #|  build:
      #|    runs-on: self-hosted
      #|    steps: [{run: echo build}]
    ),
  )
  assert_eq(
    mapped.jobs[0].deployment_environment,
    "${{ needs.build.outputs.target }}",
  )
  for
    source in [
      "environment: {url: https://example.test}", "environment: '${{ secrets.NAME }}'",
      "environment: {name: prod, unknown: true}",
    ] {
    try
      ignore(
        parse(
          "on: workflow_dispatch\njobs:\n  deploy:\n    " +
          source +
          "\n    runs-on: self-hosted\n    steps: [{run: echo deploy}]",
        ),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("invalid environment accepted")
    }
  }
}

///|
async test "the repository deployment environment declaration retains its protected target" {
  let source = @fs.read_file(".github/workflows/deploy.yml").text()
  let fields = yaml_as_obj(read_yaml(source), "workflow")
  let jobs = yaml_as_obj(fields["jobs"], "jobs")
  let deploy = yaml_as_obj(jobs["deploy"], "deploy")
  assert_eq(
    parse_deployment_environment(deploy.get("environment")),
    ("production", ""),
  )
  // The repository's GitHub-only bootstrap variables remain reserved here.
  try ignore(parse(source)) catch {
    InvalidWorkflow(message) =>
      assert_true(
        message.contains("MOONHUB_DEPLOY_INSTANCE_ID") &&
        message.contains("reserved"),
      )
  } noraise {
    _ => fail("reserved bootstrap namespace became writable")
  }
}

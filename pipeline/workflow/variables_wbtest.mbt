///|
test "repository variables are available in job conditions concurrency and output templates" {
  let workflow = parse(
    (
      #|on: workflow_dispatch
      #|concurrency:
      #|  group: build-${{ vars.CHANNEL }}-${{ vars.MISSING }}
      #|  cancel-in-progress: vars.CANCEL == 'true'
      #|jobs:
      #|  build:
      #|    if: vars.CHANNEL == 'nightly' && vars.MISSING == ''
      #|    runs-on: self-hosted
      #|    outputs:
      #|      region: ${{ vars.OPENSEEK_S3_REGION }}
      #|    steps:
      #|      - if: vars.CHANNEL == 'nightly'
      #|        env: {REGION: '${{ vars.OPENSEEK_S3_REGION }}'}
      #|        run: echo ${{ vars.CHANNEL }}
    ),
  )
  let variables : Map[String, String] = {
    "CHANNEL": "nightly",
    "CANCEL": "true",
    "OPENSEEK_S3_REGION": "us-east-1",
  }
  assert_true(
    job_condition(
      workflow.jobs[0].condition,
      Map([]),
      Map([]),
      variables=Some(variables),
      success=true,
      failure=false,
      cancelled=false,
    ),
  )
  assert_eq(
    workflow.concurrency.unwrap().resolve(Map([]), variables=Some(variables)),
    ("build-nightly-", true),
  )
  assert_eq(
    workflow.jobs[0].outputs.get("region"),
    Some("${{ vars.OPENSEEK_S3_REGION }}"),
  )
}

///|
test "variables lookup ignores case returns missing strings and evaluates only once" {
  let variables : Map[String, String] = {
    "REGION": "ap-east-1",
    "LITERAL": "${{ vars.REGION }}",
  }
  let context : Map[String, Json] = { "vars": ToJson::to_json(variables) }
  assert_eq(scheduling_template("${{ VaRs.ReGiOn }}", context), "ap-east-1")
  assert_eq(scheduling_template("${{ vars.MISSING }}", context), "")
  assert_eq(
    scheduling_template("${{ vars.LITERAL }}", context),
    "${{ vars.REGION }}",
  )
  assert_true(
    job_condition(
      "vars.MISSING == ''",
      Map([]),
      Map([]),
      variables=Some(Map([])),
      success=true,
      failure=false,
      cancelled=false,
    ),
  )
}

///|
test "historical scheduling contracts keep variables unavailable" {
  try
    ignore(
      job_condition(
        "vars.MISSING == ''",
        Map([]),
        Map([]),
        success=true,
        failure=false,
        cancelled=false,
      ),
    )
  catch {
    InvalidWorkflow(message) => assert_true(message.contains("unavailable"))
  } noraise {
    _ => fail("historical job condition acquired variables context")
  }
  let policy = parse_concurrency(Some(@yaml.String("${{ vars.MISSING }}x"))).unwrap()
  try ignore(policy.resolve(Map([]))) catch {
    InvalidWorkflow(message) => assert_true(message.contains("unavailable"))
  } noraise {
    _ => fail("historical concurrency acquired variables context")
  }
  assert_eq(policy.resolve(Map([]), variables=Some(Map([]))), ("x", false))
}

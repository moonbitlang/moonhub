///|
test "dynamic matrix templates round trip and enforce global expansion budgets" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  plan:
    #|    runs-on: self-hosted
    #|    steps: [{run: echo plan}]
    #|  build:
    #|    needs: plan
    #|    runs-on: ${{ matrix.labels }}
    #|    strategy: {matrix: '${{ fromJSON(needs.plan.outputs.matrix) }}'}
    #|    continue-on-error: ${{ matrix.allowed }}
    #|    concurrency: {group: '${{ matrix.name }}', queue: max}
    #|    steps: [{run: echo test}]
  let workflow = parse(source)
  let decoded : Workflow = @json.from_json(ToJson::to_json(workflow))
  assert_eq(ToJson::to_json(decoded), ToJson::to_json(workflow))
  let template = decoded.jobs[1]
  assert_true(template.dynamic_matrix is Some(_))
  let context : Map[String, Json] = {
    "needs": {
      "plan": {
        "outputs": {
          "matrix": "{\"include\":[{\"labels\":[\"self-hosted\",\"linux\"],\"name\":\"test\",\"allowed\":true}]}",
        },
      },
    },
    "github": {},
    "vars": {},
    "inputs": {},
  }
  let (_, jobs) = expand_dynamic_matrix(
    template,
    context,
    remaining_jobs=1,
    remaining_steps=1,
    remaining_bytes=65536,
  )
  assert_eq(jobs.length(), 1)
  assert_eq(jobs[0].id, "build[1]")
  assert_eq(jobs[0].runs_on, ["self-hosted", "linux"])
  assert_true(jobs[0].dynamic_matrix is None)
  for (jobs, steps, bytes) in [(0, 1, 65536), (1, 0, 65536), (1, 1, 1)] {
    try
      ignore(
        expand_dynamic_matrix(
          template,
          context,
          remaining_jobs=jobs,
          remaining_steps=steps,
          remaining_bytes=bytes,
        ),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("ignored dynamic workflow budget")
    }
  }
}

///|
test "queue max rejects incompatible cancellation and malformed queue policy" {
  for
    policy in [
      "{group: x, queue: max, cancel-in-progress: true}", "{group: x, queue: max, cancel-in-progress: '${{ github.event.cancel }}'}",
      "{group: x, queue: 100}",
    ] {
    expect_invalid("concurrency: " + policy + "\n" + basic_workflow, "queue")
    expect_invalid(basic_workflow + "\n    concurrency: " + policy, "queue")
  }
  let old : Concurrency = @json.from_json(
    ({ "group": "legacy", "cancel_in_progress": "false" } : Json),
  )
  assert_false(old.queue_max)
}

///|
test "scheduling JSON functions and relational comparisons require extended policy context" {
  let context : Map[String, Json] = {
    "matrix": { "allowed": true },
    "needs": {
      "plan": { "outputs": { "matrix": "{\"include\":[{\"version\":1}]}" } },
    },
  }
  assert_true(
    scheduling_expression("matrix.allowed", context, extended=true) is True,
  )
  assert_eq(
    scheduling_expression(
      "fromJSON(needs.plan.outputs.matrix)",
      context,
      extended=true,
    ),
    ({ "include": [{ "version": 1 }] } : Json),
  )
  assert_eq(
    scheduling_expression(
      "join(fromJSON('[1,2]'), ':')",
      context,
      extended=true,
    ),
    Json::string("1:2"),
  )
  assert_true(
    scheduling_expression("'2' > 1 && 'a' < 'B'", context, extended=true)
    is True,
  )
  for
    expression in [
      "fromJSON('bad')",
      "fromJSON('{\"prototype\":{}}')",
      "join('a','b','c')",
      "fromJSON('1e400')",
      "fromJSON('" + "[".repeat(33) + "0" + "]".repeat(33) + "')",
    ] {
    try
      ignore(scheduling_expression(expression, context, extended=true))
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("invalid extended expression")
    }
  }
  try ignore(scheduling_expression("fromJSON('true')", context)) catch {
    InvalidWorkflow(_) => ()
  } noraise {
    _ => fail("changed legacy scheduling semantics")
  }
}

///|
async test "scheduler and runner share extended scheduling expression cases" {
  let data = @json.parse(
    @fs.read_file("pipeline/workflow/fixtures/expression-scheduling.json").text(),
  )
  guard data
    is {
      "context": Object(context),
      "valid": Array(valid),
      "invalid": Array(invalid),
      ..
    } else {
    fail("invalid fixture")
  }
  for item in valid {
    guard item is Array([String(expression), expected]) else {
      fail("invalid case")
    }
    assert_eq(
      scheduling_expression(expression, context, extended=true),
      expected,
    )
  }
  for item in invalid {
    guard item is String(expression) else { fail("invalid case") }
    try
      ignore(scheduling_expression(expression, context, extended=true))
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted invalid expression")
    }
  }
}

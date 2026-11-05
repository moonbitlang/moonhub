///|
async test "original Editor workflow expands its cross platform matrix and concurrency without YAML edits" {
  let source = @fs.read_file("pipeline/workflow/fixtures/openseek-editor.yml").text()
  let workflow = parse(source)
  assert_eq(workflow.jobs.length(), 3)
  let matrix = workflow.jobs.filter(job => job.matrix_group == "moon-gates")
  assert_eq(matrix.length(), 2)
  assert_eq(matrix[0].name, "moon (stable, ubuntu-24.04)")
  assert_eq(matrix[0].runs_on, ["self-hosted", "linux", "x64", "ubuntu-24.04"])
  assert_eq(matrix[1].runs_on, ["self-hosted", "macos", "arm64", "macos-latest"])
  assert_false(matrix[0].fail_fast)
  let github : Map[String, Json] = {
    "workflow": Json::string("Editor"),
    "ref": Json::string("refs/pull/42/merge"),
    "event_name": Json::string("pull_request"),
  }
  assert_eq(
    workflow.concurrency.unwrap().resolve(github),
    ("editor-refs/pull/42/merge", true),
  )
  github["event_name"] = Json::string("push")
  assert_eq(workflow.concurrency.unwrap().resolve(github).1, false)
  let decoded : Workflow = @json.from_json(ToJson::to_json(workflow))
  assert_eq(ToJson::to_json(decoded), ToJson::to_json(workflow))
}

///|
test "matrix axes include exclude types and downstream needs expand deterministically" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-24.04
    #|    strategy:
    #|      fail-fast: false
    #|      max-parallel: 2
    #|      matrix:
    #|        os: [a, b]
    #|        version: [1, 2]
    #|        exclude: [{os: b, version: 1}]
    #|        include:
    #|          - {os: a, extra: hello}
    #|          - {os: c, version: 3}
    #|          - {os: a, extra: goodbye}
    #|    steps:
    #|      - run: echo '${{ matrix.os }}-${{ matrix.version }}'
    #|  after:
    #|    needs: build
    #|    runs-on: ubuntu-24.04
    #|    steps: [{run: echo done}]
  let workflow = parse(source)
  assert_eq(workflow.jobs.length(), 5)
  assert_eq(workflow.jobs[0].matrix.get("version"), Some(ToJson::to_json(1)))
  assert_eq(workflow.jobs[0].matrix.get("extra"), Some(Json::string("goodbye")))
  assert_eq(workflow.jobs[1].matrix.get("extra"), Some(Json::string("goodbye")))
  assert_eq(workflow.jobs[2].matrix.get("os"), Some(Json::string("b")))
  assert_eq(workflow.jobs[3].matrix.get("os"), Some(Json::string("c")))
  assert_true(workflow.jobs[3].matrix.get("extra") is None)
  assert_true(workflow.jobs[0].steps[0].templates.contains("run"))
  assert_eq(workflow.jobs[4].needs, workflow.jobs[:4].map(job => job.id))
  assert_eq(workflow.jobs[0].max_parallel, 2)
  let include_only = source.replace_all(old="os: [a, b]", new="unused: [a]")
  expect_invalid(include_only, "unknown axis")
}

///|
test "matrix include only does not merge standalone entries and preserves scalar types" {
  let rows = expand_matrix(
    @yaml.Yaml::load_from_string(
      "include: [{target: linux, enabled: true}, {target: linux, version: 1}]",
    )[0],
  )
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].get("enabled"), Some(Json::boolean(true)))
  assert_true(rows[1].get("enabled") is None)
  for
    source in [
      "axis: []", "axis: [a]\nexclude: [{missing: a}]", "axis: [{object: value}]",
    ] {
    try ignore(expand_matrix(@yaml.Yaml::load_from_string(source)[0])) catch {
      InvalidWorkflow(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid matrix")
    }
  }
  expect_invalid(
    basic_workflow + "\n    strategy: {matrix: {x: [a]}, max-parallel: 0}",
    "max-parallel",
  )
}

///|
test "scheduling expressions are parsed bounded nonrecursive and scope checked" {
  let context : Map[String, Json] = {
    "github": { "ref": "${{ secrets.NEVER }}", "event_name": "pull_request" },
    "matrix": { "os": "ubuntu-24.04" },
  }
  assert_eq(
    scheduling_template("group-${{ github.ref }}", context),
    "group-${{ secrets.NEVER }}",
  )
  assert_eq(
    scheduling_expression(
      "github.event_name == 'pull_request' && !false", context,
    ),
    Json::boolean(true),
  )
  assert_eq(
    scheduling_template("${{ format('{0}-{1}', matrix.os, 'x') }}", context),
    "ubuntu-24.04-x",
  )
  for
    expr in [
      "secrets.TOKEN",
      "github.ref;system()",
      "unknown()",
      "(".repeat(40) + "true" + ")".repeat(40),
    ] {
    try ignore(scheduling_expression(expr, context)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted unsupported expression")
    }
  }
  expect_invalid(
    "concurrency: {group: '${{ matrix.os }}'}\n" + basic_workflow,
    "unavailable",
  )
}

///|
test "scheduling format and comparisons do not recursively substitute arguments" {
  let context : Map[String, Json] = { "github": ({} : Json) }
  assert_eq(scheduling_expression("'1' == 1", context), Json::boolean(true))
  assert_eq(
    scheduling_expression("'TRUE' == 'true'", context),
    Json::boolean(true),
  )
  assert_eq(
    scheduling_expression("format('{0}-{1}', '{1}', 'safe')", context),
    Json::string("{1}-safe"),
  )
  assert_eq(
    scheduling_expression("format('{{{0}}}', 'safe')", context),
    Json::string("{safe}"),
  )
  expect_invalid(
    "concurrency: {group: safe, cancel-in-progress: 'false && matrix.os'}\n" +
    basic_workflow,
    "unavailable",
  )
}

///|
test "matrix and scheduling expansion charge UTF8 budgets before allocating oversized results" {
  let context : Map[String, Json] = {
    "matrix": { "label": "字".repeat(15000) },
  }
  try
    ignore(
      scheduling_template("${{ matrix.label }}${{ matrix.label }}", context),
    )
  catch {
    InvalidWorkflow(_) => ()
  } noraise {
    _ => fail("scheduling template accepted more than 64 KiB UTF8")
  }
  let rows = Array::makei(256, i => i.to_string()).join(", ")
  let step = "      - run: echo hello\n"
  let source = "on: workflow_dispatch\njobs:\n  build:\n    runs-on: ubuntu-24.04\n    strategy: {matrix: {item: [" +
    rows +
    "]}}\n    steps:\n" +
    step.repeat(64)
  expect_invalid(source, "expanded workflow")
}

///|
async test "scheduler and runner share literal index fixtures" {
  let fixture : Map[String, Json] = @json.from_json(
    @json.parse(
      @fs.read_file("pipeline/workflow/fixtures/expression-indexes.json").text(),
    ),
  )
  let context : Map[String, Json] = @json.from_json(fixture["context"])
  let valid : Array[(String, String)] = @json.from_json(fixture["valid"])
  for (expression, expected) in valid {
    assert_eq(
      scheduling_template("${{ " + expression + " }}", context),
      expected,
    )
  }
  let invalid : Array[String] = @json.from_json(fixture["invalid"])
  for expression in invalid {
    try ignore(scheduling_expression(expression, context)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted invalid index: " + expression)
    }
  }
}

///|
test "job output validation checks syntax without evaluating runtime data" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    outputs:
    #|      flags: ${{ join(matrix.node.flags, ' | ') }}
    #|      ready: ${{ steps.count.outputs.value >= 2 }}
    #|      lt: ${{ steps.count.outputs.value < 4 }}
    #|      le: ${{ steps.count.outputs.value <= 3 }}
    #|      gt: ${{ steps.count.outputs.value > -1.5e2 }}
    #|      parsed: ${{ fromJSON(steps.count.outputs.json) }}
    #|      literal: ${{ format('{0}', '}} secrets.TOKEN') }}
    #|    steps: [{id: count, run: echo count}]
  let workflow = parse(source)
  assert_eq(workflow.jobs[0].outputs.length(), 7)
  for
    expression in [
      "join()", "join(matrix.flags, ',', 'x')", "steps.x >=", "false && secrets.TOKEN",
      "env.TOKEN", "fromJSON()", "hashFiles('**')",
    ] {
    expect_invalid(
      source.replace_all(old="join(matrix.node.flags, ' | ')", new=expression),
      "",
    )
  }
}

///|
test "whole runs-on expressions preserve label arrays and validate each label" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: ${{ matrix.node.labels }}
    #|    strategy:
    #|      matrix:
    #|        node:
    #|          - {labels: [self-hosted, linux]}
    #|          - {labels: [self-hosted, linux, arm64]}
    #|    steps:
    #|      - run: echo '${{ matrix.node.labels[0] }}'
  let jobs = (parse(source) catch { InvalidWorkflow(message) => fail(message) }).jobs
  assert_eq(jobs[0].runs_on, ["self-hosted", "linux"])
  assert_true(jobs[0].compatibility_runtime)
  assert_eq(jobs[1].runs_on, ["self-hosted", "linux", "arm64"])
  assert_eq(
    parse(
      source.replace_all(
        old="runs-on: ${{ matrix.node.labels }}",
        new="runs-on: ${{ 'self' }}-${{ 'hosted' }}",
      ),
    ).jobs[0].runs_on,
    ["self-hosted"],
  )
  for
    labels in [
      "[self-hosted, 1]", "[self-hosted, linux, windows]", "[self-hosted, linux, linux]",
      "[]", "[self-hosted, 'bad label']",
    ] {
    expect_invalid(
      source.replace_all(old="[self-hosted, linux]", new=labels),
      "",
    )
  }
  assert_eq(
    parse(
      source.replace_all(
        old="matrix.node.labels }}",
        new="matrix.node.labels[0] }}",
      ),
    ).jobs[0].runs_on,
    ["self-hosted"],
  )
}

///|
test "bounded YAML aliases preserve env and steps and reject expansion attacks" {
  let anchored =
    #|on: workflow_dispatch
    #|env: &env {GREETING: hello}
    #|jobs:
    #|  first:
    #|    runs-on: self-hosted
    #|    steps: &steps
    #|      - env: *env
    #|        run: echo hello
    #|  second:
    #|    runs-on: self-hosted
    #|    steps: *steps
  let inline = anchored
    .replace_all(old="&env ", new="")
    .replace_all(old="*env", new="{GREETING: hello}")
    .replace_all(old="&steps", new="")
    .replace_all(
      old="*steps",
      new="[{env: {GREETING: hello}, run: echo hello}]",
    )
  assert_eq(ToJson::to_json(parse(anchored)), ToJson::to_json(parse(inline)))
  expect_invalid(
    "env: &env {X: *env}\n" + basic_workflow,
    "recursive YAML alias",
  )
  expect_invalid("env: *missing\n" + basic_workflow, "invalid YAML")
  let mut bomb = "a: &a [x,x,x,x]\n"
  for i = 0; i < 10; i = i + 1 {
    let previous = if i == 0 { "a" } else { "a" + (i - 1).to_string() }
    bomb += "a\{i}: &a\{i} [*\{previous},*\{previous},*\{previous},*\{previous}]\n"
  }
  expect_invalid(bomb, "8192 nodes")
  let scalar = "a: &a '" +
    "字".repeat(10000) +
    "'\nb: [" +
    Array::make(40, "*a").join(",") +
    "]"
  expect_invalid(scalar, "expanded YAML exceeds 1 MiB")
  let nested = "a: &a " +
    "[".repeat(20) +
    "x" +
    "]".repeat(20) +
    "\nb: " +
    "[".repeat(20) +
    "*a" +
    "]".repeat(20)
  expect_invalid(nested, "nesting exceeds 32 levels")
}

///|
test "bare step conditions request numeric-index runtime capabilities" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    strategy:
    #|      matrix:
    #|        node: [{flags: [test]}]
    #|    steps:
    #|      - run: echo test
    #|        CONDITION
  for field in ["if", "continue-on-error"] {
    for
      condition in [
        "matrix.node.flags[0] == 'test'", "${{ matrix.node.flags[0] == 'test' }}",
      ] {
      let workflow = parse(
        source.replace_all(old="CONDITION", new=field + ": " + condition),
      )
      assert_true(workflow.jobs[0].compatibility_runtime)
      assert_eq(workflow.jobs[0].steps[0].templates.get(field), Some(condition))
    }
    let workflow = parse(
      source.replace_all(old="CONDITION", new=field + ": \"'[0]' == '[0]'\""),
    )
    assert_false(workflow.jobs[0].compatibility_runtime)
  }
  let script = source
    .replace_all(old="CONDITION", new="name: test")
    .replace_all(old="echo test", new="echo '[0]'")
  assert_false(parse(script).jobs[0].compatibility_runtime)
}

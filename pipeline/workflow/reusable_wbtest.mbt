///|
let reusable_caller_fixture : String =
  #|on: workflow_dispatch
  #|permissions: {contents: read}
  #|jobs:
  #|  call:
  #|    uses: ./.github/workflows/callee.yml
  #|    with: {enabled: true, count: 3, label: release}
  #|  after:
  #|    needs: call
  #|    runs-on: self-hosted
  #|    steps: [{run: 'echo ${{ needs.call.outputs.version }}'}]

///|
let reusable_callee_fixture : String =
  #|on:
  #|  workflow_call:
  #|    inputs:
  #|      enabled: {type: boolean, required: true}
  #|      count: {type: number, default: 1}
  #|      label: {type: string, default: none}
  #|    outputs:
  #|      version: {value: '${{ jobs.build.outputs.version }}'}
  #|permissions: {contents: write, id-token: write}
  #|jobs:
  #|  build:
  #|    if: inputs.enabled
  #|    runs-on: self-hosted
  #|    outputs: {version: '${{ steps.build.outputs.version }}'}
  #|    steps: [{id: build, run: 'echo ${{ inputs.label }}-${{ inputs.count }}'}]

///|
test "reusable snapshots retain typed declarations cap permissions and namespace dependencies" {
  let workflow = parse(reusable_caller_fixture, reusable={
    ".github/workflows/callee.yml": reusable_callee_fixture,
  }) catch {
    InvalidWorkflow(message) => fail(message)
  }
  let decoded : Workflow = @json.from_json(ToJson::to_json(workflow))
  assert_eq(ToJson::to_json(decoded), ToJson::to_json(workflow))
  let (inputs, children) = instantiate_reusable(decoded.jobs[0], {
    "github": {},
    "inputs": {},
    "needs": {},
    "vars": {},
  }) catch {
    InvalidWorkflow(message) => fail(message)
  }
  assert_true(inputs.get("enabled") is Some(True))
  assert_eq(inputs.get("count"), Some(Json::number(3)))
  assert_eq(children[0].id, "call/build")
  assert_eq(children[0].context_prefix, "call/")
  assert_eq(children[0].api_permissions, 1)
  assert_true(children[0].contents_read)
  assert_false(children[0].id_token_write)
  assert_eq(
    reusable_outputs(
      decoded.jobs[0],
      { "build": { "result": "success", "outputs": { "version": "1.2.3" } } },
      inputs,
      Map([]),
    ),
    { "version": "1.2.3" },
  )
}

///|
test "reusable workflows reject moving refs cycles undeclared inputs and wrong types" {
  let sources = { ".github/workflows/callee.yml": reusable_callee_fixture }
  for
    source in [
      reusable_caller_fixture.replace_all(
        old="./.github/workflows/callee.yml",
        new="owner/repo/.github/workflows/callee.yml@master",
      ),
      reusable_caller_fixture.replace_all(
        old="./.github/workflows/callee.yml",
        new="./.github/workflows/../callee.yml",
      ),
      reusable_caller_fixture.replace_all(
        old="enabled: true",
        new="enabled: 'true'",
      ),
      reusable_caller_fixture.replace_all(
        old="enabled: true",
        new="unknown: true",
      ),
      reusable_caller_fixture.replace_all(old="enabled: true, ", new=""),
    ] {
    try ignore(parse(source, reusable=sources)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("invalid reusable workflow accepted")
    }
  }
  let cycle = "on: workflow_call\njobs:\n  loop:\n    uses: ./.github/workflows/callee.yml\n"
  try
    ignore(parse(cycle, reusable={ ".github/workflows/callee.yml": cycle }))
  catch {
    InvalidWorkflow(message) => assert_true(message.contains("cycle"))
  } noraise {
    _ => fail("recursive callee accepted")
  }
}

///|
async test "unchanged CI required selection includes six logical checks and the pinned frontend callee" {
  let caller = @fs.read_file(".github/workflows/ci.yml").text()
  let callee = @fs.read_file(".github/workflows/frontend-checks.yml").text()
  assert_eq(reusable_paths(caller, jobs=["required"]), [
    ".github/workflows/frontend-checks.yml",
  ])
  let workflow = parse(caller, jobs=["required"], reusable={
    ".github/workflows/frontend-checks.yml": callee,
  })
  let required = workflow.jobs
    .iter()
    .find_first(job => job.id == "required")
    .unwrap()
  assert_eq(required.needs.length(), 7)
  for
    name in [
      "self-check", "docker-ssh", "windows-runner", "macos-runner", "frontend", "build-deploy-regressions",
    ] {
    assert_true(
      workflow.jobs.any(job => job.id == name || job.matrix_group == name),
    )
  }
  let frontend = workflow.jobs
  .iter()
  .find_first(job => job.id == "frontend")
  .unwrap().reusable_call.unwrap()
  assert_eq(frontend.source, callee)
  assert_eq(frontend.definition.jobs[0].id, "browser")
  assert_true(frontend.definition.jobs[0].steps.length() > 10)
  assert_false(workflow.jobs.any(job => job.id == "deploy"))
}

///|
test "workflow call input declarations require types and strictly typed defaults" {
  for
    declaration in [
      "{default: false}", "{type: boolean, default: 'false'}", "{type: number, default: '3'}",
      "{type: choice, options: [a]}",
    ] {
    try
      ignore(
        triggers(
          "on:\n  workflow_call:\n    inputs:\n      value: " + declaration,
        ),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("untyped reusable input accepted")
    }
  }
}

///|
test "nested expansion contributes to the global executable job budget" {
  let callee = "on: workflow_call\njobs:\n  build:\n    runs-on: self-hosted\n    strategy:\n      matrix:\n        index: [" +
    Array::makei(256, index => index.to_string()).join(",") +
    "]\n    steps: [{run: echo build}]\n"
  let caller = "on: workflow_dispatch\njobs:\n  one:\n    uses: ./.github/workflows/callee.yml\n  two:\n    uses: ./.github/workflows/callee.yml\n"
  try
    ignore(parse(caller, reusable={ ".github/workflows/callee.yml": callee }))
  catch {
    InvalidWorkflow(message) =>
      assert_true(message.contains("256 jobs"), msg=message)
  } noraise {
    _ => fail("callee jobs escaped the workflow budget")
  }
}

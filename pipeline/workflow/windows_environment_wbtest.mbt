///|
test "Windows aliases resolve to a concrete immutable environment" {
  for selector in ["windows-latest", "windows-2025"] {
    let job = parse(
        basic_workflow.replace_all(old="[self-hosted, linux]", new=selector),
      ).jobs[0]
    assert_eq(job.runs_on, ["self-hosted", "windows", "x64", "windows-2025"])
    let saved : Job = @json.from_json(ToJson::to_json(job))
    assert_eq(saved.runs_on, job.runs_on)
  }
  let custom = parse(
      basic_workflow.replace_all(
        old="[self-hosted, linux]",
        new="[self-hosted, windows, x64, custom-build]",
      ),
    ).jobs[0]
  assert_eq(custom.runs_on, ["self-hosted", "windows", "x64", "custom-build"])
}

///|
async test "original pinned openseek Windows workflows parse without repository-specific rewriting" {
  let source = @fs.read_file(
    "pipeline/workflow/fixtures/openseek-ci-windows.yml",
  ).text()
  let jobs = parse(source).jobs
  let windows = jobs.iter().find_first(job => job.id == "tui-windows").unwrap()
  let selected = parse(source, jobs=["tui-windows"])
  assert_eq(selected.jobs.length(), 1)
  assert_eq(ToJson::to_json(selected.jobs[0]), ToJson::to_json(windows))
  assert_eq(windows.runs_on, ["self-hosted", "windows", "x64", "windows-2025"])
  assert_eq(windows.steps[0].uses, Some("actions/checkout@v5"))
  assert_eq(windows.steps[1].uses, Some("ilammy/msvc-dev-cmd@v1"))
  assert_true(windows.steps[2].run.contains("desktop/.moonbit-version"))
  assert_true(windows.steps[5].run.contains("git ls-files"))
  let desktop = parse(
      @fs.read_file("pipeline/workflow/fixtures/openseek-desktop-windows.yml").text(),
    ).jobs[0]
  assert_eq(desktop.runs_on, windows.runs_on)
  assert_eq(desktop.timeout_minutes, 60)
  assert_true(
    desktop.steps.any(step => step.uses == Some("actions/setup-node@v4")),
  )
}

///|
test "selected workflow jobs retain dependency closure and reject invalid selections" {
  let source =
    #|on: pull_request
    #|jobs:
    #|  prepare:
    #|    runs-on: self-hosted
    #|    steps: [{run: echo prepare}]
    #|  build:
    #|    needs: prepare
    #|    runs-on: windows-latest
    #|    steps: [{run: echo build}]
    #|  unrelated:
    #|    runs-on: macos-latest
    #|    steps: [{run: echo unrelated}]
  let selected = parse(source, jobs=["build"])
  assert_eq(selected.jobs.length(), 2)
  assert_true(selected.jobs.any(job => job.id == "prepare"))
  assert_eq(
    selected.jobs.iter().find_first(job => job.id == "build").unwrap().needs,
    ["prepare"],
  )
  let matrix = parse(
    source.replace_all(
      old="    needs: prepare",
      new="    needs: prepare\n    strategy:\n      matrix:\n        flavor: [a, b]",
    ),
    jobs=["build"],
  )
  assert_eq(matrix.jobs.length(), 3)
  assert_eq(matrix.jobs.filter(job => job.matrix_group == "build").length(), 2)
  for jobs in [["missing"], ["build", "build"], [""]] {
    try ignore(parse(source, jobs~)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("invalid selected jobs accepted")
    }
  }
  try
    ignore(
      parse(source.replace_all(old="needs: prepare", new="needs: build"), jobs=[
        "build",
      ]),
    )
  catch {
    InvalidWorkflow(_) => ()
  } noraise {
    _ => fail("selected dependency cycle accepted")
  }
}

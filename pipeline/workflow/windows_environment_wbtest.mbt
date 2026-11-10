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

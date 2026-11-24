///|
test "container plans retain services options and bounded public expressions" {
  let workflow = parse(
    (
      #|on: workflow_dispatch
      #|jobs:
      #|  build:
      #|    runs-on: [self-hosted, linux]
      #|    container:
      #|      image: '${{ vars.IMAGE }}'
      #|      env: {REGION: '${{ vars.REGION }}'}
      #|      options: --cpus 1 --memory 1g
      #|    services:
      #|      database:
      #|        image: postgres:16-bookworm
      #|        ports: [5432, '15432:5432/tcp']
      #|        options: --health-cmd "pg_isready -U postgres" --health-retries 5
      #|    steps: [{uses: 'docker://busybox:1.37'}]
    ),
  )
  let decoded : Workflow = @json.from_json(ToJson::to_json(workflow))
  let plan = decoded.jobs[0].containers.unwrap()
  assert_eq(plan.job.unwrap().image, "${{ vars.IMAGE }}")
  assert_eq(plan.services["database"].ports, ["5432", "15432:5432/tcp"])
  assert_eq(plan.services["database"].options, [
    "--health-cmd", "pg_isready -U postgres", "--health-retries", "5",
  ])
  for
    field in [
      "container: {image: debian, volumes: ['/:/host']}", "container: {image: debian, options: '--privileged true'}",
      "container: {image: debian, options: '--network host'}", "container: {image: debian, ports: ['0.0.0.0:80:80']}",
      "container: {image: debian, env: {VALUE: '${{ secrets.TOKEN }}'}}", "services: {localhost: {image: debian}}",
    ] {
    try
      ignore(
        parse(
          "on: workflow_dispatch\njobs:\n  build:\n    runs-on: self-hosted\n    " +
          field +
          "\n    steps: [{run: echo ok}]",
        ),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("unsafe container plan accepted")
    }
  }
}

///|
test "explicit linux-ci selection and image actions request isolation while old definitions stay unchanged" {
  for selector in ["[self-hosted, linux, linux-ci]", "self-hosted"] {
    let workflow = parse(
      "on: workflow_dispatch\njobs:\n  build:\n    runs-on: " +
      selector +
      "\n    steps: [{uses: 'docker://busybox:1.37'}]",
    )
    assert_true(workflow.jobs[0].containers is Some(_))
  }
  let old = parse(
    "on: workflow_dispatch\njobs:\n  build:\n    runs-on: self-hosted\n    steps: [{run: echo ok}]",
  )
  assert_true(old.jobs[0].containers is None)
  assert_eq(@actions.docker_options("--health-cmd 'pg_isready -U postgres'"), [
    "--health-cmd", "pg_isready -U postgres",
  ])
  try ignore(@actions.docker_options("--health-cmd 'line\nline'")) catch {
    @actions.InvalidAction(_) => ()
  } noraise {
    _ => fail("multiline option accepted")
  }
}

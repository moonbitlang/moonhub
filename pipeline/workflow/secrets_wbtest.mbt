///|
test "secret env is normalized after precedence and kept separate from public interpolation" {
  let source =
    #|on: workflow_dispatch
    #|env:
    #|  TOKEN: ${{ secrets.original }}
    #|  REMOVED: ${{ secrets.ignored }}
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    env:
    #|      REMOVED: public
    #|    steps:
    #|      - run: echo hello
    #|        env:
    #|          TOKEN: ${{ secrets.actual }}
    #|          HEAD: ${{ github.head_ref }}
  let step = resolve_context(parse(source), {
      ..mr_context,
      head_ref: "${{secrets.INJECTED}}",
    }).jobs[0].steps[0]
  assert_eq(step.env.get("TOKEN"), None)
  assert_eq(step.secret_env.get("TOKEN"), Some("ACTUAL"))
  assert_eq(step.secret_env.length(), 1)
  assert_eq(step.env.get("REMOVED"), Some("public"))
  assert_eq(step.env.get("HEAD"), Some("${{secrets.INJECTED}}"))
  assert_eq(step.secret_env.get("HEAD"), None)
  let decoded : Step = @json.from_json(ToJson::to_json(step))
  assert_eq(decoded.secret_env.get("TOKEN"), Some("ACTUAL"))
}

///|
test "secret expressions reject concatenation indexing functions and reserved names" {
  for
    value in [
      "prefix-${{ secrets.TOKEN }}", "${{ secrets.TOKEN }}suffix", "${{ secrets['TOKEN'] }}",
      "${{ secrets.TOKEN || 'x' }}", "${{ secrets.GITHUB_TOKEN }}", "${{ secrets.1TOKEN }}",
      "${{ secrets. }}",
    ] {
    try
      ignore(
        parse(basic_workflow + "\n        env: {TOKEN: \"" + value + "\"}"),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted invalid secret expression")
    }
  }
  let legacy : Step = @json.from_json(
    @json.parse(
      "{\"id\":\"one\",\"name\":\"one\",\"run\":\"true\",\"uses\":null,\"shell\":null,\"working_directory\":\".\",\"env\":{},\"timeout_minutes\":null}",
    ),
  )
  assert_true(legacy.secret_env.is_empty())
}

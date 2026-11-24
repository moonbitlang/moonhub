///|
async test "workflow containers cannot be claimed by ordinary providers or enabled by labels" {
  let source = @test_support.single_job_workflow.replace_all(
    old="    steps:",
    new="    container: debian:bookworm\n    steps:",
  )
  with_protocol_fixture(
    (c, pool, _, run, provider, clock) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      let actor = @identity.active_user_by_name(pool, "alice")
      assert_true(run.definition.jobs[0].containers is Some(_))
      assert_true(c.runtime.claim(provider_secret, claim_request()) is None)
      c.runtime.set_provider_labels(admin, provider.id, [
        "self-hosted", "linux", "linux-ci",
      ])
      let restarted = @runtime.Coordinator::new(pool, clock=() => clock.val)
      assert_true(restarted.claim(provider_secret, claim_request()) is None)
      assert_true(
        restarted
        .queue_reasons(actor, protocol_repo, run.number)
        .values()
        .any(reason => reason is @runtime.ContainerIsolationUnavailable),
      )
    },
    workflow=source,
  )
}

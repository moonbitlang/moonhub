///|
async test "log polling stops only after completion and draining the final redaction tail" {
  with_protocol_fixture((coordinator, pool, _, run, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let assignment = coordinator
      .claim(provider_secret, claim_request())
      .unwrap()
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    assert_false(
      coordinator.read_log_page(actor, protocol_repo, run.number, id).complete,
    )
    for n = 1; n <= 100; n = n + 1 {
      ignore(
        coordinator.append_log(
          id,
          attempt_secret,
          log_request(n.to_int64(), "line\n"),
        ),
      )
    }
    let tail = attempt_secret[:6].to_owned()
    ignore(coordinator.append_log(id, attempt_secret, log_request(101L, tail)))
    let first = coordinator.read_log_page(actor, protocol_repo, run.number, id)
    assert_eq(first.chunks.length(), 100)
    assert_true(first.has_more)
    assert_false(first.complete)
    let second = coordinator.read_log_page(
      actor,
      protocol_repo,
      run.number,
      id,
      after=@protocol.parse_decimal(first.next_cursor).unwrap(),
    )
    assert_eq(second.chunks.length(), 1)
    assert_eq(second.chunks[0].text, "")
    assert_false(second.has_more)
    assert_false(second.complete)
    ignore(
      coordinator.complete(id, attempt_secret, {
        version: 1,
        conclusion: "success",
        last_log_sequence: "101",
      }),
    )
    let backlog = coordinator.read_log_page(
      actor,
      protocol_repo,
      run.number,
      id,
    )
    assert_true(backlog.has_more)
    assert_false(backlog.complete)
    let last_page = coordinator.read_log_page(
      actor,
      protocol_repo,
      run.number,
      id,
      after=@protocol.parse_decimal(second.next_cursor).unwrap(),
    )
    assert_eq(last_page.chunks.length(), 1)
    assert_eq(last_page.chunks[0].text, tail)
    assert_false(last_page.has_more)
    assert_true(last_page.complete)
    let empty = coordinator.read_log_page(
      actor,
      protocol_repo,
      run.number,
      id,
      after=@protocol.parse_decimal(last_page.next_cursor).unwrap(),
    )
    assert_true(empty.chunks.is_empty())
    assert_true(empty.complete)
    assert_eq(empty.next_cursor, last_page.next_cursor)
  })
}

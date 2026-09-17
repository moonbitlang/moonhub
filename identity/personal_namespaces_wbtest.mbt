///|
async test "accepting a team invitation also provisions the member's personal namespace" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (5, 'acme', 'Acme', 'org');
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (9, 'team_member', 'newcomer@example.com', 'newcomer', 'Newcomer',
          #|  'test', 5, 'member', 3);
        ),
      )
    })
    let invitation : InvitationSession = {
      id: 9L,
      name_key: "newcomer",
      display_name: "Newcomer",
    }
    guard accept_invitation(pool, invitation, "AcceptedPassword123") is Some(_) else {
      fail("invitation was not accepted")
    }
    let newcomer = active_user_by_name(pool, "newcomer")
    let personal = personal_namespace(pool, newcomer).unwrap_or_else(() => {
      fail("member has no personal namespace")
    })
    assert_eq(personal.kind, "personal")
    assert_eq(personal.name_key, "newcomer")
    assert_eq(personal.display_name, "Newcomer")
    assert_eq(team_role(pool, newcomer, personal.id), Some("owner"))
    let org = get_team_by_name_key(pool, "acme").unwrap()
    assert_eq(team_role(pool, newcomer, org.id), Some("member"))
  })
}

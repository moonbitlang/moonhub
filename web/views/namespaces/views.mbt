///|
fn render_teams(
  asset_path_map : Map[String, String],
  user : @domain.CurrentUser,
  teams : Array[@identity.TeamSummary],
  message : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Teams",
    asset_path_map,
    Html(b => {
      b <+
        #|<section class="page-heading page-heading--actions">
        #|<div class="heading-title"><h1>Teams</h1></div>
      if user.is_site_admin {
        b <+
          "<a class=\"button-link\" href=\"/-/teams/new\"><span class=\"ui-icon\" data-icon=\"plus\" aria-hidden=\"true\"></span>New team</a>"
      }
      b <+ "</section>"
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      if teams.is_empty() {
        b <+
          "<section class=\"empty-state\"><p class=\"muted\">No teams available.</p></section>"
      } else {
        b <+
          "<section class=\"table-frame\"><div class=\"table-scroll\"><table class=\"teams-table\"><thead><tr><th>Team</th><th>Your role</th></tr></thead><tbody>"
        for team in teams {
          let role = team.role.unwrap_or(
            if user.is_site_admin {
              "site admin"
            } else {
              ""
            },
          )
          b <+
            "<tr><td><div class=\"identity-cell\"><span class=\"team-avatar\" aria-hidden=\"true\">\{team.name_key[:1].to_owned().to_upper()}</span><span><a class=\"repo-name\" href=\"/\{team.name_key}\">\{team.display_name}</a><span class=\"cell-secondary\">\{team.name_key}</span></span></div></td><td><span class=\"role-label\">\{role}</span></td></tr>"
        }
        b <+ "</tbody></table></div></section>"
      }
    }),
    current_user=Some(user),
    navigation=@web_ui.WorkspaceNavigation("teams"),
  )
}

///|
fn render_new_team(
  asset_path_map : Map[String, String],
  user : @domain.CurrentUser,
  message : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "New team",
    asset_path_map,
    Html(b => {
      b <+
        #|<section class="page-heading">
        #|<h1>New team</h1>
        #|</section>
        #|<section class="panel"><form class="form-stack" method="post" action="/-/teams">
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<label class="field"><span>Team handle</span><input name="name_key" autocomplete="off" required></label>
        #|<label class="field"><span>Display name</span><input name="display_name" required></label>
        #|<p class="form-actions"><button type="submit">Create team</button></p>
        #|</form></section>
    }),
    current_user=Some(user),
    navigation=@web_ui.WorkspaceNavigation("teams"),
    body_class="form-page",
  )
}

///|
fn render_team_detail(
  asset_path_map : Map[String, String],
  user : @domain.CurrentUser,
  team : @identity.TeamSummary,
  members : Array[@identity.TeamMemberSummary],
  invitations : Array[@identity.InvitationSummary],
  repositories~ : Array[@repository.TeamRepository],
  can_manage~ : Bool,
  invitation_credentials_csrf~ : String,
  message : String?,
  active_tab~ : String = "repositories",
  invite_open~ : Bool = false,
  invitation_form~ : Map[String, String] = Map([]),
  notice~ : String? = None,
) -> @moonback.Html {
  @web_ui.layout(
    team.display_name,
    asset_path_map,
    Html(b => {
      b <+
        "<section class=\"page-heading team-heading\"><span class=\"team-avatar team-avatar-large\" aria-hidden=\"true\">\{team.name_key[:1].to_owned().to_upper()}</span><div><h1>\{team.display_name}</h1><p class=\"page-subtitle\">\{team.name_key}<span class=\"metadata-separator\" aria-hidden=\"true\">/</span>\{repositories.length().to_string()} repositories<span class=\"metadata-separator\" aria-hidden=\"true\">/</span>\{members.length().to_string()} members</p></div></section>"
      if notice is Some(notice) {
        b <+
          "<p class=\"settings-success\" role=\"status\"><span class=\"ui-icon\" data-icon=\"circle-check\" aria-hidden=\"true\"></span>\{notice}</p>"
      }
      b <+ "<div id=\"team-repositories\""
      if active_tab != "repositories" {
        b <+ " hidden"
      }
      b <+
        ">\{@web_ui.render_team_repositories(team, repositories, can_manage)}</div><section id=\"team-members\""
      if active_tab != "members" {
        b <+ " hidden"
      }
      b <+ "><div class=\"section-heading\"><h2>Members</h2>"
      if can_manage {
        b <+
          "<a class=\"button-link\" href=\"/\{team.name_key}?tab=invitations&amp;invite=1\"><span class=\"ui-icon\" data-icon=\"user-plus\" aria-hidden=\"true\"></span>Invite member</a>"
      }
      b <+
        "</div><div class=\"table-frame\"><div class=\"table-scroll\"><table class=\"members-table\"><thead><tr><th>Member</th><th>Email</th><th>Role</th></tr></thead><tbody>"
      if members.is_empty() {
        b <+ "<tr><td colspan=\"3\" class=\"muted\">No members.</td></tr>"
      } else {
        for person in members {
          let email = person.email.unwrap_or("")
          b <+
            "<tr><td><div class=\"identity-cell\"><span class=\"avatar\" aria-hidden=\"true\">\{person.name_key[:1].to_owned().to_upper()}</span><span><strong>\{person.display_name}</strong><span class=\"cell-secondary\">\{person.name_key}</span></span></div></td><td class=\"muted\">\{email}</td><td><span class=\"role-label\">\{person.role}</span></td></tr>"
        }
      }
      b <+
        "</tbody></table></div></div></section><section id=\"team-invitations\""
      if active_tab != "invitations" {
        b <+ " hidden"
      }
      b <+ "><div class=\"section-heading\"><h2>Invitations</h2>"
      if can_manage && !invite_open {
        b <+
          "<a class=\"button-link\" href=\"/\{team.name_key}?tab=invitations&amp;invite=1\"><span class=\"ui-icon\" data-icon=\"user-plus\" aria-hidden=\"true\"></span>Invite member</a>"
      }
      b <+ "</div>"
      if can_manage {
        b <+
          "<form class=\"invite-form\" method=\"post\" action=\"/\{team.name_key}/-/invitations\""
        if !invite_open {
          b <+ " hidden"
        }
        b <+ "><h3>Invite member</h3>"
        if message is Some(message) {
          b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
        }
        b <+
          "<div class=\"invite-fields\"><label class=\"field\"><span>Email</span><input type=\"email\" name=\"email\" autocomplete=\"email\" value=\"\{invitation_form.get("email").unwrap_or("")}\" required></label><label class=\"field\"><span>Username</span><input name=\"name_key\" autocomplete=\"off\" value=\"\{invitation_form.get("name_key").unwrap_or("")}\" required></label><label class=\"field\"><span>Display name</span><input name=\"display_name\" autocomplete=\"name\" value=\"\{invitation_form.get("display_name").unwrap_or("")}\" required></label><label class=\"field\"><span>Role</span><select name=\"role\" aria-label=\"Role\"><option value=\"member\">Member</option><option value=\"admin\""
        if invitation_form.get("role") == Some("admin") {
          b <+ " selected"
        }
        b <+
          ">Admin</option></select></label></div><div class=\"form-actions\"><button type=\"submit\"><span class=\"ui-icon\" data-icon=\"send\" aria-hidden=\"true\"></span>Send invite</button><a class=\"secondary-button button-link\" href=\"/\{team.name_key}?tab=invitations\">Cancel</a></div></form>"
      }
      b <+
        "<div class=\"table-frame\"><div class=\"table-scroll\"><table class=\"invitations-table\"><thead><tr><th>Email</th><th>User</th><th>Role</th><th>Status</th><th>Delivery</th><th><span class=\"sr-only\">Actions</span></th></tr></thead><tbody>"
      if invitations.is_empty() {
        b <+ "<tr><td colspan=\"6\" class=\"muted\">No invitations.</td></tr>"
      } else {
        for invitation in invitations {
          let invitation_id = invitation.id.to_string()
          let role = invitation.role.unwrap_or("")
          let delivery_status = invitation.email_status.unwrap_or("not queued")
          let status_label = match invitation.status {
            "sent" => "Awaiting acceptance"
            "accepted" => "Accepted"
            "expired" => "Expired"
            _ => "Revoked"
          }
          let delivery_label = match delivery_status {
            "pending" => "Queued"
            "sent" => "Delivered"
            "failed" => "Failed"
            _ => "Not queued"
          }
          b <+
            "<tr><td>\{invitation.email}</td><td><span class=\"repo-name\">\{invitation.display_name}</span><div class=\"cell-secondary\">\{invitation.name_key}</div></td><td><span class=\"role-label\">\{role}</span></td><td><span class=\"status-badge\" data-status=\"\{invitation.status}\">\{status_label}</span></td><td><span class=\"delivery-state\" data-delivery=\"\{delivery_status}\">\{delivery_label}</span>"
          match invitation.email_sent_at {
            Some(sent_at) => b <+ "<div class=\"muted\">\{sent_at}</div>"
            None => ()
          }
          match invitation.email_last_error {
            Some(_) =>
              b <+
                "<details class=\"delivery-detail\"><summary>Details</summary><p class=\"flash-error\">\{@domain.email_delivery_error_message}</p></details>"
            None => ()
          }
          b <+ "</td><td><div class=\"row-action-group\">"
          if can_manage &&
            invitation.status == "sent" &&
            (
              invitation.email_status == Some("pending") ||
              invitation.email_status == Some("failed")
            ) &&
            invitation.email_last_error is Some(_) {
            b <+
              "<form class=\"inline-form\" method=\"post\" action=\"/\{team.name_key}/-/invitations/\{invitation_id}/resend\"><button class=\"secondary-button\" type=\"submit\">Resend</button></form>"
          }
          if (can_manage || user.is_site_admin) && invitation.status == "sent" {
            b <+
              "<details class=\"row-menu\" data-dismissable><summary class=\"icon-button\" aria-label=\"Invitation actions for \{invitation.email}\" title=\"More actions\"><span class=\"ui-icon\" data-icon=\"ellipsis\" aria-hidden=\"true\"></span></summary><div class=\"row-menu-panel\">"
            if user.is_site_admin && invitation.email_status is Some(_) {
              b <+
                "<form class=\"inline-form\" method=\"post\" action=\"/\{team.name_key}/-/invitations/\{invitation_id}/credentials\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{invitation_credentials_csrf}\"><button class=\"secondary-button\" type=\"submit\">View sign-in details</button></form>"
            }
            if can_manage {
              b <+
                "<form class=\"inline-form\" method=\"post\" action=\"/\{team.name_key}/-/invitations/\{invitation_id}/revoke\"><button class=\"danger-button secondary-button\" type=\"submit\">Revoke</button></form>"
            }
            b <+ "</div></details>"
          }
          b <+ "</div></td></tr>"
        }
      }
      b <+ "</tbody></table></div></div></section>"
    }),
    current_user=Some(user),
    navigation=@web_ui.TeamNavigation(team, active_tab),
  )
}

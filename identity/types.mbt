///|
pub(all) struct RootUserConfig {
  name_key : String
  initial_password : String
}

///|
pub struct LoginResult {
  token : String
  invitation : InvitationLogin?
}

///|
pub struct InvitationLogin {
  id : Int64
}

///|
pub struct InvitationSession {
  id : Int64
  name_key : String
  display_name : String
}

///|
pub struct TeamSummary {
  id : Int64
  name_key : String
  display_name : String
  kind : String
  role : String?
}

///|
pub struct TeamMemberSummary {
  name_key : String
  display_name : String
  email : String?
  role : String
}

///|
pub struct InvitationSummary {
  id : Int64
  email : String
  name_key : String
  display_name : String
  role : String?
  status : String
  email_status : String?
  email_sent_at : String?
  email_last_error : String?
}

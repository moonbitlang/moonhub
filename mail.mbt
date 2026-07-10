///|
let default_mail_outbox_dir : String = "_build/mail_outbox"

///|
let default_mail_from : String = "moonhub@localhost"

///|
enum MailTransportConfig {
  File(outbox_dir~ : String)
  Smtp(config~ : @transport.SmtpConfig, from~ : String)
}

///|
struct EmailOutboxMessage {
  id : Int64
  to_email : String
  subject : String
  body : String
}

///|
suberror MailConfigError {
  Invalid(message~ : String)
} derive(Debug)

///|
suberror MailDeliveryError {
  Rejected(message~ : String)
} derive(Debug)

///|
fn mail_worker_id() -> String {
  "moonhub"
}

///|
fn mail_outbox_dir_from_env() -> String {
  @env.get_env_var("MAIL_OUTBOX_DIR").unwrap_or(default_mail_outbox_dir)
}

///|
fn env_value(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) => {
      let value = value.trim().to_owned()
      if value.is_empty() {
        None
      } else {
        Some(value)
      }
    }
    None => None
  }
}

///|
fn env_value_or(name : String, default : String) -> String {
  env_value(name).unwrap_or(default)
}

///|
fn parse_env_int(name : String, default : Int) -> Int raise MailConfigError {
  match env_value(name) {
    None => default
    Some(value) =>
      @string.parse_int(value) catch {
        _ => raise Invalid(message="invalid \{name}")
      }
  }
}

///|
fn parse_env_bool(name : String, default : Bool) -> Bool raise MailConfigError {
  match env_value(name) {
    None => default
    Some(value) =>
      match value.to_lower() {
        "1" | "true" | "yes" | "on" => true
        "0" | "false" | "no" | "off" => false
        _ => raise Invalid(message="invalid \{name}")
      }
  }
}

///|
fn mail_transport_from_env() -> MailTransportConfig raise MailConfigError {
  match env_value_or("MAIL_TRANSPORT", "file").to_lower() {
    "file" => File(outbox_dir=mail_outbox_dir_from_env())
    "smtp" =>
      Smtp(
        config=smtp_config_from_env(),
        from=env_value_or("SMTP_FROM", default_mail_from),
      )
    value =>
      raise Invalid(message="MAIL_TRANSPORT must be file or smtp, got \{value}")
  }
}

///|
fn smtp_config_from_env() -> @transport.SmtpConfig raise MailConfigError {
  let host = match env_value("SMTP_HOST") {
    Some(host) => host
    None => raise Invalid(message="SMTP_HOST is required")
  }
  let port = parse_env_int("SMTP_PORT", 587)
  let security : @transport.SmtpSecurity = match
    env_value_or("SMTP_SECURITY", "starttls").to_lower() {
    "plain" => Plain
    "starttls" | "start_tls" => StartTls
    "tls" | "ssl" => Tls
    value =>
      raise Invalid(
        message="SMTP_SECURITY must be plain, starttls, or tls, got \{value}",
      )
  }
  let auth : @transport.SmtpAuth = match
    env_value_or("SMTP_AUTH", "plain").to_lower() {
    "none" => None
    "plain" =>
      Plain(
        required_env_value("SMTP_USERNAME"),
        required_env_value("SMTP_PASSWORD"),
      )
    "login" =>
      Login(
        required_env_value("SMTP_USERNAME"),
        required_env_value("SMTP_PASSWORD"),
      )
    "xoauth2" =>
      Xoauth2(
        required_env_value("SMTP_USERNAME"),
        required_env_value("SMTP_PASSWORD"),
      )
    value =>
      raise Invalid(
        message="SMTP_AUTH must be none, plain, login, or xoauth2, got \{value}",
      )
  }
  let tls_trust : @transport.SmtpTlsTrust = match
    env_value_or("SMTP_TLS_TRUST", "system").to_lower() {
    "system" | "system_root" => SystemRoot
    "insecure" | "insecure_no_verify" => InsecureNoVerify
    "custom_pem_file" | "custom" =>
      CustomPemFile(required_env_value("SMTP_TLS_ROOT_CERT_FILE"))
    value =>
      raise Invalid(
        message="SMTP_TLS_TRUST must be system, insecure, or custom, got \{value}",
      )
  }
  @transport.SmtpConfig::new(
    host,
    port,
    hello_name=env_value_or("SMTP_HELO_NAME", "localhost"),
    security~,
    auth~,
    tls_trust~,
    timeouts=@transport.SmtpTimeouts::new(
      connect_ms=parse_env_int("SMTP_CONNECT_TIMEOUT_MS", 10_000),
      greeting_ms=parse_env_int("SMTP_GREETING_TIMEOUT_MS", 10_000),
      command_ms=parse_env_int("SMTP_COMMAND_TIMEOUT_MS", 10_000),
      data_ms=parse_env_int("SMTP_DATA_TIMEOUT_MS", 120_000),
      idle_ms=parse_env_int("SMTP_IDLE_TIMEOUT_MS", 60_000),
    ),
    retry_policy=@transport.SmtpRetryPolicy::new(
      max_retries=parse_env_int("SMTP_MAX_RETRIES", 1),
      retry_delay_ms=parse_env_int("SMTP_RETRY_DELAY_MS", 250),
      retry_on_connection_failure=parse_env_bool(
        "SMTP_RETRY_CONNECTION_FAILURE", true,
      ),
      retry_on_timeout=parse_env_bool("SMTP_RETRY_TIMEOUT", true),
      retry_on_transient_failure=parse_env_bool(
        "SMTP_RETRY_TRANSIENT_FAILURE", true,
      ),
    ),
    reuse_connection=parse_env_bool("SMTP_REUSE_CONNECTION", true),
  )
}

///|
fn required_env_value(name : String) -> String raise MailConfigError {
  match env_value(name) {
    Some(value) => value
    None => raise Invalid(message="\{name} is required")
  }
}

///|
async fn start_mail_worker(
  pool : @pgpool.Pool,
  group : @async.TaskGroup[Unit],
) -> Unit {
  let worker_id = mail_worker_id()
  let transport = mail_transport_from_env()
  match transport {
    File(outbox_dir~) =>
      @fs.mkdir(outbox_dir, recursive=true) catch {
        @os_error.OSError(_) => ()
        err => raise err
      }
    Smtp(_) => ()
  }
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    run_mail_worker(pool, worker_id, transport)
  })
}

///|
async fn run_mail_worker(
  pool : @pgpool.Pool,
  worker_id : String,
  transport : MailTransportConfig,
) -> Unit {
  for ;; {
    let processed = deliver_next_email(pool, worker_id, transport) catch {
      err => {
        println("mail worker error: \{err}")
        false
      }
    }
    if !processed {
      @async.sleep(1000)
    }
  }
}

///|
async fn deliver_next_email(
  pool : @pgpool.Pool,
  worker_id : String,
  transport : MailTransportConfig,
) -> Bool {
  match claim_next_email(pool, worker_id) {
    None => false
    Some(message) => {
      let delivered = try {
        let provider_message_id = deliver_email(transport, message)
        mark_email_delivered(pool, message.id, provider_message_id)
        true
      } catch {
        err => {
          mark_email_failed(pool, message.id, "\{err}")
          false
        }
      }
      let _ = delivered
      true
    }
  }
}

///|
async fn deliver_email(
  transport : MailTransportConfig,
  message : EmailOutboxMessage,
) -> String {
  match transport {
    File(outbox_dir~) => deliver_email_to_file(outbox_dir, message)
    Smtp(config~, from~) => deliver_email_to_smtp(config, from, message)
  }
}

///|
async fn claim_next_email(
  pool : @pgpool.Pool,
  worker_id : String,
) -> EmailOutboxMessage? {
  pool.with_client(client => {
    let sql =
      #|WITH picked AS (
      #|  SELECT id
      #|  FROM email_outbox
      #|  WHERE status = 'pending'
      #|    AND next_attempt_at <= now()
      #|  ORDER BY next_attempt_at, id
      #|  FOR UPDATE SKIP LOCKED
      #|  LIMIT 1
      #|)
      #|UPDATE email_outbox
      #|SET locked_at = now(),
      #|    locked_by = $1,
      #|    attempt_count = attempt_count + 1
      #|FROM picked
      #|WHERE email_outbox.id = picked.id
      #|RETURNING
      #|  email_outbox.id,
      #|  email_outbox.to_email,
      #|  email_outbox.subject,
      #|  email_outbox.body
    match client.query_opt(sql, params=[worker_id]) {
      None => None
      Some(row) =>
        Some({
          id: row.get_name("id"),
          to_email: row.get_name("to_email"),
          subject: row.get_name("subject"),
          body: row.get_name("body"),
        })
    }
  })
}

///|
async fn deliver_email_to_file(
  outbox_dir : String,
  message : EmailOutboxMessage,
) -> String {
  let provider_message_id = "file-\{message.id}"
  let outbox_dir = trim_trailing_slash(outbox_dir)
  @fs.mkdir(outbox_dir, recursive=true) catch {
    @os_error.OSError(_) => ()
    err => raise err
  }
  let path = "\{outbox_dir}/\{message.id}.eml"
  let content =
    $|To: \{message.to_email}
    $|Subject: \{message.subject}
    $|
    $|\{message.body}
  @fs.write_file(path, content, create_mode=CreateOrTruncate)
  provider_message_id
}

///|
async fn deliver_email_to_smtp(
  config : @transport.SmtpConfig,
  from : String,
  message : EmailOutboxMessage,
) -> String {
  let sender = mailbox_or_raise("SMTP_FROM", from)
  let recipient = mailbox_or_raise("message recipient", message.to_email)
  let email_message = message_or_raise(sender, recipient, message)
  let envelope = envelope_or_raise(sender, recipient)
  let transport = @transport.SmtpTransport::new(config)
  defer transport.close()
  let outcome = transport.send_message(envelope, email_message)
  if !outcome.rejected.is_empty() || outcome.accepted.is_empty() {
    raise MailDeliveryError::Rejected(message=outcome.response)
  }
  "smtp: \{outcome.response}"
}

///|
fn mailbox_or_raise(
  label : String,
  address : String,
) -> @core.Mailbox raise MailDeliveryError {
  match @core.Mailbox::address_only(address) {
    Ok(mailbox) => mailbox
    Err(_) => raise Rejected(message="invalid \{label}: \{address}")
  }
}

///|
fn envelope_or_raise(
  sender : @core.Mailbox,
  recipient : @core.Mailbox,
) -> @core.Envelope raise MailDeliveryError {
  match @core.Envelope::new(sender, [recipient]) {
    Ok(envelope) => envelope
    Err(_) => raise Rejected(message="invalid envelope")
  }
}

///|
fn message_or_raise(
  sender : @core.Mailbox,
  recipient : @core.Mailbox,
  message : EmailOutboxMessage,
) -> @core.Message raise MailDeliveryError {
  match
    @core.Message::new(
      sender,
      [recipient],
      [],
      [],
      message.subject,
      @core.Body::plain_text(message.body),
      [],
    ) {
    Ok(email_message) => email_message
    Err(_) => raise Rejected(message="invalid email message")
  }
}

///|
async fn mark_email_delivered(
  pool : @pgpool.Pool,
  message_id : Int64,
  provider_message_id : String,
) -> Unit {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|UPDATE email_outbox
        #|SET status = 'sent',
        #|    sent_at = now(),
        #|    provider_message_id = $2,
        #|    locked_at = NULL,
        #|    locked_by = NULL,
        #|    last_error = NULL
        #|WHERE id = $1
      ),
      params=[message_id, provider_message_id],
    )
  })
}

///|
async fn mark_email_failed(
  pool : @pgpool.Pool,
  message_id : Int64,
  message : String,
) -> Unit {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|UPDATE email_outbox
        #|SET status = CASE
        #|      WHEN attempt_count >= 10 THEN 'failed'::email_outbox_status
        #|      ELSE 'pending'::email_outbox_status
        #|    END,
        #|    next_attempt_at = now() + (interval '1 minute' * LEAST(attempt_count, 10)),
        #|    locked_at = NULL,
        #|    locked_by = NULL,
        #|    last_error = $2
        #|WHERE id = $1
      ),
      params=[message_id, message],
    )
  })
}

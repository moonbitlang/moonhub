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
struct SmtpSettings {
  host : String
  port : Int
  security : String
  auth : String
  username : String
  password : String
  tls_trust : String
  tls_root_cert_file : String
  helo_name : String
  from : String
}

///|
struct MailSettings {
  transport : String
  smtp : SmtpSettings
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
fn default_smtp_settings() -> SmtpSettings {
  {
    host: "",
    port: 587,
    security: "starttls",
    auth: "plain",
    username: "",
    password: "",
    tls_trust: "system",
    tls_root_cert_file: "",
    helo_name: "localhost",
    from: default_mail_from,
  }
}

///|
fn load_mail_settings(pool : Database) -> MailSettings raise {
  pool.with_client(client => {
    match
      client.query_opt(
        "SELECT transport, smtp_host, smtp_port, smtp_security, smtp_auth, smtp_username, smtp_password, smtp_tls_trust, smtp_tls_root_cert_file, smtp_helo_name, smtp_from FROM mail_settings WHERE id = 1",
      ) {
      None => { transport: "file", smtp: default_smtp_settings(), }
      Some(row) =>
        {
          transport: row.get_name("transport"),
          smtp: {
            host: row.get_name("smtp_host"),
            port: (row.get_name("smtp_port") : Int64).to_int(),
            security: row.get_name("smtp_security"),
            auth: row.get_name("smtp_auth"),
            username: row.get_name("smtp_username"),
            password: row.get_name("smtp_password"),
            tls_trust: row.get_name("smtp_tls_trust"),
            tls_root_cert_file: row.get_name("smtp_tls_root_cert_file"),
            helo_name: row.get_name("smtp_helo_name"),
            from: row.get_name("smtp_from"),
          },
        }
    }
  })
}

///|
fn smtp_config_from_settings(
  settings : SmtpSettings,
) -> @transport.SmtpConfig raise MailConfigError {
  guard !settings.host.is_empty() else {
    raise Invalid(message="SMTP host is required")
  }
  let security : @transport.SmtpSecurity = match settings.security.to_lower() {
    "plain" => Plain
    "starttls" | "start_tls" => StartTls
    "tls" | "ssl" => Tls
    value =>
      raise Invalid(
        message="SMTP security must be plain, starttls, or tls, got \{value}",
      )
  }
  let auth : @transport.SmtpAuth = match settings.auth.to_lower() {
    "none" => None
    "plain" => Plain(settings.username, settings.password)
    "login" => Login(settings.username, settings.password)
    "xoauth2" => Xoauth2(settings.username, settings.password)
    value =>
      raise Invalid(
        message="SMTP authentication must be none, plain, login, or xoauth2, got \{value}",
      )
  }
  let tls_trust : @transport.SmtpTlsTrust = match
    settings.tls_trust.to_lower() {
    "system" | "system_root" => SystemRoot
    "insecure" | "insecure_no_verify" => InsecureNoVerify
    "custom_pem_file" | "custom" => CustomPemFile(settings.tls_root_cert_file)
    value =>
      raise Invalid(
        message="SMTP TLS trust must be system, insecure, or custom, got \{value}",
      )
  }
  @transport.SmtpConfig::new(
    settings.host,
    settings.port,
    hello_name=settings.helo_name,
    security~,
    auth~,
    tls_trust~,
    timeouts=@transport.SmtpTimeouts::new(
      connect_ms=10_000,
      greeting_ms=10_000,
      command_ms=10_000,
      data_ms=120_000,
      idle_ms=60_000,
    ),
    retry_policy=@transport.SmtpRetryPolicy::new(
      max_retries=1,
      retry_delay_ms=250,
      retry_on_connection_failure=true,
      retry_on_timeout=true,
      retry_on_transient_failure=true,
    ),
    reuse_connection=true,
  )
}

///|
fn mail_transport_from_db(pool : Database) -> MailTransportConfig raise {
  let settings = load_mail_settings(pool)
  match settings.transport.to_lower() {
    "file" => File(outbox_dir=mail_outbox_dir_from_env())
    "smtp" =>
      Smtp(
        config=smtp_config_from_settings(settings.smtp),
        from=settings.smtp.from,
      )
    value => raise Invalid(message="invalid mail transport: \{value}")
  }
}

///|
fn start_mail_worker(pool : Database, group : @async.TaskGroup[Unit]) -> Unit {
  let worker_id = mail_worker_id()
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    run_mail_worker(pool, worker_id)
  })
}

///|
async fn run_mail_worker(pool : Database, worker_id : String) -> Unit {
  for ;; {
    let processed = deliver_next_email(
      pool,
      worker_id,
      mail_transport_from_db(pool),
    ) catch {
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
  pool : Database,
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
fn claim_next_email(
  pool : Database,
  worker_id : String,
) -> EmailOutboxMessage? raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let picked = tx.query_opt(
        (
          #|SELECT id, to_email, subject, body
          #|FROM email_outbox
          #|WHERE status = 'pending'
          #|  AND next_attempt_at <= datetime('now')
          #|ORDER BY next_attempt_at, id
          #|LIMIT 1
        ),
      )
      match picked {
        None => None
        Some(row) => {
          let id : Int64 = row.get_name("id")
          let changed = tx.execute(
            (
              #|UPDATE email_outbox
              #|SET locked_at = datetime('now'),
              #|    locked_by = ?,
              #|    attempt_count = attempt_count + 1
              #|WHERE id = ? AND status = 'pending'
            ),
            params=[worker_id, id],
          )
          if changed == 1 {
            Some({
              id,
              to_email: row.get_name("to_email"),
              subject: row.get_name("subject"),
              body: row.get_name("body"),
            })
          } else {
            None
          }
        }
      }
    })
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
  let sender = mailbox_or_raise("SMTP From address", from)
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
fn mark_email_delivered(
  pool : Database,
  message_id : Int64,
  provider_message_id : String,
) -> Unit raise {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|UPDATE email_outbox
        #|SET status = 'sent',
        #|    sent_at = datetime('now'),
        #|    provider_message_id = ?,
        #|    locked_at = NULL,
        #|    locked_by = NULL,
        #|    last_error = NULL
        #|WHERE id = ?
      ),
      params=[provider_message_id, message_id],
    )
  })
}

///|
fn mark_email_failed(
  pool : Database,
  message_id : Int64,
  message : String,
) -> Unit raise {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|UPDATE email_outbox
        #|SET status = CASE
        #|      WHEN attempt_count >= 10 THEN 'failed'
        #|      ELSE 'pending'
        #|    END,
        #|    next_attempt_at = datetime('now', '+' || MIN(attempt_count, 10) || ' minutes'),
        #|    locked_at = NULL,
        #|    locked_by = NULL,
        #|    last_error = ?
        #|WHERE id = ?
      ),
      params=[message, message_id],
    )
  })
}

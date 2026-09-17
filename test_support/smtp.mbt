///|
pub(all) struct TestSmtpTranscript {
  lines : Array[String]
  mut data : String
}

///|
pub async fn run_one_message_smtp_server(
  server : @socket.TcpServer,
  transcript : TestSmtpTranscript,
) -> Unit {
  defer server.close()
  match @async.with_timeout_opt(5000, () => server.accept()) {
    Some((conn, _)) => {
      defer conn.close()
      conn.write("220 moonhub test smtp\r\n")
      let mut in_data = false
      for ;; {
        match conn.read_until("\r\n") {
          None => return
          Some(line) =>
            if in_data {
              if line == "." {
                in_data = false
                conn.write("250 queued test-message\r\n")
              } else {
                transcript.data = transcript.data + line + "\n"
              }
            } else {
              transcript.lines.push(line)
              if line.has_prefix("EHLO ") {
                conn.write("250-localhost\r\n250 AUTH PLAIN\r\n")
              } else if line.has_prefix("AUTH PLAIN ") {
                conn.write("235 authenticated\r\n")
              } else if line.has_prefix("MAIL FROM:") {
                conn.write("250 sender ok\r\n")
              } else if line.has_prefix("RCPT TO:") {
                conn.write("250 recipient ok\r\n")
              } else if line == "DATA" {
                conn.write("354 end with <CRLF>.<CRLF>\r\n")
                in_data = true
              } else if line == "QUIT" {
                conn.write("221 bye\r\n")
                return
              } else {
                conn.write("500 unsupported\r\n")
              }
            }
        }
      }
    }
    None => abort("smtp test server did not receive a connection")
  }
}

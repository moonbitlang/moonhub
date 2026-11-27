///|
async fn run_ssh_key(
  action : String,
  matches : @argparse.Matches,
  options : @argparse.Matches,
  server : String,
  token : String,
  allow_http~ : Bool,
) -> Int32 {
  let base = "/user/ssh-keys"
  let (path, body) : (String, Json?) = match action {
    "add" => {
      let title = required(matches, "title")
      let key = read_text_input(
          required(matches, "key-file"),
          16384L,
          "--key-file",
        )
        .trim()
        .to_owned()
      let fields = key
        .replace(old="\t", new=" ")
        .split(" ")
        .filter(field => !field.is_empty())
      guard !key.contains("\n") &&
        !key.contains("\r") &&
        fields.next() is Some("ssh-ed25519") &&
        fields.next() is Some(payload) else {
        raise Invalid("--key-file must contain one OpenSSH Ed25519 public key")
      }
      // Submit the key fields only, without the local comment.
      (
        base,
        Some({
          "title": title,
          "public_key": "ssh-ed25519 " + payload.to_owned(),
        }),
      )
    }
    "list" => (base, None)
    "delete" => {
      let id = decimal(required(options, "key-id"))
      ("\{base}/\{id}/revoke", Some(Json::empty_object()))
    }
    _ => raise Invalid("unknown ssh-key command")
  }
  let result = request(server, token, path, body, allow_http~)
  if matches.flags.get("json").unwrap_or(false) {
    println(result.stringify())
  } else {
    match (action, result) {
      ("add", { "id": String(id), "fingerprint": String(fingerprint), .. }) =>
        println(
          "Added SSH key \{terminal_text(id)} (\{terminal_text(fingerprint)}).",
        )
      ("delete", { "id": String(id), "revoked": True, .. }) =>
        println("Revoked SSH key \{terminal_text(id)}.")
      ("list", { "items": Array(keys), .. }) => {
        if keys.is_empty() {
          println("No SSH keys.")
        }
        for key in keys {
          guard key
            is {
              "id": String(id),
              "title": String(title),
              "fingerprint": String(fingerprint),
              "revoked_at": revoked,
              ..
            } else {
            raise InvalidResponse
          }
          let state = if revoked is Null { "active" } else { "revoked" }
          println(
            "\{terminal_text(id)}\t\{terminal_text(title)}\t\{terminal_text(fingerprint)}\t\{state}",
          )
        }
      }
      _ => raise InvalidResponse
    }
  }
  0
}

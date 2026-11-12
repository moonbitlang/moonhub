///|
pub suberror StorageError {
  InvalidConfiguration
  InvalidKey
  Unavailable
  IntegrityFailure
}

///|
pub(all) struct ObjectInfo {
  size : Int64
  digest : String
}

///|
pub(all) struct Part {
  key : String
  size : Int64
  digest : String
}

///|
pub struct Reader {
  priv next : async () -> Bytes?
}

///|
pub async fn Reader::read(self : Reader) -> Bytes? {
  (self.next)()
}

///|
// Descriptors contain destinations, never credentials. Persist them with each
// object so changing the default backend does not move or hide existing data.
enum Backend {
  Filesystem(String)
  S3
}

///|
pub struct Store {
  priv backend : Backend
  priv descriptor : Json
  priv node : String
  priv helper : String
}

///|
pub fn Store::location(self : Store) -> String {
  self.descriptor.stringify()
}

///|
pub fn filesystem(root : String) -> Store raise {
  guard !root.is_empty() && !root.contains("\u0000") else {
    raise InvalidConfiguration
  }
  {
    backend: Filesystem(root),
    descriptor: { "type": "fs", "root": root },
    node: "node",
    helper: "",
  }
}

///|
fn valid_key(key : String) -> Bool {
  !key.is_empty() &&
  key.length() <= 256 &&
  key
  .split("/")
  .all(part => {
    !part.is_empty() &&
    part != "." &&
    part != ".." &&
    part
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '-' || c == '_'
    })
  })
}

///|
fn object_key(key : String) -> Unit raise {
  guard valid_key(key) && key.split("/").count() == 2 else { raise InvalidKey }
}

///|
fn namespace_key(key : String) -> Unit raise {
  guard valid_key(key) && !key.contains("/") else { raise InvalidKey }
}

///|
pub struct Config {
  artifacts : String
  caches : String
  releases : String
  priv node : String
  priv helper : String
}

///|
pub fn Config::parse(
  value : Json,
  node~ : String = "node",
  helper~ : String = "storage/s3/bridge.mjs",
) -> Config raise {
  guard value is Object(fields) &&
    fields
    .keys()
    .all(k => ["artifacts", "caches", "releases", "backends"].contains(k)) &&
    fields.get("backends") is Some(Object(backends)) &&
    !backends.is_empty() &&
    backends.length() <= 16 &&
    fields.get("artifacts") is Some(String(artifacts)) &&
    fields.get("caches") is Some(String(caches)) &&
    !node.is_empty() &&
    !helper.is_empty() else {
    raise InvalidConfiguration
  }
  let locations : Map[String, String] = Map([])
  for name, descriptor in backends {
    guard valid_key(name) && !name.contains("/") else {
      raise InvalidConfiguration
    }
    locations[name] = parse_store(descriptor, node, helper).location()
  }
  guard locations.get(artifacts) is Some(artifacts) &&
    locations.get(caches) is Some(caches) else {
    raise InvalidConfiguration
  }
  let releases = match fields.get("releases") {
    None => artifacts
    Some(String(name)) =>
      locations.get(name).unwrap_or_else(() => raise InvalidConfiguration)
    _ => raise InvalidConfiguration
  }
  { artifacts, caches, releases, node, helper, }
}

///|
pub async fn Config::load(
  path : String,
  node~ : String = "node",
  helper~ : String = "storage/s3/bridge.mjs",
) -> Config {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.size() <= 65536L else { raise InvalidConfiguration }
  let config = Config::parse(
    @json.parse(file.read_all().text()),
    node~,
    helper~,
  )
  // Fail at startup for a missing/incompatible SDK bridge, not on the first job.
  for location in [config.artifacts, config.caches, config.releases] {
    let store = config.resolve(location, legacy_root="")
    if store.backend is S3 {
      ignore(store.s3_command("verify", {}, b""))
    }
  }
  config
}

///|
pub fn Config::resolve(
  self : Config,
  location : String,
  legacy_root~ : String,
) -> Store raise {
  if location == "legacy-fs" {
    filesystem(legacy_root)
  } else {
    parse_store(@json.parse(location), self.node, self.helper)
  }
}

///|
// This resolver also reads historical S3 locations after switching the defaults
// back to fs. Credentials always come from the deployment's SDK provider chain.
pub fn resolve(location : String, legacy_root~ : String) -> Store raise {
  if location == "legacy-fs" {
    filesystem(legacy_root)
  } else {
    parse_store(@json.parse(location), "node", "storage/s3/bridge.mjs")
  }
}

///|
fn parse_store(value : Json, node : String, helper : String) -> Store raise {
  guard value is Object(fields) else { raise InvalidConfiguration }
  match fields.get("type") {
    Some(String("fs")) => {
      guard fields.length() == 2 &&
        fields.get("root") is Some(String(root)) &&
        root.has_prefix("/") else {
        raise InvalidConfiguration
      }
      filesystem(root)
    }
    Some(String("s3")) => {
      guard fields
        .keys()
        .all(k => {
          ["type", "bucket", "region", "prefix", "endpoint", "force_path_style"].contains(
            k,
          )
        }) &&
        fields.get("bucket") is Some(String(bucket)) &&
        bucket.length() >= 3 &&
        bucket.length() <= 63 &&
        bucket
        .iter()
        .all(c => {
          c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-'
        }) &&
        fields.get("region") is Some(String(region)) &&
        !region.is_empty() &&
        region.length() <= 64 &&
        region
        .iter()
        .all(c => c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '-') &&
        fields.get("prefix") is Some(String(prefix)) &&
        valid_key(prefix) else {
        raise InvalidConfiguration
      }
      if fields.get("endpoint") is Some(endpoint) {
        guard endpoint is String(endpoint) &&
          endpoint.length() <= 512 &&
          (
            endpoint.has_prefix("https://") ||
            endpoint.has_prefix("http://127.0.0.1:")
          ) &&
          !endpoint.contains("@") &&
          !endpoint.contains("?") &&
          !endpoint.contains("#") else {
          raise InvalidConfiguration
        }
      }
      if fields.get("force_path_style") is Some(style) {
        guard style is True || style is False else {
          raise InvalidConfiguration
        }
      }
      { backend: S3, descriptor: value, node, helper, }
    }
    _ => raise InvalidConfiguration
  }
}

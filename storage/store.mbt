///|
pub async fn Store::put(self : Store, key : String, bytes : Bytes) -> Unit {
  object_key(key)
  guard !bytes.is_empty() && bytes.length() <= 134217728 else {
    raise IntegrityFailure
  }
  match self.backend {
    Filesystem(root) => {
      let path = fs_path(root, key, true)
      @fs.write_file(
        path,
        bytes,
        create_mode=CreateNew,
        permission=0o600,
        sync=Full,
      )
    }
    S3 =>
      ignore(
        self.s3_command("put", { "key": key, "size": bytes.length() }, bytes),
      )
  }
}

///|
pub async fn Store::compose(
  self : Store,
  key : String,
  parts : Array[Part],
) -> ObjectInfo {
  object_key(key)
  guard !parts.is_empty() && parts.length() <= 256 else { raise InvalidKey }
  let scope_key = key.split_once("/").unwrap().0
  for part in parts {
    object_key(part.key)
    guard part.key.split_once("/").unwrap().0 == scope_key &&
      part.size > 0L &&
      part.size <= 134217728L &&
      part.digest.length() == 64 else {
      raise IntegrityFailure
    }
  }
  match self.backend {
    Filesystem(root) => {
      let path = fs_path(root, key, false)
      let output = @fs.open(
        path,
        mode=ReadWrite,
        create_mode=CreateNew,
        permission=0o600,
      )
      defer output.close()
      let mut success = false
      defer (if !success { @fs.remove(path) catch { _ => () } })
      let hasher = @crypto.SHA256::new()
      let mut total = 0L
      for part in parts {
        let input_path = fs_path(root, part.key, false)
        guard @fs.kind(input_path, follow_symlink=false) is Regular else {
          raise IntegrityFailure
        }
        let input = @fs.open(input_path, mode=ReadOnly)
        defer input.close()
        guard input.size() == part.size else { raise IntegrityFailure }
        let part_hash = @crypto.SHA256::new()
        let mut size = 0L
        while input.read_some(max_len=65536) is Some(chunk) {
          size += chunk.length().to_int64()
          guard size <= part.size else { raise IntegrityFailure }
          part_hash.update(chunk)
          hasher.update(chunk)
          output.write(chunk)
        }
        guard size == part.size &&
          @crypto.bytes_to_hex_string(part_hash.finalize()) == part.digest else {
          raise IntegrityFailure
        }
        total += size
      }
      output.sync()
      success = true
      {
        size: total,
        digest: "sha256:" + @crypto.bytes_to_hex_string(hasher.finalize()),
      }
    }
    S3 => {
      let result = self.s3_command(
        "compose",
        {
          "key": key,
          "parts": ToJson::to_json(
            parts.map(part => {
              (
                {
                  "key": part.key,
                  "size": part.size.to_string(),
                  "digest": part.digest,
                } : Json)
            }),
          ),
        },
        b"",
      )
      guard result is { "size": String(size), "digest": String(digest), .. } else {
        raise Unavailable
      }
      { size: @json.from_json(Json::string(size)), digest, }
    }
  }
}

///|
// The callback owns a bounded stream only for this scope. Backends validate the
// object size before the callback can send HTTP response headers.
pub async fn Store::with_reader(
  self : Store,
  key : String,
  size : Int64,
  consume : async (Reader) -> Unit,
) -> Unit {
  object_key(key)
  match self.backend {
    Filesystem(root) => {
      let path = fs_path(root, key, false)
      guard @fs.kind(path, follow_symlink=false) is Regular else {
        raise IntegrityFailure
      }
      let file = @fs.open(path, mode=ReadOnly)
      defer file.close()
      guard file.size() == size else { raise IntegrityFailure }
      let mut remaining = size
      consume({
        next: () => {
          let chunk = file.read_some(max_len=65536)
          if chunk is Some(bytes) {
            remaining -= bytes.length().to_int64()
          }
          guard remaining >= 0L && (chunk is Some(_) || remaining == 0L) else {
            raise IntegrityFailure
          }
          chunk
        },
      })
    }
    S3 => self.s3_stream(key, size, consume)
  }
}

///|
pub async fn Store::remove(self : Store, key : String) -> Unit {
  object_key(key)
  match self.backend {
    Filesystem(root) => {
      if !@fs.exists(root) {
        return
      }
      let (scope_key, _) = key.split_once("/").unwrap()
      if !@fs.exists(root + "/" + scope_key.to_owned()) {
        return
      }
      let path = fs_path(root, key, false)
      if @fs.exists(path) {
        @fs.remove(path)
      }
    }
    S3 => ignore(self.s3_command("remove", { "key": key }, b""))
  }
}

///|
pub async fn Store::remove_namespace(self : Store, scope_key : String) -> Unit {
  namespace_key(scope_key)
  match self.backend {
    Filesystem(root) => {
      if !@fs.exists(root) || !@fs.exists(root + "/" + scope_key) {
        return
      }
      @fs.rmdir(fs_directory(root, scope_key, false), recursive=true)
    }
    S3 => ignore(self.s3_command("remove_namespace", { "key": scope_key }, b""))
  }
}

///|
// Only needed to recover legacy filesystem orphans which predate the deletion
// journal. New S3 namespaces always have a durable reservation or deletion intent.
pub async fn Store::visit_filesystem_namespaces(
  self : Store,
  visit : async (String) -> Bool,
) -> Unit {
  match self.backend {
    Filesystem(root) => {
      if !@fs.exists(root) {
        return
      }
      guard @fs.kind(root, follow_symlink=false) is Directory else {
        raise IntegrityFailure
      }
      let directory = @fs.opendir(root)
      defer directory.close()
      while directory.next() is Some(entry) {
        let key = entry.name
        if key.length() == 64 &&
          key.iter().all(c => c.is_ascii_digit() || ('a' <= c && c <= 'f')) &&
          !visit(key) {
          break
        }
      }
    }
    S3 => ()
  }
}

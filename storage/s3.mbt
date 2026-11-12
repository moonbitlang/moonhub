///|
async fn Store::s3_exchange(
  self : Store,
  operation : String,
  request : Json,
  bytes : Bytes,
  consume : async (@process.ReadFromProcess) -> Json,
) -> Json {
  @async.with_timeout(600000, () => {
    let (stdin, writer) = @process.write_to_process()
    defer writer.close()
    let (reader, stdout) = @process.read_from_process()
    defer reader.close()
    let (errors, stderr) = @process.read_from_process()
    defer errors.close()
    @async.with_task_group(group => {
      let child = @process.spawn(
        group,
        self.node,
        [self.helper],
        stdin~,
        stdout~,
        stderr~,
        cancel_handler=@process.graceful_cancel(timeout=5000),
      )
      group.spawn_bg(() => {
        defer writer.close()
        let header : Json = {
          "version": 1,
          "operation": operation,
          "location": self.descriptor,
          "request": request,
        }
        writer.write(header.stringify() + "\n")
        writer.write(bytes)
      })
      // SDK diagnostics can contain endpoints/credentials. Never reflect them in
      // HTTP errors or retain unbounded subprocess output.
      group.spawn_bg(() => {
        while errors.read_some(max_len=4096) is Some(_) {

        }
      })
      let result = consume(reader)
      guard child.wait() == 0 else { raise Unavailable }
      result
    })
  })
}

///|
async fn Store::s3_command(
  self : Store,
  operation : String,
  request : Json,
  bytes : Bytes,
) -> Json {
  self.s3_exchange(operation, request, bytes, reader => {
    let output : Array[Byte] = []
    while reader.read_some(max_len=4096) is Some(chunk) {
      guard output.length() + chunk.length() <= 65536 else { raise Unavailable }
      output.append(chunk.to_array())
    }
    guard !output.is_empty() else { raise Unavailable }
    @json.parse(@utf8.decode(Bytes::from_array(output)))
  })
}

///|
async fn Store::s3_stream(
  self : Store,
  key : String,
  size : Int64,
  consume : async (Reader) -> Unit,
) -> Unit {
  ignore(
    self.s3_exchange("read", { "key": key, "size": size.to_string() }, b"", reader => {
      let header = reader.read_until("\n").unwrap_or("")
      guard !header.is_empty() &&
        header.length() <= 4096 &&
        @json.parse(header) is { "ok": True, .. } else {
        raise Unavailable
      }
      let mut remaining = size
      consume({
        next: () => {
          let chunk = @async.with_timeout(30000, () => {
            reader.read_some(max_len=65536)
          })
          if chunk is Some(bytes) {
            remaining -= bytes.length().to_int64()
          }
          guard remaining >= 0L && (chunk is Some(_) || remaining == 0L) else {
            raise IntegrityFailure
          }
          chunk
        },
      })
      guard remaining == 0L else { raise IntegrityFailure }
      Json::null()
    }),
  )
}

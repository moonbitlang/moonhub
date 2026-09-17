///|
fn decode_chunk(bytes : Bytes) -> (String, Bytes) {
  let end = bytes.length()
  if end == 0 {
    return ("", b"")
  }
  let mut start = end - 1
  while start > 0 &&
        bytes[start].to_int() >= 0x80 &&
        bytes[start].to_int() <= 0xbf {
    start -= 1
  }
  let lead = bytes[start].to_int()
  let width = if lead >= 0xc2 && lead <= 0xdf {
    2
  } else if lead >= 0xe0 && lead <= 0xef {
    3
  } else if lead >= 0xf0 && lead <= 0xf4 {
    4
  } else {
    1
  }
  let cut = if end - start < width { start } else { end }
  (@utf8.decode_lossy(bytes[:cut]), bytes[cut:].to_owned())
}

///|
async fn Runtime::upload(
  self : Runtime,
  step_id : String,
  stream : String,
  text : String,
) -> Unit {
  if text.is_empty() {
    return
  }
  self.lock.acquire()
  defer self.lock.release()
  self.check_live()
  let size = @utf8.encode(text).length().to_int64()
  guard self.sequence < @protocol.max_log_chunks &&
    self.bytes + size <= @protocol.max_log_bytes else {
    raise Stopped("failure")
  }
  let sequence = self.sequence + 1L
  let request : @protocol.LogRequest = {
    version: @protocol.version,
    sequence,
    step_id,
    stream,
    text,
  }
  let state = self.request("logs", ToJson::to_json(request))
  guard state.log_sequence == sequence else { raise InvalidResponse }
  self.sequence = sequence
  self.bytes += size
  self.check_live()
}

///|
async fn Runtime::stream_log(
  self : Runtime,
  reader : @process.ReadFromProcess,
  step_id : String,
  stream : String,
  drain_until : Ref[Int64],
) -> Unit {
  let mut tail = b""
  for ;; {
    if drain_until.val > 0L && monotonic_ms() >= drain_until.val {
      break
    }
    let chunk = @async.with_timeout_opt(100, () => {
      reader.read_some(max_len=1024)
    })
    let chunk = match chunk {
      None => continue
      Some(None) => break
      Some(Some(chunk)) => chunk
    }
    let bytes = Bytes::from_array([..tail.to_array(), ..chunk.to_array()])
    let (text, rest) = decode_chunk(bytes)
    tail = rest
    self.upload(step_id, stream, text)
  }
  self.upload(step_id, stream, @utf8.decode_lossy(tail))
}

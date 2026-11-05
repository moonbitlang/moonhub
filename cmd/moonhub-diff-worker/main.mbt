///|
async fn main {
  let response = try {
    let bytes : Array[Byte] = []
    while @stdio.stdin.read_some(max_len=8192) is Some(chunk) {
      guard bytes.length() + chunk.length() <= @protocol.request_limit else {
        fail("input limit exceeded")
      }
      bytes.append(chunk.to_array())
    }
    let request : @protocol.Request = @json.from_json(
      @json.parse(@utf8.decode(Bytes::from_array(bytes))),
    )
    @compute.compute(request)
  } catch {
    _ =>
      @protocol.Response::{
        protocol: @protocol.protocol_version,
        document: None,
        error: Some("invalid worker request"),
      }
  }
  let output = @utf8.encode(Json(response).stringify())
  if output.length() <= @protocol.result_limit {
    @stdio.stdout.write(output)
  } else {
    @stdio.stdout.write(
      Json(@protocol.Response::{
        protocol: @protocol.protocol_version,
        document: None,
        error: Some("result limit exceeded"),
      }).stringify(),
    )
  }
}

///|
pub async fn stream_artifact(
  read : async () -> Bytes?,
  writer : &@io.Writer,
  authorize : () -> Unit raise,
  timeout_ms~ : Int32 = 30000,
) -> Unit {
  while read() is Some(chunk) {
    authorize()
    @async.with_timeout(timeout_ms, () => writer.write(chunk))
  }
}

///|
pub struct Service {
  priv pool : @database.Database
  priv storage : @storage.Config?
  priv downloads : @async.Semaphore
  priv clock : () -> Int64
}

///|
pub fn Service::new(
  pool : @database.Database,
  storage? : @storage.Config,
  clock~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> Service {
  { pool, clock, storage, downloads: @async.Semaphore(4), }
}

///|
pub struct Service {
  priv pool : @database.Database
  priv oidc : OidcIssuer?
  priv clock : () -> Int64
}

///|
pub fn Service::new(
  pool : @database.Database,
  oidc? : OidcIssuer,
  clock~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> Service {
  { pool, clock, oidc, }
}

///|
struct PipelineFixture {
  runtime : @runtime.Coordinator
  results : @results.Service
  oidc : @oidc.Service
  issuer : @oidc.OidcIssuer?
  clock : () -> Int64
}

///|
fn test_services(
  pool : @database.Database,
  oidc? : @oidc.OidcIssuer,
  storage? : @storage.Config,
  clock~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> PipelineFixture {
  {
    runtime: @runtime.Coordinator::new(pool, clock~),
    results: @results.Service::new(pool, storage?, clock~),
    oidc: @oidc.Service::new(pool, oidc?, clock~),
    issuer: oidc,
    clock,
  }
}

///|
// Public discovery and keys share the configured issuer, never a request Host
// header. The token endpoint accepts only a live execution's scoped credential.
pub let oidc_module : @moonback.Module = Module(ctx => {
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.get(
    "/.well-known/openid-configuration",
    json_handler(_ => coordinator.oidc_discovery()),
  )
  ctx.get("/-/oidc/jwks", json_handler(_ => coordinator.oidc_jwks()))
  ctx.get(
    "/-/oidc/token",
    json_handler(req => {
      let token = bearer_token(req)
      let query = req.query()
      guard query.iter().count() <= 2 &&
        query.iter().all(pair => ["attempt_id", "audience"].contains(pair.0)) &&
        query.get_all("attempt_id").length() == 1 &&
        query.get_all("audience").length() <= 1 else {
        raise @domain.BadRequest(message="invalid OIDC query")
      }
      let id = @web_context.positive_resource_number(
        query.get("attempt_id").unwrap_or(""),
      )
      coordinator.oidc_token(id, token, query.get("audience").unwrap_or(""))
    }),
  )
})

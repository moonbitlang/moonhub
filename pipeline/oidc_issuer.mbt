///|
// Private material stays in the coordinator process. Node's standard crypto
// implementation receives it through stdin, never argv, env, logs or a job plan.
pub struct OidcIssuer {
  priv config : String
  priv node : String
  priv kid : String
  priv issuer : String
  priv audiences : Array[String]
  priv keys : Json
  priv signing : @async.Semaphore
}

///|
let oidc_crypto_program : String =
  #|const fs = require('node:fs');
  #|const crypto = require('node:crypto');
  #|try {
  #|  const x = JSON.parse(fs.readFileSync(0, 'utf8'));
  #|  const key = crypto.createPrivateKey(x.private_key);
  #|  if (key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 2048 || key.asymmetricKeyDetails.modulusLength > 4096) throw Error();
  #|  const pub = crypto.createPublicKey(key);
  #|  const active = pub.export({format:'jwk'});
  #|  active.kid = crypto.createHash('sha256').update(pub.export({format:'der',type:'spki'})).digest('base64url');
  #|  active.alg = 'RS256'; active.use = 'sig';
  #|  const previous = x.previous_keys || [];
  #|  if (!Array.isArray(previous) || previous.length > 7) throw Error();
  #|  const keys = [active];
  #|  for (const jwk of previous) {
  #|    if (Object.keys(jwk).some(k => !['kty','n','e','kid','alg','use'].includes(k)) || jwk.kty !== 'RSA') throw Error();
  #|    const p = crypto.createPublicKey({key:jwk,format:'jwk'});
  #|    if (p.asymmetricKeyDetails.modulusLength < 2048 || p.asymmetricKeyDetails.modulusLength > 4096) throw Error();
  #|    const k = p.export({format:'jwk'});
  #|    k.kid = crypto.createHash('sha256').update(p.export({format:'der',type:'spki'})).digest('base64url');
  #|    k.alg = 'RS256'; k.use = 'sig';
  #|    if (keys.some(v => v.kid === k.kid)) throw Error();
  #|    keys.push(k);
  #|  }
  #|  const u = new URL(x.issuer);
  #|  if (u.origin !== x.issuer || u.username || u.password || (!x.allow_http && (u.protocol !== 'https:' || u.port)) || (x.allow_http && !['http:','https:'].includes(u.protocol))) throw Error();
  #|  if (x.input !== undefined) {
  #|    if (typeof x.input !== 'string' || x.input.length > 32768) throw Error();
  #|    process.stdout.write(JSON.stringify({signature:crypto.sign('RSA-SHA256',Buffer.from(x.input),{key,padding:crypto.constants.RSA_PKCS1_PADDING}).toString('base64url')}));
  #|  } else process.stdout.write(JSON.stringify({kid:active.kid,keys}));
  #|} catch { process.stderr.write('Invalid OIDC signing configuration'); process.exitCode = 1; }

///|
async fn oidc_crypto(node : String, config : Json) -> Json {
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      group.spawn_bg(() => {
        writer.write(config.stringify())
        writer.close()
      })
      let (code, output, _) = @process.collect_output(
        node,
        ["-e", oidc_crypto_program],
        stdin=input,
        inherit_env=false,
      )
      guard code == 0 && output.binary().length() <= 16384 else {
        raise @domain.BadRequest(message="invalid OIDC signing configuration")
      }
      @json.parse(output.text())
    })
  })
}

///|
pub async fn OidcIssuer::load(
  path : String,
  node~ : String = "node",
  allow_http~ : Bool = false,
) -> OidcIssuer {
  let bytes = @fs.read_file(path)
  guard bytes.binary().length() <= 65536 else {
    raise @domain.BadRequest(message="OIDC configuration exceeds 64 KiB")
  }
  let config = @json.parse(bytes.text())
  guard config is Object(fields) &&
    fields.get("issuer") is Some(String(issuer)) &&
    fields.get("private_key") is Some(String(_)) &&
    fields
    .keys()
    .all(key => {
      ["issuer", "private_key", "previous_keys", "audiences"].contains(key)
    }) &&
    issuer.length() <= 320 else {
    raise @domain.BadRequest(message="invalid OIDC signing configuration")
  }
  let audiences : Array[String] = @json.from_json(
    fields.get("audiences").unwrap_or(["sts.amazonaws.com"]),
  )
  guard !audiences.is_empty() &&
    audiences.length() <= 16 &&
    audiences.all(aud => {
      !aud.is_empty() &&
      @utf8.encode(aud).length() <= 256 &&
      aud.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127)
    }) else {
    raise @domain.BadRequest(message="invalid OIDC audiences")
  }
  fields["allow_http"] = Json::boolean(allow_http)
  let public = oidc_crypto(node, config)
  guard public is { "kid": String(kid), "keys": keys, .. } else {
    raise @domain.BadRequest(message="invalid OIDC signing configuration")
  }
  {
    config: config.stringify(),
    node,
    kid,
    issuer,
    audiences,
    keys,
    signing: @async.Semaphore(4),
  }
}

///|
pub fn OidcIssuer::discovery(self : OidcIssuer) -> Json {
  {
    "issuer": self.issuer,
    "jwks_uri": self.issuer + "/-/oidc/jwks",
    "response_types_supported": ["id_token"],
    "subject_types_supported": ["public"],
    "id_token_signing_alg_values_supported": ["RS256"],
    "claims_supported": [
      "iss", "sub", "aud", "iat", "nbf", "exp", "jti", "repository", "repository_id",
      "ref", "sha", "run_id", "job_id", "event_name", "workflow_ref",
    ],
  }
}

///|
pub fn OidcIssuer::jwks(self : OidcIssuer) -> Json {
  { "keys": self.keys }
}

///|
async fn OidcIssuer::sign(self : OidcIssuer, claims : Json) -> String {
  let header : Json = { "alg": "RS256", "typ": "JWT", "kid": self.kid }
  let input = base64url(@utf8.encode(header.stringify())) +
    "." +
    base64url(@utf8.encode(claims.stringify()))
  let config = @json.parse(self.config)
  guard config is Object(fields) else { abort("invalid saved OIDC config") }
  fields["input"] = Json::string(input)
  let result = oidc_crypto(self.node, config)
  guard result is { "signature": String(signature), .. } else {
    raise @domain.BadRequest(message="OIDC signing failed")
  }
  input + "." + signature
}

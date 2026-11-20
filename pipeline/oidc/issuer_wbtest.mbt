///|
async test "OIDC configuration rejects non-RSA weak keys insecure issuers and private previous keys" {
  @test_support.with_repository_test_data((_, root) => {
    let path = root + "/oidc.json"
    @test_support.create_oidc_config(path, "http://issuer.example")
    try ignore(OidcIssuer::load(path)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted HTTP issuer")
    }
    @test_support.create_oidc_config(path, "https://issuer.example")
    let issuer = OidcIssuer::load(path)
    assert_true(
      issuer.discovery()
      is {
        "issuer": String("https://issuer.example"),
        "jwks_uri": String("https://issuer.example/-/oidc/jwks"),
        ..
      },
    )
    for kind in ["rsa", "ec"] {
      let code = @process.run(
        "node",
        [
          "-e", "const c=require('node:crypto'),fs=require('node:fs');const type=process.argv[2];const {privateKey}=c.generateKeyPairSync(type,type==='rsa'?{modulusLength:1024}:{namedCurve:'prime256v1'});fs.writeFileSync(process.argv[1],JSON.stringify({issuer:'https://issuer.example',private_key:privateKey.export({type:'pkcs8',format:'pem'})}),{mode:0o600});",
          path, kind,
        ],
        inherit_env=false,
      )
      assert_eq(code, 0)
      try ignore(OidcIssuer::load(path)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted weak or non-RSA key")
      }
    }
    @test_support.create_oidc_config(path, "https://issuer.example")
    let original = @fs.read_file(path).text()
    for field in ["issuer", "private_key", "audiences", "previous_keys"] {
      let json = @json.parse(original)
      guard json is Object(fields) else { fail("invalid config") }
      fields[field] = match field {
        "issuer" => "https://issuer.example/"
        "private_key" => "broken private key"
        "audiences" => ["", "sts.amazonaws.com"]
        _ => [{ "kty": "RSA", "n": "abc", "e": "AQAB", "d": "private" }]
      }
      @fs.write_file(path, json.stringify())
      try ignore(OidcIssuer::load(path)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid " + field)
      }
    }
  })
}

///|
async test "OIDC key rotation publishes old public keys while signing with the new key" {
  @test_support.with_repository_test_data((_, root) => {
    let old_path = root + "/old-key.json"
    let new_path = root + "/new-key.json"
    @test_support.create_oidc_config(old_path, "https://issuer.example")
    @test_support.create_oidc_config(new_path, "https://issuer.example")
    let old = OidcIssuer::load(old_path)
    let config = @json.parse(@fs.read_file(new_path).text())
    guard config is Object(fields) else { fail("invalid config") }
    fields["previous_keys"] = old.keys
    @fs.write_file(new_path, config.stringify())
    let current = OidcIssuer::load(new_path)
    assert_true(current.kid != old.kid)
    assert_true(
      current.keys is Array(keys) &&
      keys.length() == 2 &&
      keys.any(key => key is { "kid": String(kid), .. } && kid == old.kid),
    )
    let token = current.sign({ "test": true })
    let header = token.split(".").next().unwrap()
    assert_eq(
      header,
      base64url(
        @utf8.encode(
          ({ "alg": "RS256", "typ": "JWT", "kid": current.kid } : Json).stringify(),
        ),
      ),
    )
    assert_true(!current.jwks().stringify().contains("PRIVATE KEY"))
  })
}

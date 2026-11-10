///|
// Generates disposable signing material inside a private test directory. The
// private key never appears in command arguments or test output.
pub async fn create_oidc_config(path : String, issuer : String) -> Unit {
  let code = @process.run(
    "node",
    [
      "-e", "const {generateKeyPairSync}=require('node:crypto');const fs=require('node:fs');const {privateKey}=generateKeyPairSync('rsa',{modulusLength:2048});fs.writeFileSync(process.argv[1],JSON.stringify({issuer:process.argv[2],private_key:privateKey.export({type:'pkcs8',format:'pem'})}),{mode:0o600});",
      path, issuer,
    ],
    inherit_env=false,
  )
  guard code == 0 else { fail("could not create test OIDC key") }
}

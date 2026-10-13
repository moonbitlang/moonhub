///|
let password_cost : Int32 = 12

///|
pub fn hash_password(password : String) -> String {
  guard @env.rand(@bcrypt.salt_length) is Some(salt) else {
    abort("secure randomness is unavailable")
  }
  @bcrypt.hash(password=@utf8.encode(password), salt~, cost=password_cost) catch {
    _ => abort("failed to hash password")
  }
}

///|
fn verify_password(password : String, hash : String) -> Bool {
  @bcrypt.verify(password=@utf8.encode(password), hashed=hash) catch {
    _ => false
  }
}

///|
pub fn random_hex(byte_count : Int32) -> String {
  guard @env.rand(byte_count) is Some(bytes) else {
    abort("secure randomness is unavailable")
  }
  @crypto.bytes_to_hex_string(bytes)
}

///|
pub fn hash_token(token : String) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(token)))
}

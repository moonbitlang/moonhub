///|
pub async fn with_repository_test_data(
  f : async (@database.Database, String) -> Unit,
) -> Unit {
  with_ssh_test_db(pool => with_git_test_repo((root, _) => f(pool, root)))
}

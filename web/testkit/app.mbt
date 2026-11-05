///|
pub let test_repo_root : String = "testdata/repos"

///|
pub let test_assets_root : String = "assets"

///|
pub let test_auth_name_key : String = "moonhub_test_root"

///|
pub let test_auth_password : String = "initialPassword123"

///|
pub let browser_app_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  ctx.mount("/\{@domain.PUBLIC_ASSETS_OWNER}", App(@web.assets_module, config~))
  ctx.mount(
    "/",
    App(
      Module(ctx => {
        ctx.use_(@web.browser_resources_module)
        let asset_path_map = ctx.require(@web_context.asset_paths_key)
        let root = ctx.require(@web_context.config_root)
        ctx.provide(@web_context.diff_executor_key, @gitops.DiffExecutor::new())
        ctx.provide(@web_context.diff_enabled_key, false)
        ctx.provide(@web_context.browser_access_key, {
          repositories: _ => @gitops.list_repositories(root),
          personal_owner: _ => None,
          authorize: (_, _) => (),
          clone_url: _ => None,
          manager: (_, _) => false,
        })
        ctx.add_middleware(@web_context.app_error_middleware(asset_path_map))
        ctx.use_(@repository_views.index_module)
        ctx.use_(@repository_views.repo_browser_module)
      }),
      config~,
    ),
  )
})

///|
pub fn test_app_config(
  repo_root~ : String = test_repo_root,
  assets_root~ : String = test_assets_root,
) -> @moonback.Config {
  @moonback.Config(custom=[
    @moonback.Config::custom(@web_context.config_root, repo_root),
    @moonback.Config::custom(@web_context.config_assets_root, assets_root),
  ])
}

///|
pub async fn rendered_blob_page(port : Int32) -> String {
  let (response, body) = @http.get(
    "http://127.0.0.1:\{port}/alice/demo/blob/master/src/main.mbt",
  )
  assert_eq(response.code, 200)
  body.text()
}

///|
pub fn extract_attr(html : String, marker : String, attr : String) -> String {
  match html.find(marker) {
    Some(marker_start) => {
      let attr_start = marker_start + html[marker_start:].find(attr).unwrap()
      let value_start = attr_start + attr.length()
      let value_end = value_start + html[value_start:].find("\"").unwrap()
      html[value_start:value_end].to_owned()
    }
    None => abort("missing marker")
  }
}

///|
pub async fn rendered_commit_page(port : Int32) -> String {
  let commits = @gitops.list_commits(
    "\{test_repo_root}/alice/demo.git",
    "master",
  )
  let (response, body) = @http.get(
    "http://127.0.0.1:\{port}/alice/demo/commit/\{commits[0].hash}",
  )
  assert_eq(response.code, 200)
  body.text()
}

///|
pub async fn http_head(port : Int32, path : String) -> @http.Response {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  client..request(Head, path).end_request()
}

///|
pub async fn http_get_path(
  port : Int32,
  path : String,
) -> (@http.Response, String) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client..request(Get, path).end_request()
  (response, client.read_all().text())
}

///|
pub async fn http_get_path_with_cookie(
  port : Int32,
  path : String,
  cookie : @http.Cookie,
) -> (@http.Response, String) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.get(path, extra_headers={
    "Cookie": "\{cookie.name}=\{cookie.value}",
  })
  (response, client.read_all().text())
}

///|
pub async fn http_post_path_with_cookie(
  port : Int32,
  path : String,
  body : String,
  cookie : @http.Cookie,
) -> (@http.Response, String) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.post(path, body, extra_headers={
    "Content-Type": "application/x-www-form-urlencoded",
    "Cookie": "\{cookie.name}=\{cookie.value}",
  })
  (response, client.read_all().text())
}

///|
pub async fn login_test_user(
  port : Int32,
  name_key : String,
  password : String,
) -> @http.Cookie {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.post(
    "/-/login",
    "name_key=\{name_key}&password=\{password}",
    extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
  )
  client.skip_response_body()
  assert_eq(response.code, 303)
  match response.cookies.get(0) {
    Some(cookie) => cookie
    None => abort("missing session cookie")
  }
}

///|
fn reset_auth_test_data(pool : @database.Database) -> Unit raise {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|DELETE FROM team
        #|WHERE name_key IN ('moonhub_test_root', 'moonhub_test_team')
      ),
    )
    let _ = client.execute(
      (
        #|DELETE FROM "user"
        #|WHERE name_key IN ('moonhub_test_root', 'moonhub_invited_admin')
      ),
    )
    let _ = client.execute(
      (
        #|DELETE FROM invitation
        #|WHERE name_key IN ('moonhub_test_root', 'moonhub_invited_admin')
      ),
    )
    let _ = client.execute(
      (
        #|DELETE FROM email_outbox
        #|WHERE to_email IN ('invited-admin@example.com')
      ),
    )
  })
}

///|
pub async fn with_production_test_app(
  f : async (@moonback.App, Int32, @database.Database) -> Unit,
) -> Unit {
  @test_support.database_test_slot.acquire()
  defer @test_support.database_test_slot.release()
  @async.with_task_group(group => {
    let pool = @database.new_db_pool({ path: ":memory:", }, group) catch {
      err => abort("database open failed: \{(err : Error)}")
    }
    defer pool.close()
    @database.initialize_db(pool) catch {
      err => abort("database initialization failed: \{err}")
    }
    reset_auth_test_data(pool) catch {
      err => abort("reset auth test data failed: \{err}")
    }
    @identity.ensure_root_invitation(pool, {
      name_key: test_auth_name_key,
      initial_password: test_auth_password,
    }) catch {
      err => abort("ensure root invitation failed: \{err}")
    }
    let app = @moonback.App(
      @web.app_module,
      config=@moonback.Config(custom=[
        @moonback.Config::custom(@web_context.config_root, test_repo_root),
        @moonback.Config::custom(
          @web_context.config_assets_root, test_assets_root,
        ),
        @moonback.Config::custom(@web_context.config_db_pool, pool),
      ]),
    )
    defer app.close()
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    f(app, server.addr.port(), pool) catch {
      err => abort("production app test failed: \{err}")
    }
  })
}

///|
pub fn invited_admin_password_from_outbox(
  pool : @database.Database,
) -> String raise {
  let body : String = pool.with_client(client => {
    let row = client.query_one(
      (
        #|SELECT body
        #|FROM email_outbox
        #|WHERE to_email = 'invited-admin@example.com'
        #|ORDER BY id DESC
        #|LIMIT 1
      ),
    )
    row.get_name("body")
  })
  let marker = "One-time password: "
  let start = body.find(marker).unwrap() + marker.length()
  let end = match body[start:].find("\n") {
    Some(offset) => start + offset
    None => body.length()
  }
  body[start:end].to_owned()
}

///|
pub fn latest_invited_admin_outbox_id(pool : @database.Database) -> Int64 raise {
  pool.with_client(client => {
    let row = client.query_one(
      (
        #|SELECT id
        #|FROM email_outbox
        #|WHERE to_email = 'invited-admin@example.com'
        #|ORDER BY id DESC
        #|LIMIT 1
      ),
    )
    row.get_name("id")
  })
}

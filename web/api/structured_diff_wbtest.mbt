///|
async test "structured diff preserves patch compatibility permissions and validates document anchors" {
  @web_testkit.with_repository_test_app(
    (port, pool, root, cookie, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let token = @identity.create_access_token(
        pool, actor, "structured", "write", 1,
      )
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let scope = @repository.repository_scope(pool, actor, repo)
      let dir = repo.git_dir(root)
      let base = @gitops.branch_sha(dir, "master")
      let _ = @test_support.merge_test_commit(dir, "feature", base, "changed\n")
      let mr = @collaboration.create_merge_request(
        pool, scope, dir, actor, "Structured", "", "feature", "master", false,
      )
      let url = "/repos/alice/demo/mrs/1/diff?version=1"
      let (status, legacy) = api_test_request(
        port,
        url + "&mode=invalid",
        token,
        None,
      )
      assert_eq(status, 200)
      assert_true(legacy is { "patch": String(_), .. })
      let (status, manifest) = api_test_request(
        port,
        url + "&format=structured",
        token,
        None,
      )
      assert_eq(status, 200)
      guard manifest
        is {
          "protocol": String("moonhub-diff/1"),
          "version": String("1"),
          "files": Array(files),
          ..
        } else {
        fail("missing structured manifest")
      }
      let file = files
        .iter()
        .find_first(f => f is { "new_path": String("README.md"), .. })
        .unwrap()
      guard file is { "id": String(file_id), .. } else {
        fail("missing file ID")
      }
      let file_url = url + "&format=structured&file_id=" + file_id
      let (status, result) = api_test_request(port, file_url, token, None)
      assert_eq(status, 200)
      guard result
        is {
          "document_id": String(document_id),
          "options": { "mode": String("line"), .. },
          "document": {
            "sections": Array(
              [{ "hunks": Array([{ "id": String(hunk_id), .. }, ..]), .. }, ..]
            ),
            ..
          },
          ..
        } else {
        fail("missing file document")
      }
      let body : Map[String, Json] = {
        "version": Json("1"),
        "path": Json("README.md"),
        "side": Json("new"),
        "start_line": Json("1"),
        "end_line": Json("1"),
        "body": Json("Structured comment"),
        "document_id": Json(document_id),
        "file_id": Json(file_id),
        "hunk_id": Json(hunk_id),
        "mode": Json("line"),
        "ignore_comments": Json("false"),
        "ignore_tests": Json("false"),
      }
      let (status, created) = api_test_request(
        port,
        "/repos/alice/demo/mrs/1/inline-comment",
        token,
        Some(Json(body)),
      )
      assert_eq(status, 200)
      assert_true(
        created
        is {
          "discussion": { "anchor": { "context": String(context), .. }, .. },
          ..
        } &&
        context.contains("changed"),
      )
      body.set("document_id", Json("0".repeat(64)))
      let (status, _) = api_test_request(
        port,
        "/repos/alice/demo/mrs/1/inline-comment",
        token,
        Some(Json(body)),
      )
      assert_eq(status, 400)
      body.set("document_id", Json(document_id))
      body.set("end_line", Json("101"))
      let (status, _) = api_test_request(
        port,
        "/repos/alice/demo/mrs/1/inline-comment",
        token,
        Some(Json(body)),
      )
      assert_eq(status, 400)
      let (status, _) = api_test_request(
        port,
        url + "&format=structured&file_id=" + base,
        token,
        None,
      )
      assert_eq(status, 404)
      let (status, _) = api_test_request(
        port,
        url + "&format=structured&mode=invalid",
        token,
        None,
      )
      assert_eq(status, 400)
      let (page, html) = @web_testkit.http_get_path_with_cookie(
        port, "/alice/demo/merge-requests/1?tab=changes&version=1", cookie,
      )
      assert_eq(page.code, 200)
      assert_true(html.contains("<moonhub-structured-diff"))
      let (page, html) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo/merge-requests/1?tab=changes&version=1&file_id=" + file_id,
        cookie,
      )
      assert_eq(page.code, 200)
      assert_true(html.contains("new 1: changed"))
      let (page, response) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo/merge-requests/1/diff?version=1&file_id=" + file_id,
        cookie,
      )
      assert_eq(page.code, 200)
      assert_eq(page.headers.get("Cache-Control"), Some("no-store"))
      assert_true(response.contains(document_id))
      assert_eq(mr.version, 1L)
      // Cache results never bypass revocation of repository access.
      pool.with_client(client => {
        ignore(
          client.execute(
            "DELETE FROM team_member WHERE team_id = ? AND user_id = ?",
            params=[scope.team_id, actor.id],
          ),
        )
      })
      let (status, _) = api_test_request(port, file_url, token, None)
      assert_eq(status, 404)
    },
    moondiff=true,
  )
}

///|
async test "queued inline diff leaves ordinary HTTP requests and repository writes available" {
  let worker = "_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe"
  let executor = @gitops.DiffExecutor::new(worker~)
  @web_testkit.with_repository_test_app(
    (port, pool, root, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let token = @identity.create_access_token(
        pool, actor, "slow diff", "write", 1,
      )
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let scope = @repository.repository_scope(pool, actor, repo)
      let dir = repo.git_dir(root)
      let base = @gitops.branch_sha(dir, "master")
      let head = @test_support.merge_test_commit(
        dir, "feature", base, "changed\n",
      )
      let _ = @collaboration.create_merge_request(
        pool, scope, dir, actor, "Queued", "", "feature", "master", false,
      )
      let manifest = executor.manifest(dir, base, head)
      let file = manifest.files
        .iter()
        .find_first(f => f.new_path == "README.md")
        .unwrap()
      let reference = @gitops.DiffExecutor::new(worker~).file(
        dir,
        manifest,
        file.id,
        @gitops.diff_options(mode="line"),
      )
      let document = reference.document.unwrap()
      let body : Json = {
        "version": "1",
        "path": "README.md",
        "side": "new",
        "start_line": "1",
        "end_line": "1",
        "body": "Queued comment",
        "document_id": reference.document_id,
        "file_id": file.id,
        "hunk_id": document.sections[0].hunks[0].id,
        "mode": "line",
        "ignore_comments": "false",
        "ignore_tests": "false",
      }
      executor.slots.acquire()
      let mut held = true
      defer (if held { executor.slots.release() })
      @async.with_task_group(group => {
        let pending = group.spawn(() => {
          api_test_request(
            port,
            "/repos/alice/demo/mrs/1/inline-comment",
            token,
            Some(body),
          )
        })
        @async.sleep(50)
        assert_true(pending.try_wait() is None)
        let (status, _) = api_test_request(port, "/user", token, None)
        assert_eq(status, 200)
        @async.with_timeout(500, () => {
          @repository.with_repository_write(pool, root, actor, repo, (_, _) => {
            ()
          })
        })
        assert_true(pending.try_wait() is None)
        held = false
        executor.slots.release()
        let (status, _) = pending.wait()
        assert_eq(status, 200)
      })
    },
    diff_executor=executor,
  )
}

///|
async test "manifest admission failures return retryable HTTP responses and keep MR comments" {
  let executor = @gitops.DiffExecutor::new()
  @web_testkit.with_repository_test_app(
    (port, pool, root, cookie, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let token = @identity.create_access_token(
        pool, actor, "manifest busy", "write", 1,
      )
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let scope = @repository.repository_scope(pool, actor, repo)
      let dir = repo.git_dir(root)
      let head = @test_support.merge_test_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "master"),
        "changed\n",
      )
      let mr = @collaboration.create_merge_request(
        pool, scope, dir, actor, "Busy manifest", "", "feature", "master", false,
      )
      let prepared = @collaboration.prepare_anchored_merge_discussion(
        pool,
        scope,
        actor,
        mr,
        dir,
        1L,
        None,
        "README.md",
        "new",
        1L,
        1L,
        "Keep this discussion",
      )
      ignore(
        @collaboration.create_prepared_merge_discussion(
          pool, scope, actor, mr, prepared,
        ),
      )
      executor.slots.acquire()
      defer executor.slots.release()
      let (status, json) = api_test_request(
        port,
        "/repos/alice/demo/mrs/1/diff?format=structured",
        token,
        None,
      )
      assert_eq(status, 503)
      assert_true(
        json is { "error": { "code": String("diff_unavailable"), .. }, .. },
      )
      for
        path in [
          "/alice/demo/merge-requests/1/diff?version=1",
          "/alice/demo/commit/\{head}/diff",
        ] {
        let (response, _) = @web_testkit.http_get_path_with_cookie(
          port, path, cookie,
        )
        assert_eq(response.code, 503)
        assert_eq(response.headers.get("Retry-After"), Some("2"))
      }
      let (response, html) = @web_testkit.http_get_path_with_cookie(
        port, "/alice/demo/merge-requests/1?tab=changes", cookie,
      )
      assert_eq(response.code, 200)
      assert_true(html.contains("queue wait exceeded"))
      assert_true(html.contains("Keep this discussion"))
    },
    moondiff=true,
    diff_executor=executor,
  )
}

///|
async test "non UTF8 Git paths are isolated in API and server rendered file lists" {
  @web_testkit.with_repository_test_app(
    (port, pool, root, cookie, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let token = @identity.create_access_token(
        pool, actor, "byte paths", "write", 1,
      )
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let scope = @repository.repository_scope(pool, actor, repo)
      let dir = repo.git_dir(root)
      ignore(@test_support.structured_diff_fixture(dir))
      ignore(
        @collaboration.create_merge_request(
          pool, scope, dir, actor, "Byte paths", "", "paged-head", "paged-base",
          false,
        ),
      )
      let url = "/repos/alice/demo/mrs/1/diff?version=1&format=structured"
      let (status, manifest) = api_test_request(port, url, token, None)
      assert_eq(status, 200)
      guard manifest is { "files": Array(files), .. } else {
        fail("missing manifest")
      }
      let mut count = 0
      for file in files {
        if file is { "id": String(id), "path_error": String(_), .. } {
          count += 1
          let (status, result) = api_test_request(
            port,
            url + "&file_id=" + id,
            token,
            None,
          )
          assert_eq(status, 200)
          assert_true(result is { "error": String(_), "document": Null, .. })
        }
      }
      assert_eq(count, 3)
      let (response, html) = @web_testkit.http_get_path_with_cookie(
        port, "/alice/demo/merge-requests/1?tab=changes", cookie,
      )
      assert_eq(response.code, 200)
      assert_true(html.contains("non-UTF-8 path"))
      guard files
        .iter()
        .find_first(f => f is { "new_path": String("a-100.txt"), .. })
        is Some({ "id": String(id), .. }) else {
        fail("normal file missing")
      }
      let (status, result) = api_test_request(
        port,
        url + "&file_id=" + id,
        token,
        None,
      )
      assert_eq(status, 200)
      assert_true(result is { "document": Object(_), .. })
    },
    moondiff=true,
  )
}

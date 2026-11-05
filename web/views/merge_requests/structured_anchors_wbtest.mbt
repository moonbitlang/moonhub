///|
async test "old comment and source links locate later file pages for add delete rename and commit anchors" {
  let executor = @gitops.DiffExecutor::new(
    worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
  )
  @web_testkit.with_repository_test_app(
    (port, pool, root, cookie, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let scope = @repository.repository_scope(pool, actor, repo)
      let dir = repo.git_dir(root)
      let (base, head) = @test_support.structured_diff_fixture(dir)
      let mr = @collaboration.create_merge_request(
        pool, scope, dir, actor, "Paged comments", "", "paged-head", "paged-base",
        false,
      )
      let manifest = executor.manifest(dir, base, head, page=2)
      let cases = [
        ("z-add.txt", "new", None),
        ("z-delete.txt", "old", None),
        ("z-old.txt", "old", None),
        ("z-new.txt", "new", Some(head)),
      ]
      let targets = []
      for (path, side, commit) in cases {
        let file = manifest.files
          .iter()
          .find_first(f => {
            (if side == "old" { f.old_path } else { f.new_path }) == path
          })
          .unwrap()
        let result = executor.file(
          dir,
          manifest,
          file.id,
          @gitops.diff_options(mode="line"),
        )
        let hunk = result.document.unwrap().sections[0].hunks[0]
        let prepared = @collaboration.prepare_anchored_merge_discussion(
          pool,
          scope,
          actor,
          mr,
          dir,
          1L,
          commit,
          path,
          side,
          1L,
          1L,
          "Saved later-page comment",
          structured=(
            executor,
            {
              file_id: file.id,
              document_id: result.document_id,
              hunk_id: hunk.id,
              page: 2,
              options: result.options,
            },
          ),
        )
        let id = @collaboration.create_prepared_merge_discussion(
          pool, scope, actor, mr, prepared,
        )
        let reply = @collaboration.reply_merge_discussion(
          pool, scope, actor, mr, id, "Saved reply",
        )
        targets.push((id, reply, file.id, commit.unwrap_or("")))
      }
      // All subsequent links refer to a saved version after the branch advances.
      ignore(
        @test_support.merge_test_commit(
          dir,
          "paged-head",
          head,
          "new version\n",
          preserve_files=true,
        ),
      )
      let latest = @collaboration.refresh_merge_request(pool, scope, dir, mr)
      assert_eq(latest.version, 2L)
      for (id, reply, file_id, commit) in targets {
        for
          suffix in ["&comment=\{reply}", "&code=\{id}&page=1&file_id=\{base}"] {
          let (response, _) = @web_testkit.http_get_path_with_cookie(
            port,
            "/alice/demo/merge-requests/1?discussion=\{id}&discussion_page=3\{suffix}",
            cookie,
          )
          assert_eq(response.code, 303)
          let location = response.headers.get("location").unwrap()
          assert_true(location.contains("version=1&commit=\{commit}"))
          assert_true(location.contains("discussion=\{id}&discussion_page=3"))
          assert_true(location.contains("&page=2&file_id=\{file_id}"))
          if suffix.contains("code=") {
            assert_true(location.contains("&code=\{id}#diff-code"))
          } else {
            assert_true(location.contains("&comment=\{reply}#comment-\{reply}"))
          }
          let (loaded, html) = @web_testkit.http_get_path_with_cookie(
            port,
            location.split("#").next().unwrap().to_owned(),
            cookie,
          )
          assert_eq(loaded.code, 200)
          assert_true(html.contains("data-selected=\"{&quot;protocol&quot;"))
          assert_true(html.contains("Saved later-page comment"))
          assert_true(html.contains("data-diff-fallback"))
          // Refresh is already canonical, not a repeated redirect.
          let (refreshed, _) = @web_testkit.http_get_path_with_cookie(
            port,
            location.split("#").next().unwrap().to_owned(),
            cookie,
          )
          assert_eq(refreshed.code, 200)
        }
        let (response, html) = @web_testkit.http_get_path_with_cookie(
          port,
          "/alice/demo/merge-requests/1?tab=changes&version=1&commit=\{commit}&discussion=\{id}&page=1",
          cookie,
        )
        assert_eq(response.code, 200)
        assert_true(html.contains("&quot;page&quot;:1"))
        assert_true(html.contains("data-selected=\"\""))
      }
      // A stale/corrupt legacy path keeps its discussion and saved snippet visible.
      let (id, _, _, _) = targets[0]
      let original = @collaboration.merge_discussion(pool, scope, actor, mr, id).anchor.unwrap()
      let id : Int64 = pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO merge_activity(merge_request_id, actor_id, kind, body, version) VALUES (?, ?, 'comment', ?, 1)",
            params=[mr.id, actor.id, "Saved later-page comment"],
          ),
        )
        let id : Int64 = client
          .query_one("SELECT last_insert_rowid() AS id")
          .get_name("id")
        ignore(
          client.execute(
            "UPDATE merge_discussion SET anchor = json_set(?, '$.new_path', 'missing.txt') WHERE id = ?",
            params=[Json(original).stringify(), id],
          ),
        )
        id
      })
      let (response, html) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo/merge-requests/1?tab=changes&version=1&discussion=\{id}&code=\{id}&file_id=stale-file",
        cookie,
      )
      assert_eq(response.code, 200)
      assert_true(html.contains("The commented file is unavailable"))
      assert_true(html.contains("Saved later-page comment"))
    },
    moondiff=true,
    diff_executor=executor,
  )
}

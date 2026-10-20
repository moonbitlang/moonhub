///|
let test_png : String = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII="

///|
test "image syntax preserves unicode offsets" {
  let value = "😀 ![a](data:image/png;base64,AAAA)"
  let links = image_links(value)
  assert_eq(links.length(), 1)
  assert_eq(value[links[0].start:links[0].end], "data:image/png;base64,AAAA")
  assert_true(valid_id("".pad_start(64, 'a')))
  assert_false(valid_id("../private"))
}

///|
async test "ordinary attachment links claim files and reject file image embeds" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let file = upload(
      pool, root, scope, alice, "报告 [final].pdf", b"%PDF-1.7\nfixture",
    )
    assert_eq(file.media_type, "application/octet-stream")
    assert_eq(markdown(file), "[报告  final .pdf](\{file.url})")
    assert_eq(image_links(markdown(file)).length(), 0)
    assert_eq(attachment_links(markdown(file)).length(), 1)
    let download = read(pool, root, scope, alice, file.id)
    assert_eq(download.filename, "报告 [final].pdf")
    assert_eq(download.bytes, b"%PDF-1.7\nfixture")
    pool.with_client(client => {
      client.with_transaction(tx => {
        ignore(
          tx.execute(
            "INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(99,?,99,?,'Files')",
            params=[scope.id, alice.id],
          ),
        )
        replace_references(tx, scope.id, alice.id, Issue(99L), markdown(file))
        try
          replace_references(
            tx,
            scope.id,
            alice.id,
            Issue(99L),
            "![file](\{file.url})",
          )
        catch {
          @domain.BadRequest(_) => ()
          err => raise err
        } noraise {
          _ => fail("non-image file accepted as an embedded image")
        }
        assert_eq(
          tx
          .query_all("SELECT attachment_id FROM attachment_reference")
          .length(),
          1,
        )
      })
    })
    assert_eq(read(pool, root, scope, admin, file.id).bytes, download.bytes)
    let code = "\u{0060}[file](\{file.url})\u{0060}\n\u{0060}\u{0060}\u{0060}\n[file](\{file.url})\n\u{0060}\u{0060}\u{0060}"
    assert_true(attachment_links(code).is_empty())
    for filename in ["", "bad\r\nname", "x".repeat(201)] {
      try upload(pool, root, scope, alice, filename, b"file") catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid filename accepted")
      }
    }
  })
}

///|
async test "managed images enforce repository access and transactional claims" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let other = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "public",
    })
    let bytes = @base64.decode(test_png[:])
    let image = upload(pool, root, scope, alice, "test.png", bytes)
    assert_eq(read(pool, root, scope, alice, image.id).bytes, bytes)
    try read(pool, root, scope, bob, image.id) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("outsider read a private image")
    }
    try read(pool, root, scope, admin, image.id) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("another writer read an unclaimed image")
    }
    try read(pool, root, other, alice, image.id) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("image leaked across repositories")
    }
    let body = "![test](\{image.url})"
    pool.with_client(client => {
      client.with_transaction(tx => {
        ignore(
          tx.execute(
            "INSERT INTO issue(id, repository_id, number, author_id, title) VALUES(99, ?, 99, ?, 'Image')",
            params=[scope.id, alice.id],
          ),
        )
        replace_references(tx, scope.id, alice.id, Issue(99L), body)
      })
    })
    assert_eq(read(pool, root, scope, admin, image.id).bytes, bytes)
    pool.with_client(client => {
      client.with_transaction(tx => {
        try replace_references(tx, other.id, alice.id, Issue(99L), body) catch {
          @domain.NotFound(_) => ()
          err => raise err
        } noraise {
          _ => fail("forged target scope accepted")
        }
        replace_references(tx, scope.id, alice.id, Issue(99L), "removed")
      })
      ignore(
        client.execute(
          "UPDATE attachment SET created_at = datetime('now', '-2 days')",
        ),
      )
    })
    cleanup_pending(pool, root)
    assert_true(@fs.exists(storage_path(root, image.id)))
    let pending = upload(pool, root, scope, alice, "abandoned.png", bytes)
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE attachment SET created_at = datetime('now', '-2 days') WHERE id = ?",
          params=[pending.id],
        ),
      )
    })
    cleanup_pending(pool, root)
    assert_false(@fs.exists(storage_path(root, pending.id)))
    assert_true(
      pool.with_client(client => {
        client.query_opt("SELECT id FROM attachment WHERE id = ?", params=[
          pending.id,
        ])
      })
      is None,
    )
    assert_true(
      pool.with_client(client => {
        client.query_all("PRAGMA foreign_key_check").is_empty()
      }),
    )
  })
}

///|
async test "inline data is validated before writes and replaced with stable URLs" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let body = "😀 ![sample](data:image/png;base64,\{test_png}) end"
    let prepared = prepare_markdown(pool, root, scope, alice, body)
    assert_true(prepared.has_prefix("😀 ![sample](/alice/demo/attachments/"))
    assert_true(prepared.has_suffix(") end"))
    assert_false(prepared.contains("base64"))
    let before = pool.with_client(client => {
      client.query_all("SELECT id FROM attachment").length()
    })
    for
      invalid in [
        body + " ![bad](data:image/png;base64,bad)",
        "![bad](data:image/svg+xml;base64,AAAA)",
        "![bad](data:image/jpeg;base64,\{test_png})",
        "x".repeat(20001) + body,
      ] {
      try prepare_markdown(pool, root, scope, alice, invalid) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid inline content accepted")
      }
    }
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM attachment").length()
      }),
      before,
    )
  })
}

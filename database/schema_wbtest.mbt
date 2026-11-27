///|
async test "empty database initializes the complete baseline and repeats safely" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      for
        (kind, count) in [
          ("table", 112L),
          ("index", 81L),
          ("view", 8L),
          ("trigger", 68L),
        ] {
        assert_eq(
          (
            client
            .query_one(
              "SELECT count(*) AS n FROM sqlite_schema WHERE type=? AND name NOT GLOB 'sqlite_*'",
              params=[kind],
            )
            .get_name("n") : Int64),
          count,
        )
      }
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      assert_eq(
        (
          client.query_one("PRAGMA integrity_check").get_name("integrity_check") :
          String),
        "ok",
      )
      assert_eq(
        (
          client.query_one("PRAGMA foreign_keys").get_name("foreign_keys") :
          Int64),
        1L,
      )
    })
  })
}

///|
async test "SSH token migration preserves legacy tokens and their ID sequence" {
  let baseline = @fs.read_file("db/base.sql").text()
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    pool.with_client(client => {
      client.batch_execute(baseline)
      client.batch_execute(
        (
          #|PRAGMA user_version=38;
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES (1,'alice','Alice','test');
          #|INSERT INTO access_token(id,user_id,name,token_hash,permission,expires_at,revoked_at,last_used_at)
          #|VALUES (7,1,'legacy','legacy-hash','merge','2030-01-01','2026-10-01','2026-09-01'),
          #|  (40,1,'removed','removed-hash','read','2030-01-01',NULL,NULL);
          #|DELETE FROM access_token WHERE id=40;
        ),
      )
    })
    initialize_db(pool)
    pool.with_client(client => {
      let legacy = client.query_one("SELECT * FROM access_token WHERE id=7")
      assert_eq((legacy.get_name("token_hash") : String), "legacy-hash")
      assert_eq((legacy.get_name("permission") : String), "merge")
      assert_eq((legacy.get_name("expires_at") : String), "2030-01-01")
      assert_eq((legacy.get_name("revoked_at") : String), "2026-10-01")
      assert_eq((legacy.get_name("last_used_at") : String), "2026-09-01")
      let new = client.query_one(
        "INSERT INTO access_token(user_id,name,token_hash,permission,expires_at) VALUES (1,'ssh','ssh-hash','ssh','2030-01-01') RETURNING id",
      )
      assert_eq((new.get_name("id") : Int64), 41L)
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "schema 38 upgrades atomically and preserves existing data" {
  let baseline = @fs.read_file("db/base.sql").text()
  let migration = @fs.read_file("db/migrations/039_blob_storage.sql").text()
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    pool.with_client(client => {
      client.batch_execute(baseline)
      client.batch_execute(
        "PRAGMA user_version=38; INSERT INTO team(name_key,display_name,kind) VALUES('existing','Existing','org');",
      )
      try
        initialize_database_schema(client, None, [
          (39L, migration + "\nSELECT * FROM missing_table;"),
        ])
      catch {
        @moondb.QueryError(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid incremental migration succeeded")
      }
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        38L,
      )
      assert_true(
        client.query_opt(
          "SELECT name FROM sqlite_schema WHERE name='pipeline_artifact_location'",
        )
        is None,
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_eq(
        (
          client
          .query_one("SELECT display_name FROM team WHERE name_key='existing'")
          .get_name("display_name") : String),
        "Existing",
      )
      assert_true(
        client.query_all("SELECT * FROM pipeline_artifact_location").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "workflow run number migration ranks original runs and copies their number to reruns" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TRIGGER pipeline_workflow_run_number_immutable;
          #|DROP TABLE pipeline_workflow_run_sequence;
          #|ALTER TABLE pipeline_run DROP COLUMN workflow_run_number;
          #|PRAGMA user_version=58;
          #|INSERT INTO pipeline_run(id,repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json,public_run_id,run_attempt)
          #|VALUES
          #|  (10,1,1,1,'.github/workflows/main.yml','Main','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/pipeline/10',1,'old','{}',NULL,1),
          #|  (20,1,2,1,'.github/workflows/other.yml','Other','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/pipeline/20',1,'old','{}',NULL,1),
          #|  (30,1,3,1,'.github/workflows/main.yml','Main','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/pipeline/30',1,'old','{}',NULL,1),
          #|  (40,1,4,1,'.github/workflows/main.yml','Main','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/pipeline/40',1,'old','{}',10,2),
          #|  (50,2,1,1,'.github/workflows/main.yml','Main','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/pipeline/50',1,'old','{}',NULL,1);
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let numbers : Array[Int64] = client
        .query_all("SELECT workflow_run_number FROM pipeline_run ORDER BY id")
        .map(row => row.get_name("workflow_run_number"))
      assert_eq(numbers, [1L, 1L, 2L, 1L, 1L])
      let counters : Array[Int64] = client
        .query_all(
          "SELECT last_number FROM pipeline_workflow_run_sequence ORDER BY repository_id,workflow_path",
        )
        .map(row => row.get_name("last_number"))
      assert_eq(counters, [2L, 1L, 1L])
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "current schema initialization preserves data and schema" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO session(user_id,token_hash,expires_at) VALUES(1,'existing-session','2099-01-01');
          #|INSERT INTO email_outbox(to_email,subject,body) VALUES('alice@example.com','Existing mail','Preserved body');
          #|UPDATE "user" SET created_at='2024-01-02 03:04:05' WHERE id=1;
        ),
      )
    })
    let before : Array[(String, String)] = pool.with_client(client => {
      client
      .query_all(
        "SELECT name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name",
      )
      .map(row => (row.get_name("name"), row.get_name("sql")))
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let after : Array[(String, String)] = client
        .query_all(
          "SELECT name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name",
        )
        .map(row => (row.get_name("name"), row.get_name("sql")))
      assert_eq(after, before)
      assert_eq(
        (
          client
          .query_one("SELECT created_at FROM \"user\" WHERE id=1")
          .get_name("created_at") : String),
        "2024-01-02 03:04:05",
      )
      assert_eq(
        (
          client
          .query_one("SELECT token_hash FROM session")
          .get_name("token_hash") : String),
        "existing-session",
      )
      assert_eq(
        (
          client.query_one("SELECT body FROM email_outbox").get_name("body") :
          String),
        "Preserved body",
      )
      assert_eq(client.query_all("SELECT id FROM repository").length(), 2)
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "all older versions and future versions are rejected without changing data" {
  @async.with_task_group(group => {
    let versions = [ for version in 0..<38 => version ]
    versions.push(database_schema_version.to_int() + 1)
    versions.push(100)
    for version in versions {
      let pool = new_db_pool({ path: ":memory:", }, group)
      defer pool.close()
      pool.with_client(client => {
        client.batch_execute(
          "CREATE TABLE retained(value TEXT); INSERT INTO retained VALUES('keep'); PRAGMA user_version=\{version};",
        )
      })
      try initialize_db(pool) catch {
        @domain.BadRequest(message~) =>
          if version.to_int64() > database_schema_version {
            assert_eq(
              message, "database schema is newer than this moonhub version",
            )
          } else {
            assert_true(message.contains("historical MoonHub release first"))
            assert_true(message.contains("38"))
          }
        err => raise err
      } noraise {
        _ => fail("accepted unsupported schema version \{version}")
      }
      pool.with_client(client => {
        assert_eq(
          (
            client.query_one("PRAGMA user_version").get_name("user_version") :
            Int64),
          version.to_int64(),
        )
        assert_eq(
          (
            client.query_one("SELECT value FROM retained").get_name("value") :
            String),
          "keep",
        )
        assert_eq(
          client.query_all("SELECT name FROM sqlite_schema").length(),
          1,
        )
      })
    }
  })
}

///|
async test "version zero rejects empty tables partial baselines and view-only databases" {
  let baseline = @fs.read_file("db/base.sql").text()
  @async.with_task_group(group => {
    for
      sql in [
        "CREATE TABLE unrelated(id INTEGER PRIMARY KEY)", "CREATE TABLE \"user\"(id INTEGER PRIMARY KEY)",
        "CREATE VIEW existing_view AS SELECT 1 AS id", baseline,
      ] {
      let pool = new_db_pool({ path: ":memory:", }, group)
      defer pool.close()
      pool.with_client(client => client.batch_execute(sql))
      try initialize_db(pool) catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("contains user-defined objects"))
        err => raise err
      } noraise {
        _ => fail("initialized a nonempty version-zero database")
      }
      pool.with_client(client => {
        assert_eq(
          (
            client.query_one("PRAGMA user_version").get_name("user_version") :
            Int64),
          0L,
        )
      })
    }
  })
}

///|
async test "baseline creation rolls back DDL and version and can retry" {
  let baseline = @fs.read_file("db/base.sql").text()
  let migration = @fs.read_file("db/migrations/039_blob_storage.sql").text()
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    pool.with_client(client => {
      try
        initialize_database_schema(client, Some(baseline), [
          (
            39L,
            migration +
            "\nPRAGMA user_version=38; CREATE TABLE \"user\"(id INTEGER);",
          ),
        ])
      catch {
        @moondb.QueryError(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid baseline succeeded")
      }
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        0L,
      )
      assert_true(client.query_all("SELECT name FROM sqlite_schema").is_empty())
    })
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
    })
  })
}

///|
async test "baseline transaction rechecks version and objects after preflight" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    pool.with_client(client => {
      assert_true(
        database_needs_initialization(
          client.query_one(database_initialization_state),
        ),
      )
      // A version 38 preflight does not load the baseline. If the database
      // becomes empty before the write lock, it must retry with that script.
      try
        initialize_database_schema(client, None, [
          (41L, "SQL that must not execute"),
        ])
      catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("state changed"))
        err => raise err
      } noraise {
        _ => fail("initialized an empty database without the baseline")
      }
    })
    initialize_db(pool)
    pool.with_client(client => {
      // A second initializer must accept the first one's committed baseline.
      initialize_database_schema(client, None, [
        (41L, "invalid SQL that must not execute"),
      ])
      let future = database_schema_version + 1L
      for
        sql in [
          "PRAGMA user_version=37",
          "PRAGMA user_version=\{future}",
          "PRAGMA user_version=0",
        ] {
        client.batch_execute(sql)
        try
          initialize_database_schema(client, None, [
            (41L, "invalid SQL that must not execute"),
          ])
        catch {
          @domain.BadRequest(_) => ()
          err => raise err
        } noraise {
          _ => fail("baseline transaction skipped state validation")
        }
      }
    })
  })
}

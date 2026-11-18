///|
priv struct EnvironmentFixture {
  c : Coordinator
  pool : @database.Database
  root : String
  repo : @domain.RepoId
  provider : Provider
  admin : @domain.CurrentUser
  actor : @domain.CurrentUser
}

///|
async fn with_environment_fixture(
  source : String,
  f : async (EnvironmentFixture) -> Unit,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(@test_support.workflow_commit(repo.git_dir(root), source))
    let admin = @identity.active_user_by_name(pool, "admin")
    let actor = @identity.active_user_by_name(pool, "alice")
    let c = Coordinator::new(pool)
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "linux", "moonhub-build", "ubuntu-24.04", "x64"],
      [repo],
    )
    ignore(c.register_runner("a".repeat(64), control_registration()))
    ignore(c.sync_provider("b".repeat(64), environment_sync(1L)))
    f({ c, pool, root, repo, provider, admin, actor, })
  })
}

///|
fn environment_sync(revision : Int64) -> @protocol.ProviderSyncRequest {
  {
    environment_protocol: Some(1),
    version: 1,
    controller_id: "manager",
    observed_revision: revision.to_string(),
    applied_revision: revision.to_string(),
    status: "applied",
    schema: None,
    defaults: None,
  }
}

///|
fn fixture_environment(
  name : String,
  selector : String,
  digest : String,
) -> @environment.Definition {
  {
    name,
    selector,
    architecture: "x64",
    image: "registry.example/runner@sha256:" + digest.repeat(64),
    labels: [],
  }
}

///|
fn environment_ready(
  revision : Int64,
  profiles : Array[@environment.Profile],
) -> @protocol.WorkerSyncRequest {
  {
    environments: Some(profiles.map(profile => profile.id)),
    version: 1,
    state: "ready",
    applied_revision: revision.to_string(),
  }
}

///|
let environment_workflow : String =
  #|name: Multiple Linux environments
  #|on: workflow_dispatch
  #|jobs:
  #|  ubuntu:
  #|    runs-on: ubuntu-24.04
  #|    steps:
  #|      - run: echo ubuntu
  #|  debian:
  #|    runs-on: debian-12
  #|    steps:
  #|      - run: echo debian
  #|  generic:
  #|    runs-on: [self-hosted, linux, moonhub-build]
  #|    steps:
  #|      - run: echo default
  #|  contradictory:
  #|    runs-on: [self-hosted, linux, debian-12, ubuntu-24.04]
  #|    steps:
  #|      - run: echo impossible

///|
async test "profiles match one complete environment and share worker capacity" {
  with_environment_fixture(environment_workflow, fixture => {
    let { c, pool, root, repo, provider, admin, actor, } = fixture
    let debian = fixture_environment("debian", "debian-12", "a")
    let ubuntu = fixture_environment("ubuntu", "ubuntu-24.04", "b")
    c.save_provider_environments(
      admin,
      provider.id,
      1L,
      [debian, ubuntu],
      "debian",
    )
    let control = c.sync_provider("b".repeat(64), environment_sync(2L))
    let profiles = control.environments.unwrap()
    let run = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, provider.id).snapshot.queued_jobs, 3)
    assert_true(
      c.queue_reasons(actor, repo, run.number)["contradictory"]
      is NoMatchingLabels,
    )
    ignore(
      c.register_worker("b".repeat(64), {
        version: 1,
        key: "one",
        token: "c".repeat(64),
      }),
    )
    ignore(
      c.register_worker("b".repeat(64), {
        version: 1,
        key: "two",
        token: "d".repeat(64),
      }),
    )
    let ready = environment_ready(2L, profiles)
    try c.sync_worker("c".repeat(64), { ..ready, environments: None, }) catch {
      Conflict(_) => ()
      error => raise error
    } noraise {
      _ => fail("old worker advertised unprepared environments")
    }
    ignore(c.sync_worker("c".repeat(64), ready))
    ignore(c.sync_worker("d".repeat(64), ready))
    let claim = claim_request(secret="e".repeat(64))
    assert_true(c.claim("c".repeat(64), claim) is None)
    let debian_id = profiles
      .iter()
      .find_first(profile => profile.environment.selector == "debian-12")
      .unwrap().id
    let first = c
      .claim("c".repeat(64), { ..claim, environments: Some([debian_id]), })
      .unwrap()
    assert_eq(first.job.id, "debian")
    assert_eq(first.environment, Some(debian))
    assert_eq(first.version, @protocol.profile_assignment_version)
    assert_eq(
      c
      .claim("c".repeat(64), { ..claim, environments: Some([debian_id]), })
      .unwrap().environment,
      first.environment,
    )
    assert_true(
      c.claim("c".repeat(64), {
        ..claim,
        request_id: "2".repeat(32),
        attempt_token: "f".repeat(64),
        environments: ready.environments,
      })
      is None,
    )
    let second = c
      .claim("d".repeat(64), {
        ..claim,
        request_id: "3".repeat(32),
        attempt_token: "f".repeat(64),
        environments: ready.environments,
      })
      .unwrap()
    assert_eq(second.job.id, "ubuntu")
    assert_eq(second.environment, Some(ubuntu))
    assert_eq(c.provider_control(admin, provider.id).snapshot.queued_jobs, 1)
    c.set_provider_labels(admin, provider.id, [
      "self-hosted", "linux", "moonhub-build", "x64", "ubuntu-24.04",
    ])
    assert_false(
      c.heartbeat(
        @protocol.parse_decimal(first.attempt_id).unwrap(),
        "e".repeat(64),
        1,
      ).cancel_requested,
    )
    try
      c.set_provider_labels(admin, provider.id, ["self-hosted", "windows"])
    catch {
      @domain.BadRequest(_) => ()
      error => raise error
    } noraise {
      _ => fail("changed a multi-environment provider to Windows")
    }
  })
}

///|
async test "generic jobs pin the default image and reruns cannot silently switch images" {
  with_environment_fixture(@test_support.single_job_workflow, fixture => {
    let { c, pool, root, repo, provider, admin, actor, } = fixture
    let debian = fixture_environment("debian", "debian-12", "a")
    let ubuntu = fixture_environment("ubuntu", "ubuntu-24.04", "b")
    c.save_provider_environments(
      admin,
      provider.id,
      1L,
      [debian, ubuntu],
      "debian",
    )
    let profiles = c.sync_provider("b".repeat(64), environment_sync(2L)).environments.unwrap()
    ignore(
      c.register_worker("b".repeat(64), {
        version: 1,
        key: "one",
        token: "c".repeat(64),
      }),
    )
    ignore(c.sync_worker("c".repeat(64), environment_ready(2L, profiles)))
    let original = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let claim = {
      ..claim_request(secret="e".repeat(64)),
      environments: Some(profiles.map(profile => profile.id)),
    }
    let first = c.claim("c".repeat(64), claim).unwrap()
    assert_eq(first.environment, Some(debian))
    let attempt = @protocol.parse_decimal(first.attempt_id).unwrap()
    ignore(c.start(attempt, "e".repeat(64), 1))
    ignore(c.complete(attempt, "e".repeat(64), completion()))
    let rerun = rerun_run(pool, root, actor, repo, original.number)
    assert_eq(c.job_environments(actor, repo, rerun.number)["build"], debian)
    c.save_provider_environments(
      admin,
      provider.id,
      2L,
      [
        { ..debian, image: "registry.example/runner@sha256:" + "c".repeat(64), },
        ubuntu,
      ],
      "ubuntu",
    )
    let changed = c.sync_provider("b".repeat(64), environment_sync(3L)).environments.unwrap()
    ignore(c.sync_worker("c".repeat(64), environment_ready(3L, changed)))
    let next = {
      ..claim_request(id="2", secret="f".repeat(64)),
      environments: Some(changed.map(profile => profile.id)),
    }
    assert_true(c.claim("c".repeat(64), next) is None)
    assert_true(
      c.queue_reasons(actor, repo, rerun.number)["build"]
      is EnvironmentUnavailable,
    )
    assert_eq(c.provider_control(admin, provider.id).snapshot.queued_jobs, 0)
    c.save_provider_environments(
      admin,
      provider.id,
      3L,
      [{ ..debian, name: "recovery", }, ubuntu],
      "ubuntu",
    )
    let restored = c.sync_provider("b".repeat(64), environment_sync(4L)).environments.unwrap()
    ignore(c.sync_worker("c".repeat(64), environment_ready(4L, restored)))
    let retried = c
      .claim("c".repeat(64), {
        ..next,
        environments: Some(restored.map(profile => profile.id)),
      })
      .unwrap()
    assert_eq(retried.run_id, rerun.id.to_string())
    assert_eq(retried.environment, Some(debian))
  })
}

///|
async test "environment administration preserves authorization and configuration fencing" {
  with_environment_fixture(@test_support.single_job_workflow, fixture => {
    let { c, provider, admin, actor, .. } = fixture
    let debian = fixture_environment("debian", "debian-12", "a")
    try
      c.save_provider_environments(actor, provider.id, 1L, [debian], "debian")
    catch {
      @domain.Forbidden(_) => ()
      error => raise error
    } noraise {
      _ => fail("repository owner configured provider images")
    }
    c.save_provider_environments(admin, provider.id, 1L, [debian], "debian")
    try c.save_provider_environments(admin, provider.id, 1L, [], "") catch {
      Conflict(_) => ()
      error => raise error
    } noraise {
      _ => fail("stale save removed execution environments")
    }
    try
      c.sync_provider("b".repeat(64), {
        ..environment_sync(2L),
        environment_protocol: None,
      })
    catch {
      Conflict(_) => ()
      error => raise error
    } noraise {
      _ => fail("old controller accepted a multi-environment pool")
    }
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.environments
      .unwrap()
      .length(),
      1,
    )
  })
}

///|
async test "environment edits do not alter leased tasks and new jobs use the new default" {
  with_environment_fixture(@test_support.single_job_workflow, fixture => {
    let { c, pool, root, repo, provider, admin, actor, } = fixture
    let debian = fixture_environment("debian", "debian-12", "a")
    let ubuntu = fixture_environment("ubuntu", "ubuntu-24.04", "b")
    c.save_provider_environments(admin, provider.id, 1L, [debian], "debian")
    let profiles = c.sync_provider("b".repeat(64), environment_sync(2L)).environments.unwrap()
    ignore(
      c.register_worker("b".repeat(64), {
        version: 1,
        key: "one",
        token: "c".repeat(64),
      }),
    )
    ignore(c.sync_worker("c".repeat(64), environment_ready(2L, profiles)))
    let original = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let request = {
      ..claim_request(secret="e".repeat(64)),
      environments: Some(profiles.map(profile => profile.id)),
    }
    let assignment = c.claim("c".repeat(64), request).unwrap()
    c.save_provider_environments(admin, provider.id, 2L, [ubuntu], "ubuntu")
    assert_eq(
      c.claim("c".repeat(64), request).unwrap().environment,
      Some(debian),
    )
    let attempt = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    assert_false(c.start(attempt, "e".repeat(64), 1).cancel_requested)
    ignore(c.complete(attempt, "e".repeat(64), completion()))
    assert_eq(c.job_environments(actor, repo, original.number)["build"], debian)
    let next = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let changed = c.sync_provider("b".repeat(64), environment_sync(3L)).environments.unwrap()
    ignore(c.sync_worker("c".repeat(64), environment_ready(3L, changed)))
    let claimed = c
      .claim("c".repeat(64), {
        ..claim_request(id="2", secret="f".repeat(64)),
        environments: Some(changed.map(profile => profile.id)),
      })
      .unwrap()
    assert_eq(claimed.run_id, next.id.to_string())
    assert_eq(claimed.environment, Some(ubuntu))
  })
}

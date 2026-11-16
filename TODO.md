# Repository deletion race follow-ups

- [ ] **P1: Bind SSH reads to the original repository throughout the transfer.**

  In `ssh/ssh.mbt:204`, only write operations acquire the repository control
  lock. An authorized read can therefore open the same path after deletion,
  cleanup, and recreation have replaced the repository.

  Reproduced with separate Web and SSH processes: pause a public repository's
  SSH read after its final authorization but before Git opens the repository,
  delete and clean up the repository, recreate it as private with a new ref,
  then resume the read. The old request exposes the replacement repository's
  ref to a user whose fresh request is denied.

  Hold a shared lifecycle lock throughout reads, or bind them to a storage
  identity that cannot be reused by a replacement repository. An identity
  check immediately before starting Git alone does not close the race. Add a
  regression test covering an unauthorized reader and a private replacement.

- [ ] **P2: Preserve the original repository scope when submitting secrets.**

  In `pipeline/secrets.mbt:48`, `save_secret` resolves a new scope by repository
  name instead of accepting the scope captured by the Web handler before
  `protected_form` reads the request body. The later write-lock validation
  consequently checks the replacement identity rather than the original one.

  Reproduced by pausing a Secret form request before its final body byte,
  deleting and cleaning up the original repository, recreating the same name,
  and completing the request. The old form passes CSRF validation, returns
  HTTP 303, and saves its secret under the replacement repository's ID.

  Pass the original `RepositoryScope` from the handler into the business
  operation and validate it after acquiring the repository control lock.
  Reject requests whose original repository has disappeared or changed. Add
  an HTTP regression test with a partial request body and a same-name rebuild.

# Error Handling

- `AppError` and `gitops.Failure` contain application-authored, public messages.
  Never wrap SQL, exception text, process output, paths, or credentials in them.
- Unexpected HTTP errors are logged on the server and return a generic 500 page
  with `Cache-Control: no-store`. Cancellation propagates, and errors after
  response headers have been sent do not produce a second response.
- Git command diagnostics use `gitops.InternalFailure`, not `Failure`.
  Remote SSH commands also return a generic message for unexpected exceptions.
- Email, repository, and merge diagnostics stored in `last_error` are private.
  Their pages show fixed messages or explicitly allowed business errors,
  including for records created by older versions. Merge failure activity is
  likewise redacted. Stored merge blockers are restricted to known public
  messages before use in a response.
- Duplicate identities are handled by database conflict clauses and reported
  as validation errors. Do not turn every database exception into a duplicate
  error: connection failures, invalid SQL, and unrelated constraints remain
  internal failures.
- Invitation creation and its queued email are transactional. Expired pending
  invitations release their reserved identity before replacement. Inactive
  invitation emails cannot be resent or claimed for delivery.

Regression coverage lives in `web/context/errors_wbtest.mbt`, invitation tests in
`web/views/auth/`, `web/views/namespaces/`, `identity/` and `mail/`, and
the existing SSH, repository, issue, and merge request tests. No database
migration is needed for these changes; historical diagnostics remain available
to operators without being returned to users.

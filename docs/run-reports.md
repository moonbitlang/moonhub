# Workflow run reports

New workflow snapshots use assignment v19 to persist `GITHUB_STEP_SUMMARY` and
structured `::notice::`, `::warning::`, and `::error::` commands. Update server and
runner together. Old snapshots decode reporting as disabled and retain their
previous assignment and local-summary behavior; they do not silently acquire a
new execution requirement when rerun.

The run page shows each job's combined summaries grouped by originating workflow
step, followed by annotations with severity, title, message, file, line range and
column range when supplied. Pre/main/post handlers retain their owning workflow
step; composite invocations share that step. Error annotations alone do not
change the process exit status or job conclusion. Polling reloads the page when a
persisted report changes, and stored reports remain readable after completion.

The runner gathers command files after each invocation, including failed
processes, and sends a monotonic report revision before completing the step or
job. Repeating the same revision and payload is idempotent; stale or conflicting
revisions are rejected. The server binds the report to the live lease, execution,
job attempt and known started steps. Cancellation or lease expiry prevents new
reports. A process terminated before its command files can be collected can lose
that invocation's partial report; previously persisted steps remain available.

Reruns have their own reports. Historical run/attempt pages retain their records,
and a reused job links to its original run's results. Repository read permission
protects reports just as it protects logs. The runner applies workflow masks, and
the server also applies delivered-secret and lease-token masking. Summaries use
the application's safe Markdown renderer; raw HTML and unsafe links do not
execute. Annotation text is escaped, and source paths are displayed as text.

Limits are 1 MiB of UTF-8 summary content per job, 200 annotations and 256 KiB of
serialized annotation content per job, 16 KiB per annotation message, 200 bytes
per runner-normalized title and 1,024 bytes per source path. Positions are positive
32-bit integers; invalid positions are omitted. Aggregate runner limits truncate
later content with a visible notice. Individual command files retain their
existing 1 MiB read limit. The server rejects malformed or oversized submissions,
limits the JSON envelope to 4 MiB and stored reports across a workflow attempt to
8 MiB. It reapplies field and aggregate byte limits after server-side masking,
truncating expanded content at UTF-8 boundaries with the same visible notice. Reports belong to their job attempts and are removed with those records.

The runner endpoint is `POST /-/runner-api/v1/attempts/ID/reports`, using the
existing lease bearer credential, protocol version 1, bound `execution_id`, and a
`report` object containing `revision`, `entries`, and `truncated`. It does not grant
repository API, artifact, or provider-control access.

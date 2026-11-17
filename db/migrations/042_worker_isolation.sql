-- Only the outside controller can arm a privileged worker after disabling IMDS.
-- Revisions fence workers whose image or execution configuration has changed.
ALTER TABLE pipeline_worker ADD COLUMN isolation_revision INTEGER NOT NULL DEFAULT 0;

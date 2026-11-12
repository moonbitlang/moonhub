-- Persist a destination independently of deployment defaults. Missing rows are
-- historical blobs in the legacy repository-root filesystem layout.
CREATE TABLE IF NOT EXISTS pipeline_artifact_location (
  artifact_id INTEGER PRIMARY KEY REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
  location TEXT NOT NULL
);

-- No foreign key: these intents must survive run/repository cascade deletion.
CREATE TABLE IF NOT EXISTS pipeline_blob_garbage (
  location TEXT NOT NULL,
  key TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('object','namespace')),
  not_before_ms INTEGER NOT NULL,
  PRIMARY KEY(location,key,kind)
);
CREATE INDEX IF NOT EXISTS pipeline_blob_garbage_due ON pipeline_blob_garbage(not_before_ms);
CREATE TRIGGER IF NOT EXISTS pipeline_artifact_storage_delete BEFORE DELETE ON pipeline_artifact
BEGIN
  INSERT OR REPLACE INTO pipeline_blob_garbage(location,key,kind,not_before_ms)
  VALUES(COALESCE((SELECT location FROM pipeline_artifact_location WHERE artifact_id=OLD.id),'legacy-fs'),
    OLD.storage_key,'namespace',CAST(strftime('%s','now') AS INTEGER)*1000+600000);
END;

-- Release publications share the ref event queue and its run deduplication.
-- This is the default branch verified at publication, not the checkout ref.
ALTER TABLE repository_ref_event ADD COLUMN release_branch TEXT
  CHECK (release_branch IS NULL OR (
    length(release_branch) > 0 AND reference GLOB 'refs/tags/*'
    AND source_key GLOB 'release:*' AND state IN ('ready', 'processed')
  ));

-- Anchors are immutable snapshots; existing discussions remain unanchored.
ALTER TABLE merge_discussion ADD COLUMN anchor TEXT CHECK (anchor IS NULL OR json_valid(anchor));
CREATE TRIGGER merge_discussion_anchor_immutable BEFORE UPDATE OF anchor ON merge_discussion
WHEN OLD.anchor IS NOT NULL AND OLD.anchor IS NOT NEW.anchor BEGIN
  SELECT RAISE(ABORT, 'discussion anchors are immutable');
END;

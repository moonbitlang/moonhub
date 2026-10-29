CREATE TABLE mirror_ssh_key (
 mirror_id INTEGER PRIMARY KEY REFERENCES repository_mirror(id) ON DELETE CASCADE,
 private_key TEXT NOT NULL,
 public_key TEXT NOT NULL
);

-- Do not reuse a namespace identity after upgrading. Save each existing mirror
-- to generate its dedicated key, authorize that key, then enable sync again.
UPDATE repository_mirror
SET active=0,status='disabled',version=version+1,
    generation=generation+1,lease=NULL,locked_at=NULL;

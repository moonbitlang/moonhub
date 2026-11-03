ALTER TABLE branch_rule ADD COLUMN allow_self_approval INTEGER NOT NULL DEFAULT 0 CHECK (allow_self_approval IN (0, 1));

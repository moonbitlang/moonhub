ALTER TABLE pipeline_job ADD COLUMN requires_containers INTEGER NOT NULL DEFAULT 0 CHECK(requires_containers IN (0,1));
CREATE TRIGGER pipeline_container_requirement_immutable BEFORE UPDATE OF requires_containers ON pipeline_job BEGIN SELECT RAISE(ABORT,'immutable container requirement'); END;

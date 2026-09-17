-- Every activated account owns a personal namespace named after its name_key,
-- so users can create repositories under their own name. Team names already in
-- use by another namespace keep their kind and owner unchanged.
INSERT INTO team (name_key, display_name, kind)
SELECT "user".name_key, "user".display_name, 'personal'
FROM "user"
WHERE "user".status = 'active'
ON CONFLICT (name_key) DO NOTHING;

INSERT INTO team_member (team_id, user_id, role)
SELECT team.id, "user".id, 'owner'
FROM "user"
JOIN team ON team.name_key = "user".name_key AND team.kind = 'personal'
WHERE "user".status = 'active'
ON CONFLICT (team_id, user_id) DO NOTHING;

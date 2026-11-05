-- last_seen is all the 30 day cleanup needs. When an install first registered
-- is not used anywhere, so it is not kept.
ALTER TABLE installs DROP COLUMN created;

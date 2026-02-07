ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS follow_previous BOOLEAN DEFAULT false;

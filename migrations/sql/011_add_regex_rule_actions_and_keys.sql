ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS rule_key VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS action_type VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS action_project_title VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS action_activity_title VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS pattern_format VARCHAR;

UPDATE mapping_rules
SET source = 'user'
WHERE source IS NULL OR source = '';

UPDATE mapping_rules
SET action_type = 'assign_explicit'
WHERE action_type IS NULL OR action_type = '';

UPDATE mapping_rules
SET pattern_format = 'glob'
WHERE pattern_format IS NULL OR pattern_format = '';

UPDATE mapping_rules
SET action_type = 'follow_current_context'
WHERE COALESCE(follow_previous, false) = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_mapping_rules_rule_key ON mapping_rules(rule_key);

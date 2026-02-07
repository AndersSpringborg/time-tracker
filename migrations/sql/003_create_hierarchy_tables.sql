CREATE TABLE IF NOT EXISTS customers (
    customer_id INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS projects (
    project_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS phases (
    phase_id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS activities (
    activity_id INTEGER PRIMARY KEY,
    phase_id INTEGER NOT NULL REFERENCES phases(phase_id),
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS kinds (
    kind_id INTEGER PRIMARY KEY,
    activity_id INTEGER NOT NULL REFERENCES activities(activity_id),
    name VARCHAR NOT NULL,
    billable BOOLEAN NOT NULL DEFAULT true
);

import Database from 'better-sqlite3';

export const openDb = (path) => new Database(path);

export function bootstrap(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, google_sub TEXT UNIQUE NOT NULL, email TEXT NOT NULL, name TEXT, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS orgs (id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_user_id TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS memberships (user_id TEXT NOT NULL, org_id TEXT NOT NULL, role TEXT NOT NULL, PRIMARY KEY (user_id, org_id));
    CREATE TABLE IF NOT EXISTS invites (id TEXT PRIMARY KEY, org_id TEXT NOT NULL, token TEXT UNIQUE NOT NULL, role TEXT NOT NULL, created_at INTEGER NOT NULL, accepted_by TEXT);
    CREATE TABLE IF NOT EXISTS device_tokens (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, org_id TEXT NOT NULL, token_hash TEXT NOT NULL, created_at INTEGER NOT NULL, last_used INTEGER);
    CREATE TABLE IF NOT EXISTS pairing_codes (code TEXT PRIMARY KEY, user_id TEXT NOT NULL, org_id TEXT NOT NULL, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS summaries (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL, org_id TEXT NOT NULL, kind TEXT NOT NULL, date TEXT NOT NULL,
      items TEXT NOT NULL, notes TEXT NOT NULL, visibility TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS summaries_uniq ON summaries(user_id, org_id, kind, date);
    CREATE TABLE IF NOT EXISTS org_people (
      id TEXT PRIMARY KEY, org_id TEXT NOT NULL, erp_id INTEGER NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL, title TEXT NOT NULL,
      manager_erp_id INTEGER, note TEXT NOT NULL, user_id TEXT, linked_by_hand INTEGER NOT NULL DEFAULT 0, UNIQUE(org_id, erp_id)
    );
    CREATE TABLE IF NOT EXISTS org_projects (
      id TEXT PRIMARY KEY, org_id TEXT NOT NULL, erp_id INTEGER NOT NULL, name TEXT NOT NULL, name_by_hand INTEGER NOT NULL DEFAULT 0,
      description TEXT NOT NULL, active INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0, UNIQUE(org_id, erp_id)
    );
    CREATE TABLE IF NOT EXISTS project_members (
      project_id TEXT NOT NULL, person_id TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('lead','member')),
      role_by_hand INTEGER NOT NULL DEFAULT 0, removed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(project_id, person_id)
    );
  `);
}

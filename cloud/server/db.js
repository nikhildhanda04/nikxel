import Database from 'better-sqlite3';

export const openDb = (path) => new Database(path);

export function bootstrap(db) {
  db.exec('DROP TABLE IF EXISTS org_people; DROP TABLE IF EXISTS org_projects; DROP TABLE IF EXISTS project_members;');
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
    CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, org_id TEXT NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', created_by TEXT NOT NULL, created_at INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
    CREATE UNIQUE INDEX IF NOT EXISTS projects_name ON projects(org_id, lower(name));
    CREATE TABLE IF NOT EXISTS project_users (project_id TEXT NOT NULL, user_id TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY(project_id, user_id));
    CREATE TABLE IF NOT EXISTS meeting_shares (
      id TEXT PRIMARY KEY, org_id TEXT NOT NULL, project_id TEXT NOT NULL, user_id TEXT NOT NULL, meeting_id TEXT NOT NULL, title TEXT NOT NULL,
      date TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(project_id, user_id, meeting_id)
    );
  `);
}

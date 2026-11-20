import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import { openDb, bootstrap } from './db.js';
import { assertSecret } from './auth.js';
import { buildRouter, errorHandler } from './routes.js';

const here = path.dirname(fileURLToPath(import.meta.url));

export function createApp(db, opts) {
  const app = express();
  app.use(express.json());
  app.use('/api', buildRouter(db, opts));
  app.use('/api', (req, res) => res.status(404).json({ error: 'not found' }));
  const dist = path.join(here, '../dashboard/dist');
  app.use(express.static(dist));
  app.get('/{*splat}', (req, res) => res.sendFile(path.join(dist, 'index.html'), (e) => e && res.status(404).end()));
  app.use(errorHandler);
  return app;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  assertSecret(process.env.SESSION_SECRET); // fail loud at startup
  const db = openDb(process.env.DB_PATH || 'nikxel.db'); bootstrap(db);
  createApp(db).listen(process.env.PORT || 3000);
}

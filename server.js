const fs = require('fs');
const path = require('path');
const express = require('express');

const app = express();

function ensureRuntimeFolders() {
  const dataDir = path.join(__dirname, 'data');
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
}
ensureRuntimeFolders();

app.use(express.json({ limit: '2mb' }));
app.use(express.urlencoded({ extended: true }));

app.get('/health', (_req, res) => {
  res.status(200).json({ ok: true });
});

app.get('/api/health', (_req, res) => {
  res.status(200).json({
    ok: true,
    service: 'lifeos-atlas',
    storage: process.env.DATABASE_URL ? 'postgres-configured' : 'in-memory',
    db: process.env.DATABASE_URL ? 'configured' : 'not-configured',
    time: new Date().toISOString()
  });
});

app.get('/', (_req, res) => {
  res.status(200).send('LifeOS Atlas live');
});

const port = Number(process.env.PORT || 8080);
app.listen(port, () => {
  console.log(`LifeOS Atlas listening on ${port}`);
});

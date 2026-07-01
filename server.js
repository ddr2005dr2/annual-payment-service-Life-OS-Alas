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

const analytics = [];
const users = [];
const concierge = [];

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

app.use((req, _res, next) => {
  if (req.path !== '/api/health' && req.path !== '/health') {
    analytics.push({
      event_type: 'page_view',
      path: req.path,
      created_at: new Date().toISOString(),
      source: req.headers.referer || req.headers.origin || 'direct'
    });
  }
  next();
});

app.post('/api/signup', (req, res) => {
  const { fullName, email, plan } = req.body || {};
  if (!fullName || !email) {
    return res.status(400).json({ ok: false, error: 'Missing required fields' });
  }

  const user = {
    id: String(users.length + 1),
    fullName,
    email: String(email).toLowerCase(),
    plan: plan || 'starter',
    created_at: new Date().toISOString()
  };

  users.push(user);
  analytics.push({
    event_type: 'signup_completed',
    path: '/api/signup',
    created_at: new Date().toISOString(),
    source: 'app'
  });

  res.status(200).json({ ok: true, user });
});

app.post('/api/concierge', (req, res) => {
  const { name, email, topic, message } = req.body || {};
  if (!name || !email || !topic || !message) {
    return res.status(400).json({ ok: false, error: 'Missing required fields' });
  }

  concierge.push({
    id: String(concierge.length + 1),
    name,
    email: String(email).toLowerCase(),
    topic,
    message,
    created_at: new Date().toISOString()
  });

  analytics.push({
    event_type: 'concierge_submitted',
    path: '/api/concierge',
    created_at: new Date().toISOString(),
    source: 'app'
  });

  res.status(200).json({ ok: true, message: 'Concierge request received' });
});

app.get('/api/admin/overview', (_req, res) => {
  const counts = analytics.reduce((acc, item) => {
    acc[item.event_type] = (acc[item.event_type] || 0) + 1;
    return acc;
  }, {});

  res.status(200).json({
    ok: true,
    metrics: {
      users: users.length,
      conciergeMessages: concierge.length,
      events: analytics.length
    },
    recentEvents: analytics.slice(-20).reverse(),
    eventBreakdown: Object.keys(counts).map(k => ({ eventType: k, count: counts[k] }))
  });
});

app.get('/', (_req, res) => {
  res.status(200).send('LifeOS Atlas live with admin route');
});

const port = Number(process.env.PORT || 8080);
app.listen(port, () => {
  console.log(`LifeOS Atlas listening on ${port}`);
});

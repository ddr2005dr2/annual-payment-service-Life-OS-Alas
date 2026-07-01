const fs = require('fs');
const path = require('path');
const express = require('express');

const app = express();
const root = __dirname;
const dataDir = path.join(root, 'data');

const files = {
  analytics: path.join(dataDir, 'analytics.json'),
  users: path.join(dataDir, 'users.json'),
  concierge: path.join(dataDir, 'concierge.json'),
  missions: path.join(dataDir, 'missions.json'),
  family: path.join(dataDir, 'family.json')
};

fs.mkdirSync(dataDir, { recursive: true });

function ensureFile(filePath) {
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(filePath, '[]', 'utf8');
  }
}

Object.values(files).forEach(ensureFile);

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return [];
  }
}

function writeJson(filePath, data) {
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8');
}

function pushRecord(filePath, record) {
  const list = readJson(filePath);
  list.push(record);
  writeJson(filePath, list);
}

function analyticsEvent(eventType, pathName, source) {
  pushRecord(files.analytics, {
    id: Date.now().toString(),
    event_type: eventType,
    path: pathName || '',
    source: source || 'direct',
    created_at: new Date().toISOString()
  });
}

app.use(express.json({ limit: '2mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(root, 'public')));

app.get('/health', (_req, res) => {
  res.status(200).json({ ok: true });
});

app.get('/api/health', (_req, res) => {
  res.status(200).json({
    ok: true,
    service: 'lifeos-atlas',
    storage: process.env.DATABASE_URL ? 'postgres-configured-but-json-fallback-active' : 'json-file-persistence',
    db: process.env.DATABASE_URL ? 'configured' : 'not-configured',
    time: new Date().toISOString()
  });
});

app.use((req, _res, next) => {
  if (!req.path.startsWith('/api/health') && req.path !== '/health' && !req.path.startsWith('/assets')) {
    analyticsEvent('page_view', req.path, req.headers.referer || req.headers.origin || 'direct');
  }
  next();
});

app.post('/api/signup', (req, res) => {
  const payload = req.body || {};
  const user = {
    id: Date.now().toString(),
    created_at: new Date().toISOString(),
    ...payload
  };
  pushRecord(files.users, user);
  analyticsEvent('signup_submitted', '/api/signup', payload.email || 'unknown');
  res.status(200).json({ ok: true, user });
});

app.get('/api/concierge', (_req, res) => {
  res.status(200).json({ ok: true, items: readJson(files.concierge).slice().reverse() });
});

app.post('/api/concierge', (req, res) => {
  const { message, context, role } = req.body || {};
  if (!message) return res.status(400).json({ ok: false, error: 'Message required' });

  const item = {
    id: Date.now().toString(),
    message,
    context: context || 'general',
    role: role || 'user',
    created_at: new Date().toISOString()
  };

  pushRecord(files.concierge, item);
  analyticsEvent('concierge_message', '/api/concierge', item.context);
  res.status(200).json({ ok: true, item });
});

app.get('/api/missions', (_req, res) => {
  res.status(200).json({ ok: true, items: readJson(files.missions).slice().reverse() });
});

app.post('/api/missions', (req, res) => {
  const { title, category, status, owner } = req.body || {};
  if (!title) return res.status(400).json({ ok: false, error: 'Title required' });

  const mission = {
    id: Date.now().toString(),
    title,
    category: category || 'general',
    status: status || 'active',
    owner: owner || 'atlas',
    created_at: new Date().toISOString()
  };

  pushRecord(files.missions, mission);
  analyticsEvent('mission_created', '/api/missions', mission.category);
  res.status(200).json({ ok: true, mission });
});

app.get('/api/family', (_req, res) => {
  res.status(200).json({ ok: true, items: readJson(files.family).slice().reverse() });
});

app.post('/api/family', (req, res) => {
  const { name, role, focus, status } = req.body || {};
  if (!name || !role) return res.status(400).json({ ok: false, error: 'Missing required fields' });

  const member = {
    id: Date.now().toString(),
    name,
    role,
    focus: focus || '',
    status: status || 'active',
    created_at: new Date().toISOString()
  };

  pushRecord(files.family, member);
  analyticsEvent('family_member_added', '/api/family', role);
  res.status(200).json({ ok: true, member });
});

app.get('/api/admin/overview', (_req, res) => {
  const analytics = readJson(files.analytics);
  const users = readJson(files.users);
  const concierge = readJson(files.concierge);
  const missions = readJson(files.missions);
  const family = readJson(files.family);

  const eventBreakdownMap = analytics.reduce((acc, item) => {
    acc[item.event_type] = (acc[item.event_type] || 0) + 1;
    return acc;
  }, {});

  const sourceBreakdownMap = analytics.reduce((acc, item) => {
    const key = item.source || 'unknown';
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});

  res.status(200).json({
    ok: true,
    metrics: {
      users: users.length,
      conciergeMessages: concierge.length,
      events: analytics.length,
      missions: missions.length,
      familyMembers: family.length
    },
    recentEvents: analytics.slice(-20).reverse(),
    eventBreakdown: Object.keys(eventBreakdownMap).map(k => ({ eventType: k, count: eventBreakdownMap[k] })),
    sourceBreakdown: Object.keys(sourceBreakdownMap).map(k => ({ source: k, count: sourceBreakdownMap[k] }))
  });
});

app.get('/', (_req, res) => {
  res.sendFile(path.join(root, 'public', 'index.html'));
});

const port = Number(process.env.PORT || 8080);
app.listen(port, () => {
  console.log(LifeOS Atlas listening on );
});

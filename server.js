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

function ensureRuntimeFolders() {
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  for (const file of Object.values(files)) {
    if (!fs.existsSync(file)) fs.writeFileSync(file, '[]', 'utf8');
  }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return []; }
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2), 'utf8');
}

function pushRecord(file, record) {
  const items = readJson(file);
  items.push(record);
  writeJson(file, items);
  return record;
}

function analyticsEvent(event_type, pathValue, source) {
  pushRecord(files.analytics, {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    event_type,
    path: pathValue,
    source: source || 'app',
    created_at: new Date().toISOString()
  });
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
  const { fullName, email, plan, goal, householdSize, source } = req.body || {};
  if (!fullName || !email) return res.status(400).json({ ok: false, error: 'Missing required fields' });
  const users = readJson(files.users);
  const user = {
    id: String(users.length + 1),
    fullName,
    email: String(email).toLowerCase(),
    plan: plan || 'free',
    goal: goal || 'admin-autopilot',
    householdSize: householdSize || '1',
    source: source || 'direct',
    created_at: new Date().toISOString()
  };
  pushRecord(files.users, user);
  analyticsEvent('signup_completed', '/api/signup', user.source);
  pushRecord(files.missions, {
    id: `${Date.now()}`,
    title: `First mission for ${fullName}`,
    module: user.goal,
    priority: 'high',
    owner: fullName,
    notes: 'Auto-generated first mission preview from onboarding.',
    created_at: new Date().toISOString()
  });
  res.status(200).json({ ok: true, user, firstMissionCreated: true });
});

app.post('/api/concierge', (req, res) => {
  const { name, email, topic, message, stage } = req.body || {};
  if (!name || !email || !topic || !message) return res.status(400).json({ ok: false, error: 'Missing required fields' });
  pushRecord(files.concierge, {
    id: `${Date.now()}`,
    name,
    email: String(email).toLowerCase(),
    topic,
    message,
    stage: stage || 'landing',
    created_at: new Date().toISOString()
  });
  analyticsEvent('concierge_submitted', '/api/concierge', stage || 'landing');
  res.status(200).json({ ok: true, message: 'Concierge request received' });
});

app.get('/api/missions', (_req, res) => {
  res.status(200).json({ ok: true, items: readJson(files.missions).slice().reverse() });
});

app.post('/api/missions', (req, res) => {
  const { title, module, priority, owner, notes } = req.body || {};
  if (!title || !module) return res.status(400).json({ ok: false, error: 'Missing required fields' });
  const mission = {
    id: `${Date.now()}`,
    title,
    module,
    priority: priority || 'medium',
    owner: owner || 'Unassigned',
    notes: notes || '',
    created_at: new Date().toISOString()
  };
  pushRecord(files.missions, mission);
  analyticsEvent('mission_created', '/api/missions', module);
  res.status(200).json({ ok: true, mission });
});

app.get('/api/family', (_req, res) => {
  res.status(200).json({ ok: true, items: readJson(files.family).slice().reverse() });
});

app.post('/api/family', (req, res) => {
  const { name, role, focus, status } = req.body || {};
  if (!name || !role) return res.status(400).json({ ok: false, error: 'Missing required fields' });
  const member = {
    id: `${Date.now()}`,
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

app.use(express.static(path.join(root, 'public')));
app.get('/', (_req, res) => res.sendFile(path.join(root, 'public', 'index.html')));

const port = Number(process.env.PORT || 8080);
app.listen(port, () => {
  console.log(`LifeOS Atlas listening on ${port}`);
});

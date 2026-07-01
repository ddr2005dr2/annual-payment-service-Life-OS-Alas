const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const Database = require('better-sqlite3');
const multer = require('multer');

const app = express();
const port = process.env.PORT || 3000;
const dbFile = path.join(__dirname, process.env.DB_FILE || 'data/lifeos-atlas.db');
fs.mkdirSync(path.dirname(dbFile), { recursive: true });
fs.mkdirSync(path.join(__dirname, 'public', 'uploads'), { recursive: true });

const db = new Database(dbFile);
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  first_name TEXT NOT NULL DEFAULT '',
  last_name TEXT NOT NULL DEFAULT '',
  profile_picture TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  token TEXT NOT NULL UNIQUE,
  user_id INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS families (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  owner_user_id INTEGER NOT NULL,
  seat_limit INTEGER NOT NULL DEFAULT 4,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS family_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  family_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  access_role TEXT NOT NULL DEFAULT 'member',
  can_view_finance INTEGER NOT NULL DEFAULT 0,
  can_manage_family INTEGER NOT NULL DEFAULT 0,
  can_manage_promos INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(family_id, user_id)
);
CREATE TABLE IF NOT EXISTS reminders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  family_id INTEGER NOT NULL,
  created_by_user_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  due_date TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL DEFAULT 'admin',
  priority TEXT NOT NULL DEFAULT 'normal',
  notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  family_id INTEGER NOT NULL,
  created_by_user_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  owner TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS contact_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  topic TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS promo_campaigns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  family_id INTEGER,
  created_by_user_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  channel TEXT NOT NULL,
  instruction TEXT NOT NULL,
  hashtags TEXT NOT NULL DEFAULT '',
  scheduled_for TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',
  throttle_per_hour INTEGER NOT NULL DEFAULT 12,
  manual_override INTEGER NOT NULL DEFAULT 0,
  last_action TEXT NOT NULL DEFAULT 'created',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS campaign_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL,
  event_name TEXT NOT NULL,
  event_detail TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor TEXT NOT NULL,
  event_name TEXT NOT NULL,
  event_detail TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS page_hits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  referrer TEXT NOT NULL DEFAULT '',
  user_agent TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`);

function hashPassword(password) {
  return crypto.createHash('sha256').update(password).digest('hex');
}

function parseCookies(req) {
  const header = req.headers.cookie || '';
  const out = {};
  header.split(';').map(v => v.trim()).filter(Boolean).forEach(part => {
    const idx = part.indexOf('=');
    if (idx > -1) out[part.slice(0, idx)] = decodeURIComponent(part.slice(idx + 1));
  });
  return out;
}

function audit(actor, eventName, detail) {
  db.prepare('INSERT INTO audit_log (actor, event_name, event_detail) VALUES (?, ?, ?)').run(actor || 'system', eventName, detail || '');
}

function currentUser(req) {
  const cookies = parseCookies(req);
  const token = cookies[process.env.SESSION_COOKIE_NAME || 'session_token'];
  if (!token) return null;
  const session = db.prepare('SELECT user_id FROM sessions WHERE token=?').get(token);
  if (!session) return null;
  return db.prepare('SELECT id,email,role,first_name,last_name,profile_picture FROM users WHERE id=?').get(session.user_id) || null;
}

function setSession(res, userId) {
  const token = crypto.randomBytes(24).toString('hex');
  db.prepare('INSERT INTO sessions (token, user_id) VALUES (?, ?)').run(token, userId);
  res.setHeader('Set-Cookie', `${process.env.SESSION_COOKIE_NAME || 'session_token'}=${token}; Path=/; HttpOnly; SameSite=Lax`);
}

function clearSession(req, res) {
  const cookies = parseCookies(req);
  const name = process.env.SESSION_COOKIE_NAME || 'session_token';
  if (cookies[name]) db.prepare('DELETE FROM sessions WHERE token=?').run(cookies[name]);
  res.setHeader('Set-Cookie', `${name}=; Path=/; HttpOnly; Max-Age=0; SameSite=Lax`);
}

function ensureAuth(req, res, next) {
  const user = currentUser(req);
  if (!user) return res.status(401).json({ message: 'Authentication required.' });
  req.user = user;
  next();
}

function familyForUser(userId) {
  return db.prepare(`
    SELECT f.*, fm.access_role, fm.can_view_finance, fm.can_manage_family, fm.can_manage_promos
    FROM family_members fm
    JOIN families f ON f.id = fm.family_id
    WHERE fm.user_id = ?
    ORDER BY f.id ASC
    LIMIT 1
  `).get(userId) || null;
}

function seed() {
  const userCount = db.prepare('SELECT COUNT(*) c FROM users').get().c;
  if (!userCount) {
    const info = db.prepare('INSERT INTO users (email,password_hash,role,first_name,last_name) VALUES (?,?,?,?,?)').run('owner@lifeosatlas.com', hashPassword('AtlasDemo123!'), 'admin', 'Atlas', 'Owner');
    const ownerId = info.lastInsertRowid;
    const family = db.prepare('INSERT INTO families (name, owner_user_id, seat_limit) VALUES (?,?,?)').run('Atlas Household', ownerId, 4);
    db.prepare('INSERT INTO family_members (family_id,user_id,access_role,can_view_finance,can_manage_family,can_manage_promos) VALUES (?,?,?,?,?,?)').run(family.lastInsertRowid, ownerId, 'owner', 1, 1, 1);
    db.prepare('INSERT INTO reminders (family_id,created_by_user_id,title,due_date,category,priority,notes) VALUES (?,?,?,?,?,?,?)').run(family.lastInsertRowid, ownerId, 'MVA renewal reminder', '2026-07-12', 'admin', 'high', 'Bring payment method and supporting ID.');
    db.prepare('INSERT INTO tasks (family_id,created_by_user_id,title,owner,notes,status) VALUES (?,?,?,?,?,?)').run(family.lastInsertRowid, ownerId, 'Doctor follow-up prep', 'Atlas', 'Collect referral notes and questions.', 'open');
    db.prepare('INSERT INTO promo_campaigns (family_id,created_by_user_id,title,channel,instruction,hashtags,scheduled_for,status,throttle_per_hour,manual_override,last_action) VALUES (?,?,?,?,?,?,?,?,?,?,?)').run(family.lastInsertRowid, ownerId, 'Free launch awareness', 'social', 'Promote the free-first LifeOS Atlas concierge launch without oversharing and stay within compliant frequency caps.', '#lifeops #familyadmin #tealworkflow', '', 'paused', 8, 1, 'seeded');
    audit('system', 'bootstrap', 'Seeded owner account and starter family workspace.');
  }
}
seed();

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, path.join(__dirname, 'public', 'uploads')),
    filename: (_req, file, cb) => cb(null, `${Date.now()}-${file.originalname.replace(/[^a-zA-Z0-9._-]/g, '-')}`)
  }),
  limits: { fileSize: 2 * 1024 * 1024 }
});

app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));
app.use((req, res, next) => {
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  next();
});

app.use((req, _res, next) => {
  if (req.method === 'GET' && !req.path.startsWith('/api/') && !req.path.startsWith('/uploads/')) {
    db.prepare('INSERT INTO page_hits (path, referrer, user_agent) VALUES (?, ?, ?)').run(req.path, req.headers.referer || '', req.headers['user-agent'] || '');
  }
  next();
});

app.use(express.static(path.join(__dirname, 'public'), { extensions: ['html'] }));

app.get('/health', (_req, res) => {
  res.json({ ok: true, app: 'lifeos-atlas', db: 'sqlite', time: new Date().toISOString() });
});

app.get('/api/auth/me', (req, res) => {
  const user = currentUser(req);
  if (!user) return res.json({ user: null });
  const family = familyForUser(user.id);
  res.json({ user, family });
});

app.post('/api/auth/signup', (req, res) => {
  const { email, password, firstName, lastName } = req.body || {};
  if (!email || !password) return res.status(400).json({ message: 'Email and password are required.' });
  try {
    const info = db.prepare('INSERT INTO users (email,password_hash,role,first_name,last_name) VALUES (?,?,?,?,?)').run(email.trim().toLowerCase(), hashPassword(password), 'admin', firstName || '', lastName || '');
    const userId = info.lastInsertRowid;
    const fam = db.prepare('INSERT INTO families (name, owner_user_id, seat_limit) VALUES (?,?,?)').run((firstName || 'My') + ' Household', userId, 4);
    db.prepare('INSERT INTO family_members (family_id,user_id,access_role,can_view_finance,can_manage_family,can_manage_promos) VALUES (?,?,?,?,?,?)').run(fam.lastInsertRowid, userId, 'owner', 1, 1, 1);
    audit(email, 'signup', 'Created owner account and family workspace.');
    setSession(res, userId);
    res.json({ message: 'Account created.', redirect: './dashboard.html' });
  } catch (error) {
    res.status(400).json({ message: 'Account already exists.' });
  }
});

app.post('/api/auth/login', (req, res) => {
  const { email, password } = req.body || {};
  if (!email || !password) return res.status(400).json({ message: 'Email and password are required.' });
  const user = db.prepare('SELECT * FROM users WHERE email=?').get(email.trim().toLowerCase());
  if (!user || user.password_hash !== hashPassword(password)) return res.status(401).json({ message: 'Invalid login.' });
  setSession(res, user.id);
  audit(email, 'login', 'User login successful.');
  res.json({ message: 'Login successful.', redirect: user.role === 'admin' ? './admin.html' : './dashboard.html' });
});

app.post('/api/auth/logout', (req, res) => {
  const user = currentUser(req);
  clearSession(req, res);
  audit(user?.email || 'unknown', 'logout', 'Session cleared.');
  res.json({ message: 'Logged out.' });
});

app.post('/api/profile/photo', ensureAuth, upload.single('profilePhoto'), (req, res) => {
  if (!req.file) return res.status(400).json({ message: 'Profile image required.' });
  const photoPath = '/uploads/' + req.file.filename;
  db.prepare('UPDATE users SET profile_picture=? WHERE id=?').run(photoPath, req.user.id);
  audit(req.user.email, 'profile-photo', 'Profile picture updated.');
  res.json({ message: 'Profile picture updated.', profile_picture: photoPath });
});

app.post('/api/profile', ensureAuth, (req, res) => {
  const { firstName, lastName } = req.body || {};
  db.prepare('UPDATE users SET first_name=?, last_name=? WHERE id=?').run(firstName || '', lastName || '', req.user.id);
  audit(req.user.email, 'profile-update', 'Updated profile details.');
  res.json({ message: 'Profile updated.' });
});

app.get('/api/family', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.status(404).json({ message: 'Family not found.' });
  const members = db.prepare(`
    SELECT u.id,u.email,u.first_name,u.last_name,u.profile_picture,fm.access_role,fm.can_view_finance,fm.can_manage_family,fm.can_manage_promos
    FROM family_members fm JOIN users u ON u.id = fm.user_id
    WHERE fm.family_id=? ORDER BY fm.id ASC
  `).all(family.id);
  res.json({ family, members });
});

app.post('/api/family/settings', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_family) return res.status(403).json({ message: 'Manage-family permission required.' });
  let seatLimit = Number(req.body?.seatLimit || family.seat_limit);
  if (![4,5].includes(seatLimit)) seatLimit = 4;
  db.prepare('UPDATE families SET seat_limit=? WHERE id=?').run(seatLimit, family.id);
  audit(req.user.email, 'family-settings', 'Seat limit updated to ' + seatLimit);
  res.json({ message: 'Family settings updated.', seatLimit });
});

app.post('/api/family/members', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_family) return res.status(403).json({ message: 'Manage-family permission required.' });
  const memberCount = db.prepare('SELECT COUNT(*) c FROM family_members WHERE family_id=?').get(family.id).c;
  if (memberCount >= family.seat_limit) return res.status(400).json({ message: 'Seat limit reached.' });

  const { email, firstName, lastName, accessRole, canViewFinance, canManageFamily, canManagePromos } = req.body || {};
  if (!email) return res.status(400).json({ message: 'Member email required.' });

  let user = db.prepare('SELECT * FROM users WHERE email=?').get(String(email).trim().toLowerCase());
  if (!user) {
    const tempPassword = crypto.randomBytes(8).toString('hex');
    const created = db.prepare('INSERT INTO users (email,password_hash,role,first_name,last_name) VALUES (?,?,?,?,?)').run(String(email).trim().toLowerCase(), hashPassword(tempPassword), 'member', firstName || '', lastName || '');
    user = db.prepare('SELECT * FROM users WHERE id=?').get(created.lastInsertRowid);
  }

  db.prepare('INSERT INTO family_members (family_id,user_id,access_role,can_view_finance,can_manage_family,can_manage_promos) VALUES (?,?,?,?,?,?)').run(
    family.id,
    user.id,
    accessRole || 'member',
    canViewFinance ? 1 : 0,
    canManageFamily ? 1 : 0,
    canManagePromos ? 1 : 0
  );
  audit(req.user.email, 'family-member-added', 'Added family member ' + user.email);
  res.json({ message: 'Family member added.' });
});

app.get('/api/reminders', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  const items = family ? db.prepare('SELECT * FROM reminders WHERE family_id=? ORDER BY due_date ASC, id DESC').all(family.id) : [];
  res.json({ items });
});

app.post('/api/reminders', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.status(404).json({ message: 'Family not found.' });
  const { title, dueDate, category, priority, notes } = req.body || {};
  if (!title || !dueDate) return res.status(400).json({ message: 'Title and due date are required.' });
  db.prepare('INSERT INTO reminders (family_id,created_by_user_id,title,due_date,category,priority,notes) VALUES (?,?,?,?,?,?,?)').run(family.id, req.user.id, title, dueDate, category || 'admin', priority || 'normal', notes || '');
  audit(req.user.email, 'reminder-created', 'Reminder created: ' + title);
  res.json({ message: 'Reminder saved.' });
});

app.get('/api/tasks', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  const items = family ? db.prepare('SELECT * FROM tasks WHERE family_id=? ORDER BY id DESC').all(family.id) : [];
  res.json({ items });
});

app.post('/api/tasks', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.status(404).json({ message: 'Family not found.' });
  const { title, owner, notes } = req.body || {};
  if (!title) return res.status(400).json({ message: 'Task title required.' });
  db.prepare('INSERT INTO tasks (family_id,created_by_user_id,title,owner,notes,status) VALUES (?,?,?,?,?,?)').run(family.id, req.user.id, title, owner || '', notes || '', 'open');
  audit(req.user.email, 'task-created', 'Task created: ' + title);
  res.json({ message: 'Task saved.' });
});

app.post('/api/contact', (req, res) => {
  const { name, email, topic, message } = req.body || {};
  if (!name || !email || !topic || !message) return res.status(400).json({ message: 'All contact fields are required.' });
  db.prepare('INSERT INTO contact_messages (name,email,topic,message) VALUES (?,?,?,?)').run(name, email, topic, message);
  audit(email, 'contact-message', 'Contact form submitted: ' + topic);
  res.json({ message: 'Message received.' });
});

app.get('/api/promos', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.json({ items: [] });
  const items = db.prepare('SELECT * FROM promo_campaigns WHERE family_id=? ORDER BY id DESC').all(family.id);
  res.json({ items });
});

app.post('/api/promos', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_promos) return res.status(403).json({ message: 'Manage-promo permission required.' });
  const { title, channel, instruction, hashtags, scheduledFor, throttlePerHour } = req.body || {};
  if (!title || !channel || !instruction) return res.status(400).json({ message: 'Title, channel, and instruction are required.' });
  const throttle = Math.max(1, Math.min(24, Number(throttlePerHour || 8)));
  const info = db.prepare('INSERT INTO promo_campaigns (family_id,created_by_user_id,title,channel,instruction,hashtags,scheduled_for,status,throttle_per_hour,manual_override,last_action) VALUES (?,?,?,?,?,?,?,?,?,?,?)').run(family.id, req.user.id, title, channel, instruction, hashtags || '', scheduledFor || '', 'scheduled', throttle, 0, 'scheduled');
  db.prepare('INSERT INTO campaign_events (campaign_id,event_name,event_detail) VALUES (?,?,?)').run(info.lastInsertRowid, 'scheduled', 'Campaign scheduled with throttling safeguard.');
  audit(req.user.email, 'promo-created', 'Campaign created: ' + title);
  res.json({ message: 'Promotion scheduled.' });
});

app.post('/api/promos/:id/action', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_promos) return res.status(403).json({ message: 'Manage-promo permission required.' });
  const action = String(req.body?.action || '').toLowerCase();
  const allowed = ['pause','resume','stop','manual-run'];
  if (!allowed.includes(action)) return res.status(400).json({ message: 'Invalid promo action.' });
  const status = action === 'resume' ? 'scheduled' : action === 'manual-run' ? 'manual-running' : action;
  db.prepare('UPDATE promo_campaigns SET status=?, manual_override=?, last_action=? WHERE id=?').run(status, action === 'manual-run' ? 1 : 0, action, req.params.id);
  db.prepare('INSERT INTO campaign_events (campaign_id,event_name,event_detail) VALUES (?,?,?)').run(req.params.id, action, 'Manual control action executed.');
  audit(req.user.email, 'promo-action', `Campaign ${req.params.id} -> ${action}`);
  res.json({ message: 'Promotion action applied.' });
});

app.get('/api/stats', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  const totalSignups = db.prepare('SELECT COUNT(*) c FROM users').get().c;
  const pageViews = db.prepare('SELECT COUNT(*) c FROM page_hits').get().c;
  const dailyVisitors = db.prepare("SELECT COUNT(DISTINCT substr(user_agent,1,60) || '|' || substr(referrer,1,60)) c FROM page_hits WHERE created_at >= datetime('now','-1 day')").get().c;
  const reminders = family ? db.prepare('SELECT COUNT(*) c FROM reminders WHERE family_id=?').get(family.id).c : 0;
  const tasks = family ? db.prepare('SELECT COUNT(*) c FROM tasks WHERE family_id=? AND status=?').get(family.id, 'open').c : 0;
  const campaigns = family ? db.prepare('SELECT COUNT(*) c FROM promo_campaigns WHERE family_id=?').get(family.id).c : 0;
  const recentActivity = db.prepare('SELECT event_name AS type, event_detail AS detail, created_at FROM audit_log ORDER BY id DESC LIMIT 20').all();
  res.json({
    totalSignups,
    pageViews,
    dailyVisitors,
    campaigns,
    reminders,
    openTasks: tasks,
    recentActivity,
    trafficSources: db.prepare('SELECT COALESCE(NULLIF(referrer,\'\'),\'direct\') AS source, COUNT(*) AS hits FROM page_hits GROUP BY source ORDER BY hits DESC LIMIT 8').all()
  });
});

app.get('/api/admin/overview', ensureAuth, (req, res) => {
  if (req.user.role !== 'admin') return res.status(403).json({ message: 'Admin only.' });
  res.json({
    users: db.prepare('SELECT COUNT(*) c FROM users').get().c,
    families: db.prepare('SELECT COUNT(*) c FROM families').get().c,
    familySeats: db.prepare('SELECT COALESCE(SUM(seat_limit),0) c FROM families').get().c,
    campaigns: db.prepare('SELECT COUNT(*) c FROM promo_campaigns').get().c,
    liveEvents: db.prepare('SELECT event_name AS type, event_detail AS detail, created_at FROM audit_log ORDER BY id DESC LIMIT 25').all(),
    contactMessages: db.prepare('SELECT COUNT(*) c FROM contact_messages').get().c,
    health: 'Healthy'
  });
});

app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api/')) return next();
  if (req.path === '/' || req.path === '/index' || req.path === '/index.html') {
    return res.sendFile(path.join(__dirname, 'public', 'index.html'));
  }
  next();
});

app.listen(port, () => {
  console.log(`LifeOS Atlas listening on ${port}`);
});
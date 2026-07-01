const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const multer = require('multer');

const app = express();
const port = process.env.PORT || 3000;
const publicDir = path.join(__dirname, 'public');
const uploadsDir = path.join(__dirname, 'uploads');
if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir, { recursive: true });

const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, uploadsDir),
  filename: (_req, file, cb) => {
    const ext = path.extname(file.originalname || '').toLowerCase() || '.bin';
    cb(null, Date.now() + '-' + crypto.randomBytes(6).toString('hex') + ext);
  }
});
const upload = multer({ storage });

app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));
app.use('/uploads', express.static(uploadsDir));
app.use(express.static(publicDir));

const state = {
  users: [{ id: 1, email: 'admin@lifeos.local', password: 'admin', role: 'admin', first_name: 'LifeOS', last_name: 'Admin', profile_picture: '' }],
  sessions: new Map(),
  pageHits: [],
  reminders: [],
  tasks: [],
  promos: [],
  campaignEvents: [],
  contactMessages: [],
  auditLog: [],
  family: { id: 1, name: 'Atlas Family', seat_limit: 4, can_manage_family: 1, can_manage_promos: 1, can_view_finance: 1 },
  familyMembers: [{ family_id: 1, user_id: 1, access_role: 'owner', can_view_finance: 1, can_manage_family: 1, can_manage_promos: 1 }],
  nextIds: { user: 2, reminder: 1, task: 1, promo: 1, contact: 1 }
};

const nowIso = () => new Date().toISOString();

function audit(email, type, detail) {
  state.auditLog.unshift({ id: state.auditLog.length + 1, email: email || 'anonymous', type, detail, created_at: nowIso() });
  state.auditLog = state.auditLog.slice(0, 200);
}

function parseCookies(req) {
  const header = req.headers.cookie || '';
  return header.split(';').reduce((acc, part) => {
    const idx = part.indexOf('=');
    if (idx === -1) return acc;
    acc[part.slice(0, idx).trim()] = decodeURIComponent(part.slice(idx + 1).trim());
    return acc;
  }, {});
}

function setSession(res, user) {
  const token = crypto.randomBytes(24).toString('hex');
  state.sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `lifeos_session=${token}; Path=/; HttpOnly; SameSite=Lax`);
}

function clearSession(req, res) {
  const cookies = parseCookies(req);
  if (cookies.lifeos_session) state.sessions.delete(cookies.lifeos_session);
  res.setHeader('Set-Cookie', 'lifeos_session=; Path=/; HttpOnly; Max-Age=0; SameSite=Lax');
}

function getUserFromSession(req) {
  const cookies = parseCookies(req);
  const token = cookies.lifeos_session;
  if (!token) return null;
  const userId = state.sessions.get(token);
  if (!userId) return null;
  return state.users.find(u => u.id === userId) || null;
}

function ensureAuth(req, res, next) {
  const user = getUserFromSession(req);
  if (!user) return res.status(401).json({ message: 'Authentication required.' });
  req.user = user;
  next();
}

function publicUser(user) {
  return { id: user.id, email: user.email, role: user.role, firstName: user.first_name || '', lastName: user.last_name || '', profile_picture: user.profile_picture || '' };
}

function familyForUser(userId) {
  const membership = state.familyMembers.find(m => m.user_id === userId);
  if (!membership) return null;
  return { id: state.family.id, name: state.family.name, seat_limit: state.family.seat_limit, can_manage_family: membership.can_manage_family, can_manage_promos: membership.can_manage_promos, can_view_finance: membership.can_view_finance };
}

app.use((req, _res, next) => {
  if (!req.path.startsWith('/api/') && !req.path.startsWith('/uploads/')) {
    state.pageHits.push({ path: req.path, referrer: req.headers.referer || '', user_agent: req.headers['user-agent'] || '', created_at: nowIso() });
    if (state.pageHits.length > 1000) state.pageHits.shift();
  }
  next();
});

app.get('/health', (_req, res) => res.json({ ok: true, service: 'lifeos-atlas', storage: 'in-memory', time: nowIso() }));
app.get('/api/health', (_req, res) => res.json({ ok: true, service: 'lifeos-atlas', storage: 'in-memory', time: nowIso() }));

app.post('/api/auth/signup', (req, res) => {
  const email = String(req.body?.email || '').trim().toLowerCase();
  const password = String(req.body?.password || '').trim();
  const firstName = String(req.body?.firstName || '').trim();
  const lastName = String(req.body?.lastName || '').trim();
  if (!email || !password) return res.status(400).json({ message: 'Email and password required.' });
  if (state.users.some(u => u.email === email)) return res.status(409).json({ message: 'Account already exists.' });
  const user = { id: state.nextIds.user++, email, password, role: 'member', first_name: firstName, last_name: lastName, profile_picture: '' };
  state.users.push(user);
  state.familyMembers.push({ family_id: 1, user_id: user.id, access_role: 'member', can_view_finance: 0, can_manage_family: 0, can_manage_promos: 0 });
  audit(email, 'signup', 'Account created.');
  setSession(res, user);
  res.json({ message: 'Account created.', user: publicUser(user) });
});

app.post('/api/auth/login', (req, res) => {
  const email = String(req.body?.email || '').trim().toLowerCase();
  const password = String(req.body?.password || '').trim();
  const user = state.users.find(u => u.email === email && u.password === password);
  if (!user) return res.status(401).json({ message: 'Invalid credentials.' });
  setSession(res, user);
  audit(email, 'login', 'User logged in.');
  res.json({ message: 'Logged in.', user: publicUser(user) });
});

app.post('/api/auth/logout', (req, res) => {
  clearSession(req, res);
  audit('logout', 'logout', 'Session cleared.');
  res.json({ message: 'Logged out.' });
});

app.get('/api/auth/me', ensureAuth, (req, res) => res.json({ user: publicUser(req.user) }));

app.post('/api/profile/photo', ensureAuth, upload.single('profilePhoto'), (req, res) => {
  if (!req.file) return res.status(400).json({ message: 'Profile image required.' });
  const photoPath = '/uploads/' + req.file.filename;
  req.user.profile_picture = photoPath;
  audit(req.user.email, 'profile-photo', 'Profile picture updated.');
  res.json({ message: 'Profile picture updated.', profile_picture: photoPath });
});

app.post('/api/profile', ensureAuth, (req, res) => {
  req.user.first_name = String(req.body?.firstName || '').trim();
  req.user.last_name = String(req.body?.lastName || '').trim();
  audit(req.user.email, 'profile-update', 'Updated profile details.');
  res.json({ message: 'Profile updated.' });
});

app.get('/api/family', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.status(404).json({ message: 'Family not found.' });
  const members = state.familyMembers.filter(m => m.family_id === family.id).map(m => {
    const u = state.users.find(x => x.id === m.user_id);
    return { id: u.id, email: u.email, first_name: u.first_name, last_name: u.last_name, profile_picture: u.profile_picture, access_role: m.access_role, can_view_finance: m.can_view_finance, can_manage_family: m.can_manage_family, can_manage_promos: m.can_manage_promos };
  });
  res.json({ family, members });
});

app.post('/api/family/settings', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_family) return res.status(403).json({ message: 'Manage-family permission required.' });
  let seatLimit = Number(req.body?.seatLimit || state.family.seat_limit);
  if (![4, 5].includes(seatLimit)) seatLimit = 4;
  state.family.seat_limit = seatLimit;
  audit(req.user.email, 'family-settings', 'Seat limit updated to ' + seatLimit);
  res.json({ message: 'Family settings updated.', seatLimit });
});

app.post('/api/family/members', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_family) return res.status(403).json({ message: 'Manage-family permission required.' });
  const memberCount = state.familyMembers.filter(m => m.family_id === family.id).length;
  if (memberCount >= state.family.seat_limit) return res.status(400).json({ message: 'Seat limit reached.' });
  const email = String(req.body?.email || '').trim().toLowerCase();
  if (!email) return res.status(400).json({ message: 'Member email required.' });
  let user = state.users.find(u => u.email === email);
  if (!user) {
    user = { id: state.nextIds.user++, email, password: crypto.randomBytes(8).toString('hex'), role: 'member', first_name: String(req.body?.firstName || '').trim(), last_name: String(req.body?.lastName || '').trim(), profile_picture: '' };
    state.users.push(user);
  }
  if (state.familyMembers.some(m => m.family_id === family.id && m.user_id === user.id)) return res.status(409).json({ message: 'Member already exists.' });
  state.familyMembers.push({ family_id: family.id, user_id: user.id, access_role: String(req.body?.accessRole || 'member'), can_view_finance: req.body?.canViewFinance ? 1 : 0, can_manage_family: req.body?.canManageFamily ? 1 : 0, can_manage_promos: req.body?.canManagePromos ? 1 : 0 });
  audit(req.user.email, 'family-member-added', 'Added family member ' + user.email);
  res.json({ message: 'Family member added.' });
});

app.get('/api/reminders', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  const items = family ? state.reminders.filter(x => x.family_id === family.id).sort((a, b) => String(a.due_date).localeCompare(String(b.due_date))) : [];
  res.json({ items });
});

app.post('/api/reminders', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.status(404).json({ message: 'Family not found.' });
  const title = String(req.body?.title || '').trim();
  const dueDate = String(req.body?.dueDate || '').trim();
  if (!title || !dueDate) return res.status(400).json({ message: 'Title and due date are required.' });
  state.reminders.unshift({ id: state.nextIds.reminder++, family_id: family.id, created_by_user_id: req.user.id, title, due_date: dueDate, category: String(req.body?.category || 'admin'), priority: String(req.body?.priority || 'normal'), notes: String(req.body?.notes || ''), created_at: nowIso() });
  audit(req.user.email, 'reminder-created', 'Reminder created: ' + title);
  res.json({ message: 'Reminder saved.' });
});

app.get('/api/tasks', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  const items = family ? state.tasks.filter(x => x.family_id === family.id) : [];
  res.json({ items });
});

app.post('/api/tasks', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.status(404).json({ message: 'Family not found.' });
  const title = String(req.body?.title || '').trim();
  if (!title) return res.status(400).json({ message: 'Task title required.' });
  state.tasks.unshift({ id: state.nextIds.task++, family_id: family.id, created_by_user_id: req.user.id, title, owner: String(req.body?.owner || ''), notes: String(req.body?.notes || ''), status: 'open', created_at: nowIso() });
  audit(req.user.email, 'task-created', 'Task created: ' + title);
  res.json({ message: 'Task saved.' });
});

app.post('/api/contact', (req, res) => {
  const name = String(req.body?.name || '').trim();
  const email = String(req.body?.email || '').trim();
  const topic = String(req.body?.topic || '').trim();
  const message = String(req.body?.message || '').trim();
  if (!name || !email || !topic || !message) return res.status(400).json({ message: 'All contact fields are required.' });
  state.contactMessages.unshift({ id: state.nextIds.contact++, name, email, topic, message, created_at: nowIso() });
  audit(email, 'contact-message', 'Contact form submitted: ' + topic);
  res.json({ message: 'Message received.' });
});

app.get('/api/promos', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family) return res.json({ items: [] });
  res.json({ items: state.promos.filter(x => x.family_id === family.id) });
});

app.post('/api/promos', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_promos) return res.status(403).json({ message: 'Manage-promo permission required.' });
  const title = String(req.body?.title || '').trim();
  const channel = String(req.body?.channel || '').trim();
  const instruction = String(req.body?.instruction || '').trim();
  if (!title || !channel || !instruction) return res.status(400).json({ message: 'Title, channel, and instruction are required.' });
  const throttle = Math.max(1, Math.min(24, Number(req.body?.throttlePerHour || 8)));
  const promo = { id: state.nextIds.promo++, family_id: family.id, created_by_user_id: req.user.id, title, channel, instruction, hashtags: String(req.body?.hashtags || ''), scheduled_for: String(req.body?.scheduledFor || ''), status: 'scheduled', throttle_per_hour: throttle, manual_override: 0, last_action: 'scheduled', created_at: nowIso() };
  state.promos.unshift(promo);
  state.campaignEvents.unshift({ campaign_id: promo.id, event_name: 'scheduled', event_detail: 'Campaign scheduled with throttling safeguard.', created_at: nowIso() });
  audit(req.user.email, 'promo-created', 'Campaign created: ' + title);
  res.json({ message: 'Promotion scheduled.' });
});

app.post('/api/promos/:id/action', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  if (!family || !family.can_manage_promos) return res.status(403).json({ message: 'Manage-promo permission required.' });
  const action = String(req.body?.action || '').toLowerCase();
  const allowed = ['pause', 'resume', 'stop', 'manual-run'];
  if (!allowed.includes(action)) return res.status(400).json({ message: 'Invalid promo action.' });
  const promo = state.promos.find(x => String(x.id) === String(req.params.id));
  if (!promo) return res.status(404).json({ message: 'Campaign not found.' });
  promo.status = action === 'resume' ? 'scheduled' : action === 'manual-run' ? 'manual-running' : action;
  promo.manual_override = action === 'manual-run' ? 1 : 0;
  promo.last_action = action;
  state.campaignEvents.unshift({ campaign_id: promo.id, event_name: action, event_detail: 'Manual control action executed.', created_at: nowIso() });
  audit(req.user.email, 'promo-action', `Campaign ${req.params.id} -> ${action}`);
  res.json({ message: 'Promotion action applied.' });
});

app.get('/api/stats', ensureAuth, (req, res) => {
  const family = familyForUser(req.user.id);
  const recentActivity = state.auditLog.slice(0, 20).map(x => ({ type: x.type, detail: x.detail, createdAt: x.created_at }));
  const familyId = family ? family.id : null;
  const reminders = familyId ? state.reminders.filter(x => x.family_id === familyId).length : 0;
  const tasks = familyId ? state.tasks.filter(x => x.family_id === familyId && x.status === 'open').length : 0;
  const campaigns = familyId ? state.promos.filter(x => x.family_id === familyId).length : 0;
  const sourceCounts = {};
  for (const hit of state.pageHits) {
    const key = (hit.referrer || '').trim() || 'direct';
    sourceCounts[key] = (sourceCounts[key] || 0) + 1;
  }
  const trafficSources = Object.entries(sourceCounts).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([source, hits]) => ({ source, hits }));
  const oneDayAgo = Date.now() - 24 * 60 * 60 * 1000;
  const dailyVisitors = new Set(state.pageHits.filter(hit => new Date(hit.created_at).getTime() >= oneDayAgo).map(hit => `${String(hit.user_agent).slice(0,60)}|${String(hit.referrer).slice(0,60)}`)).size;
  res.json({ totalSignups: state.users.length, pageViews: state.pageHits.length, dailyVisitors, campaigns, reminders, openTasks: tasks, recentActivity, trafficSources });
});

app.get('/api/admin/overview', ensureAuth, (req, res) => {
  if (req.user.role !== 'admin') return res.status(403).json({ message: 'Admin only.' });
  res.json({ users: state.users.length, families: 1, familySeats: state.family.seat_limit, campaigns: state.promos.length, liveEvents: state.auditLog.slice(0, 25).map(x => ({ type: x.type, detail: x.detail, created_at: x.created_at })), contactMessages: state.contactMessages.length, health: 'Healthy' });
});

app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api/')) return next();
  if (req.path === '/' || req.path === '/index' || req.path === '/index.html') return res.sendFile(path.join(publicDir, 'index.html'));
  next();
});

app.listen(port, () => console.log(`LifeOS Atlas listening on ${port}`));
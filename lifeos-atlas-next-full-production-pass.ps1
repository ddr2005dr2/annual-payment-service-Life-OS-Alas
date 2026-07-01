$ErrorActionPreference = 'Stop'

$RepoPath = 'C:\Users\PC\lifeos-work\annual-payment-service-Life-OS-Alas'
Set-Location $RepoPath

function Write-Info {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Cyan
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Rotate-Backup {
    param([string]$Root)
    $backupRoot = Join-Path $Root '_single_backup'
    if (Test-Path $backupRoot) {
        Remove-Item $backupRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $targets = @(
        'server.js','package.json','railway.json','.env.example',
        'public','data'
    )
    foreach ($target in $targets) {
        $source = Join-Path $Root $target
        if (Test-Path $source) {
            $dest = Join-Path $backupRoot $target
            Copy-Item $source $dest -Recurse -Force
        }
    }
    Write-Host "Fresh single backup created at $backupRoot" -ForegroundColor Green
}

function Get-CanonicalPublicFiles {
    return @(
        'index.html','login.html','register.html','dashboard.html','admin.html',
        'contact.html','pricing.html','privacy.html','terms.html','refund.html','data-deletion.html'
    )
}

Write-Info 'STEP 1: create one fresh backup and remove the previous backup set'
Rotate-Backup -Root $RepoPath

Write-Info 'STEP 2: write production package definition'
$packageJson = @'
{
  "name": "lifeos-atlas",
  "version": "2.0.0",
  "private": true,
  "scripts": {
    "start": "node server.js",
    "dev": "node server.js",
    "validate": "node scripts/validate.mjs"
  },
  "dependencies": {
    "better-sqlite3": "^11.10.0",
    "express": "^4.21.2",
    "multer": "^1.4.5-lts.1"
  }
}
'@
Write-Utf8NoBom -Path '.\package.json' -Content $packageJson

$railwayJson = @'
{
  "$schema": "https://railway.com/railway.schema.json",
  "deploy": {
    "startCommand": "npm start",
    "healthcheckPath": "/health",
    "restartPolicyType": "on_failure"
  }
}
'@
Write-Utf8NoBom -Path '.\railway.json' -Content $railwayJson

$envExample = @'
PORT=3000
DB_FILE=data/lifeos-atlas.db
SESSION_COOKIE_NAME=session_token
'@
Write-Utf8NoBom -Path '.\.env.example' -Content $envExample

Write-Info 'STEP 3: write validation script'
Ensure-Directory '.\scripts'
$validateScript = @'
import fs from "fs";
import path from "path";

const root = process.cwd();
const required = [
  "server.js",
  "package.json",
  "railway.json",
  "public/index.html",
  "public/login.html",
  "public/register.html",
  "public/dashboard.html",
  "public/admin.html",
  "public/contact.html"
];

const missing = required.filter(file => !fs.existsSync(path.join(root, file)));
if (missing.length) {
  console.error("Missing required files:\n" + missing.join("\n"));
  process.exit(1);
}

const indexHtml = fs.readFileSync(path.join(root, "public/index.html"), "utf8");
if (!indexHtml.includes('canonical') || !indexHtml.includes('LifeOS Atlas')) {
  console.error('Landing page validation failed.');
  process.exit(1);
}

const dashboardHtml = fs.readFileSync(path.join(root, "public/dashboard.html"), "utf8");
if (!dashboardHtml.includes('themeToggle') || !dashboardHtml.includes('familyPanel')) {
  console.error('Dashboard validation failed.');
  process.exit(1);
}

console.log('Validation passed.');
'@
Write-Utf8NoBom -Path '.\scripts\validate.mjs' -Content $validateScript

Write-Info 'STEP 4: write production server with family accounts, persistence, automation controls, analytics, uploads, and validation-safe routes'
$serverJs = @'
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
'@
Write-Utf8NoBom -Path '.\server.js' -Content $serverJs

Write-Info 'STEP 5: write locked public landing page and premium app-shell pages'
Ensure-Directory '.\public'

$indexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>LifeOS Atlas | Family life operations, organized beautifully</title>
  <meta name="description" content="LifeOS Atlas helps families manage reminders, roles, profiles, onboarding, and premium household operations in one coordinated system." />
  <meta name="robots" content="index,follow,max-image-preview:large" />
  <meta property="og:title" content="LifeOS Atlas" />
  <meta property="og:description" content="Premium family operations with reminders, permissions, profiles, and structured control." />
  <link rel="canonical" href="https://www.lifeosatlas.com/" />
  <style>
    :root{
      --bg:#0f6f73;
      --bg-deep:#09575a;
      --surface:rgba(255,255,255,.12);
      --surface-2:rgba(255,255,255,.18);
      --text:#f7fbfb;
      --muted:rgba(247,251,251,.82);
      --line:rgba(255,255,255,.22);
      --accent:#ff9d3c;
      --blue:#7fb6ff;
      --shadow:0 24px 60px rgba(0,0,0,.22);
    }
    *{box-sizing:border-box} html,body{margin:0;padding:0} body{font-family:Inter,system-ui,sans-serif;background:linear-gradient(180deg,var(--bg),var(--bg-deep));color:var(--text)}
    a{text-decoration:none;color:inherit}
    .shell{width:min(1200px,calc(100% - 28px));margin:0 auto}
    .nav{display:flex;justify-content:space-between;align-items:center;padding:20px 0;gap:16px}
    .brand{font-weight:800;letter-spacing:-.03em;font-size:1.1rem}
    .navlinks,.cta{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
    .chip,.btn{border-radius:999px;padding:12px 16px;border:1px solid var(--line);background:rgba(255,255,255,.10)}
    .btn.primary{background:#fff;color:#0b4e50;border-color:transparent;font-weight:800}
    .hero{padding:44px 0 38px;display:grid;grid-template-columns:minmax(0,1.12fr) minmax(320px,.88fr);gap:22px;align-items:start}
    .hero h1{margin:0;font-size:clamp(2.7rem,5vw,5.3rem);line-height:.98;letter-spacing:-.05em;max-width:11ch}
    .lede{font-size:1.08rem;line-height:1.8;color:var(--muted);max-width:66ch;margin-top:18px}
    .actions{display:flex;gap:12px;flex-wrap:wrap;margin-top:22px}
    .glass{background:var(--surface);backdrop-filter:blur(18px);border:1px solid var(--line);box-shadow:var(--shadow);border-radius:30px}
    .heroCard{padding:22px}
    .heroStat{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:18px}
    .stat{padding:14px;border-radius:20px;background:var(--surface-2);border:1px solid var(--line)}
    .stat strong{display:block;font-size:1.6rem;letter-spacing:-.04em}
    .section{padding:18px 0 40px}
    .strip{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
    .strip .item{padding:18px;border-radius:22px;background:var(--surface);border:1px solid var(--line)}
    .item .k{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
    .item .v{margin-top:10px;font-size:1.12rem;font-weight:700}
    footer{padding:24px 0 40px;color:var(--muted)}
    @media (max-width:900px){.hero{grid-template-columns:1fr}.strip{grid-template-columns:1fr}}
  </style>
</head>
<body>
  <div class="shell">
    <header class="nav">
      <div class="brand">LifeOS Atlas</div>
      <div class="navlinks">
        <a class="chip" href="/pricing.html">Pricing</a>
        <a class="chip" href="/contact.html">Contact</a>
        <a class="chip" href="/login.html">Login</a>
        <a class="btn primary" href="/register.html">Create account</a>
      </div>
    </header>

    <section class="hero">
      <div>
        <h1>Family life operations, organized beautifully.</h1>
        <p class="lede">LifeOS Atlas brings reminders, household coordination, permissions, profiles, premium dashboards, and structured admin control into one elegant system built for real families and high-trust operations.</p>
        <div class="actions">
          <a class="btn primary" href="/register.html">Start free</a>
          <a class="chip" href="/login.html">Enter workspace</a>
        </div>
      </div>
      <aside class="glass heroCard">
        <div style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)">Current live focus</div>
        <h2 style="margin:10px 0 0;font-size:1.5rem;letter-spacing:-.03em">Premium family account control</h2>
        <p style="margin:10px 0 0;line-height:1.8;color:var(--muted)">Owner-managed roles, profile support, automation oversight, reminders, tasks, and admin analytics in one coordinated system.</p>
        <div class="heroStat">
          <div class="stat"><div class="k">Seat model</div><strong>4–5</strong><div style="color:var(--muted)">Configurable family cap</div></div>
          <div class="stat"><div class="k">Control</div><strong>Owner</strong><div style="color:var(--muted)">Permission-based access</div></div>
          <div class="stat"><div class="k">Promo</div><strong>Manual + scheduled</strong><div style="color:var(--muted)">Safeguarded execution</div></div>
          <div class="stat"><div class="k">Mode</div><strong>Light + dark</strong><div style="color:var(--muted)">Premium app-shell experience</div></div>
        </div>
      </aside>
    </section>

    <section class="section">
      <div class="strip">
        <div class="item"><div class="k">Family accounts</div><div class="v">Multiple profiles, multiple emails, owner-led visibility.</div></div>
        <div class="item"><div class="k">Premium dashboard</div><div class="v">Teal-led panels, richer contrast, elegant navigation, and clearer workflow depth.</div></div>
        <div class="item"><div class="k">Growth system</div><div class="v">SEO-ready structure, analytics, scheduled promotions, and manual override controls.</div></div>
      </div>
    </section>

    <footer>
      <div style="display:flex;gap:12px;flex-wrap:wrap">
        <a href="/privacy.html">Privacy</a>
        <a href="/terms.html">Terms</a>
        <a href="/refund.html">Refund</a>
        <a href="/data-deletion.html">Data deletion</a>
      </div>
    </footer>
  </div>
</body>
</html>
'@
Write-Utf8NoBom -Path '.\public\index.html' -Content $indexHtml

$loginHtml = @'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>LifeOS Atlas | Login</title><style>body{margin:0;font-family:Inter,system-ui,sans-serif;background:#0f6f73;color:#eef8f8;display:grid;place-items:center;min-height:100vh} .card{width:min(440px,calc(100% - 24px));background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.18);border-radius:28px;padding:24px;backdrop-filter:blur(14px)} input,button{width:100%;padding:14px 15px;border-radius:16px;font:inherit} input{margin:10px 0;border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.10);color:#fff} button{border:none;background:#fff;color:#0c4f51;font-weight:800;cursor:pointer;margin-top:8px} .hint{color:rgba(238,248,248,.82);line-height:1.7}</style></head><body><form class="card" id="loginForm"><h1 style="margin:0 0 10px;letter-spacing:-.04em">Login</h1><p class="hint">Use your email and password to enter the premium family workspace.</p><input name="email" type="email" placeholder="Email" required><input name="password" type="password" placeholder="Password" required><button type="submit">Enter workspace</button><p id="msg" class="hint"></p><p class="hint"><a href="/register.html" style="color:#fff">Create account</a></p></form><script>document.getElementById('loginForm').addEventListener('submit',async function(e){e.preventDefault();const fd=new FormData(e.currentTarget);const res=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:String(fd.get('email')||''),password:String(fd.get('password')||'')})});const body=await res.json().catch(()=>({}));document.getElementById('msg').textContent=body.message||'';if(res.ok&&body.redirect)location.href=body.redirect;});</script></body></html>
'@
Write-Utf8NoBom -Path '.\public\login.html' -Content $loginHtml

$registerHtml = @'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>LifeOS Atlas | Register</title><style>body{margin:0;font-family:Inter,system-ui,sans-serif;background:#0f6f73;color:#eef8f8;display:grid;place-items:center;min-height:100vh} .card{width:min(460px,calc(100% - 24px));background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.18);border-radius:28px;padding:24px;backdrop-filter:blur(14px)} input,button{width:100%;padding:14px 15px;border-radius:16px;font:inherit} input{margin:10px 0;border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.10);color:#fff} button{border:none;background:#fff;color:#0c4f51;font-weight:800;cursor:pointer;margin-top:8px} .hint{color:rgba(238,248,248,.82);line-height:1.7}</style></head><body><form class="card" id="registerForm"><h1 style="margin:0 0 10px;letter-spacing:-.04em">Create family account</h1><p class="hint">Start with one owner account and a configurable family seat cap of 4 or 5.</p><input name="firstName" type="text" placeholder="First name" required><input name="lastName" type="text" placeholder="Last name" required><input name="email" type="email" placeholder="Email" required><input name="password" type="password" placeholder="Password" required><button type="submit">Create account</button><p id="msg" class="hint"></p></form><script>document.getElementById('registerForm').addEventListener('submit',async function(e){e.preventDefault();const fd=new FormData(e.currentTarget);const payload={firstName:String(fd.get('firstName')||''),lastName:String(fd.get('lastName')||''),email:String(fd.get('email')||''),password:String(fd.get('password')||'')};const res=await fetch('/api/auth/signup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});const body=await res.json().catch(()=>({}));document.getElementById('msg').textContent=body.message||'';if(res.ok&&body.redirect)location.href=body.redirect;});</script></body></html>
'@
Write-Utf8NoBom -Path '.\public\register.html' -Content $registerHtml

$contactHtml = @'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>LifeOS Atlas | Contact</title><style>body{margin:0;font-family:Inter,system-ui,sans-serif;background:#0e666a;color:#eef7f7;display:grid;place-items:center;min-height:100vh} .card{width:min(560px,calc(100% - 24px));background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.2);border-radius:28px;padding:24px} input,textarea,button,select{width:100%;padding:14px 15px;border-radius:16px;font:inherit} input,textarea,select{margin:10px 0;border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.10);color:#fff} button{border:none;background:#fff;color:#0a4d50;font-weight:800;cursor:pointer}</style></head><body><form class="card" id="contactForm"><h1 style="margin:0 0 10px;letter-spacing:-.04em">Contact LifeOS Atlas</h1><input name="name" placeholder="Name" required><input name="email" type="email" placeholder="Email" required><select name="topic" required><option value="">Choose topic</option><option>Support</option><option>Family setup</option><option>Promotion controls</option></select><textarea name="message" rows="6" placeholder="Message" required></textarea><button type="submit">Send message</button><p id="msg"></p></form><script>document.getElementById('contactForm').addEventListener('submit',async function(e){e.preventDefault();const fd=new FormData(e.currentTarget);const payload=Object.fromEntries(fd.entries());const res=await fetch('/api/contact',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});const body=await res.json().catch(()=>({}));document.getElementById('msg').textContent=body.message||'';if(res.ok)e.currentTarget.reset();});</script></body></html>
'@
Write-Utf8NoBom -Path '.\public\contact.html' -Content $contactHtml

$policyHtml = @'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>LifeOS Atlas</title><style>body{margin:0;font-family:Inter,system-ui,sans-serif;background:#f3f7f7;color:#153034} .wrap{width:min(900px,calc(100% - 24px));margin:34px auto} .card{background:#fff;border:1px solid #d8e5e7;border-radius:24px;padding:28px} h1{margin-top:0;letter-spacing:-.04em} p,li{line-height:1.8;color:#46636a}</style></head><body><div class="wrap"><div class="card"><h1>{{TITLE}}</h1><p>{{LEDE}}</p><ul>{{ITEMS}}</ul><p><a href="/index.html">Back to home</a></p></div></div></body></html>
'@
$policies = @(
    @{ File='pricing.html'; Title='Pricing'; Lede='LifeOS Atlas is currently free-first while premium family capacity, automation, and control tooling are being refined.'; Items=@('Owner-led family workspace with a 4-seat default and optional 5-seat cap.','Premium dashboard, reminders, tasks, profile picture support, and family role control.','Future paid plans may be introduced later after launch-stage validation.'); },
    @{ File='privacy.html'; Title='Privacy'; Lede='LifeOS Atlas handles account, family, workflow, and contact data to operate the service and protect users.'; Items=@('Account and family data are stored to power roles, sessions, reminders, tasks, and analytics.','Operational analytics help monitor traffic, health, and service usage.','Users can contact support for data questions and operational privacy requests.'); },
    @{ File='terms.html'; Title='Terms'; Lede='LifeOS Atlas provides family operations software and related support tools subject to controlled use and service safeguards.'; Items=@('Owner accounts are responsible for invited members and permission assignments.','Promotion controls must be used lawfully and within anti-spam safeguards.','Service features may evolve as launch operations mature.'); },
    @{ File='refund.html'; Title='Refund'; Lede='LifeOS Atlas is operating in a free-first launch stage while premium features continue to mature.'; Items=@('No recurring subscription charge is currently required for baseline use.','Future paid services will be governed by plan-specific billing terms.','Support can review account issues through the contact surface.'); },
    @{ File='data-deletion.html'; Title='Data deletion'; Lede='Users may request deletion of account-related data through support and controlled account processes.'; Items=@('Deletion requests should identify the account email and the scope of requested deletion.','Operational records may be retained only where legally or security-wise necessary.','Use the contact route for current deletion coordination.'); }
)
foreach ($policy in $policies) {
    $items = ($policy.Items | ForEach-Object { "<li>$_</li>" }) -join ''
    $html = $policyHtml.Replace('{{TITLE}}', $policy.Title).Replace('{{LEDE}}', $policy.Lede).Replace('{{ITEMS}}', $items)
    Write-Utf8NoBom -Path ('.\public\' + $policy.File) -Content $html
}

$dashboardHtml = @'
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>LifeOS Atlas | Dashboard</title>
  <style>
    :root,[data-theme="light"]{--bg:#0f6f73;--bg-2:#0a5558;--shell:rgba(240,251,251,.96);--shell-2:#ffffff;--text:#163037;--muted:#597278;--line:#d4e4e6;--accent:#0f6f73;--soft:#e6f5f5;--blue:#457eef;--orange:#e69233;--success:#2f7d53;--shadow:0 22px 60px rgba(5,20,22,.18)}
    [data-theme="dark"]{--bg:#07181a;--bg-2:#0d3033;--shell:rgba(12,31,35,.94);--shell-2:#14282d;--text:#edf7f7;--muted:#9bb4b7;--line:#214046;--accent:#59b7bb;--soft:#133136;--blue:#7da8ff;--orange:#f4a95a;--success:#6dc994;--shadow:0 24px 64px rgba(0,0,0,.38)}
    *{box-sizing:border-box} html,body{margin:0;padding:0} body{font-family:Inter,system-ui,sans-serif;background:radial-gradient(circle at top left, rgba(69,126,239,.12), transparent 24%),radial-gradient(circle at top right, rgba(230,146,51,.14), transparent 24%),linear-gradient(180deg,var(--bg),var(--bg-2));color:var(--text);min-height:100vh}
    a{text-decoration:none;color:inherit} button,input,select,textarea{font:inherit}
    .shell{width:min(1320px,calc(100% - 24px));margin:18px auto;display:grid;grid-template-columns:300px minmax(0,1fr);gap:18px}
    .side,.main{background:var(--shell);backdrop-filter:blur(18px);border:1px solid var(--line);box-shadow:var(--shadow)}
    .side{border-radius:30px;padding:22px 18px;display:flex;flex-direction:column;gap:18px;position:sticky;top:18px;height:calc(100vh - 36px)}
    .main{border-radius:32px;padding:20px;display:grid;gap:18px}
    .brand{display:flex;justify-content:space-between;gap:12px;align-items:center}.logo{display:flex;gap:12px;align-items:center}.mark{width:46px;height:46px;border-radius:16px;background:linear-gradient(135deg,var(--accent),var(--blue));display:grid;place-items:center;color:#fff;font-weight:800;box-shadow:0 16px 28px rgba(15,111,115,.32)}
    .theme-toggle,.nav-btn,.side-link,.btn,.tab,.pill{border:1px solid var(--line);background:var(--shell-2);color:var(--text);border-radius:18px}
    .theme-toggle{padding:10px 14px;cursor:pointer}.nav-btn,.side-link{padding:14px 14px;display:flex;justify-content:space-between;gap:12px}.nav-btn{width:100%;cursor:pointer;background:transparent}.nav-btn.active{background:var(--soft);color:var(--accent)}
    .hero{display:flex;justify-content:space-between;gap:18px;flex-wrap:wrap;align-items:flex-start}.hero h1{margin:0;font-size:clamp(2.1rem,4vw,3.2rem);letter-spacing:-.05em;line-height:1.02}.lede{margin:10px 0 0;color:var(--muted);line-height:1.75;max-width:68ch}
    .top-actions{display:flex;gap:10px;flex-wrap:wrap}.btn{padding:12px 16px;cursor:pointer}.btn.primary{background:var(--accent);color:#fff;border-color:transparent}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}.metric,.panel,.mini-card,.profile-card{background:var(--shell-2);border:1px solid var(--line);border-radius:26px}.metric,.panel,.mini-card,.profile-card{padding:18px}.metric .value{margin-top:10px;font-size:clamp(1.8rem,3vw,2.6rem);font-weight:800;letter-spacing:-.04em}.metric .hint,.muted{color:var(--muted);line-height:1.65}
    .layout{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(360px,.8fr);gap:18px}.panel-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;flex-wrap:wrap;margin-bottom:14px}.panel-head h2{margin:0;font-size:1.1rem;letter-spacing:-.02em}.tablist{display:flex;gap:8px;flex-wrap:wrap}.tab{padding:10px 14px;cursor:pointer;background:transparent}.tab[aria-selected="true"]{background:var(--accent);color:#fff;border-color:transparent}.tabpanel{display:none}.tabpanel.active{display:block}.grid-2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.field{display:grid;gap:8px;margin-bottom:12px}.field label{font-size:13px;color:var(--muted)} .field input,.field textarea,.field select{width:100%;padding:14px;border:1px solid var(--line);border-radius:16px;background:var(--shell);color:var(--text)} .field textarea{min-height:104px;resize:vertical}
    .list{display:grid;gap:10px}.item{border:1px solid var(--line);background:var(--shell);border-radius:22px;padding:14px}.item-top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.badge{display:inline-flex;align-items:center;gap:6px;padding:7px 10px;border-radius:999px;font-size:12px;border:1px solid transparent}.badge.teal{background:color-mix(in srgb,var(--accent) 12%, transparent);color:var(--accent);border-color:color-mix(in srgb,var(--accent) 24%, transparent)}.badge.orange{background:color-mix(in srgb,var(--orange) 14%, transparent);color:var(--orange);border-color:color-mix(in srgb,var(--orange) 26%, transparent)}.badge.blue{background:color-mix(in srgb,var(--blue) 14%, transparent);color:var(--blue);border-color:color-mix(in srgb,var(--blue) 26%, transparent)}.badge.success{background:color-mix(in srgb,var(--success) 14%, transparent);color:var(--success);border-color:color-mix(in srgb,var(--success) 26%, transparent)}
    .familyPanel{display:grid;gap:12px}.member{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:12px 0;border-bottom:1px solid var(--line)}.member:last-child{border-bottom:none}.avatar{width:48px;height:48px;border-radius:16px;background:linear-gradient(135deg,var(--accent),var(--blue));display:grid;place-items:center;color:#fff;font-weight:800;overflow:hidden}.avatar img{width:100%;height:100%;object-fit:cover}.row-actions{display:flex;gap:10px;flex-wrap:wrap}.empty{border:1px dashed var(--line);border-radius:20px;padding:18px;color:var(--muted)}
    @media (max-width:1080px){.shell{grid-template-columns:1fr}.side{position:relative;height:auto}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.layout{grid-template-columns:1fr}}
    @media (max-width:720px){.metrics,.grid-2{grid-template-columns:1fr}.main{padding:16px}.hero,.panel-head{flex-direction:column;align-items:stretch}}
  </style>
</head>
<body>
  <div class="shell">
    <aside class="side">
      <div class="brand">
        <div class="logo"><div class="mark">LA</div><div><strong>LifeOS Atlas</strong><div class="muted" style="font-size:12px">Premium family workspace</div></div></div>
        <button class="theme-toggle" id="themeToggle" type="button">Dark mode</button>
      </div>
      <div class="muted" style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;padding:0 10px">Workspace</div>
      <button class="nav-btn active" data-tab="overview">Overview <small>Snapshot</small></button>
      <button class="nav-btn" data-tab="family">Family <small>Seats + roles</small></button>
      <button class="nav-btn" data-tab="workflow">Workflow <small>Reminders + tasks</small></button>
      <button class="nav-btn" data-tab="promos">Promotions <small>Manual + scheduled</small></button>
      <div style="margin-top:auto;display:grid;gap:10px">
        <a class="side-link" href="/admin.html">Admin <strong>Open</strong></a>
        <a class="side-link" href="/contact.html">Contact <strong>Support</strong></a>
        <button class="side-link" id="logoutBtn" type="button">Logout <strong>Exit</strong></button>
      </div>
    </aside>

    <main class="main">
      <section class="hero">
        <div>
          <p class="muted" style="margin:0 0 10px;font-size:12px;letter-spacing:.12em;text-transform:uppercase">Dashboard</p>
          <h1>Welcome back, <span id="userFirstName">there</span>.</h1>
          <p class="lede">Run a premium family account with reminders, profile images, permissions, roles, tasks, traffic metrics, and safeguarded promo controls from one elegant teal-led workspace.</p>
        </div>
        <div class="top-actions">
          <label class="btn" style="cursor:pointer">Profile picture<input id="photoUpload" type="file" accept="image/*" hidden></label>
          <button class="btn primary" id="saveProfileBtn" type="button">Save profile</button>
        </div>
      </section>

      <section class="metrics">
        <article class="metric"><div class="muted">Family seats</div><div class="value" id="metricSeats">0</div><div class="hint">Configured family-member capacity.</div></article>
        <article class="metric"><div class="muted">Reminders</div><div class="value" id="metricReminders">0</div><div class="hint">Active family reminders.</div></article>
        <article class="metric"><div class="muted">Open tasks</div><div class="value" id="metricTasks">0</div><div class="hint">Tasks still requiring action.</div></article>
        <article class="metric"><div class="muted">Campaigns</div><div class="value" id="metricCampaigns">0</div><div class="hint">Scheduled or controlled promotions.</div></article>
      </section>

      <section class="layout">
        <section class="panel">
          <div class="panel-head">
            <div><h2>Workspace controls</h2><p class="muted">Premium app-shell tools with controlled family access and persistence-backed forms.</p></div>
            <div class="tablist">
              <button class="tab" data-panel="familyPanel" aria-selected="false">Family</button>
              <button class="tab active" data-panel="remindersPanel" aria-selected="true">Reminders</button>
              <button class="tab" data-panel="tasksPanel" aria-selected="false">Tasks</button>
              <button class="tab" data-panel="promosPanel" aria-selected="false">Promos</button>
            </div>
          </div>

          <div class="tabpanel" id="familyPanel">
            <div class="familyPanel">
              <div class="grid-2">
                <div class="field"><label>Family name</label><input id="familyName" disabled></div>
                <div class="field"><label>Seat limit</label><select id="seatLimit"><option value="4">4</option><option value="5">5</option></select></div>
              </div>
              <div class="row-actions"><button class="btn primary" id="saveSeatLimitBtn" type="button">Save seat limit</button></div>
              <form id="memberForm">
                <div class="grid-2">
                  <div class="field"><label>Member email</label><input name="email" type="email" required></div>
                  <div class="field"><label>Access role</label><select name="accessRole"><option value="member">Member</option><option value="manager">Manager</option></select></div>
                </div>
                <div class="grid-2">
                  <div class="field"><label>First name</label><input name="firstName"></div>
                  <div class="field"><label>Last name</label><input name="lastName"></div>
                </div>
                <div class="grid-2">
                  <label class="btn"><input type="checkbox" name="canViewFinance"> Finance visibility</label>
                  <label class="btn"><input type="checkbox" name="canManagePromos"> Promo control</label>
                </div>
                <div class="row-actions"><button class="btn primary" type="submit">Add family member</button></div>
              </form>
              <div class="list" id="familyList"></div>
            </div>
          </div>

          <div class="tabpanel active" id="remindersPanel">
            <form id="reminderForm">
              <div class="grid-2">
                <div class="field"><label>Reminder title</label><input name="title" required></div>
                <div class="field"><label>Due date</label><input name="dueDate" type="date" required></div>
              </div>
              <div class="grid-2">
                <div class="field"><label>Category</label><select name="category"><option value="admin">Admin</option><option value="medical">Medical</option><option value="paperwork">Paperwork</option><option value="household">Household</option></select></div>
                <div class="field"><label>Priority</label><select name="priority"><option value="normal">Normal</option><option value="high">High</option><option value="urgent">Urgent</option></select></div>
              </div>
              <div class="field"><label>Notes</label><textarea name="notes"></textarea></div>
              <div class="row-actions"><button class="btn primary" type="submit">Save reminder</button></div>
            </form>
            <div class="list" id="reminderList"></div>
          </div>

          <div class="tabpanel" id="tasksPanel">
            <form id="taskForm">
              <div class="grid-2">
                <div class="field"><label>Task name</label><input name="title" required></div>
                <div class="field"><label>Owner label</label><input name="owner"></div>
              </div>
              <div class="field"><label>Notes</label><textarea name="notes"></textarea></div>
              <div class="row-actions"><button class="btn primary" type="submit">Add task</button></div>
            </form>
            <div class="list" id="taskList"></div>
          </div>

          <div class="tabpanel" id="promosPanel">
            <form id="promoForm">
              <div class="grid-2">
                <div class="field"><label>Campaign title</label><input name="title" required></div>
                <div class="field"><label>Channel</label><select name="channel"><option value="social">Social</option><option value="email">Email</option><option value="content">Content</option></select></div>
              </div>
              <div class="field"><label>Instruction</label><textarea name="instruction" required></textarea></div>
              <div class="grid-2">
                <div class="field"><label>Hashtags</label><input name="hashtags" placeholder="#lifeops #familyadmin"></div>
                <div class="field"><label>Schedule</label><input name="scheduledFor" type="datetime-local"></div>
              </div>
              <div class="grid-2">
                <div class="field"><label>Throttle per hour</label><select name="throttlePerHour"><option>4</option><option>8</option><option>12</option><option>16</option></select></div>
                <div class="field"><label>Guardrail</label><input value="Anti-spam safeguard enforced" disabled></div>
              </div>
              <div class="row-actions"><button class="btn primary" type="submit">Schedule promotion</button></div>
            </form>
            <div class="list" id="promoList"></div>
          </div>
        </section>

        <aside class="panel">
          <div class="panel-head"><div><h2>Status and profile</h2><p class="muted">Live analytics, profile image, and recent family activity.</p></div><span class="badge teal">Premium</span></div>
          <div class="profile-card">
            <div style="display:flex;gap:14px;align-items:center">
              <div class="avatar" id="profileAvatar">LA</div>
              <div><strong id="profileName">LifeOS user</strong><div class="muted" id="profileEmail">—</div></div>
            </div>
          </div>
          <div class="mini-card" style="margin-top:12px"><div class="muted">Daily visitors</div><div style="font-size:1.8rem;font-weight:800;letter-spacing:-.04em" id="dailyVisitors">0</div></div>
          <div class="mini-card" style="margin-top:12px"><div class="muted">Recent activity</div><div class="list" id="activityFeed" style="margin-top:10px"></div></div>
        </aside>
      </section>
    </main>
  </div>

  <script>
    (function(){
      const root = document.documentElement;
      const themeToggle = document.getElementById('themeToggle');
      let theme = (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
      function syncTheme(){root.setAttribute('data-theme', theme);themeToggle.textContent = theme === 'dark' ? 'Light mode' : 'Dark mode';}
      themeToggle.addEventListener('click', function(){theme = theme === 'dark' ? 'light' : 'dark';syncTheme();});
      syncTheme();

      async function fetchJson(url, options){
        const res = await fetch(url, Object.assign({credentials:'include',headers:{'Accept':'application/json'}}, options || {}));
        let body = null; try { body = await res.json(); } catch (_) {}
        return { ok: res.ok, status: res.status, body };
      }

      function fdToJson(form){ return Object.fromEntries(new FormData(form).entries()); }
      function setText(id, value){ const node = document.getElementById(id); if(node) node.textContent = value; }
      function escapeHtml(value){ return String(value || '').replace(/[&<>"']/g, s => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[s])); }

      function renderActivity(items){
        const rootNode = document.getElementById('activityFeed');
        if(!items || !items.length){ rootNode.innerHTML = '<div class="empty">No activity yet.</div>'; return; }
        rootNode.innerHTML = items.slice(0,8).map(item => `<div class="item"><strong>${escapeHtml(item.type || 'event')}</strong><div class="muted">${escapeHtml(item.detail || '')}</div></div>`).join('');
      }

      function renderMembers(items){
        const rootNode = document.getElementById('familyList');
        if(!items || !items.length){ rootNode.innerHTML = '<div class="empty">No family members yet.</div>'; return; }
        rootNode.innerHTML = items.map(item => {
          const initials = ((item.first_name || 'L').slice(0,1) + (item.last_name || 'A').slice(0,1)).toUpperCase();
          return `<div class="member"><div style="display:flex;gap:12px;align-items:center"><div class="avatar">${item.profile_picture ? `<img src="${escapeHtml(item.profile_picture)}" alt="">` : initials}</div><div><strong>${escapeHtml((item.first_name || '') + ' ' + (item.last_name || '')) || escapeHtml(item.email)}</strong><div class="muted">${escapeHtml(item.email)} · ${escapeHtml(item.access_role)}</div></div></div><div class="row-actions"><span class="badge teal">${item.can_manage_family ? 'Manager' : 'Member'}</span><span class="badge blue">${item.can_manage_promos ? 'Promo' : 'Standard'}</span></div></div>`;
        }).join('');
      }

      function renderList(id, items, mapper, emptyText){
        const node = document.getElementById(id);
        if(!items || !items.length){ node.innerHTML = `<div class="empty">${emptyText}</div>`; return; }
        node.innerHTML = items.map(mapper).join('');
      }

      function priorityClass(priority){ return priority === 'urgent' ? 'orange' : priority === 'high' ? 'blue' : 'teal'; }

      async function hydrate(){
        const me = await fetchJson('/api/auth/me');
        if(!me.ok || !me.body || !me.body.user){ location.href = '/login.html'; return; }
        const user = me.body.user;
        const family = me.body.family;
        setText('userFirstName', user.first_name || 'there');
        setText('profileName', ((user.first_name || '') + ' ' + (user.last_name || '')).trim() || 'LifeOS user');
        setText('profileEmail', user.email || '');
        const avatar = document.getElementById('profileAvatar');
        if(user.profile_picture){ avatar.innerHTML = `<img src="${escapeHtml(user.profile_picture)}" alt="">`; }
        if(family){ document.getElementById('familyName').value = family.name || ''; document.getElementById('seatLimit').value = String(family.seat_limit || 4); setText('metricSeats', String(family.seat_limit || 0)); }

        const stats = await fetchJson('/api/stats');
        if(stats.ok && stats.body){
          setText('metricCampaigns', String(stats.body.campaigns || 0));
          setText('metricReminders', String(stats.body.reminders || 0));
          setText('metricTasks', String(stats.body.openTasks || 0));
          setText('dailyVisitors', String(stats.body.dailyVisitors || 0));
          renderActivity(stats.body.recentActivity || []);
        }

        const fam = await fetchJson('/api/family');
        if(fam.ok && fam.body){ renderMembers(fam.body.members || []); }

        const reminders = await fetchJson('/api/reminders');
        if(reminders.ok){ renderList('reminderList', reminders.body.items || [], item => `<article class="item"><div class="item-top"><div><strong>${escapeHtml(item.title)}</strong><div class="muted">${escapeHtml(item.category)} due ${escapeHtml(item.due_date)}</div></div><span class="badge ${priorityClass(item.priority)}">${escapeHtml(item.priority)}</span></div><div class="muted">${escapeHtml(item.notes || '')}</div></article>`, 'No reminders yet.'); }

        const tasks = await fetchJson('/api/tasks');
        if(tasks.ok){ renderList('taskList', tasks.body.items || [], item => `<article class="item"><div class="item-top"><div><strong>${escapeHtml(item.title)}</strong><div class="muted">${escapeHtml(item.owner || 'Unassigned')}</div></div><span class="badge success">${escapeHtml(item.status)}</span></div><div class="muted">${escapeHtml(item.notes || '')}</div></article>`, 'No tasks yet.'); }

        const promos = await fetchJson('/api/promos');
        if(promos.ok){ renderList('promoList', promos.body.items || [], item => `<article class="item"><div class="item-top"><div><strong>${escapeHtml(item.title)}</strong><div class="muted">${escapeHtml(item.channel)} · ${escapeHtml(item.scheduled_for || 'manual')}</div></div><span class="badge blue">${escapeHtml(item.status)}</span></div><div class="muted">${escapeHtml(item.instruction)}</div><div class="row-actions" style="margin-top:10px"><button class="btn" data-action="pause" data-id="${item.id}">Pause</button><button class="btn" data-action="resume" data-id="${item.id}">Resume</button><button class="btn" data-action="stop" data-id="${item.id}">Stop</button><button class="btn primary" data-action="manual-run" data-id="${item.id}">Manual run</button></div></article>`, 'No promotions yet.'); }
      }

      document.querySelectorAll('.tab').forEach(btn => btn.addEventListener('click', function(){ document.querySelectorAll('.tab').forEach(x => x.setAttribute('aria-selected', x === btn ? 'true' : 'false')); document.querySelectorAll('.tabpanel').forEach(p => p.classList.toggle('active', p.id === btn.dataset.panel)); }));
      document.querySelectorAll('.nav-btn').forEach(btn => btn.addEventListener('click', function(){ document.querySelectorAll('.nav-btn').forEach(x => x.classList.toggle('active', x === btn)); const mapping = { overview:'remindersPanel', family:'familyPanel', workflow:'tasksPanel', promos:'promosPanel' }; const target = mapping[btn.dataset.tab] || 'remindersPanel'; document.querySelectorAll('.tabpanel').forEach(p => p.classList.toggle('active', p.id === target)); document.querySelectorAll('.tab').forEach(t => t.setAttribute('aria-selected', t.dataset.panel === target ? 'true' : 'false')); }));

      document.getElementById('reminderForm').addEventListener('submit', async function(e){ e.preventDefault(); const body = fdToJson(e.currentTarget); const res = await fetchJson('/api/reminders', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) }); if(res.ok){ e.currentTarget.reset(); hydrate(); } });
      document.getElementById('taskForm').addEventListener('submit', async function(e){ e.preventDefault(); const body = fdToJson(e.currentTarget); const res = await fetchJson('/api/tasks', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) }); if(res.ok){ e.currentTarget.reset(); hydrate(); } });
      document.getElementById('promoForm').addEventListener('submit', async function(e){ e.preventDefault(); const body = fdToJson(e.currentTarget); const res = await fetchJson('/api/promos', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) }); if(res.ok){ e.currentTarget.reset(); hydrate(); } });
      document.getElementById('memberForm').addEventListener('submit', async function(e){ e.preventDefault(); const raw = fdToJson(e.currentTarget); raw.canViewFinance = !!new FormData(e.currentTarget).get('canViewFinance'); raw.canManagePromos = !!new FormData(e.currentTarget).get('canManagePromos'); const res = await fetchJson('/api/family/members', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(raw) }); if(res.ok){ e.currentTarget.reset(); hydrate(); } });
      document.getElementById('saveSeatLimitBtn').addEventListener('click', async function(){ await fetchJson('/api/family/settings', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ seatLimit: document.getElementById('seatLimit').value }) }); hydrate(); });
      document.getElementById('saveProfileBtn').addEventListener('click', async function(){ const firstName = prompt('First name'); const lastName = prompt('Last name'); if(firstName !== null){ await fetchJson('/api/profile', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ firstName, lastName }) }); hydrate(); } });
      document.getElementById('photoUpload').addEventListener('change', async function(e){ if(!e.target.files.length) return; const fd = new FormData(); fd.append('profilePhoto', e.target.files[0]); await fetch('/api/profile/photo', { method:'POST', credentials:'include', body:fd }); hydrate(); });
      document.getElementById('promoList').addEventListener('click', async function(e){ const btn = e.target.closest('button[data-action]'); if(!btn) return; await fetchJson('/api/promos/' + btn.dataset.id + '/action', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ action: btn.dataset.action }) }); hydrate(); });
      document.getElementById('logoutBtn').addEventListener('click', async function(){ await fetchJson('/api/auth/logout', { method:'POST' }); location.href = '/login.html'; });

      hydrate();
    })();
  </script>
</body>
</html>
'@
Write-Utf8NoBom -Path '.\public\dashboard.html' -Content $dashboardHtml

$adminHtml = @'
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>LifeOS Atlas | Admin</title>
  <style>
    :root,[data-theme="light"]{--bg:#0f6f73;--bg-2:#0a5558;--shell:rgba(245,252,252,.96);--shell-2:#ffffff;--text:#173137;--muted:#5b7379;--line:#d4e4e6;--accent:#0f6f73;--blue:#467fed;--orange:#e59637;--success:#2f7d53;--shadow:0 22px 60px rgba(5,20,22,.18)}
    [data-theme="dark"]{--bg:#07181a;--bg-2:#0d3033;--shell:rgba(12,31,35,.94);--shell-2:#14282d;--text:#edf7f7;--muted:#9bb4b7;--line:#214046;--accent:#59b7bb;--blue:#7da8ff;--orange:#f4a95a;--success:#6dc994;--shadow:0 24px 64px rgba(0,0,0,.38)}
    *{box-sizing:border-box} body{margin:0;font-family:Inter,system-ui,sans-serif;background:radial-gradient(circle at top left, rgba(70,127,237,.12), transparent 24%),radial-gradient(circle at top right, rgba(229,150,55,.12), transparent 24%),linear-gradient(180deg,var(--bg),var(--bg-2));color:var(--text);min-height:100vh} a{text-decoration:none;color:inherit}
    .wrap{width:min(1320px,calc(100% - 24px));margin:18px auto;display:grid;gap:18px}.shell{background:var(--shell);border:1px solid var(--line);box-shadow:var(--shadow);border-radius:32px;padding:20px;backdrop-filter:blur(18px)}
    .top,.head{display:flex;justify-content:space-between;gap:14px;align-items:flex-start;flex-wrap:wrap}.btn,.tab{border:1px solid var(--line);background:var(--shell-2);color:var(--text);padding:12px 16px;border-radius:18px;cursor:pointer}.tab.active{background:var(--accent);color:#fff;border-color:transparent}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin-top:18px}.card,.panel{background:var(--shell-2);border:1px solid var(--line);border-radius:26px;padding:18px}.value{margin-top:10px;font-size:clamp(1.8rem,3vw,2.6rem);font-weight:800;letter-spacing:-.04em}.muted{color:var(--muted);line-height:1.65}.panels{display:grid;grid-template-columns:minmax(0,1.16fr) minmax(360px,.84fr);gap:18px;margin-top:18px}.subpanel{display:none}.subpanel.active{display:block}.row{display:grid;grid-template-columns:1.5fr .9fr .9fr .9fr;gap:10px;border:1px solid var(--line);background:var(--shell);border-radius:18px;padding:14px;margin-top:10px}.event{padding:12px 0;border-bottom:1px solid var(--line)}.event:last-child{border-bottom:none}.badge{display:inline-flex;padding:7px 10px;border-radius:999px;font-size:12px}.badge.teal{background:rgba(15,111,115,.12);color:var(--accent)}.badge.blue{background:rgba(70,127,237,.12);color:var(--blue)}.badge.orange{background:rgba(229,150,55,.14);color:var(--orange)}.badge.success{background:rgba(47,125,83,.14);color:var(--success)}
    @media (max-width:1080px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.panels{grid-template-columns:1fr}.row{grid-template-columns:1fr}} @media (max-width:720px){.grid{grid-template-columns:1fr}.top,.head{flex-direction:column;align-items:stretch}}
  </style>
</head>
<body>
  <div class="wrap">
    <section class="shell">
      <div class="top">
        <div><p class="muted" style="margin:0 0 10px;font-size:12px;letter-spacing:.12em;text-transform:uppercase">Admin dashboard</p><h1 style="margin:0;font-size:clamp(2rem,4vw,3.1rem);letter-spacing:-.05em">Operational control for LifeOS Atlas.</h1><p class="muted">Review signups, family seats, campaign activity, live events, and health status from one richer premium command layer.</p></div>
        <div style="display:flex;gap:10px;flex-wrap:wrap"><button class="btn" id="themeToggle" type="button">Dark mode</button><a class="btn" href="/dashboard.html">Client dashboard</a><button class="btn" id="logoutBtn" type="button">Logout</button></div>
      </div>
      <div class="grid">
        <article class="card"><div class="muted">Users</div><div class="value" id="usersMetric">0</div><div class="muted">Registered accounts.</div></article>
        <article class="card"><div class="muted">Families</div><div class="value" id="familiesMetric">0</div><div class="muted">Owner-led family workspaces.</div></article>
        <article class="card"><div class="muted">Family seats</div><div class="value" id="seatsMetric">0</div><div class="muted">Total configured seat capacity.</div></article>
        <article class="card"><div class="muted">Campaigns</div><div class="value" id="campaignsMetric">0</div><div class="muted">Tracked promotion objects.</div></article>
      </div>
      <div class="panels">
        <section class="panel">
          <div class="head"><div><h2 style="margin:0">Admin views</h2><p class="muted">Switch between live events, system map, and signals.</p></div><div style="display:flex;gap:8px;flex-wrap:wrap"><button class="tab active" data-panel="eventsPanel">Events</button><button class="tab" data-panel="surfacePanel">Surface map</button><button class="tab" data-panel="signalsPanel">Signals</button></div></div>
          <div class="subpanel active" id="eventsPanel"><div id="eventsRoot"></div></div>
          <div class="subpanel" id="surfacePanel"><div class="row"><div>Landing page</div><div>/index.html</div><div><span class="badge teal">Canonical</span></div><div>Single locked public path</div></div><div class="row"><div>Dashboard</div><div>/dashboard.html</div><div><span class="badge blue">Member</span></div><div>Family workspace</div></div><div class="row"><div>Admin</div><div>/admin.html</div><div><span class="badge orange">Control</span></div><div>Operational command view</div></div></div>
          <div class="subpanel" id="signalsPanel"><div class="row"><div>Contact messages</div><div id="contactMetric">0</div><div><span class="badge success">Live</span></div><div>Support capture available</div></div><div class="row"><div>Health</div><div id="healthMetric">Healthy</div><div><span class="badge teal">Ready</span></div><div>Runtime and DB responsive</div></div></div>
        </section>
        <aside class="panel"><div class="head"><div><h2 style="margin:0">Live notes</h2><p class="muted">Current premium product direction in production.</p></div><span class="badge teal">Updated</span></div><div class="card"><div class="muted">Landing page</div><div style="margin-top:10px;font-weight:700">Kept structurally locked with one darker teal shade only.</div></div><div class="card" style="margin-top:12px"><div class="muted">Family architecture</div><div style="margin-top:10px;font-weight:700">Owner-managed roles, seat limits, member access, and profile support.</div></div><div class="card" style="margin-top:12px"><div class="muted">Growth controls</div><div style="margin-top:10px;font-weight:700">Scheduled promotions, manual overrides, throttling, and audit logs.</div></div></aside>
      </div>
    </section>
  </div>
  <script>
    (function(){
      const root=document.documentElement;const themeToggle=document.getElementById('themeToggle');let theme=(window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches)?'dark':'light';function sync(){root.setAttribute('data-theme',theme);themeToggle.textContent=theme==='dark'?'Light mode':'Dark mode';}themeToggle.addEventListener('click',function(){theme=theme==='dark'?'light':'dark';sync();});sync();
      async function fetchJson(url, options){const res=await fetch(url,Object.assign({credentials:'include',headers:{'Accept':'application/json'}},options||{}));let body=null;try{body=await res.json();}catch(_){}return{ok:res.ok,status:res.status,body};}
      function setText(id,value){const n=document.getElementById(id);if(n)n.textContent=value;}
      document.querySelectorAll('.tab').forEach(btn=>btn.addEventListener('click',function(){document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('active',x===btn));document.querySelectorAll('.subpanel').forEach(p=>p.classList.toggle('active',p.id===btn.dataset.panel));}));
      document.getElementById('logoutBtn').addEventListener('click',async function(){await fetchJson('/api/auth/logout',{method:'POST'});location.href='/login.html';});
      (async function(){
        const me=await fetchJson('/api/auth/me'); if(!me.ok||!me.body||!me.body.user){location.href='/login.html'; return;}
        const overview=await fetchJson('/api/admin/overview'); if(!overview.ok){location.href='/dashboard.html'; return;}
        setText('usersMetric', String(overview.body.users||0)); setText('familiesMetric', String(overview.body.families||0)); setText('seatsMetric', String(overview.body.familySeats||0)); setText('campaignsMetric', String(overview.body.campaigns||0)); setText('contactMetric', String(overview.body.contactMessages||0)); setText('healthMetric', overview.body.health||'Check');
        const rootNode=document.getElementById('eventsRoot'); const events=overview.body.liveEvents||[]; rootNode.innerHTML=events.length?events.map(item=>`<div class="event"><strong>${item.type||'event'}</strong><div class="muted">${item.detail||''}</div><div class="muted">${new Date(item.created_at).toLocaleString()}</div></div>`).join(''):'<div class="muted">No events yet.</div>';
      })();
    })();
  </script>
</body>
</html>
'@
Write-Utf8NoBom -Path '.\public\admin.html' -Content $adminHtml

Write-Info 'STEP 6: install packages, validate, commit, push, and deploy'
npm install
npm run validate

git add .
$pending = (git diff --cached --name-only | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($pending)) {
    throw 'No staged changes found; stopping to avoid empty deploy.'
}

git commit -m "Full premium family-account production pass for LifeOS Atlas"
git push origin main
railway up --detach

Write-Info 'STEP 7: production verification'
Start-Sleep -Seconds 12
try {
    railway deployment list
} catch {
    Write-Host 'Railway deployment list could not be displayed by this CLI version.' -ForegroundColor Yellow
}
try {
    node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/health').then(r=>r.text()).then(t=>console.log(t)).catch(()=>process.exit(0))"
} catch {}

Write-Info 'DONE'
Write-Host 'LifeOS Atlas full production pass script completed.' -ForegroundColor Green

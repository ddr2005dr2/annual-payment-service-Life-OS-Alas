const express = require("express");
const fs = require("fs");
const path = require("path");
const cookieParser = require("cookie-parser");
const cors = require("cors");
const rateLimit = require("express-rate-limit");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const { nanoid } = require("nanoid");

const app = express();
const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || "change-this-secret-in-production";
const BASE_URL = process.env.BASE_URL || "https://www.lifeosatlas.com";
const DATA_DIR = path.join(__dirname, "data");
const USERS_FILE = path.join(DATA_DIR, "users.json");
const EVENTS_FILE = path.join(DATA_DIR, "events.json");
const CONTENT_FILE = path.join(DATA_DIR, "content.json");

app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());
app.use(express.static(__dirname));

const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 50, standardHeaders: true, legacyHeaders: false });
app.use("/api/auth", authLimiter);

function ensureFile(filePath, fallback) {
  if (!fs.existsSync(filePath)) fs.writeFileSync(filePath, JSON.stringify(fallback, null, 2));
}
function readJson(filePath, fallback) {
  ensureFile(filePath, fallback);
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}
function writeJson(filePath, data) {
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
}
function nowIso() {
  return new Date().toISOString();
}
function recordEvent(type, payload = {}) {
  const events = readJson(EVENTS_FILE, []);
  events.unshift({ id: nanoid(), type, payload, createdAt: nowIso() });
  writeJson(EVENTS_FILE, events.slice(0, 5000));
}
function getTokenFromReq(req) {
  const header = req.headers.authorization || "";
  if (header.startsWith("Bearer ")) return header.slice(7);
  if (req.cookies && req.cookies.lifeos_token) return req.cookies.lifeos_token;
  return null;
}
function authRequired(req, res, next) {
  try {
    const token = getTokenFromReq(req);
    if (!token) return res.status(401).json({ error: "Unauthorized" });
    const decoded = jwt.verify(token, JWT_SECRET);
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(401).json({ error: "Unauthorized" });
  }
}
function adminRequired(req, res, next) {
  if (req.user && req.user.role === "admin") return next();
  return res.status(403).json({ error: "Forbidden" });
}
function publicUser(user) {
  return {
    id: user.id,
    email: user.email,
    firstName: user.firstName,
    lastName: user.lastName,
    role: user.role,
    createdAt: user.createdAt
  };
}
function trackRequest(req, res, next) {
  const startedAt = Date.now();
  res.on("finish", () => {
    if (req.path.startsWith("/api/admin")) return;
    const source = req.query.utm_source || req.headers["referer"] || "direct";
    recordEvent("page_view", {
      path: req.path,
      method: req.method,
      status: res.statusCode,
      durationMs: Date.now() - startedAt,
      source,
      ua: req.headers["user-agent"] || ""
    });
  });
  next();
}
app.use(trackRequest);

ensureFile(USERS_FILE, []);
ensureFile(EVENTS_FILE, []);
ensureFile(CONTENT_FILE, {
  seo: {
    title: "LifeOS Atlas | Private life operations",
    description: "LifeOS Atlas gives adults one private place to organize tasks, documents, reminders, scheduling, household responsibilities, support workflows, and important life administration."
  },
  affiliates: [
    { id: nanoid(), name: "Insurance Partner", url: "https://example.com/insurance", category: "admin", active: true },
    { id: nanoid(), name: "Calendar Tools Partner", url: "https://example.com/calendar", category: "productivity", active: true }
  ]
});

app.get("/health", (req, res) => {
  res.json({ ok: true, uptime: process.uptime(), timestamp: nowIso() });
});

app.get("/robots.txt", (req, res) => {
  res.type("text/plain").send(`User-agent: *\nAllow: /\nSitemap: ${BASE_URL}/sitemap.xml\n`);
});

app.get("/sitemap.xml", (req, res) => {
  const urls = [
    "/",
    "/pricing.html",
    "/faq.html",
    "/contact.html",
    "/privacy.html",
    "/terms.html",
    "/refund.html",
    "/data-deletion.html",
    "/login.html",
    "/register.html",
    "/dashboard.html",
    "/admin.html"
  ];
  res.type("application/xml").send(`<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map(u => `<url><loc>${BASE_URL}${u}</loc></url>`).join("\n")}
</urlset>`);
});

app.post("/api/events", (req, res) => {
  const body = req.body || {};
  recordEvent(body.type || "custom_event", {
    label: body.label || "",
    value: body.value || "",
    path: body.path || "",
    source: body.source || "web"
  });
  res.json({ ok: true });
});

app.post("/api/auth/register", async (req, res) => {
  const { firstName, lastName, email, password } = req.body;
  if (!firstName || !lastName || !email || !password) return res.status(400).json({ error: "Missing fields" });

  const users = readJson(USERS_FILE, []);
  const existing = users.find(u => u.email.toLowerCase() === String(email).toLowerCase());
  if (existing) return res.status(409).json({ error: "Email already exists" });

  const passwordHash = await bcrypt.hash(password, 10);
  const role = users.length === 0 ? "admin" : "user";
  const user = {
    id: nanoid(),
    firstName,
    lastName,
    email: String(email).toLowerCase(),
    passwordHash,
    role,
    createdAt: nowIso()
  };
  users.push(user);
  writeJson(USERS_FILE, users);

  const token = jwt.sign({ id: user.id, email: user.email, role: user.role, firstName: user.firstName }, JWT_SECRET, { expiresIn: "7d" });
  res.cookie("lifeos_token", token, { httpOnly: true, sameSite: "lax", secure: false, maxAge: 7 * 24 * 60 * 60 * 1000 });
  recordEvent("signup", { email: user.email, role: user.role });
  res.json({ ok: true, user: publicUser(user), token });
});

app.post("/api/auth/login", async (req, res) => {
  const { email, password } = req.body;
  const users = readJson(USERS_FILE, []);
  const user = users.find(u => u.email === String(email).toLowerCase());
  if (!user) return res.status(401).json({ error: "Invalid credentials" });

  const valid = await bcrypt.compare(password, user.passwordHash);
  if (!valid) return res.status(401).json({ error: "Invalid credentials" });

  const token = jwt.sign({ id: user.id, email: user.email, role: user.role, firstName: user.firstName }, JWT_SECRET, { expiresIn: "7d" });
  res.cookie("lifeos_token", token, { httpOnly: true, sameSite: "lax", secure: false, maxAge: 7 * 24 * 60 * 60 * 1000 });
  recordEvent("login", { email: user.email });
  res.json({ ok: true, user: publicUser(user), token });
});

app.post("/api/auth/logout", (req, res) => {
  res.clearCookie("lifeos_token");
  recordEvent("logout", {});
  res.json({ ok: true });
});

app.get("/api/auth/me", authRequired, (req, res) => {
  const users = readJson(USERS_FILE, []);
  const user = users.find(u => u.id === req.user.id);
  if (!user) return res.status(404).json({ error: "User not found" });
  res.json({ ok: true, user: publicUser(user) });
});

app.post("/api/auth/reset-password", (req, res) => {
  const { email } = req.body;
  recordEvent("reset_password_requested", { email: String(email || "").toLowerCase() });
  res.json({ ok: true, message: "Reset request recorded" });
});

app.get("/api/dashboard/summary", authRequired, (req, res) => {
  const events = readJson(EVENTS_FILE, []);
  const summary = {
    remindersTracked: events.filter(e => e.type === "custom_event" && e.payload.label === "reminder").length,
    signups: events.filter(e => e.type === "signup").length,
    pageViews: events.filter(e => e.type === "page_view").length,
    recentEvents: events.slice(0, 10)
  };
  res.json({ ok: true, summary });
});

app.get("/api/admin/metrics", authRequired, adminRequired, (req, res) => {
  const events = readJson(EVENTS_FILE, []);
  const users = readJson(USERS_FILE, []);
  const today = new Date().toISOString().slice(0, 10);

  const dailyVisitors = events.filter(e => e.type === "page_view" && String(e.createdAt).slice(0, 10) === today).length;
  const signups = events.filter(e => e.type === "signup").length;
  const trafficSources = {};
  const liveEvents = events.slice(0, 20);

  events.filter(e => e.type === "page_view").forEach(e => {
    const source = e.payload.source || "direct";
    trafficSources[source] = (trafficSources[source] || 0) + 1;
  });

  res.json({
    ok: true,
    metrics: {
      dailyVisitors,
      totalUsers: users.length,
      signups,
      trafficSources,
      liveEvents
    }
  });
});

app.get("/api/admin/affiliates", authRequired, adminRequired, (req, res) => {
  const content = readJson(CONTENT_FILE, {});
  res.json({ ok: true, affiliates: content.affiliates || [] });
});

app.post("/api/admin/affiliates", authRequired, adminRequired, (req, res) => {
  const { name, url, category } = req.body;
  const content = readJson(CONTENT_FILE, {});
  content.affiliates = content.affiliates || [];
  content.affiliates.unshift({ id: nanoid(), name, url, category, active: true });
  writeJson(CONTENT_FILE, content);
  recordEvent("affiliate_created", { name, url, category });
  res.json({ ok: true, affiliates: content.affiliates });
});

app.get("/api/marketing/feed", authRequired, adminRequired, (req, res) => {
  res.json({
    ok: true,
    feed: [
      { channel: "seo", status: "ready", detail: "robots.txt and sitemap.xml active" },
      { channel: "analytics", status: "ready", detail: "event capture enabled" },
      { channel: "affiliates", status: "ready", detail: "partner slots available" },
      { channel: "email", status: "planned", detail: "SMTP provider should be connected next" }
    ]
  });
});

app.get("*", (req, res, next) => {
  const requested = path.join(__dirname, req.path);
  if (fs.existsSync(requested) && fs.statSync(requested).isFile()) return res.sendFile(requested);
  if (req.path.startsWith("/api/")) return next();
  res.sendFile(path.join(__dirname, "index.html"));
});

app.listen(PORT, () => {
  console.log(`LifeOS Atlas running on port ${PORT}`);
});

const fs = require("fs");
const path = require("path");
const bcrypt = require("bcryptjs");

const dataDir = path.join(__dirname, "..", "data");
const usersFile = path.join(dataDir, "users.json");
const eventsFile = path.join(dataDir, "events.json");
const contentFile = path.join(dataDir, "content.json");

if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

(async () => {
  const passwordHash = await bcrypt.hash("Admin123!ChangeMe", 10);
  fs.writeFileSync(usersFile, JSON.stringify([
    {
      id: "seed-admin",
      firstName: "Admin",
      lastName: "User",
      email: "admin@lifeosatlas.com",
      passwordHash,
      role: "admin",
      createdAt: new Date().toISOString()
    }
  ], null, 2));

  fs.writeFileSync(eventsFile, JSON.stringify([
    { id: "evt-1", type: "signup", payload: { email: "admin@lifeosatlas.com", role: "admin" }, createdAt: new Date().toISOString() },
    { id: "evt-2", type: "page_view", payload: { path: "/", source: "direct" }, createdAt: new Date().toISOString() }
  ], null, 2));

  fs.writeFileSync(contentFile, JSON.stringify({
    affiliates: [
      { id: "aff-1", name: "Insurance Partner", url: "https://example.com/insurance", category: "admin", active: true },
      { id: "aff-2", name: "Calendar Tools Partner", url: "https://example.com/calendar", category: "productivity", active: true }
    ]
  }, null, 2));

  console.log("Seed complete");
})();

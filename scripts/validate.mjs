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
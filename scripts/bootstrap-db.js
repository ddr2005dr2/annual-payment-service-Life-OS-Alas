const fs = require("fs");
const path = require("path");
const db = require("../db/db");

async function main() {
  if (!db.hasDatabase) {
    console.log("DATABASE_URL not set; skipping schema bootstrap.");
    process.exit(0);
  }

  const schemaPath = path.join(__dirname, "..", "db", "schema.sql");
  const sql = fs.readFileSync(schemaPath, "utf8");
  await db.query(sql);
  console.log("Schema bootstrap complete.");
  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

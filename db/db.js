const { Pool } = require("pg");

const databaseUrl = process.env.DATABASE_URL;
const hasDatabase = Boolean(databaseUrl);

let pool = null;

if (hasDatabase) {
  pool = new Pool({
    connectionString: databaseUrl,
    ssl: process.env.PGSSLMODE === "disable" ? false : { rejectUnauthorized: false }
  });
}

async function query(text, params = []) {
  if (!pool) {
    throw new Error("DATABASE_UNAVAILABLE");
  }
  return pool.query(text, params);
}

async function testConnection() {
  if (!pool) {
    return { ok: false, storage: "in-memory", db: "not-configured" };
  }
  await pool.query("select 1 as ok");
  return { ok: true, storage: "postgres", db: "connected" };
}

function getStorageMode() {
  return hasDatabase ? "postgres" : "in-memory";
}

module.exports = {
  hasDatabase,
  pool,
  query,
  testConnection,
  getStorageMode
};

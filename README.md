# LifeOS Atlas

Premium multi-view landing shell with:

- Working top navigation tabs
- Free-first pricing posture
- Onboarding view
- Community view
- Trust Center view
- Contact form view
- Policy modals
- Concierge intake modal
- Login and account creation shell

## Local run

`powershell
npm install
npm run dev
`

## Deploy notes

This project uses static HTML in both index.html and public/index.html so Railway or other static-serving flows can serve the same experience consistently.
## Postgres persistence bootstrap

1. Add a PostgreSQL service inside the same Railway project.
2. In the app service Variables, set:
   DATABASE_URL = ${{Postgres.DATABASE_URL}}
3. Run once locally or in Railway shell:
   npm run db:bootstrap
4. Redeploy the app.
5. Verify:
   /api/health
   The JSON should show storage:"postgres" and db:"connected" when DATABASE_URL is active.

This change only adds the DB layer and schema bootstrap. Route-by-route migration from in-memory state to PostgreSQL is the next patch.

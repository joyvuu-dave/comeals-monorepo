# Comeals

A meal management and cost-splitting app for
[cohousing](https://en.wikipedia.org/wiki/Cohousing) communities. Residents
sign up for shared dinners, volunteer to cook, and the cost is split
proportionally among the people who attended.

One repository holds both parts: a Rails 8.1 API and a React 19 single-page
app. In production, one Heroku dyno runs Rails, which serves the app from
`public/` and the API from `/api/v1/`.

## Getting Started

### Local development (with fake data)

Use the dev seed. It creates a community called "Patches Way" with two admins
(one superuser, one plain admin), 24 units, 41 fake residents, and a year of
meals — 26 weeks back and 26 weeks forward — so there is data to click through.
The oldest meals are already reconciled.

```bash
git clone https://github.com/joyvuu-dave/comeals-monorepo.git
cd comeals-monorepo
bundle install
npm install
git config core.hooksPath .githooks   # turn on the repo's git hooks (bin/setup also does this)
bundle exec rake db:setup   # creates the database and runs db/seeds.rb (dev fixtures)
bin/dev
```

`bin/dev` starts Rails (port 3000), Vite (port 3036), and the clock process
via foreman.

The resident app is at `http://localhost:3036`. ActiveAdmin is on its own
subdomain, served by Rails directly: log in at `http://admin.lvh.me:3000/login`
as `joslyn@email.com` / `password` (the superuser), or `reader@email.com` /
`password` (the plain admin).

### Fresh deployment (real community, no fake data)

On a new install, the database starts empty. Create the first admin user from
a Rails console, then finish setup in the ActiveAdmin UI. No seed data is
loaded, and nothing is created without you asking for it.

```bash
bundle install
npm install
bundle exec rails db:create db:migrate
bundle exec rails console
```

In the console:

```ruby
AdminUser.create!(email: 'you@example.com',
                  password: 'pick-something-strong',
                  password_confirmation: 'pick-something-strong')
```

Leave `community:` out. It may be empty during setup, and it is filled in
automatically the moment you create the Community below.

Then start the server and sign in on the admin subdomain — `/login` on
`admin.lvh.me:3000` in development, `admin.<your-domain>` in production. On
your first sign-in, the dashboard sends you to the form for creating the
Community. Pick a name and a **timezone** (the dropdown covers Hawaii
through Auckland). Saving that form finishes setup and links your admin user
to the new community.

## Local URLs

- **App (via Vite proxy)**: http://localhost:3036 — the SPA with hot reload; API requests are proxied to Rails
- **Rails direct**: http://localhost:3000 — API endpoints
- **ActiveAdmin**: http://admin.lvh.me:3000/login — the Vite proxy only forwards `/api`, so admin is served by Rails directly
- **Mail inbox**: http://localhost:3000/letter_opener

## Common Commands

```bash
bin/check                  # Full health check: tests, linters, security, freshness
bundle exec rspec          # Ruby tests
npm test                   # Frontend unit tests (Vitest)
npm run test:e2e           # Playwright E2E tests
npm run lint               # ESLint on frontend source
npm run build              # Vite build -> public/
```

## Rake Tasks

- `rake billing:recalculate` — recompute resident balances from source data (runs daily in production)
- `rake ledger:verify` — check every settled balance against its source data (runs daily in production)
- `rake reconciliations:create` — close a billing period with a cutoff of yesterday, compute settlement balances, and email each cook

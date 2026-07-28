# Comeals

A meal management and cost-splitting app for
[cohousing](https://en.wikipedia.org/wiki/Cohousing) communities. Residents sign
up for communal dinners, volunteer to cook, and the cost is split
proportionally among attendees.

Rails 8.1 API + React 19 SPA in a single monorepo. In production, Rails serves
the SPA from `public/` and the API from `/api/v1/` on one Heroku dyno.

## Getting Started

### Local development (with fake data)

Use the dev seed — it creates "Patches Way", two admins (one superuser, one
plain admin), 24 units, 41 fake residents, and a year of meals: 26 weeks back
and 26 weeks forward, so you have something to click around. The oldest batch
comes already reconciled.

```bash
git clone https://github.com/joyvuu-dave/comeals-monorepo.git
cd comeals-monorepo
bundle install
npm install
bundle exec rake db:setup   # creates DB + runs db/seeds.rb (dev fixtures)
bin/dev
```

The resident app lives at `http://localhost:3036`. ActiveAdmin is on its own
subdomain, served by Rails directly: log in at `http://admin.lvh.me:3000/login`
as `joslyn@email.com` / `password` (the superuser), or `reader@email.com` /
`password` (the plain admin).

### Fresh deployment (real community, no fake data)

On a new install, the database starts empty. Create the first admin user
from a Rails console, then finish setup through the ActiveAdmin UI — no seed
data, no silent defaults.

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

(Leave `community:` off — it's nullable during bootstrap and will be backfilled
the moment you create the Community below.)

Then start the server and sign in on the admin subdomain — `/login` on
`admin.lvh.me:3000` in development, `admin.<your-domain>` in production. On
first sign-in the dashboard redirects you to the Community new form — pick a
name, slug, and **timezone** (the dropdown covers Hawaii through Auckland; pick
yours). Saving that form completes bootstrap and links your admin to the new
community.

`bin/dev` boots Rails (3000), Vite (3036), and the clock process via foreman.

## Local URLs

- **App (via Vite proxy)**: http://localhost:3036 — SPA with HMR; API requests proxy to Rails
- **Rails direct**: http://localhost:3000 — API endpoints
- **ActiveAdmin**: http://admin.lvh.me:3000/login — the Vite proxy only forwards `/api`, so admin is Rails direct
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

- `rake billing:recalculate` — refresh resident balances from source data (run daily in production)
- `rake reconciliations:create` — close a billing period with a cutoff of yesterday, compute settlement balances, and email each cook

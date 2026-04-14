# Migration Plan: Approach B (Integrated Vite + CI)

## Context

Comeals currently runs as two separate apps: a Rails 8.1 API backend (`comeals-backend`) and a React 19 + MobX SPA (`comeals-ui`) served by Express. Every API call travels Browser -> Express -> Rails -> back, adding latency and cost (2 Heroku dynos). This plan consolidates everything into a single Rails app that serves the React SPA from `public/` and the API from `/api/v1/`. Express is eliminated, CORS is eliminated, and we drop to 1 dyno.

---

## Phase 0: Merge Backend Git History into Monorepo

The monorepo currently has only one uncommitted file (`APPROACH_COMPARISON.md`). We bring in the full Rails app with its history.

1. Commit `APPROACH_COMPARISON.md` (it's currently untracked)
2. Add backend as a remote and merge:
   ```
   git remote add backend ../comeals-backend
   git fetch backend
   git merge backend/main --allow-unrelated-histories
   ```
3. Resolve any trivial merge conflicts (e.g., `.gitignore`, `README.md`)
4. Remove the temporary remote: `git remote remove backend`
5. Verify: `git log --oneline` shows full backend history; `bundle exec rspec` passes

---

## Phase 1: Copy Frontend Source into `app/frontend/`

Copy from `comeals-ui` (no git history merge -- archived repo serves as reference).

| Source (`comeals-ui/`) | Destination (monorepo) |
|---|---|
| `src/` | `app/frontend/src/` |
| `index.html` | `app/frontend/index.html` |
| `tests/` | `tests/` |

**Do NOT copy:** `server.js`, `Procfile`, `node_modules/`, `build/`, `.git/`

---

## Phase 2: Add Frontend Build Configuration

Create these files at the repo root:

### `package.json`
- Copy deps from `comeals-ui/package.json`, **removing** `express` and `http-proxy-middleware`
- Scripts: `"build": "vite build"`, `"dev": "vite"`, `"test": "vitest run"`, `"lint": "eslint app/frontend/src/"`, etc.
- Keep `engines: { node: "24", npm: "11" }` (tells Heroku Node buildpack which versions)

### `vite.config.js`
```javascript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "app/frontend",
  plugins: [react()],
  server: {
    port: 3036,
    proxy: {
      "/api": { target: "http://localhost:3000", changeOrigin: true },
      "/admin": { target: "http://localhost:3000", changeOrigin: true },
    },
  },
  build: {
    outDir: "../../public",
    emptyOutDir: false,   // CRITICAL: preserve error pages, favicon, etc.
    manifest: true,
    chunkSizeWarningLimit: 700,
  },
});
```

### `vitest.config.js`, `eslint.config.js`, `playwright.config.js`
Adapted from `comeals-ui` originals with updated paths (`src/**` -> `app/frontend/src/**`, baseURL `3001` -> `3036`).

Playwright `webServer` changes from `npm run build && node server.js` to `npm run build && npx vite preview --port 3036` (no Express).

### Verify
`npm install && npm run build` produces `public/index.html`, `public/assets/`, `public/.vite/manifest.json`.

---

## Phase 3: Copy Static Assets to `public/`

From `comeals-ui/public/` to monorepo `public/`:
- `favicon.ico` (replaces backend's empty placeholder)
- `manifest.json` (PWA manifest)
- `letter-j-icon-11-ffa500-180.png`, `-192.png`, `-512.png`
- `service-worker.js` (no-op, but must stay deployed for unregistration)
- `robots.txt` (replaces comment-only placeholder)

Delete backend's empty `apple-touch-icon.png` and `apple-touch-icon-precomposed.png`.

---

## Phase 4: Update `.gitignore`

Add:
```
/public/index.html
/public/.vite/
/tests/test-results/
```

(`/public/assets` and `/node_modules` are already ignored.)

---

## Phase 5: FallbackController + Route Changes

### New file: `app/controllers/fallback_controller.rb`
```ruby
class FallbackController < ActionController::API
  def index
    send_file Rails.root.join('public', 'index.html'),
              type: 'text/html', disposition: 'inline'
  end

  def vite_manifest
    path = Rails.root.join('public', '.vite', 'manifest.json')
    if path.exist?
      response.headers['Cache-Control'] = 'no-cache'
      send_file path, type: 'application/json', disposition: 'inline'
    else
      head :not_found
    end
  end
end
```

The `vite_manifest` action is needed because Rails' static file server doesn't serve dotfile directories. The `VersionBanner` component polls `/.vite/manifest.json` to detect new deploys.

### Update `config/routes.rb`
```ruby
Rails.application.routes.draw do
  mount LetterOpenerWeb::Engine, at: '/letter_opener' if Rails.env.development?

  # ActiveAdmin (path-based, no subdomain)
  devise_for :admin_users, ActiveAdmin::Devise.config
  ActiveAdmin.routes(self)
  get '/admin-logout', to: 'application#admin_logout'

  # API
  namespace :api do
    namespace :v1 do
      # ... all existing routes unchanged ...
    end
  end

  # Vite manifest (dotfile directory, not served by static file middleware)
  get '.vite/manifest.json', to: 'fallback#vite_manifest'

  # SPA catch-all (must be last)
  root to: 'fallback#index'
  get '*path', to: 'fallback#index',
      constraints: ->(req) { !req.path.start_with?('/api/', '/admin', '/letter_opener') }
end
```

### Update `config/initializers/active_admin.rb`
Remove lines 40-42:
```ruby
# DELETE THIS BLOCK:
config.namespace :admin do |_admin|
  config.route_options = { path: '' }
end
```
This lets ActiveAdmin default to `/admin/*` paths instead of requiring the subdomain.

### Verify
After `npm run build`, start Rails and confirm:
- `localhost:3000/` -> SPA
- `localhost:3000/calendar/meals/2026-04-14` -> SPA (catch-all)
- `localhost:3000/api/v1/version` -> JSON
- `localhost:3000/admin/login` -> ActiveAdmin
- `localhost:3000/.vite/manifest.json` -> Vite manifest
- Run `rails routes | grep devise` and `rails routes | grep admin_logout` to verify helpers

---

## Phase 6: Remove CORS + Fix URL References

### CORS removal
- **`config/application.rb`**: Delete the `Rack::Cors` middleware block (lines 44-52)
- **`Gemfile`**: Remove `gem 'rack-cors'`; run `bundle install`

### URL updates

| File | Change |
|---|---|
| `app/controllers/api_controller.rb:7` | `localhost:3001` -> `localhost:3036` |
| `app/mailers/application_mailer.rb:8` | `localhost:3001` -> `localhost:3036` |
| `app/mailers/application_mailer.rb:12` | `admin.comeals.com` -> `comeals.com/admin`, `admin.lvh.me:3000` -> `localhost:3000/admin` |
| `app/mailers/reconciliation_mailer.rb` | Remove `&subdomain=admin` from URL query strings (lines 11, 21) |
| `config/environments/production.rb:91` | `host: 'admin.comeals.com'` -> `host: 'comeals.com'` |
| `config/environments/development.rb:67` | Delete `config.hosts << 'admin.lvh.me'` |
| `config/environments/development.rb:70` | `host: 'admin.lvh.me:3000'` -> `host: 'localhost', port: 3000` |

### Frontend URL updates

| File | Change |
|---|---|
| `app/frontend/index.html` idle timer | Simplify `navHome()` to `window.location.href = "/"` |
| `app/frontend/src/components/calendar/webcal_links.jsx:47` | `"api.comeals.com"` -> `window.location.host` |

### Gem cleanup
- Remove `xipio` from Gemfile (was for `lvh.me` subdomain routing in dev, no longer needed)

### Verify
- `grep -r 'localhost:3001' app/ config/` returns no results
- `grep -r 'admin\.comeals\.com' app/ config/` returns no results (except docs)
- `bundle exec rspec` passes

---

## Phase 7: Dev Workflow Files

### `Procfile.dev`
```
web: bundle exec rails server -p 3000
js: npx vite
clock: bundle exec ruby lib/clock.rb
```

### `bin/dev` output update
```bash
echo ""
echo "  Comeals:       http://localhost:3036"
echo "  ActiveAdmin:   http://localhost:3036/admin/login"
echo "  Mail inbox:    http://localhost:3000/letter_opener"
echo ""
```

### `.env` (merged)
```
PUSHER_APP_ID=371753
PUSHER_KEY=8affd7213bb4643ca7f1
PUSHER_SECRET=d913e03184efc1b7458f
PUSHER_CLUSTER=us2
VITE_PUSHER_KEY=8affd7213bb4643ca7f1
VITE_PUSHER_CLUSTER=us2
```

### Verify
`bin/dev` starts Rails + Vite + clock. `http://localhost:3036` loads the SPA with HMR. API requests proxy through.

---

## Phase 8: Merge CI Workflows

Single `.github/workflows/ci.yml` with 5 parallel jobs:
1. `ruby-lint` (RuboCop)
2. `ruby-test` (RSpec + PostgreSQL)
3. `node-lint` (ESLint)
4. `node-unit-tests` (Vitest)
5. `node-e2e-tests` (Playwright + Chromium)

---

## Phase 9: Update `bin/deploy`

Simplify the 617-line script for a single Heroku app:
- Remove all `comeals-ui` / frontend app references
- Remove `deploy_frontend()` and related functions
- Keep migration detection, backup, health check logic
- Update health check URLs to `comeals.com` (no `admin.comeals.com`)
- Merge preflight checks (run both Ruby + Node lint/tests)

---

## Phase 10: Heroku Configuration (manual, pre-deploy)

```bash
heroku buildpacks:add --index 1 heroku/nodejs -a comeals-backend
heroku buildpacks:add --index 2 heroku/ruby -a comeals-backend
heroku config:set VITE_PUSHER_KEY=8affd7213bb4643ca7f1 -a comeals-backend
heroku config:set VITE_PUSHER_CLUSTER=us2 -a comeals-backend
```

Node buildpack runs first: `npm install` -> `npm run build` (Vite output to `public/`).
Ruby buildpack runs second: `bundle install` -> `rake assets:precompile` (Sprockets for ActiveAdmin).

---

## Phase 11: Deploy + DNS Cutover

1. `git push heroku main`
2. Smoke test at `comeals-backend.herokuapp.com`
3. Point `comeals.com` DNS to the single Heroku app
4. Scale `comeals-ui` to 0 dynos, eventually delete
5. Keep `admin.comeals.com` DNS briefly for existing bookmarks

---

## Phase 12: Post-Migration Cleanup

- Archive `comeals-backend` and `comeals-ui` repos on GitHub
- Remove `sprockets-rails` / `sassc-rails` if ActiveAdmin doesn't need them (test first)
- Update README and CLAUDE.md

---

## Key Gotchas

1. **`emptyOutDir: false`** in vite.config.js is critical -- without it Vite wipes `public/` including error pages
2. **Dotfile serving**: Rails won't serve `public/.vite/manifest.json` via static middleware, so `FallbackController#vite_manifest` handles it
3. **Buildpack order**: Node MUST run before Ruby on Heroku
4. **ActiveAdmin Devise routes**: After removing subdomain constraint, verify login at `/admin/login` works and `admin_logout_path` helper is still valid
5. **Webcal backward compat**: Existing calendar subscriptions use `api.comeals.com` -- will break unless DNS redirect is maintained
6. **Sprockets + Vite coexist** in `public/assets/` -- different hash patterns, no filename collisions

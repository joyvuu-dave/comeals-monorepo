# Comeals Monorepo: Approach Comparison

## Approaches

| #   | Name                                          | Summary                                                                                                                       |
| --- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| A   | **Two-folder + CI**                           | `backend/` and `frontend/` side by side. CI runs `npm run build`, copies output to `backend/public/`. Ruby-only Heroku.       |
| B   | **Integrated + Vite standalone + CI**         | React source inside Rails (`app/frontend/`). Vite runs as standalone CLI in CI. Output goes to `public/`. No gem.             |
| C   | **Integrated + `vite_rails` gem**             | React source inside Rails. `vite_rails` gem wires Vite into `rake assets:precompile`, provides tag helpers and dev HMR proxy. |
| D   | **Integrated + `jsbundling-rails` + esbuild** | Replace Vite with esbuild via Rails-native `jsbundling-rails`. Faster builds, no HMR.                                         |
| E   | **Docker (Heroku container stack)**           | Multi-stage Dockerfile: Node stage builds frontend, Ruby stage runs Rails. No buildpacks.                                     |
| F   | **Full Hotwire rewrite**                      | Drop React/MobX entirely. Server-rendered views + Turbo + Stimulus + ActionCable.                                             |

### Shared wins (all approaches)

Every approach deletes Express, deletes CORS config, removes Node.js from the Heroku
runtime, consolidates to 1 Heroku app / 1 dyno, and runs local dev with a single
`bin/dev` command.

## Comparison Matrix

| Dimension                   |   A: Two-folder + CI    | B: Integrated Vite + CI |     C: `vite_rails` gem     |     D: `jsbundling` esbuild     |        E: Docker        |    F: Full Hotwire     |
| --------------------------- | :---------------------: | :---------------------: | :-------------------------: | :-----------------------------: | :---------------------: | :--------------------: |
| **React code changes**      |          None           |          None           |     Minimal (~3 lines)      |      Minimal (config only)      |          None           |      Full rewrite      |
| **Node.js needed in CI**    |           Yes           |           Yes           |             Yes             |               Yes               |     No (in Docker)      |           No           |
| **Third-party gem risk**    |          None           |          None           | `vite_rails` (1 maintainer) | `jsbundling-rails` (Rails-core) |          None           |          None          |
| **Pusher still needed**     |           Yes           |           Yes           |             Yes             |               Yes               |           Yes           |    No (ActionCable)    |
| **npm / package.json**      |           Yes           |           Yes           |             Yes             |               Yes               |           Yes           |           No           |
| **Dev: HMR**                |     Yes (two ports)     |     Yes (two ports)     |      Yes (single port)      |     No (full reload, ~50ms)     |           N/A           |    Turbo (instant)     |
| **Dev: single port**        |    No (3000 + 3001)     |    No (3000 + 3036)     |       Yes (3000 only)       |         Yes (3000 only)         |           Yes           |    Yes (3000 only)     |
| **Build tool lock-in**      |    Vite (swappable)     |    Vite (swappable)     |    Vite (coupled to gem)    |       esbuild (swappable)       |    Vite (swappable)     |          None          |
| **Safe `git push heroku`**  | No -- broken deploy\*\* | No -- broken deploy\*\* |   No -- broken deploy\*\*   |     No -- broken deploy\*\*     | Yes (Dockerfile builds) |  Yes (no build step)   |
| **Migration effort**        |          Small          |          Small          |        Small-Medium         |             Medium              |         Medium          |         Large          |
| **Project structure**       |       Two folders       |    Single Rails app     |      Single Rails app       |        Single Rails app         |         Either          |    Single Rails app    |
| **Path to Hotwire later**   |        Possible         | Easy (source in Rails)  |            Easy             |              Easy               |          Easy           |          Done          |
| **Risk if dependency dies** |   Low (Vite is huge)    |           Low           |    Medium (`vite_rails`)    |      Very low (Rails-core)      |           Low           |        Very low        |
| **Conceptual simplicity**   |         Simple          |         Simple          |           Medium            |             Simple              |         Medium          |  Simplest (once done)  |
| **Perf++**                  |        Moderate         |        Moderate         |          Moderate           |            Moderate             |        Moderate         |      Significant       |
| **Prod JS/CSS in GH**       |          No\*           |          No\*           |            No\*             |              No\*               |           No            |     N/A (no build)     |
| **Mobile app path\***       |   Native or Capacitor   |   Native or Capacitor   |     Native or Capacitor     |       Native or Capacitor       |   Native or Capacitor   | Native or Turbo Native |
| **Host portability†**       |        Moderate         |        Moderate         |          Moderate           |            Moderate             |         Maximum         |          High          |

### Host portability detail

The industry has two deployment models: **buildpacks** (platform auto-detects your
stack and builds a slug) and **Docker** (you provide a container image). The trend
is toward Docker as the universal unit — most new platforms are Docker-first.

**Platform compatibility by approach:**

| Platform                  |  Buildpacks?   |  Docker?  |  A-D (no Dockerfile)  | E (has Dockerfile) |  F (simple Rails)  |
| ------------------------- | :------------: | :-------: | :-------------------: | :----------------: | :----------------: |
| **Heroku**                |      Yes       |    Yes    |      Works today      |    Works today     |    Works today     |
| **Railway**               | Yes (Nixpacks) |    Yes    |         Easy          |        Easy        |        Easy        |
| **Render**                |      Yes       |    Yes    |         Easy          |        Easy        |        Easy        |
| **DO App Platform**       |      Yes       |    Yes    |         Easy          |        Easy        |        Easy        |
| **DO Droplet (VPS)**      |       No       | Via Kamal | Need Dockerfile first |       Ready        | Trivial Dockerfile |
| **Coolify (self-hosted)** |       No       |    Yes    | Need Dockerfile first |       Ready        | Trivial Dockerfile |
| **Fly.io**                |       No       |    Yes    | Need Dockerfile first |       Ready        | Trivial Dockerfile |
| **GCP Cloud Run**         |       No       |    Yes    | Need Dockerfile first |       Ready        | Trivial Dockerfile |
| **GCP App Engine**        |      Yes       |    Yes    |         Easy          |        Easy        |        Easy        |
| **AWS ECS / Fargate**     |       No       |    Yes    | Need Dockerfile first |       Ready        | Trivial Dockerfile |
| **AWS App Runner**        |       No       |    Yes    | Need Dockerfile first |       Ready        | Trivial Dockerfile |
| **Tanzu (Cloud Foundry)** |    Yes (CF)    |    Yes    |   Needs adaptation‡   |        Easy        |        Easy        |
| **Kamal (any VPS)**       |       No       |    Yes    | Need Dockerfile first |       Ready        | Trivial Dockerfile |

‡ Tanzu uses Cloud Foundry buildpacks, not Heroku buildpacks. Same concept,
different implementation. The Procfile and build hooks may need adjustment.

**Summary:**

- **E (Docker)**: "Ready" everywhere. The Dockerfile is already written and tested.
  Moving hosts is a configuration change, not a development task. This is the most
  portable option by a wide margin.
- **F (Hotwire)**: "Trivial Dockerfile" for Docker-native platforms because there's
  no Node.js build stage — just `FROM ruby, COPY, bundle install, CMD puma`. Five
  lines. Also works on any buildpack platform without Docker.
- **A-D (no Dockerfile)**: Work on buildpack-compatible platforms (Heroku, Railway,
  Render, DO App Platform, GCP App Engine) with minimal changes. For Docker-native
  platforms (Coolify, Cloud Run, Fly.io, ECS, Kamal), you'd need to write a
  multi-stage Dockerfile first — the same one approach E already has. Not hard, but
  it's a task you'd face at migration time rather than having it done upfront.

**Bottom line:** if host portability matters to you, E gives you it for free today.
A-D can get there by writing a Dockerfile when the time comes. F is inherently
simple to deploy anywhere.

### Mobile app path detail

**Fully native (Swift/Kotlin)** apps just consume the JSON API. Every approach
preserves the API, so this path is equally open regardless of frontend choice.

**A-E (React kept)**: The React SPA is a perfect Cordova/Capacitor target. You
run `vite build`, point Capacitor at the `build/` output, and you have a mobile
app. All React components, MobX stores, and routing work in the WebView. One small
change: Axios base URL must become absolute (`https://comeals.com/api/v1/...`)
since there's no server to proxy through. React Native is also an option — you
can share MobX stores and API logic (but not UI components, which must be rewritten
in React Native's component model).

**F (Hotwire)**: Cordova/Capacitor is a poor fit because every page requires a
server round-trip — the app is useless without network and feels like a bookmark.
The natural mobile path is **Turbo Native** (iOS and Android libraries by
37signals). It wraps server-rendered HTML in a native shell with native navigation
transitions. This is how the HEY email app works. The tradeoff: the app requires
connectivity, but for a co-housing dinner signup app that's likely fine.

### Safe `git push heroku` detail

\*\* For A-D: if you forget CI and do a raw `git push heroku main`, Heroku's Ruby
buildpack will deploy the Rails app WITHOUT built frontend assets. The site will
serve a blank page (no JS/CSS). This is the biggest operational footgun of
approaches A-D.

**Mitigations** (pick one or combine):

1. **Release-phase guard** (recommended) — add a check in Procfile's `release:` step:

   ```ruby
   # lib/tasks/deploy.rake
   task :verify_assets do
     abort "FATAL: Frontend assets missing! Deploy via CI, not git push." unless
       File.exist?(Rails.root.join("public", "assets", ".manifest.json"))
   end
   ```

   ```
   # Procfile
   release: bin/rake verify_assets db:migrate
   ```

   Deploy fails fast with a clear error instead of silently serving a broken site.

2. **Remove the heroku git remote** — if there's no remote, you can't accidentally
   push. CI is the only deploy path. Your existing `bin/deploy` script would be
   updated to deploy via CI trigger instead of `git push heroku`.

3. **Wrap deploys in `bin/deploy`** — your existing deploy script already gates
   deploys behind pre-flight checks. Extend it to build assets (or trigger CI)
   before pushing. Nobody should be deploying outside this script anyway.

**E (Docker)**: `git push heroku main` with a `heroku.yml` triggers a Docker build,
which includes the asset build step in the Dockerfile. It just works — you can't
forget because the Dockerfile won't let you.

**F (Hotwire)**: no build step to forget. `git push heroku main` just works.

### Perf++ detail

All approaches (A-F) eliminate the cross-origin Express proxy hop — today every API
call travels Browser → Express (comeals-ui dyno) → Rails (comeals-backend dyno) → back.
After consolidation it's just Browser → Rails. That's the main win and it applies equally
to A through E.

**F (Hotwire)** goes further: no large JS bundle download, no client-side routing
overhead, no MobX hydration. Initial page load is just HTML. Subsequent navigations
fetch small HTML fragments instead of JSON + client-side rendering.

### Prod JS/CSS in GH detail

\* For A-D, it depends on how CI deploys to Heroku:

- **CI pushes directly to Heroku** (via `git push heroku` or Heroku Platform API):
  built assets exist only in the CI runner's workspace and Heroku's slug. Never in GitHub. **Recommended.**
- **Heroku auto-deploys from a GitHub branch**: built assets must be committed to a
  deploy branch in GitHub. They would NOT be on `main` — only on a `heroku-deploy` branch.

**E (Docker)**: assets are built inside the Docker image and never committed anywhere.

**F (Hotwire)**: no JS/CSS build step exists, so nothing to commit.

## Quick Decision Guide

- **Least effort, least change**: A (Two-folder + CI) or B (Integrated Vite + CI)
- **Best dev experience keeping React**: C (`vite_rails`) -- but single-maintainer risk
- **Most "Rails-native" while keeping React**: D (`jsbundling-rails` + esbuild)
- **Avoid all buildpacks**: E (Docker)
- **Best long-term, most upfront work**: F (Full Hotwire)
- **No third-party gem risk**: A, B, or E
- **Safe from "oops I forgot to build"**: E or F

## Key Differences Between A and B

A and B are very similar. The only difference is project structure:

- **A**: `monorepo/backend/` + `monorepo/frontend/` -- two peers. Feels like two projects sharing a repo. Heroku deploys the `backend/` subtree.
- **B**: React source lives inside the Rails app at `app/frontend/`. One project. Heroku deploys the whole thing. Slightly more integrated, slightly easier path to Hotwire later.

## Key Differences Between B and D

B and D both have React inside Rails with no risky gem dependency. The difference is the build tool:

- **B (Vite)**: Keep your existing vite.config.js. HMR in dev (two ports). Larger ecosystem of Vite plugins.
- **D (esbuild)**: Swap Vite for esbuild via `jsbundling-rails`. No HMR (page reloads, but esbuild rebuilds in ~50ms so you barely notice). Official Rails gem. Simpler config. One fewer tool to understand.

Switching from Vite to esbuild requires adjusting the build config but no React code changes -- they both produce the same JS/CSS bundles.

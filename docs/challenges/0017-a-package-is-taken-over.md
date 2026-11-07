---
id: 17
title: A gem or npm package is taken over
area: security
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - bin/npm-audit
---

# A gem or npm package is taken over

## The challenge

A malicious new version of a package we depend on does not reach production.

## The case that breaks it

1. An attacker gets the publishing key for a small npm package that one of our packages uses.
2. They publish a patch version that sends the page's sign-in token to their server.
3. The nightly update takes the new version, the tests pass (the code still works), the update is pushed to main, and the next deploy ships it.

## Where we stand

- `Gemfile.lock` and `package-lock.json` pin every version, with checksums.
- bundler-audit and `bin/npm-audit` fail `bin/check` and CI on known advisories. A known advisory is only found after someone reports it.
- Every night, `.github/workflows/nightly-deps.yml` updates every gem and npm package, runs the full `bin/check`, and pushes the new lock files to main when everything passes. So a new version can be on main the night after it is published.
- Not checked: whether any check waits before taking a version that was published hours ago.

## Options

1. **Wait before taking a new version** (for example 7 days after it is published), so most takeovers are found and pulled before we take them. npm and Bundler can do this with a setting or a small script.
2. **Read the diff of every new version** of a package the browser loads. Costly, by hand.
3. **A Content Security Policy** that limits where the page can send data. That stops step 2 from reaching the attacker's server. The CSP settings in `config/initializers/content_security_policy.rb` are all commented out, so production sends no CSP.

## History

- 2026-11-07: Opened.

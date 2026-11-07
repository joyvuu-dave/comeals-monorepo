---
id: 25
title: Build the app again in 20 years
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Build the app again in 20 years

## The challenge

Anyone can build and run today's commit, years from now, and get the same app.

## The case that breaks it

In 2046 someone checks out today's commit to find out how a 2026 dinner was charged. Ruby 4.0 does not build on their computer, three gems were removed from rubygems.org, and an npm package's registry entry is gone. They cannot run the code.

## Where we stand

- `Gemfile.lock` and `package-lock.json` pin exact versions, and `.node-version` and `engines` name the Node version (AGENTS.md).
- The packages themselves are not stored with the code.
- Not tried: building an old commit from scratch.

## Options

1. **Store the packages:** `bundle cache` puts every gem in the repo; npm can do the same with a package cache.
2. **A full build description** (Nix, or a container image saved for each release) that also fixes Ruby, Node, PostgreSQL and the system libraries.
3. **A yearly test:** build the release from one year earlier on a clean machine, and write down what failed.

## History

- 2026-11-07: Opened.

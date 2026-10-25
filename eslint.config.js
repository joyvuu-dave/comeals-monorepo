const js = require("@eslint/js");
const react = require("eslint-plugin-react");
const reactHooks = require("eslint-plugin-react-hooks");
const globals = require("globals");
const tseslint = require("typescript-eslint");

module.exports = [
  // Base: ESLint recommended rules for all JS files
  js.configs.recommended,

  // -----------------------------------------------------------
  // Source files (app/frontend/src/**) -- browser ESM with JSX
  // -----------------------------------------------------------
  {
    files: ["app/frontend/src/**/*.{js,jsx}"],
    plugins: {
      react,
      "react-hooks": reactHooks,
    },
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
      globals: {
        ...globals.browser,
        // Baked in at build time by the `define` block in vite.config.mjs.
        __BUILD_ID__: "readonly",
      },
    },
    settings: {
      react: {
        version: "detect",
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-console": ["warn", { allow: ["error", "warn"] }],

      "react/jsx-uses-react": "off",
      "react/jsx-uses-vars": "error",
      "react/no-direct-mutation-state": "error",
      "react/no-deprecated": "warn",
      "react/jsx-no-duplicate-props": "error",
      "react/jsx-no-undef": "error",
      "react/jsx-key": "warn",
      "react/no-unknown-property": "error",

      "react/prop-types": "off",
      "react/display-name": "off",
      "react/react-in-jsx-scope": "off",

      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
    },
  },

  // -----------------------------------------------------------
  // Config files -- Node ESM
  // -----------------------------------------------------------
  {
    files: [
      "vite.config.mjs",
      "vitest.config.mjs",
      "playwright.integration.config.js",
    ],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        ...globals.node,
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-console": "off",
    },
  },

  // -----------------------------------------------------------
  // Config files -- Node CommonJS (playwright.config.js)
  // -----------------------------------------------------------
  {
    files: ["playwright.config.js", "tests/bin/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: {
        ...globals.node,
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-console": "off",
    },
  },

  // -----------------------------------------------------------
  // E2E test files -- Node CommonJS (Playwright)
  // -----------------------------------------------------------
  {
    files: [
      "tests/e2e/**/*.js",
      "tests/admin/**/*.js",
      "tests/helpers/**/*.js",
      "tests/smoke/**/*.js",
    ],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: {
        ...globals.node,
        window: "readonly",
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-console": "off",
    },
  },

  // -----------------------------------------------------------
  // Unit test files -- Node ESM (Vitest). The glob must include .jsx:
  // with only *.js here, ESLint skipped every component test and
  // reported nothing (#52).
  // -----------------------------------------------------------
  {
    files: ["tests/unit/**/*.{js,jsx}"],
    plugins: {
      react,
    },
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
      globals: {
        // Vitest runs these in jsdom: browser globals are real, and
        // Node globals cover the setup helpers.
        ...globals.browser,
        ...globals.node,
        window: "writable",
      },
    },
    settings: {
      react: {
        version: "detect",
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-console": "off",
      "react/jsx-uses-vars": "error",
      "react/jsx-no-undef": "error",
    },
  },

  // -----------------------------------------------------------
  // Integration test files -- Node CommonJS (Playwright, real backend)
  // -----------------------------------------------------------
  {
    files: ["tests/integration/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: {
        ...globals.node,
        window: "readonly",
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-console": "off",
    },
  },

  // -----------------------------------------------------------
  // The browser check, written into index.html by vite.config.mjs.
  // It must run in the old browsers it turns away, so it is held to
  // ES5: no let, const, arrow functions, template strings, or comma
  // after a call's last argument. Any of those is a parse error here.
  // -----------------------------------------------------------
  {
    files: ["app/frontend/browser_check.js"],
    languageOptions: {
      ecmaVersion: 5,
      sourceType: "script",
      globals: {
        window: "readonly",
        encodeURIComponent: "readonly",
      },
    },
    rules: {
      // ES5 has no catch without a name, so an error that is not used
      // still needs one.
      "no-unused-vars": ["error", { caughtErrors: "none" }],
    },
  },

  // The build target, read by vite.config.mjs and the unit tests.
  {
    files: ["app/frontend/browser_target.mjs"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
    },
  },

  // -----------------------------------------------------------
  // Hand-written browser scripts served from public/
  // -----------------------------------------------------------
  {
    files: ["public/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: {
        ...globals.browser,
        ...globals.serviceworker,
      },
    },
    rules: {
      "no-console": "off",
    },
  },

  // -----------------------------------------------------------
  // TypeScript, wherever it lives (app/frontend/src and tests/unit).
  // typescript-eslint's recommended rules, scoped to .ts/.tsx by
  // tseslint.config's `extends`. Type-aware rules are not on: they need
  // the TypeScript program for every lint run, and `npm run typecheck`
  // already runs it once. TypeScript itself is pinned to the 6.x line in
  // package.json because typescript-eslint has no parser for the native
  // 7.x compiler yet (it has no JavaScript API); move back to 7 when it
  // does. Every .ts file used to be type-checked but never linted.
  // -----------------------------------------------------------
  ...tseslint.config({
    files: ["**/*.{ts,tsx}"],
    extends: [...tseslint.configs.recommended],
    // The same hook rules as the .js/.jsx source files, so a hook
    // written in TypeScript (helpers/use_form_messages.ts) is checked
    // too.
    plugins: {
      "react-hooks": reactHooks,
    },
    languageOptions: {
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
    rules: {
      "no-console": ["warn", { allow: ["error", "warn"] }],
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
    },
  }),

  // -----------------------------------------------------------
  // Unit tests in any language: Vitest's own waits go through
  // tests/unit/helpers/wait_for.js, which gives them the same 10 second
  // limit as Testing Library's waits instead of Vitest's 1 second
  // (#247). After the TypeScript block, so its rules do not replace
  // this one.
  // -----------------------------------------------------------
  {
    files: ["tests/unit/**/*.{js,jsx,ts,tsx}"],
    rules: {
      "no-restricted-properties": [
        "error",
        {
          object: "vi",
          property: "waitFor",
          message:
            "Use vitestWaitFor from tests/unit/helpers/wait_for.js. It waits up to 10 seconds, not 1 (#247).",
        },
        {
          object: "vi",
          property: "waitUntil",
          message:
            "Use vitestWaitUntil from tests/unit/helpers/wait_for.js. It waits up to 10 seconds, not 1 (#247).",
        },
      ],
    },
  },

  // -----------------------------------------------------------
  // Ignore build output, dependencies, and this config file
  // -----------------------------------------------------------
  {
    ignores: [
      "public/assets/**",
      // Vite build output (28c66c3 split it out of public/assets).
      // ESLint does not read .gitignore, so it needs its own entry.
      "public/vite-assets/**",
      "node_modules/**",
      "eslint.config.js",
      // Sprockets-era ActiveAdmin script; lives outside the Vite world.
      "app/assets/**",
      // Generated output and reports.
      "coverage/**",
      "playwright-report/**",
      "test-results/**",
      "log/**",
      "tmp/**",
      // Gems installed into the tree. CI's setup-ruby puts them in
      // vendor/bundle, and gems ship their own browser JS (the
      // 2026-08-17 nightly run failed on rack-mini-profiler's files).
      "vendor/**",
    ],
  },
];

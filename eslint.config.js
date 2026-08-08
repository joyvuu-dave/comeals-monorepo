const js = require("@eslint/js");
const react = require("eslint-plugin-react");
const reactHooks = require("eslint-plugin-react-hooks");
const globals = require("globals");

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
    files: ["playwright.config.js"],
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
  // Unit test files -- Node ESM (Vitest). The .jsx glob matters: with
  // only *.js here, every component test was silently unlinted (#52).
  // -----------------------------------------------------------
  {
    // .ts is absent on purpose: eslint has no TypeScript parser here,
    // and `npm run typecheck` (tsc) is the gate for those files.
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
    ],
  },
];

// #28: uncontrollable 7.2.1, which react-big-calendar uses, was built
// with the old JSX transform. One React.createElement call in it passes
// the debug props __source and __self. In development React 19 prints
// "outdated JSX transform" the first time it sees __self in such a
// call, on every page load, and then drops both props. So removing
// them changes nothing the page does; it only removes the warning.
//
// The dev server bundles a package like this once (optimizeDeps), and
// this plugin runs inside that step, on that one file. `vite build`
// does not use it, and React's production build never checks for the
// props. tests/unit/strip_old_jsx_props.test.js fails when the
// installed uncontrollable is no longer 7.2.1: then the upstream fix
// (react-big-calendar PR #2805) has shipped and this file can go.

export const UNCONTROLLABLE_VERSION = "7.2.1";

export const UNCONTROLLABLE_FILE =
  /[\\/]node_modules[\\/]uncontrollable[\\/]lib[\\/]esm[\\/]uncontrollable\.js$/;

const OLD_PROPS =
  /,\s*__source: \{\s*fileName: _jsxFileName,\s*lineNumber: \d+\s*\},\s*__self: this(?=\s*\})/g;

export function stripOldJsxProps(code) {
  return code.replace(OLD_PROPS, "");
}

export default function stripOldJsxPropsPlugin() {
  return {
    name: "strip-old-jsx-props",
    transform(code, id) {
      if (!UNCONTROLLABLE_FILE.test(id)) return null;
      return { code: stripOldJsxProps(code), map: null };
    },
  };
}

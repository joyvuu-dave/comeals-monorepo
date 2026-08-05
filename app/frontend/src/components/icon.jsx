// The four icons the app uses, inlined as SVG paths. The path data comes
// from Font Awesome Free 7.3.1 (https://fontawesome.com), icons licensed
// CC BY 4.0. Inlining them replaced the three @fortawesome packages, whose
// rendering runtime cost 95 KB (25 KB gzipped) in the bundle (#44).
const ICONS = {
  "chevron-left": {
    width: 320,
    path: "M9.4 233.4c-12.5 12.5-12.5 32.8 0 45.3l192 192c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3L77.3 256 246.6 86.6c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0l-192 192z",
  },
  "chevron-right": {
    width: 320,
    path: "M311.1 233.4c12.5 12.5 12.5 32.8 0 45.3l-192 192c-12.5 12.5-32.8 12.5-45.3 0s-12.5-32.8 0-45.3L243.2 256 73.9 86.6c-12.5-12.5-12.5-32.8 0-45.3s32.8-12.5 45.3 0l192 192z",
  },
  xmark: {
    width: 384,
    path: "M55.1 73.4c-12.5-12.5-32.8-12.5-45.3 0s-12.5 32.8 0 45.3L147.2 256 9.9 393.4c-12.5 12.5-12.5 32.8 0 45.3s32.8 12.5 45.3 0L192.5 301.3 329.9 438.6c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3L237.8 256 375.1 118.6c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0L192.5 210.7 55.1 73.4z",
  },
  "arrow-left": {
    width: 512,
    path: "M9.4 233.4c-12.5 12.5-12.5 32.8 0 45.3l160 160c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3L109.3 288 480 288c17.7 0 32-14.3 32-32s-14.3-32-32-32l-370.7 0 105.4-105.4c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0l-160 160z",
  },
};

// The base style copies what fontawesome-svg-core injected at runtime:
// the icon is 1em tall, keeps its own aspect ratio, and sits slightly
// below the text baseline. `size` scales it ("2x" → 2em).
const baseStyle = {
  display: "inline-block",
  height: "1em",
  verticalAlign: "-0.125em",
  overflow: "visible",
};

const Icon = ({ name, size, style, className, ...rest }) => {
  const { width, path } = ICONS[name];
  return (
    <svg
      viewBox={`0 0 ${width} 512`}
      className={className ? `icon-${name} ${className}` : `icon-${name}`}
      style={{
        ...baseStyle,
        ...(size ? { fontSize: `${parseInt(size, 10)}em` } : {}),
        ...style,
      }}
      aria-hidden={rest["aria-label"] ? undefined : true}
      focusable="false"
      {...rest}
    >
      <path fill="currentColor" d={path} />
    </svg>
  );
};

export default Icon;

// Separate esbuild entry point: the Vega runtime, ~812KB of vendored JS.
//
// It lives outside js/app.js on purpose. Only the leaderboard draws a chart, so
// bundling this into the main app would make every challenge page pay for it.
// The VegaChart hook in app.js injects /assets/vega.js on demand and waits for
// window.vegaEmbed to appear.
//
// The vendored files under assets/vendor are UMD builds that reference each
// other by bare specifier ("vega", "vega-lite"), which esbuild resolves via the
// --alias: flags in config/config.exs and nix/package.nix. There is no npm
// install anywhere in this project — the Nix release build runs esbuild in a
// sandbox with NODE_PATH pointed at the Elixir deps directory — so vendoring is
// what keeps the dev build and the release build agreeing.
import vegaEmbed from "vega-embed"

window.vegaEmbed = vegaEmbed

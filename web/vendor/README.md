# Vendored libraries

Served as-is with the web client (no build step). Downloaded from jsDelivr.

| File | Package | Version | License |
|---|---|---|---|
| `xterm.js`, `xterm.css` | [@xterm/xterm](https://github.com/xtermjs/xterm.js) (`lib/xterm.js`, `css/xterm.css`) | 5.5.0 | MIT, `LICENSE-xterm` |
| `addon-fit.js` | [@xterm/addon-fit](https://github.com/xtermjs/xterm.js/tree/master/addons/addon-fit) (`lib/addon-fit.js`) | 0.10.0 | MIT, `LICENSE-addon-fit` |

To update, fetch the same paths for the new version, e.g.
`https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js`, and change the
versions here.

Fonts (docs/UI.md: Inter for the UI, JetBrains Mono for terminals), the
variable Latin subsets from Fontsource on jsDelivr:

| File | Package | Version | License |
|---|---|---|---|
| `fonts/inter-latin-wght-normal.woff2` | [@fontsource-variable/inter](https://fontsource.org/fonts/inter) (`files/`) | 5.1.0 | SIL OFL 1.1, `LICENSE-inter` |
| `fonts/jetbrains-mono-latin-wght-normal.woff2` | [@fontsource-variable/jetbrains-mono](https://fontsource.org/fonts/jetbrains-mono) (`files/`) | 5.1.0 | SIL OFL 1.1, `LICENSE-jetbrains-mono` |

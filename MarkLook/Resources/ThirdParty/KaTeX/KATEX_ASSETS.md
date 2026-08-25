# KaTeX vendored assets

- Version: 0.18.1
- Upstream: <https://github.com/KaTeX/KaTeX>
- Package: `katex@0.18.1`
- Package integrity: `sha512-Td8GCYSxDAoMhHOlKmCFMJ/hz5qlAAb71n66Dryw9nfCVfumLo7nhuotbvKom/XPADmrYC3O5QR71EPq4DarJQ==`
- Tarball SHA-256: `7e6100b7fe6439ba91d918d8cb2873171a9fdec979281d508959cf5f7dba1da8`
- License: MIT; see `KATEX_LICENSE.txt`

`katex.min.js` and `katex.min.css` are unmodified files from the package's
`dist` directory. The `fonts` directory contains exactly the 60 font files
referenced by `katex.min.css`; no unreferenced package content is included.

To update, download the pinned npm package, verify its published integrity,
replace the two minified distribution files, and recopy only the paths found
in `url(fonts/...)` declarations in the stylesheet.

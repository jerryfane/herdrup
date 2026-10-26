# Bundled mermaid

The Chat view draws closed ```` ```mermaid ```` fences with this copy of mermaid
(`App/MermaidRenderer.swift`, #523 item 1). Nothing is downloaded at run time.

| | |
| --- | --- |
| Package | `mermaid` 11.17.2 (latest 11.x on npm at vendoring, 2026-10-25) |
| Tarball | https://registry.npmjs.org/mermaid/-/mermaid-11.17.2.tgz |
| Tarball sha256 | `6ad2f42c3fc26bbf9e45cbb6d11898972573ea52b33a5f4ff51952899f950ffd` |
| Tarball sha1 (npm `shasum`) | `e3caf3717582c0e44e5d04cff043e025caec7cba` |
| File | `package/dist/mermaid.min.js`, unmodified, 3,572,661 bytes |
| `mermaid.min.js` sha256 | `581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8` |
| Licence | MIT, `package/LICENSE` copied as `Mermaid-LICENSE.txt` |

`mermaid.html` is ours: the empty page the renderer loads, with a CSP that allows no page
script and no loads.

To update: download the new tarball, check its `dist.shasum`/`dist.integrity` against
`https://registry.npmjs.org/mermaid/<version>`, copy `package/dist/mermaid.min.js` and
`package/LICENSE` here, update this table, and set `MermaidRenderer.libraryVersion` (it is
part of the render cache key, so images drawn by the old version are not reused).

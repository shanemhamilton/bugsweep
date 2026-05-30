# Anti-pattern library — index

Curated, offline catalogs of high-impact, framework-specific bug patterns used to prime
the Hunt phase. **Always load `generic.md` and `architectural.md`** plus the file(s)
matching the detected stack.

| If the repo uses… | Load |
| --- | --- |
| TypeScript | `typescript.md` + (`javascript-node.md` if Node/Express backend, `react.md` if React) + `generic.md` + `architectural.md` |
| Node.js, Express, Fastify, Nest, plain JS backend | `javascript-node.md` + `generic.md` + `architectural.md` |
| React, React Native, Next.js (client) | `react.md` + (`typescript.md` if TS) + `generic.md` + `architectural.md` |
| Swift, SwiftUI, UIKit, iOS (any Swift) | `swift-ios.md` + `generic.md` + `architectural.md` |
| Kotlin, Android, Kotlin coroutines | `kotlin.md` + `generic.md` + `architectural.md` |
| Python, Django, Flask, FastAPI | `python.md` + `generic.md` + `architectural.md` |
| Go | `go.md` + `generic.md` + `architectural.md` |
| Anything else | `generic.md` + `architectural.md` (and infer from the closest match) |

`architectural.md` is **always included regardless of stack** — it covers cross-file
and cross-package patterns (SSRF chains, auth bypass via secondary path, taint
propagation across boundaries, contract drift, inconsistent middleware) that are blind
spots for per-file scanning on every language.

Stacks combine — load every file that applies. A Next.js + TypeScript app loads
`react.md` + `typescript.md` + `javascript-node.md` + `generic.md` + `architectural.md`.
An Android app in Kotlin loads `kotlin.md` + `generic.md` + `architectural.md`.

These are starting points, not limits. Combine with the repo-context model and, if
enabled, web research for version-specific issues. Each entry is a *smell* to look for and
*why it bites* — confirm against the actual code before reporting.

## Catalog version (contributor note)

`VERSION` in this directory is the catalog version. bugsweep stamps it on every
per-file audit event in its cross-run state. When a file was last audited under an
*older* catalog version, the coverage layer treats it as **stale** and re-queues it —
so newly added rules get a chance to find bugs in code that was already reviewed.

**When you add, materially change, or expand any catalog in this directory, bump
`VERSION`** (integer or dotted, e.g. `1` → `2`). Forgetting to bump it means existing
repos will not re-audit old files against your new rule. Pure typo/wording fixes that
add no new detection do not require a bump.

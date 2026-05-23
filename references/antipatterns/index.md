# Anti-pattern library — index

Curated, offline catalogs of high-impact, framework-specific bug patterns used to prime
the Hunt phase. Always load `generic.md` plus the file(s) matching the detected stack.

| If the repo uses… | Load |
| --- | --- |
| TypeScript | `typescript.md` + (`javascript-node.md` if Node/Express backend, `react.md` if React) + `generic.md` |
| Node.js, Express, Fastify, Nest, plain JS backend | `javascript-node.md` + `generic.md` |
| React, React Native, Next.js (client) | `react.md` + (`typescript.md` if TS) + `generic.md` |
| Swift, SwiftUI, UIKit, iOS (any Swift) | `swift-ios.md` + `generic.md` |
| Kotlin, Android, Kotlin coroutines | `kotlin.md` + `generic.md` |
| Python, Django, Flask, FastAPI | `python.md` + `generic.md` |
| Go | `go.md` + `generic.md` |
| Anything else | `generic.md` (and infer from the closest match) |

Stacks combine — load every file that applies. A Next.js + TypeScript app loads
`react.md` + `typescript.md` + `javascript-node.md` + `generic.md`. An Android app in
Kotlin loads `kotlin.md` + `generic.md`.

These are starting points, not limits. Combine with the repo-context model and, if
enabled, web research for version-specific issues. Each entry is a *smell* to look for and
*why it bites* — confirm against the actual code before reporting.

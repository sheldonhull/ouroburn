---
paths: ["Sources/Ouroburn/**"]
---

# Build-verify

- After UI/source changes, verify with `mise run relaunch` (kills the running app, rebuilds the debug `.app`, relaunches). `swift build` alone leaves a stale menu-bar binary running — don't claim a UI change is visible until relaunched.

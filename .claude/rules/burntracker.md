---
paths: ["Sources/Ouroburn/Core/BurnTracker.swift"]
---

# BurnTracker

- Alert gating + spend math go in pure `static` funcs (mirror `oauthSpend` / `monthlyProjection` / `shouldFireProjectionAlert`) with unit tests — never bury decision logic inside `state.withLock`. The lock block should just call the static and store the result.

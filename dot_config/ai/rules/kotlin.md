---
paths:
  - "**/*.kt"
  - "**/*.kts"
---

- Data classes for DTOs and general domain modeling
- Value classes for value objects
- Sealed classes/interfaces for type hierarchies
- Prefix boolean properties verbs, e.g, `isEnabled` over `enabled`
- `PascalCase` enum entries
- Coroutines over callbacks
  - Convert library callbacks into coroutines using `suspendCancellableCoroutine`
  - Convert library listeners into flows using flow builders 
- Inline references in KDoc comments with `[foo.bar.Baz]` syntax

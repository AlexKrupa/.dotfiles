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
- Empty function body: use `= Unit` expression over empty lambda `{}`
- Coroutines over callbacks
  - Convert library callbacks into coroutines using `suspendCancellableCoroutine`
  - Convert library listeners into flows using flow builders
- If catching generic `Exception` in a coroutines `suspend` function, handle `CancellationException`
  by calling `currentCoroutineContext().ensureActive()`
- Inline references in KDoc comments with `[foo.bar.Baz]` syntax

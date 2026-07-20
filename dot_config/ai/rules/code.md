---
paths:
  - "**/*.{kt,kts,java,groovy,swift,py,ts,tsx,js,jsx,go,rs,rb,c,cpp,h,hpp,cs,dart,lua,php,sql}"
  - "**/{Dangerfile,Dockerfile,Makefile}"
---

- Match existing code style, not your preference
- Formatting follows the "rectangle rule": "each subtree gets its own bounding rectangle, containing
  all of that subtree’s text and none of any other subtree’s"
- Guard clauses over nested conditionals
- Prefer positive invariants, not negated conditions
  - `if (index < size) { holds } else { doesn't }`, not `if (index >= size)`
- Push ifs up - hoist branching to the caller, keep helpers branch-free on that condition
- Push fors down - push loops into the function owning the collection, pass whole collections, not
  elements
- Match enum/sealed hierarchies exhaustively (no catch-all `else`/`default`) so a new variant fails
  at compile time instead of silently falling through
- Code comments (inline and doc):
  - Explain WHY, not WHAT
  - Exist only when the WHY is not obvious
  - Are BRIEF and only provide relevant information, not transient conversation context
  - A comment to generic code must not reference specific code
- Include context in logs and error messages
- Only clean up things your changes made unused
- Avoid abbreviations, unless very local or obvious from domain context and they aid readability
- Prefer paired names of equal length so call sites align (`source`/`target`, not `src`/`dest`).
  Don't force it when equal length isn't natural
- Numbers:
  - Keep index (0-based), count (1-based), and size (units) distinct
  - Carry the unit in the name (`rowIndex`, `rowCount`, `sizeBytes`)
  - Make rounding explicit at the call site (ceil- vs floor-div)
- Declare variables at the smallest scope, close to first use. Don't hoist early or alias

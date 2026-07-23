---
paths:
  - "**/*.{kt,kts,java,groovy,swift,py,ts,tsx,js,jsx,go,rs,rb,c,cpp,h,hpp,cs,dart,php,lua,sql}"
  - "**/*.{sh,fish,yml,yaml,xml}"
  - "**/{Dangerfile,Dockerfile,Makefile}"
---

## Style

- Match existing code style, not your preference
- Formatting follows the "rectangle rule": "each subtree gets its own bounding rectangle, containing
  all of that subtree’s text and none of any other subtree’s"

## Control flow

- Guard clauses over nested conditionals
- Prefer positive invariants, not negated conditions
  - `if (index < size) { holds } else { doesn't }`, not `if (index >= size)`
- Push ifs up - hoist branching to the caller, keep helpers branch-free on that condition
- Push fors down - push loops into the function owning the collection, pass whole collections, not
  elements
- Match enum/sealed hierarchies exhaustively (no catch-all `else`/`default`) so a new variant fails
  at compile time instead of silently falling through

## Naming

- Avoid abbreviations, unless very local or obvious from domain context and they aid readability
- Prefer paired names of equal length so call sites align (`source`/`target`, not `src`/`dest`).
  Don't force it when equal length isn't natural

## Comments (inline and doc)

- Explain WHY, not WHAT - exist only when the WHY is not obvious
- Are extremely concise and only provide relevant information
- No conversation residue: nothing about what changed, "now handles", "previously"
- A comment to generic code must not reference specific callers or cases

## Other

- Declare variables at the smallest scope, close to first use. Don't hoist early or alias
- Include context in logs and error messages
- Only clean up things your changes made unused
- Numbers:
  - Keep index (0-based), count (1-based), and size (units) distinct
  - Carry the unit in the name (`rowIndex`, `rowCount`, `sizeBytes`)
  - Make rounding explicit at the call site (ceil- vs floor-div)

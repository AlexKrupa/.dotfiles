# Review guide rules

Shared by `review-diff` (review reports) and `draft-pr` (PR descriptions). Each skill adds its own
parts: `review-diff` adds findings, `draft-pr` adds commit-by-commit review.

## High-impact changes

A high-impact change is a correct and intended change that a reader must know about before merge,
because it is hard to undo or affects many places. The commit messages and the diff tell you if a
change is intended.

Mark a change only when it is one of these, with its evidence:

- **One-way door** - the change alters or removes data that stays after a deploy, and an undo needs
  a migration or loses data: DB schema and migrations, serialized or stored fields, storage keys,
  cache keys or cached formats, file formats, analytics event names, deep links, flag names, data
  deletion. Evidence: the stored artifact and the line that writes it.
- **Wide reach** - the change alters the behavior of an existing shared utility, base class, shared
  DI module, or build logic that many places use. Evidence: the call-site or module count from a
  search. Use judgment for "many". A new shared symbol with few callers is not wide reach.
- **Contract break** - a network or schema contract (GraphQL, REST, protobuf) changes so that older
  or newer clients cannot read it. Evidence: the contract and its consumer. A compatible change,
  such as a new optional field, is not an item. A slow mobile release is not a reason by itself.

Not an item: new tables, fields, or keys with no existing data, internal refactors, test code,
changes behind a flag that is off, a DI module that provides only local dependencies.

Be conservative. Most diffs have no item. The usual count is 0-3. This is a soft limit: write more
when the diff has more independent one-way doors. Put related changes in one item: three cache
keys that get one new format are one item.

## Focus files

Focus files are the files that a reviewer must read first. A focus file has one of these:

- the core behavior change of the branch
- a new or changed public API, schema, or contract
- invasive or high-risk code: concurrency, security, data migration, a moved module boundary
- a high-impact change

Select at most 5 focus files. Order them:

1. Files with invasive or high-risk code.
2. The other focus files in dependency order: types and contracts, then the logic that uses them,
   then callers and wiring, then tests.

If no file is a focus file (for example a rename, a version bump, or a one-function fix), the diff
is a simple change.

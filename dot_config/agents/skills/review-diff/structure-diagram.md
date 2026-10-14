# Structure diagram

An ASCII map of the code structure that the diff changes. It shows a reviewer how the changed
modules or classes connect before they read the files. The diagram shows the change, not only the
current state.

## When to draw

Draw a diagram when one of these is true:

- **Module level.** The diff adds or removes a module, or adds or removes a dependency between
  modules. This includes changes in shared build logic that give many modules a new dependency.
- **Class level.** Classes in the diff communicate in a way that the code does not make obvious:
  events, flows, callbacks, or queues.

Otherwise, omit the `## Structure` section. A function-body change, a rename, a version bump, or
direct calls between classes need no diagram, also in a long call chain. The reader can follow
direct calls in the code, and the review guide gives the reading order.

The module level is more important. When both levels apply, draw the module level first.

## What goes in

- **Nodes** are names only: module paths (`:core:payments`, `@shop/auth`) or class names. No
  signatures, function bodies, fields, endpoints, or build-file lines. The diff shows the code. The
  diagram shows only how the parts connect.
- **Scope** is the modules or classes that the diff changes, plus the direct neighbors that help to
  explain the change. Omit a neighbor that does not touch the change. Unchanged modules elsewhere in
  the project stay out.
- **Finding ids** go after a node when the finding is in that node: `[* :feature:checkout] H1 M2`.
  Ids only, no text. Not on a separate line.
- **Edge labels** are for class diagrams only: the call or event name, short (`send(Request)`,
  `collect`, `status`). Module edges have no label.
- **Size.** About 12 nodes or fewer. If there are more, put the unchanged nodes into one node,
  e.g. `[4 feature modules]` or `[+N others]`. A diagram that is about as wide as it is tall reads
  best. Put at most 3-4 nodes in a row. Put the other nodes in a column below. There is no column
  limit, but a wide diagram is hard to read.

## Notation

Use only these marks, and put the legend line below each diagram:

```
[:core:ui]            unchanged          -->    unchanged dependency or call
[+ :core:payments]    new                ==>    new dependency or call
[* :feature:checkout] changed            -x->   removed dependency or call
[- :core:legacy]      removed
```

Vertical edges use the same marks: `|` then `v` is unchanged, `||` then `v` is new, and `|`, `x`,
`v` is removed.

A module or class that the diff adds is `+`. Each edge from or to a `+` node is `==>`, also when
the full diagram is new.

Each edge uses one mark from start to end. Do not mix `--` and `==` in one edge. A removed edge is
an edge in the diagram, not a text line below it.

The legend line has only the marks that the diagram uses, e.g.
`+ new  * changed  ==> new  -x-> removed`.

Arrows point from the user to the dependency: `[:app] --> [:core:ui]` means `:app` depends on
`:core:ui`. In a class diagram, arrows point in the direction of the call or the data.

Use `[...]` for nodes, not drawn boxes. Brackets cannot break when a name is long. Use a drawn box
(`+--+` and `|`) only to put classes inside their module (see "Two levels").

## Find module edges

### Gradle

1. Modules: `include(...)` in `settings.gradle(.kts)`.
2. Direct edges: `project(":x")` and type-safe accessors (`projects.core.network`) in each module's
   `build.gradle(.kts)`. `api` and `implementation` are both edges. Do not show the difference.
3. Edges from build logic: convention plugins in `build-logic/` or `buildSrc/`. When the diff
   changes a plugin that adds a dependency, find the modules that apply the plugin id
   (`id("shop.feature")`). Each of those modules gets the edge. Show the plugin as a node that
   `applies to` the modules only when that makes the reach clearer.
4. Version catalogs (`libs.versions.toml`) hold external libraries. Show an external library only
   when the diff adds or removes it in a module that the diagram shows.

Compare the files at the parent and at the tip (`git show <parent>:<path>`) to find new and removed
edges.

### Other build systems

Use the unit that the build tool calls a module or package, and its manifest: `package.json`
workspaces, `go.mod`, `Cargo.toml` workspace members, `pyproject.toml`, Maven
`pom.xml`. Source packages and directories are not units. A repo with no build units has no
module level - only the class level can apply.

Edges come from the manifests and build files, not from imports. When the imports do not agree with
a manifest (an unused or a missing dependency), draw the manifest edge and write a finding.

## Two levels

When the module change and the class flow are about the same 1-2 modules, draw one diagram. Put the
classes in a drawn box for their module. Other modules stay as `[...]` nodes. If one diagram becomes
hard to read, draw two diagrams: the module diagram first, then the class diagram. Give each its own
legend line.

## Examples

Module level. A new `:core:search-index` module replaces `:core:legacy-db` in `:feature:search`:

```
              [:app]
                |
                v
       [* :feature:search] H1
         ||             |
         ||             x
         v              v
[+ :core:search-index] M1   [- :core:legacy-db]
         |
         v
  [:core:storage]

+ new  * changed  - removed  ==> new  -x-> removed
```

Class level. `AvatarLoader` now reads a new cache before the network, and the cache reports
evictions through a callback:

```
[* ProfileScreen] --load()--> [* AvatarLoader] H1
                                ||          |
                              get()      fetch()
                                v           v
                         [+ AvatarCache]  [HttpClient]
                                ||
                           onEvicted()
                                v
                         [+ CacheMetrics] M1

+ new  * changed  --> unchanged  ==> new
```

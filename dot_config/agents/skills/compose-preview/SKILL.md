---
name: compose-preview
description: Use after a change to Jetpack Compose UI in a Kotlin file. Renders and examines its @Preview functions with no device and no Android Studio.
---

1. Get the changed Kotlin files: the files that you edited, or `git diff --name-only <parent>`.
2. Get the Gradle path from the file path: `core/designsystem/src/...` is `:core:designsystem`.
3. Run `android preview list :module`. If the error is `Variant 'debug' does not exist`, pick a
   `*Debug` name from `Available variants` and use `:module@<variant>`.
4. Keep the names that contain `<FileName>Kt.`. If there are none, tell the user that the file
   has no previews.
5. Run `android preview render <reference> --daemon --output=<folder> --fqn=<name>`, with one
   `--fqn` for each name. The `<folder>` path must not contain spaces.
6. Move all PNG files to the top level of `<folder>`.
7. Read each PNG file. If the UI is wrong, fix the code and render again.
8. Write the folder path in the reply: `📄 Previews: <folder>`.

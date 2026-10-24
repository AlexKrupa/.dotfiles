---
name: android-capture
description: >-
  Use when the user asks for screenshots, a screen recording, or a video of an Android app on a
  device or emulator: for a PR or MR, before and after a change, in light and dark mode, or as a
  visual diff of two states. Also use when a PR draft for an Android UI change needs media and the
  user asks for it.
argument-hint: "[what to capture]"
allowed-tools:
  - Bash(bash ~/.claude/skills/android-capture/capture.sh *)
  - Bash(~/.config/agents/bin/git-diff-context.sh *)
---

# android-capture

This skill captures screenshots and videos of an Android app for a reviewer. The files are small
for upload and stay easy to read.

`capture.sh` in this directory does the fixed steps. Its header has the commands and the exit
codes. Run it as `bash ~/.claude/skills/android-capture/capture.sh <command>`. Use the `android`
CLI first (the `android-cli` skill). Use `adb` and `emulator` for the steps that the CLI does not
have: recording, input, and device settings.

## Select the scenario

Find the scenario in the request, the diff, and the conversation. The axes combine, for example
before and after in light and dark mode. With no other signal, capture one light-mode screenshot
of the changed screen on the current code.

| Axis         | Capture it when                                                                    |
| ------------ | ---------------------------------------------------------------------------------- |
| Before/after | the user asks, or the media is for a PR draft of a change to an existing screen   |
| Light/dark   | the user asks, or the diff changes the theme, colors, or `values-night` resources |
| Video        | the change is an animation, a transition, a gesture, or a flow of more steps      |
| Diff         | the user asks for a diff or a comparison image of two states                       |

If the diff changes the reference images of screenshot tests, the reviewer sees the image diffs
in the MR. Capture nothing, unless the user asks.

## Output path

- A PR draft is in progress: the `media` path of `pr-path.sh`. Use the names `before.png`,
  `after.png`, `after-dark.png`, `diff.png`, and `demo.mp4`. If two files get the same name, add the state to the names.
- Else: `capture.sh path <label> <ext>` gives a path in `~/Downloads`. The label is the screen and
  the state, for example `settings-dark`.

## Capture

1. Find the device with `android info`. If no device is connected, start an AVD with
   `android emulator list` and `android emulator start <avd>`. If more than one device is
   connected, ask the user which one to use and set `ANDROID_SERIAL`.
2. Build and install the app with the task from the project docs, or with `android run`. The
   project docs also tell how to log in and how to get test data.
3. Run `capture.sh statusbar clean`. A fixed status bar keeps the clock and the battery out of a
   diff.
4. Go to the changed screen. If the project docs have a deep link to it, use the deep link. Else
   follow the `android-cli` skill to read the screen and tap.
5. Wait until the screen is idle: no loading indicator, no keyboard, no system dialog, and no
   animation in progress.
6. Capture:
   - Screenshot: `capture.sh shot <path>`.
   - Video: `capture.sh record start`, do the steps with `adb shell input`, then
     `capture.sh record stop <path>`. Keep the video short and show only the change.
   - Dark mode: `capture.sh night on`, capture, then `capture.sh night off`.
7. Before/after: capture "before" on the parent commit, then "after" on the branch, with the same
   steps and the same device state.
   1. Make sure that the working tree is clean. If it is not clean, stop and tell the user.
   2. Get the parent from `diff-base` of the PR draft, or with
      `~/.config/agents/bin/git-diff-context.sh --parent-only`.
   3. Run `git switch --detach <parent>`, build, install, and capture "before".
   4. Run `git switch -`. Do this step also when step 3 fails. Then build, install, and capture
      "after".
8. Diff: `capture.sh diff <before> <after> <path>`. If `changed_pixels` is `0`, tell the user. The
   capture probably shows a different screen than the change.
9. Run `capture.sh statusbar reset`.
10. Read each image before you report it. Make sure that it shows the changed screen in the
    correct state. If it does not, capture it again.

## Reply

List each file with its scenario, for example `after, dark: <path>`. When a PR draft is in
progress, `draft-pr` embeds the files.

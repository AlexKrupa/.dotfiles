#!/usr/bin/env bash
# Usage: capture.sh path <label> <ext>
#        capture.sh statusbar clean|reset
#        capture.sh night on|off
#        capture.sh shot <out.png>
#        capture.sh record start
#        capture.sh record stop <out.mp4>
#        capture.sh diff <before.png> <after.png> <out.png>
#
# Media capture steps for the android-capture skill. The device is $ANDROID_SERIAL, or the only
# connected device.
#
# path       Prints ~/Downloads/android-<YYYYMMDD-HHMMSS>-<label>.<ext>. Writes nothing.
# statusbar  clean: demo mode with a 12:00 clock, full battery, full wifi, no mobile
#            signal, no notifications.
#            reset: the normal status bar.
# night      Sets the system dark theme and waits until the app draws again.
# shot       Saves the screen as a PNG and optimizes it with pngquant. Prints the path.
# record     start: starts a screen recording on the device (180 s at most) and returns.
#            stop: stops it, pulls it, and compresses it with ffmpeg (h264, no audio). Prints the
#            path.
# diff       Writes <before> | <diff> | <after> as one PNG. The diff image marks changed pixels
#            in red. The images must have the same size. Prints `path: <out>` and
#            `changed_pixels: <count>`.
#
# Exit codes: 0 ok, 1 error, 2 no device, 3 more than one device and no $ANDROID_SERIAL,
# 4 missing tool.
set -euo pipefail

NAME=capture
REMOTE_VIDEO=/sdcard/android-capture.mp4
# The system UI and the app need time to draw again after a theme or status bar change.
SETTLE_SECONDS=2

die() { echo "$NAME: $1" >&2; exit "${2:-1}"; }

need() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "missing tool: $tool" 4
  done
}

select_device() {
  need adb
  [[ -z "${ANDROID_SERIAL:-}" ]] || return 0
  local serials
  serials=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  [[ -n "$serials" ]] || die "no connected device" 2
  if [[ $(wc -l <<<"$serials") -gt 1 ]]; then
    echo "$serials" >&2
    die "more than one device, set ANDROID_SERIAL" 3
  fi
  export ANDROID_SERIAL="$serials"
}

demo() { adb shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }

cmd_path() {
  [[ $# -eq 2 ]] || die "path needs <label> <ext>"
  echo "$HOME/Downloads/android-$(date +%Y%m%d-%H%M%S)-$1.$2"
}

cmd_statusbar() {
  select_device
  case "${1-}" in
    clean)
      adb shell settings put global sysui_demo_allowed 1
      demo enter
      demo clock -e hhmm 1200
      demo battery -e level 100 -e plugged false
      demo network -e wifi show -e level 4 -e fully true
      demo network -e mobile hide
      demo notifications -e visible false
      ;;
    reset)
      demo exit
      adb shell settings put global sysui_demo_allowed 0
      ;;
    *) die "statusbar needs clean or reset, got '${1-}'" ;;
  esac
  sleep "$SETTLE_SECONDS"
}

cmd_night() {
  select_device
  local mode
  case "${1-}" in
    on) mode=yes ;;
    off) mode=no ;;
    *) die "night needs on or off, got '${1-}'" ;;
  esac
  adb shell cmd uimode night "$mode" >/dev/null
  sleep "$SETTLE_SECONDS"
}

optimize_png() {
  need pngquant
  # pngquant exits 98 or 99 when the result is larger or below the quality range. It then keeps
  # the original file.
  pngquant --quality 65-90 --skip-if-larger --force --ext .png "$1" || [[ $? -ge 98 ]]
}

cmd_shot() {
  [[ $# -eq 1 ]] || die "shot needs <out.png>"
  select_device
  need android
  mkdir -p "$(dirname "$1")"
  android screen capture --device "$ANDROID_SERIAL" -o "$1" >/dev/null
  [[ -s "$1" ]] || die "no screenshot written to $1"
  optimize_png "$1"
  echo "$1"
}

cmd_record() {
  select_device
  case "${1-}" in
    start)
      adb shell rm -f "$REMOTE_VIDEO"
      nohup adb shell screenrecord --time-limit 180 "$REMOTE_VIDEO" >/dev/null 2>&1 &
      sleep 1
      adb shell pidof screenrecord >/dev/null || die "screenrecord did not start on $ANDROID_SERIAL"
      ;;
    stop)
      [[ $# -eq 2 ]] || die "record stop needs <out.mp4>"
      need ffmpeg
      local out="$2" raw
      adb shell pkill -INT screenrecord || true
      # screenrecord writes the end of the file after SIGINT.
      while adb shell pidof screenrecord >/dev/null; do sleep 0.5; done
      raw=$(mktemp -t android-capture.XXXXXX).mp4
      adb pull "$REMOTE_VIDEO" "$raw" >/dev/null 2>&1 || die "no recording at $REMOTE_VIDEO on $ANDROID_SERIAL"
      adb shell rm -f "$REMOTE_VIDEO"
      mkdir -p "$(dirname "$out")"
      ffmpeg -i "$raw" -f mp4 -vcodec h264 -an -preset fast -crf 28 -movflags +faststart \
        -hide_banner -loglevel error -y "$out" || die "ffmpeg failed, raw recording at $raw"
      rm -f "$raw"
      echo "$out"
      ;;
    *) die "record needs start or stop, got '${1-}'" ;;
  esac
}

cmd_diff() {
  [[ $# -eq 3 ]] || die "diff needs <before.png> <after.png> <out.png>"
  need magick
  local before="$1" after="$2" out="$3" mask changed
  [[ $(magick identify -format %wx%h "$before") == $(magick identify -format %wx%h "$after") ]] \
    || die "different sizes: $before, $after"
  mask=$(mktemp -t android-capture-diff.XXXXXX).png
  # compare exits 1 when the images differ. The metric goes to stderr.
  changed=$(magick compare -metric AE -fuzz 2% "$before" "$after" "$mask" 2>&1 >/dev/null || true)
  mkdir -p "$(dirname "$out")"
  magick "$before" "$mask" "$after" -bordercolor '#808080' -border 4 +append "$out"
  rm -f "$mask"
  optimize_png "$out"
  echo "path: $out"
  printf 'changed_pixels: %.0f\n' "${changed%% *}"
}

case "${1-}" in
  path) shift; cmd_path "$@" ;;
  statusbar) shift; cmd_statusbar "$@" ;;
  night) shift; cmd_night "$@" ;;
  shot) shift; cmd_shot "$@" ;;
  record) shift; cmd_record "$@" ;;
  diff) shift; cmd_diff "$@" ;;
  *) die "unknown command: '${1-}'" ;;
esac

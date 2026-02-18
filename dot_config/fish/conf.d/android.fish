# Android development environment and utilities

# ==============================================================================
# Environment
# ==============================================================================

set -gx JAVA_HOME (/usr/libexec/java_home)
set -gx ANDROID_HOME $HOME/Library/Android/sdk
set -gx ANDROID_SDK $ANDROID_HOME
set -gx ANDROID_SDK_ROOT $ANDROID_HOME

set -g ANDROID_MEDIA_PATH ~/Downloads/android-
set -g ADB_STATIC_PORT 4444

fish_add_path $ANDROID_HOME/cmdline-tools/latest/bin
fish_add_path $ANDROID_HOME/emulator
fish_add_path $ANDROID_HOME/platform-tools
fish_add_path $ANDROID_HOME/tools

fish_add_path ~/src/me/adx

# ==============================================================================
# Aliases
# ==============================================================================

# Emulator
alias emu and-emu

# Build & install
alias andi and-install
alias andis and-install-start
alias andu and-uninstall

# App lifecycle
alias ands and-start
alias andk and-kill
alias andr and-restart
alias andc and-clear
alias andcs and-clear-start
alias andpd and-process-death

# Device configuration
alias and-lag-disable "adb shell settings put global ingress_rate_limit_bytes_per_second -1"
alias and-lag-enable "adb shell settings put global ingress_rate_limit_bytes_per_second 16000"
alias and-settings "adb shell am start -n com.android.settings/.Settings"
alias and-settings-dev "adb shell am start -a com.android.settings.APPLICATION_DEVELOPMENT_SETTINGS"

# Media capture
alias scr and-screenshot
alias scrdn and-screenshot-daynight
alias rec and-screenrecord

# Connectivity
alias and-dc and-disconnect

# ==============================================================================
# Emulator
# ==============================================================================

function and-emu --description 'Select and start Android emulator'
  set -l avds "$(avdmanager list avd -c)"
  set -l avd_count (count (echo $avds | string split -n "\n"))
  if test $avd_count -ge 2
    set -f selected_avd (echo $avds | fzf)
    wait
    if test -z "$selected_avd"
      echo AVD not selected 1>&2
      return 1
    end
  else if test $avd_count -eq 1
    set -f selected_avd $avds
  else
    echo No AVDs found 1>&2
    return 1
  end
  # Start the emulator with Google's DNS server to avoid network issues.
  emulator -avd $selected_avd -dns-server 8.8.8.8
end

# ==============================================================================
# Build & install
# ==============================================================================

# Usage: and-install <variant> <package>
function and-install --description 'Build and install app on device'
  if test (count $argv) -lt 2
    echo "Usage: and-install <variant> <package>" >&2
    return 1
  end

  set -l variant $argv[1]
  set -l package $argv[2]

  if not __require_device_selection
    return 1
  end

  echo "Installing $package on $ANDROID_SERIAL"

  gw :app:assemble$variant
  if test $status -ne 0
    echo "Gradle build failed."
    return 1
  end

  set -l apk_path (__find_apk $variant)
  if test -z "$apk_path"
    echo "No APK found for variant: $variant"
    return 1
  end

  echo "Installing APK: $apk_path"
  adb install -r -d $apk_path
  set -l install_status $status

  if test $install_status -ne 0
    echo "Streaming install failed, retrying with --no-streaming..."
    adb install -r -d --no-streaming $apk_path
    set install_status $status
  end

  if test $install_status -ne 0
    echo "Installation failed."
    return 1
  end

  echo "App successfully installed."
  return 0
end

# Usage: and-install-start <variant> <package> [intent_args...]
function and-install-start --description 'Build, install, and start app'
  if test (count $argv) -lt 2
    echo "Usage: and-install-start <variant> <package> [intent_args...]" >&2
    return 1
  end

  set -l variant $argv[1]
  set -l package $argv[2]
  set -l intent_args $argv[3..-1]

  and-install $variant $package
  if test $status -ne 0
    return 1
  end

  and-start $package $intent_args
end

function and-uninstall --description 'Uninstall apps matching package prefix'
  if test (count $argv) -lt 1
    echo "Usage: and-uninstall <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo Uninstalling $package from $ANDROID_SERIAL

  adb shell pm list packages | string match "*$package*" | string replace 'package:' '' | xargs -L1 adb uninstall
end

# Find APK by variant name.
# Usage: __find_apk [variant]
# Returns path to most recent APK matching variant, or most recent APK if no variant specified.
function __find_apk
  set -l variant (string lower $argv[1])
  set -l apk_dir "app/build/outputs/apk"

  if not test -d "$apk_dir"
    return 1
  end

  # Find all APKs sorted by modification time (newest first)
  set -l apks (find $apk_dir -name "*.apk" -type f -exec stat -f "%m %N" {} + 2>/dev/null | sort -rn | cut -d' ' -f2-)

  if test -z "$apks"
    return 1
  end

  # If variant specified, find matching APK
  if test -n "$variant"
    for apk in $apks
      if string match -qi "*$variant*" (basename $apk)
        echo $apk
        return 0
      end
    end
  end

  # Fall back to most recent APK
  echo $apks[1]
end

# ==============================================================================
# App lifecycle
# ==============================================================================

function and-start --description 'Start app on device'
  if test (count $argv) -lt 1
    echo "Usage: and-start <package> [intent_args...]" >&2
    return 1
  end

  set -l package $argv[1]
  set -l intent_args $argv[2..-1]

  if not __require_device_selection
    return 1
  end

  echo "Starting $package on $ANDROID_SERIAL"

  # Resolve the launcher activity component
  set -l component (adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $package 2>/dev/null | tail -n 1)

  if test -z "$component"
    echo "Could not resolve launcher activity for $package" >&2
    return 1
  end

  adb shell am start -n $component $intent_args
end

function and-kill --description 'Force stop app on device'
  if test (count $argv) -lt 1
    echo "Usage: and-kill <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Killing $package on $ANDROID_SERIAL"
  adb shell am force-stop $package
end

# Usage: and-restart <package> [intent_args...]
function and-restart --description 'Kill and restart app'
  if test (count $argv) -lt 1
    echo "Usage: and-restart <package> [intent_args...]" >&2
    return 1
  end

  set -l package $argv[1]
  set -l intent_args $argv[2..-1]

  and-kill $package
  if test $status -ne 0
    return 1
  end

  and-start $package $intent_args
end

# Usage: and-clear <package>
function and-clear --description 'Clear app data'
  if test (count $argv) -lt 1
    echo "Usage: and-clear <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Clearing data for $package on $ANDROID_SERIAL"
  adb shell pm clear $package
end

# Usage: and-clear-start <package> [intent_args...]
function and-clear-start --description 'Clear app data and start'
  if test (count $argv) -lt 1
    echo "Usage: and-clear-start <package> [intent_args...]" >&2
    return 1
  end

  set -l package $argv[1]
  set -l intent_args $argv[2..-1]

  and-clear $package
  if test $status -ne 0
    return 1
  end

  and-start $package $intent_args
end

# Simulate process death by backgrounding the app and killing its process.
# This tests state restoration when Android kills the app to reclaim memory.
function and-process-death --description 'Simulate process death for state restoration testing'
  if test (count $argv) -lt 1
    echo "Usage: and-process-death <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Simulating process death for $package on $ANDROID_SERIAL"

  # Background the app by pressing home button
  echo "Backgrounding app..."
  adb shell input keyevent KEYCODE_HOME

  # Wait for app to be backgrounded
  sleep 2

  # Kill the process
  echo "Killing process..."
  adb shell am kill $package

  echo "Process death simulated. Re-open the app to test state restoration."
end

# ==============================================================================
# Device configuration
# ==============================================================================

function and-dpi --description 'Set device display density'
  if test (count $argv) -lt 1
    echo "Usage: and-dpi <value>" >&2
    return 1
  end

  if not __require_device_selection
    return 1
  end

  echo Setting DPI to $argv on $ANDROID_SERIAL

  adb shell wm density $argv
end

# Usage: and-font-scale [scale]  (e.g. 1.2, omit to get current value)
function and-font-scale --description 'Get or set device font scale'
  if not __require_device_selection
    return 1
  end

  if test (count $argv) -lt 1
    adb shell settings get system font_scale
    return
  end

  set -l scale $argv[1]

  echo Setting font scale to $scale on $ANDROID_SERIAL

  adb shell settings put system font_scale $scale
end

# Usage: and-anim-scale [scale]  (e.g. 0.5, 0 to disable, omit to get current values)
function and-anim-scale --description 'Get or set device animation speeds'
  if not __require_device_selection
    return 1
  end

  if test (count $argv) -lt 1
    echo "window_animation_scale:" (adb shell settings get global window_animation_scale)
    echo "transition_animation_scale:" (adb shell settings get global transition_animation_scale)
    echo "animator_duration_scale:" (adb shell settings get global animator_duration_scale)
    return
  end

  set -l scale $argv[1]

  echo Setting animation speeds to $scale on $ANDROID_SERIAL

  adb shell settings put global window_animation_scale $scale
  adb shell settings put global transition_animation_scale $scale
  adb shell settings put global animator_duration_scale $scale
end

function and-screen-size --description 'Set device screen resolution'
  if test (count $argv) -lt 1
    echo "Usage: and-screen-size <size>" >&2
    return 1
  end

  if not __require_device_selection
    return 1
  end

  echo Setting screen size to $argv on $ANDROID_SERIAL

  adb shell wm size $argv
end

# ==============================================================================
# Media capture
# ==============================================================================

function and-screenshot --description 'Screenshot device and copy to clipboard'
  set -l image (__media_file_path png)

  if not __require_device_selection
    return 1
  end

  echo Taking a screenshot of $ANDROID_SERIAL

  adbe -s $ANDROID_SERIAL screenshot $image &>/dev/null
  __optimize_png $image
  echo Screenshot saved at $image
  __copy_png_to_clipboard $image
end

function and-screenshot-daynight --description 'Screenshot in day and night mode, stitched'
  set -l image_day (mktemp -t android-day.XXXXXX.png)
  set -l image_night (mktemp -t android-night.XXXXXX.png)
  set -l image_stitched (__media_file_path png daynight)

  if not __require_device_selection
    return 1
  end

  echo Taking day and night screenshots of $ANDROID_SERIAL

  adbe -s $ANDROID_SERIAL dark mode off &>/dev/null
  sleep 2
  adbe -s $ANDROID_SERIAL screenshot $image_day &>/dev/null

  adbe -s $ANDROID_SERIAL dark mode on &>/dev/null
  sleep 2
  adbe -s $ANDROID_SERIAL screenshot $image_night &>/dev/null

  magick $image_day $image_night +append $image_stitched
  rm $image_day $image_night

  __optimize_png $image_stitched
  echo Stitched day/night screenshot saved at $image_stitched
  __copy_png_to_clipboard $image_stitched

  sleep 2
  adbe -s $ANDROID_SERIAL dark mode off &>/dev/null
end

function and-screenrecord --description 'Record and compress device video'
  set -l video (__media_file_path mp4)
  set -l compressed "$video.tmp"

  if not __require_device_selection
    return 1
  end

  echo Recording a video of $ANDROID_SERIAL
  echo Press Ctrl-C to finish

  adbe screenrecord $video &>/dev/null

  # -f mp4: output format (can't infer from .tmp extension)
  # -vcodec h264: broad compatibility
  # -an: strip audio
  # -preset fast: balanced encoding speed vs compression
  # -crf 28: quality level (0-51, higher = smaller file)
  # -movflags +faststart: enable streaming before full download
  ffmpeg \
    -i $video \
    -f mp4 \
    -vcodec h264 \
    -an \
    -preset fast \
    -crf 28 \
    -movflags +faststart \
    -hide_banner \
    -loglevel error \
    $compressed

  rm $video
  mv $compressed $video
  echo Video saved at $video
  __reveal_in_finder $video
end

# --- Media helpers ---

# Get full path for media file
# Usage: __media_file_path <ext> [suffix]
# Examples:
#   __media_file_path png         → ~/Downloads/android-20250121-143025.png
#   __media_file_path png daynight → ~/Downloads/android-20250121-143025-daynight.png
function __media_file_path
  set -l ext $argv[1]
  set -l suffix $argv[2]
  # Changed: compact timestamp format (YYYYMMDD-HHMMSS), dropped type prefix
  set -l timestamp (date +"%Y%m%d-%H%M%S")

  if test -n "$suffix"
    echo "$ANDROID_MEDIA_PATH$timestamp-$suffix.$ext"
  else
    echo "$ANDROID_MEDIA_PATH$timestamp.$ext"
  end
end

# Copy a PNG image to the macOS clipboard.
function __copy_png_to_clipboard
  set -l file_path $argv[1]

  if not command -q osascript
    echo "Warning: osascript not available, skipping clipboard copy" >&2
    return
  end

  osascript -e "set the clipboard to (read (POSIX file \"$file_path\") as «class PNGf»)" 2>/dev/null
  if test $status -eq 0
    echo "Copied to clipboard"
  else
    echo "Warning: Failed to copy to clipboard" >&2
  end
end

# Reveal a file in Finder with it selected.
function __reveal_in_finder
  set -l file_path $argv[1]

  open -R "$file_path" 2>/dev/null
  if test $status -eq 0
    echo "Revealed in Finder"
  else
    echo "Warning: Failed to reveal in Finder" >&2
  end
end

# Optimize PNG for web upload (PRs, Slack) using pngquant.
# Compresses in place. Returns 0 on success.
function __optimize_png
  set -l png_path $argv[1]

  if not command -q pngquant
    echo "Warning: pngquant not installed, skipping optimization (brew install pngquant)" >&2
    return 1
  end

  # --quality 65-90: target quality range, picks best within budget
  # --skip-if-larger: keep original if compressed is larger
  # --force --ext .png: overwrite original
  pngquant --quality 65-90 --skip-if-larger --force --ext .png "$png_path" 2>/dev/null
end

# ==============================================================================
# Connectivity
# ==============================================================================

function and-wifi --description 'Connect to device over WiFi'
  if test (count $argv) -lt 1
    echo "Usage: and-wifi <ip>" >&2
    return 1
  end

  set -l ip $argv[1]
  set -l port $ADB_STATIC_PORT
  set -l ip_with_port "$ip:$port"
  echo "Connecting to $ip_with_port"
  adb connect $ip_with_port
end

function and-wifi-new --description 'Pair new device over WiFi'
  if test (count $argv) -lt 2
    echo "Usage: and-wifi-new <ip> <port>" >&2
    return 1
  end

  set -l ip $argv[1]
  set -l port $argv[2]
  set -l ip_with_port "$ip:$port"
  set -l ip_with_new_port "$ip:$ADB_STATIC_PORT"

  echo "Connecting to $ip_with_port"
  adb connect $ip_with_port
  sleep 1
  adb -s $ip_with_port tcpip $ADB_STATIC_PORT
  sleep 1
  adb connect $ip_with_new_port
  sleep 1
  adb disconnect $ip_with_port
end

function and-disconnect --description 'Disconnect from WiFi device'
  if test (count $argv) -lt 1
    echo "Usage: and-disconnect <ip>" >&2
    return 1
  end

  set -l ip $argv[1]
  set -l port $ADB_STATIC_PORT
  set -l ip_with_port "$ip:$port"
  echo "Disconnecting from $ip_with_port"
  adb disconnect $ip_with_port
end

# ==============================================================================
# Debugging
# ==============================================================================

# Usage: and-log <package>
function and-log --description 'Show logcat filtered by app PID'
  if test (count $argv) -lt 1
    echo "Usage: and-log <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  set -l pid (adb shell pidof -s $package)
  if test -z "$pid"
    echo "Process not running: $package" >&2
    return 1
  end

  echo "Showing logcat for $package (PID: $pid) on $ANDROID_SERIAL"
  adb logcat --pid=$pid
end

# Usage: and-deeplink <url>
function and-deeplink --description 'Open deep link on device'
  if test (count $argv) -lt 1
    echo "Usage: and-deeplink <url>" >&2
    return 1
  end

  set -l url $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Opening deep link on $ANDROID_SERIAL: $url"
  adb shell am start -a android.intent.action.VIEW -d "$url"
end

# ==============================================================================
# Asset utilities
# ==============================================================================

# Usage: convert-xxxhdpi-to-split-webp <pattern>
function convert-xxxhdpi-to-split-webp --description 'Convert xxxhdpi PNGs to WebP and scale to lower densities'
  if test (count $argv) -lt 1
    echo "Usage: convert-xxxhdpi-to-split-webp <pattern>" >&2
    return 1
  end

  set -l file_filter $argv[1]

  for xxxhdpi_dir in (find . -name "drawable-xxxhdpi")
    echo "$xxxhdpi_dir"
    for file in (ls $xxxhdpi_dir/$file_filter)
      set -l file (basename $file)
      echo "$file"
      if not string match -q "*.webp" $file
        __convert_to_webp $xxxhdpi_dir $xxxhdpi_dir $file ""
        rm "$xxxhdpi_dir/$file"
      end

      set -l webp_file (string replace '.png' '.webp' $file)
      __convert_to_webp $xxxhdpi_dir "$xxxhdpi_dir/../drawable-xxhdpi" $webp_file "-resize 75%"
      __convert_to_webp $xxxhdpi_dir "$xxxhdpi_dir/../drawable-xhdpi" $webp_file "-resize 50%"
      __convert_to_webp $xxxhdpi_dir "$xxxhdpi_dir/../drawable-hdpi" $webp_file "-resize 37.5%"
      __convert_to_webp $xxxhdpi_dir "$xxxhdpi_dir/../drawable-mdpi" $webp_file "-resize 25%"
    end
  end
end

# Convert an image to WebP format with optional resize.
function __convert_to_webp
  set -l in_dir $argv[1]
  set -l out_dir $argv[2]
  set -l file $argv[3]
  set -l convert_arguments $argv[4]

  mkdir -p $out_dir
  set -l webp_file (string replace '.png' '.webp' $file)
  convert "$in_dir/$file" $convert_arguments -define webp:lossless=true "$out_dir/$webp_file"
end

# ==============================================================================
# Internal helpers
# ==============================================================================

# Helper function for device operations that require device selection
function __require_device_selection
  # Reuse existing selection if still connected
  if test -n "$ANDROID_SERIAL"
    if adb devices | string match -q -- "$ANDROID_SERIAL*"
      return 0
    end
  end

  set -gx ANDROID_SERIAL (__select_adb_device)
  if test -z "$ANDROID_SERIAL"
    return 1
  end
  return 0
end

# Select an ADB device from the list of connected devices.
function __select_adb_device
  set -l devices "$(adb devices -l | tail -n +2 | ghead -n -1)"
  set -l device_count (count (echo $devices | string split -n "\n"))
  set -l selected_device ""

  if test $device_count -ge 2
    # Preview shows device model for highlighted device
    set selected_device (echo $devices | fzf --preview 'echo {} | cut -f1 -w | xargs -I{} adb -s {} shell getprop ro.product.model 2>/dev/null')
    wait
    if test -z "$selected_device"
      echo Device not selected 1>&2
    end
  else if test $device_count -eq 1
    set selected_device $devices
  else
    echo No connected devices 1>&2
  end

  if test -n "$selected_device"
    echo (echo $selected_device | cut -f1 -w)
  end
end

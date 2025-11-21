set -gx JAVA_HOME (/usr/libexec/java_home)
set -gx ANDROID_HOME $HOME/Library/Android/sdk
set -gx ANDROID_SDK $ANDROID_HOME
set -gx ANDROID_SDK_ROOT $ANDROID_HOME

# Constants
set -g ANDROID_MEDIA_PATH ~/Downloads/android-
set -g ADB_STATIC_PORT 4444

fish_add_path $ANDROID_HOME/cmdline-tools/latest/bin
fish_add_path $ANDROID_HOME/emulator
fish_add_path $ANDROID_HOME/platform-tools
fish_add_path $ANDROID_HOME/tools

fish_add_path ~/src/me/adx

alias and_dc and_disconnect
alias and_lag_disable "adb shell settings put global ingress_rate_limit_bytes_per_second -1"
alias and_lag_enable "adb shell settings put global ingress_rate_limit_bytes_per_second 16000"
alias and_settings "adb shell am start -n com.android.settings/.Settings"
alias and_settings_dev "adb shell am start -a com.android.settings.APPLICATION_DEVELOPMENT_SETTINGS"
alias andi and_install_run
alias andu and_uninstall
alias emu and_emu
alias rec and_screenrecord
alias scr and_screenshot
alias scrdn and_screenshot_daynight

# Emulator
function and_emu
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

# Build & install
# Install and run app on connected device.
# Usage: and_install_run <variant> <package>
function and_install_run
  if test (count $argv) -lt 2
    echo "Usage: and_install_run <variant> <package>" >&2
    return 1
  end

  set -l variant $argv[1]
  set -l package $argv[2]

  # android_serial env var is read by both the gradle `install` task and by adb.
  if not __require_device_selection
    return 1
  end

  echo Installing $package on $ANDROID_SERIAL

  ./gradlew :app:assemble$variant
  set -l gradle_status $status

  if test $gradle_status -eq 0
    # Find the most recent APK
    set -l apk_path (fd -e apk . app/build/outputs/apk -t f -x ls -t | head -1)

    if test -n "$apk_path"
      # Force install the APK using adb
      echo "Force-installing APK with adb: $apk_path"

      # -d  allow downgrade
      # -r  replace existing application
      # Try streaming install first, fall back to --no-streaming if it fails
      echo "Attempting streaming install..."
      adb install -r -d $apk_path
      set -l install_status $status

      if test $install_status -ne 0
        echo "Streaming install failed, retrying with --no-streaming..."
        adb install -r -d --no-streaming $apk_path
        set install_status $status
      end

      if test $install_status -eq 0
        echo "App successfully installed."
        adb shell monkey -p $package -c android.intent.category.LAUNCHER 1
      else
        echo "Installation failed."
      end
    else
      echo "No APK found after build."
    end
  else
    echo "Gradle build failed."
  end
end

# Uninstall all apps with package starting with the first argument.
function and_uninstall
  if test (count $argv) -lt 1
    echo "Usage: and_uninstall <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo Uninstalling $package from $ANDROID_SERIAL

  adb shell pm list packages | string match "*$package*" | string replace 'package:' '' | xargs -L1 adb uninstall
end

# Device settings
# Set connected ADB device DPI to passed value (e.g. 420).
function and_dpi
  if test (count $argv) -lt 1
    echo "Usage: and_dpi <value>" >&2
    return 1
  end

  if not __require_device_selection
    return 1
  end

  echo Setting DPI to $argv on $ANDROID_SERIAL

  adb shell wm density $argv
end

# Get or set connected ADB device font scale.
# Usage: and_font_scale [scale]  (e.g. 1.2, omit to get current value)
function and_font_scale
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

# Set connected ADB device screen size to passed value (e.g. 1080x1920).
function and_screen_size
  if test (count $argv) -lt 1
    echo "Usage: and_screen_size <size>" >&2
    return 1
  end

  if not __require_device_selection
    return 1
  end

  echo Setting screen size to $argv on $ANDROID_SERIAL

  adb shell wm size $argv
end

# Screenshot connected ADB device into ~/Downloads folder and copy the image to clipboard..
function and_screenshot
  set -l image (__media_file_path img png)

  if not __require_device_selection
    return 1
  end

  echo Taking a screenshot of $ANDROID_SERIAL

  adbe -s $ANDROID_SERIAL screenshot $image &>/dev/null
  echo Screenshot saved at $image
  __copy_png_to_clipboard $image
end

# Screenshot connected ADB device in both day and night mode into ~/Downloads folder.
function and_screenshot_daynight
  set -l file_name (__media_file_name)
  set -l image_day $ANDROID_MEDIA_PATH"img-"$file_name"-day.png"
  set -l image_night $ANDROID_MEDIA_PATH"img-"$file_name"-night.png"

  if not __require_device_selection
    return 1
  end

  echo Taking day and night screenshots of $ANDROID_SERIAL

  adbe -s $ANDROID_SERIAL dark mode off &>/dev/null
  sleep 2
  adbe -s $ANDROID_SERIAL screenshot $image_day &>/dev/null
  echo Day screenshot saved at $image_day
  __copy_png_to_clipboard $image_day

  adbe -s $ANDROID_SERIAL dark mode on &>/dev/null
  sleep 2
  adbe -s $ANDROID_SERIAL screenshot $image_night &>/dev/null
  echo Night screenshot saved at $image_night
  __copy_png_to_clipboard $image_night

  sleep 2
  adbe -s $ANDROID_SERIAL dark mode off &>/dev/null
end

# Record an MP4 video of connected ADB device into ~/Downloads folder and then compresses it.
function and_screenrecord
  set -l video (__media_file_path vid mp4)
  set -l file_name (__media_file_name)
  set -l compressed $ANDROID_MEDIA_PATH"vid-"$file_name"-compressed-noaudio.mp4"

  if not __require_device_selection
    return 1
  end

  echo Recording a video of $ANDROID_SERIAL
  echo Press Ctrl-C to finish

  adbe screenrecord $video &>/dev/null

  ffmpeg -i $video -vcodec h264 -an $compressed -hide_banner -preset ultrafast -loglevel error

  rm $video
  mv $compressed $video
  echo Video saved at $video
  __reveal_in_finder $video
end

# Connectivity
function and_wifi
  if test (count $argv) -lt 1
    echo "Usage: and_wifi <ip>" >&2
    return 1
  end

  set -l ip $argv[1]
  set -l port $ADB_STATIC_PORT
  set -l ip_with_port "$ip:$port"
  echo "Connecting to $ip_with_port"
  adb connect $ip_with_port
end

function and_wifi_new
  if test (count $argv) -lt 2
    echo "Usage: and_wifi_new <ip> <port>" >&2
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

function and_disconnect
  if test (count $argv) -lt 1
    echo "Usage: and_disconnect <ip>" >&2
    return 1
  end

  set -l ip $argv[1]
  set -l port $ADB_STATIC_PORT
  set -l ip_with_port "$ip:$port"
  echo "Disconnecting from $ip_with_port"
  adb disconnect $ip_with_port
end

# Process management
# Simulate process death by backgrounding the app and killing its process.
# This tests state restoration when Android kills the app to reclaim memory.
function and_process_death
  if test (count $argv) -lt 1
    echo "Usage: and_process_death <package>" >&2
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

# Show logcat filtered by app PID.
# Usage: and_log <package>
function and_log
  if test (count $argv) -lt 1
    echo "Usage: and_log <package>" >&2
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

# Test a deep link / app link.
# Usage: and_deeplink <url>
function and_deeplink
  if test (count $argv) -lt 1
    echo "Usage: and_deeplink <url>" >&2
    return 1
  end

  set -l url $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Opening deep link on $ANDROID_SERIAL: $url"
  adb shell am start -a android.intent.action.VIEW -d "$url"
end

# Clear app data.
# Usage: and_clear_data <package>
function and_clear_data
  if test (count $argv) -lt 1
    echo "Usage: and_clear_data <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Clearing data for $package on $ANDROID_SERIAL"
  adb shell pm clear $package
end

# Force stop and relaunch app.
# Usage: and_restart <package>
function and_restart
  if test (count $argv) -lt 1
    echo "Usage: and_restart <package>" >&2
    return 1
  end

  set -l package $argv[1]

  if not __require_device_selection
    return 1
  end

  echo "Restarting $package on $ANDROID_SERIAL"
  adb shell am force-stop $package
  # Launch via monkey to open the default launcher activity
  adb shell monkey -p $package -c android.intent.category.LAUNCHER 1
end

# Utilities
# Convert all PNGs in drawable-xxxhdpi to WebP and split them into drawable-xxhdpi, drawable-xhdpi, drawable-hdpi, and drawable-mdpi.
function convert_xxxhdpi_to_split_webp
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

# Helper functions (implementation details)
# Get a media (screenshot/video) file name with a timestamp.
# Example: 2021-08-31_14-23-45
function __media_file_name
  echo (date +"%Y-%m-%d_%H-%M-%S")
end

# Get full path for media file with given prefix and extension
function __media_file_path
  set -l prefix $argv[1]
  set -l extension $argv[2]
  echo $ANDROID_MEDIA_PATH$prefix(__media_file_name).$extension
end

# Helper function for device operations that require device selection
function __require_device_selection
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
    set selected_device (echo $devices | fzf)
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

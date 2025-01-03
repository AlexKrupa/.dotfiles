################################################################################
## Android
################################################################################

function as --description "Open Android Studio"
  # set dir $PWD
  # cd
  open -na "Android Studio" --args "$argv"
  # cd $PWD
end

alias adb-slow-enable "adb shell settings put global ingress_rate_limit_bytes_per_second 16000"
alias adb-slow-disable "adb shell settings put global ingress_rate_limit_bytes_per_second -1"
alias adb-settings "adb shell am start -n com.android.settings/.Settings"
alias adb-settings-dev "adb shell am start -a com.android.settings.APPLICATION_DEVELOPMENT_SETTINGS"

# Get a media (screenshot/video) file name with a timestamp.
# Example: 2021-08-31_14-23-45
function _media-file-name
  echo (date +"%Y-%m-%d_%H-%M-%S")
end

# Select an ADB device from the list of connected devices.
function select-adb-device
  set -l devices "$(adb devices -l | tail -n +2 | ghead -n -1)"
  set -l device_count (count (echo $devices | string split -n "\n"))
  if test $device_count -ge 2
    set -f selected_device (echo $devices | fzf)
    wait
    if test -z "$selected_device"
      echo Device not selected 1>&2
    end
  else if test $device_count -eq 1
    set -f selected_device $devices
  else
    echo No connected devices 1>&2
  end
  echo (echo $selected_device | cut -f1 -w)
end

function emu
  set -l avds "$(avdmanager list avd -c)"
  set -l avd_count (count (echo $avds | string split -n "\n"))
  if test $avd_count -ge 2
    set -f selected_avd (echo $avds | fzf)
    wait
    if test -z "$selected_avd"
      echo AVD not selected 1>&2
    end
  else if test $avd_count -eq 1
    set -f selected_avd $avds
  else
    echo No AVDs found 1>&2
  end
  # Start the emulator with Google's DNS server to avoid network issues.
  emulator -avd $selected_avd -dns-server 8.8.8.8
end

# Install and run app on connected device.
# Usage: andi <variant> <package> <activity>
function andi
  set -l variant $argv[1]
  set -l package $argv[2]
  set -l activity $argv[3]

  set -l variant_lowercase (string lower $variant)

  # android_serial env var is read by both the gradle `install` task and by adb.
  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Installing $package on $ANDROID_SERIAL

  ./gradlew :app:assemble$variant
  set -l gradle_status $status

  if test $gradle_status -eq 0
    # Find the most recent APK
    set -l apk_path (find app/build/outputs/apk -name "*.apk" -type f -exec stat -f "%m %N" {} + | sort -rn | head -1 | cut -d' ' -f2-)

    if test -n "$apk_path"
      # Force install the APK using adb
      echo "Force-installing APK with adb: $apk_path"

      # -d  allow downgrade
      # -r
      # --no-streaming  workaround for Streamed install getting stuck
      adb install -r -d --no-streaming $apk_path
      if test $status -eq 0
        echo "App successfully installed."
        adb shell am start -n $package/$activity
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
function andu
  set -l package $argv[1]

  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Uninstalling $package from $ANDROID_SERIAL

  adb shell pm list packages | grep $package | sed -e s/package:// | xargs -L1 adb uninstall
end

# Set connected ADB device DPI to passed value (e.g. 420).
function dpi
  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Setting DPI to $argv on $ANDROID_SERIAL

  adb shell wm density $argv
end

# Set connected ADB device font scale to passed value (e.g. 1.2).
function font-scale
  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  set -l scale $argv

  if test -z $scale
    adb shell settings get system font_scale
    return
  end

  echo Setting DPI to $argv on $ANDROID_SERIAL

  adb shell settings put system font_scale $scale
end

# Set connected ADB device screen size to passed value (e.g. 1080x1920).
function screensize
  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Setting screen size of to $argv on $ANDROID_SERIAL

  adb shell wm size $argv
end

# Screenshot connected ADB device into ~/Downloads folder.
function screenshot
  set -l file_name (_media-file-name)
  set -l path ~/Downloads/android-img-
  set -l image $path$file_name.png

  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Taking a screenshot of $ANDROID_SERIAL

  adbe -s $ANDROID_SERIAL screenshot $image
  echo Screenshot saved at $image
end

# Screenshot connected ADB device in both day and night mode into ~/Downloads folder.
function screenshot-daynight
  set -l file_name (_media-file-name)
  set -l path ~/Downloads/android-img-
  set -l image $path$file_name.png
  set -l image_day $path$file_name-day.png
  set -l image_night $path$file_name-night.png

  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Taking day and night screenshots of $ANDROID_SERIAL

  adbe -s $ANDROID_SERIAL dark mode off
  sleep 2
  adbe -s $ANDROID_SERIAL screenshot $image_day
  echo Day screenshot saved at $image_day

  adbe -s $ANDROID_SERIAL dark mode on
  sleep 2
  adbe -s $ANDROID_SERIAL screenshot $image_night
  echo Night screenshot saved at $image_night

  sleep 2
  adbe -s $ANDROID_SERIAL dark mode off
end

# Record an MP4 video of connected ADB device into ~/Downloads folder and then compresses it.
function screenrecord
  set -l file_name (_media-file-name)
  set -l path ~/Downloads/android-vid-
  set -l video $path$file_name.mp4
  set -l compressed $path$file_name-compressed-noaudio.mp4

  set -fx ANDROID_SERIAL (select-adb-device)
  if test -z "$ANDROID_SERIAL"
    return
  end

  echo Recording a video of $ANDROID_SERIAL

  adbe screenrecord $video
  # echo Video saved at $video

  ffmpeg -i $video -vcodec h264 -an $compressed -hide_banner -preset ultrafast -loglevel error
  # echo Compressed video saved at $compressed
  rm $video
  mv $compressed $video
  echo Video saved at $video
end

set -g adb_static_port 4444

function adb-wifi
  set -l ip $argv[1]
  set -l port $adb_static_port
  set -l ip_with_port "$ip:$port"
  echo "Connecting to $ip_with_port"
  adb connect $ip_with_port
end

function adb-wifi-new
  set -l ip $argv[1]
  set -l port $argv[2]
  set -l ip_with_port "$ip:$port"
  set -l ip_with_new_port "$ip:$adb_static_port"

  echo "Connecting to $ip_with_port"
  adb connect $ip_with_port
  sleep 1
  adb -s $ip_with_port tcpip $adb_static_port
  sleep 1
  adb connect $ip_with_new_port
  sleep 1
  adb disconnect $ip_with_port
end

function adb-dc
  set -l ip $argv[1]
  set -l port $adb_static_port
  set -l ip_with_port "$ip:$port"
  echo "Disconnecting from $ip_with_port"
  adb disconnect $ip_with_port
end

# Fix Android Studio settings sync after update. Android Studio should be closed!
function fix-android-studio-settings-sync
  cd ~/Applications/IntelliJ\ IDEA\ Community\ Edition.app/Contents/lib/

  echo "Extracting IntelliJ lib.jar"
  unzip lib.jar -d lib-idea

  echo "Backing up Android Studio lib.jar"
  cp ~/Applications/Android\ Studio.app/Contents/lib/lib.jar ~/Applications/Android\ Studio.app/Contents/lib/lib-backup.jar
  cd lib-idea
  echo "Updating Android Studio lib.jar with IntelliJ's cloudconfig classes"
  jar -uf ~/Applications/Android\ Studio.app/Contents/lib/lib.jar com/jetbrains/cloudconfig/**/*

  cd ..
  echo "Cleaning up"
  rm -rf lib-idea
end

# Convert all PNGs in drawable-xxxhdpi to WebP and split them into drawable-xxhdpi, drawable-xhdpi, drawable-hdpi, and drawable-mdpi.
function convert-xxxhdpi-to-split-webp
  set -l file_filter $argv[1]

  function convert-image
    set -l in_dir $argv[1]
    set -l out_dir $argv[2]
    set -l file $argv[3]
    set -l convert_arguments $argv[4]

    mkdir -p $out_dir
    set -l webp_file (string replace '.png' '.webp' $file)
    convert "$in_dir/$file" $convert_arguments -define webp:lossless=true "$out_dir/$webp_file"
  end

  for xxxhdpi_dir in (find . -name "drawable-xxxhdpi")
    echo "$xxxhdpi_dir"
    for file in (ls $xxxhdpi_dir/$file_filter)
      set -l file (basename $file)
      echo "$file"
      if not string match -q "*.webp" $file
        convert_image $xxxhdpi_dir $xxxhdpi_dir $file ""
        rm "$xxxhdpi_dir/$file"
      end

      set -l webp_file (string replace '.png' '.webp' $file)
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-xxhdpi" $webp_file "-resize 75%"
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-xhdpi" $webp_file "-resize 50%"
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-hdpi" $webp_file "-resize 37.5%"
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-mdpi" $webp_file "-resize 25%"
    end
  end
end

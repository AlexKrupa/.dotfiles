# Configs
alias fisha "$EDITOR ~/.config/fish/alias.fish"
alias fishc "$EDITOR ~/.config/fish/config.fish"
alias fishr "source ~/.config/fish/config.fish"
alias fishl "$EDITOR ~/.config/fish/local.fish"
alias fishrl "source ~/.config/fish/local.fish"
alias fishe "$EDITOR ~/.config/fish/env.fish"
alias gitc "$EDITOR ~/.gitconfig-base"
alias gradlep "$EDITOR ~/.gradle/gradle.properties"
alias gradlei "$EDITOR ~/.gradle/init.gradle"
alias nvimc "$EDITOR ~/.config/nvim/init.lua"
alias tmuxc "$EDITOR ~/.tmux.conf"
alias tmuxr "tmux source-file ~/.tmux.conf"
alias weztermc "$EDITOR ~/.config/wezterm/wezterm.lua"

alias ls "eza"

# walk file manager
function lk
    set loc (walk $argv); and cd $loc
end


# Run a command in a new tmux pane.
function tmux-split
    set command $argv
    # Count the number of panes in the current window
    set -l pane_count (tmux list-panes | wc -l)

    # Determine the ID of the last pane in the current window
    set -l last_pane_id (tmux list-panes -F '#{pane_id}' | tail -n 1)

    # If only one pane exists, split horizontally; otherwise, split vertically below the rightmost pane
    if test $pane_count -eq 1
        tmux split-window -dh -t $last_pane_id "fish -c '$command; cat'"
        # tmux select-layout even-horizontal
    else
        tmux split-window -dv -t $last_pane_id "fish -c '$command; cat'"
        # tmux select-layout even-vertical
    end 

    # Resize panes only after the second pane has been created
    if test $pane_count -ge 2
        tmux select-layout tiled
    end
end
alias tms tmux-split

################################################################################
## Android                                                                     
################################################################################

alias adb-slow-enable "adb shell settings put global ingress_rate_limit_bytes_per_second 16000"
alias adb-slow-disable "adb shell settings put global ingress_rate_limit_bytes_per_second -1"
alias adb-settings "adb shell am start -n com.android.settings/.Settings"
alias adb-settings-dev "adb shell am start -a com.android.settings.APPLICATION_DEVELOPMENT_SETTINGS"

function as --description "Open Android Studio"
    # set dir $PWD
    # cd
    open -na "Android Studio" --args "$argv"
    # cd $PWD
end

# Get a media (screenshot/video) file name with a timestamp.
# Example: 2021-08-31_14-23-45
function media-file-name
    echo (date +"%Y-%m-%d_%H-%M-%S")
end

# Select an ADB device from the list of connected devices.
function select-adb-device
    set devices "$(adb devices -l | tail -n +2 | ghead -n -1)"
    set device_count (count (echo $devices | string split -n "\n"))
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

    echo (echo $selected_device | cut -f1 -w)
end

function emu
    set avds "$(avdmanager list avd -c)"
    set avd_count (count (echo $avds | string split -n "\n"))
    if test $avd_count -ge 2
        set selected_avd (echo $avds | fzf)
        wait
        if test -z "$selected_avd"
            echo AVD not selected 1>&2
        end
    else if test $avd_count -eq 1
        set selected_avd $avds
    else
        echo No AVDs found 1>&2
    end

    # Start the emulator with Google's DNS server to avoid network issues.
    emulator -avd $selected_avd -dns-server 8.8.8.8
end

# Install and run app on connected device.
# Usage: andi <variant> <package> <activity>
function andi
    set variant $argv[1]
    set package $argv[2]
    set activity $argv[3]

    set variant_lowercase (string lower $variant)

    # android_serial env var is read by both the gradle `install` task and by adb.
    set -fx ANDROID_SERIAL (select-adb-device)
    if test -z "$ANDROID_SERIAL"
        return
    end
    echo Installing $package on $ANDROID_SERIAL

    ./gradlew :app:assemble$variant
    set gradle_status $status

    if test $gradle_status -eq 0
        # Find the most recent APK
        set apk_path (find app/build/outputs/apk -name "*.apk" -type f -exec stat -f "%m %N" {} + | sort -rn | head -1 | cut -d' ' -f2-)
        
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
    set package $argv[1]

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

    set scale $argv

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
    set file_name (media-file-name)
    set path ~/Downloads/android-img-
    set image $path$file_name.png

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
    set file_name (media-file-name)
    set path ~/Downloads/android-img-
    set image $path$file_name.png
    set image_day $path$file_name-day.png
    set image_night $path$file_name-night.png

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
    set file_name (media-file-name)
    set path ~/Downloads/android-vid-
    set video $path$file_name.mp4
    set compressed $path$file_name-compressed-noaudio.mp4

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
    set ip $argv[1]
    set port $adb_static_port
    set ip_with_port "$ip:$port"
    echo "Connecting to $ip_with_port"
    adb connect $ip_with_port
end

function adb-wifi-new
    set ip $argv[1]
    set port $argv[2]
    set ip_with_port "$ip:$port"
    set ip_with_new_port "$ip:$adb_static_port"

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
    set ip $argv[1]
    set port $adb_static_port
    set ip_with_port "$ip:$port"
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
  set file_filter $argv[1]

  function convert-image
    set in_dir $argv[1]
    set out_dir $argv[2]
    set file $argv[3]
    set convert_arguments $argv[4]

    mkdir -p $out_dir
    set webp_file (string replace '.png' '.webp' $file)
    convert "$in_dir/$file" $convert_arguments -define webp:lossless=true "$out_dir/$webp_file"
  end

  for xxxhdpi_dir in (find . -name "drawable-xxxhdpi")
    echo "$xxxhdpi_dir"
    for file in (ls $xxxhdpi_dir/$file_filter)
      set file (basename $file)
      echo "$file"
      if not string match -q "*.webp" $file
        convert_image $xxxhdpi_dir $xxxhdpi_dir $file ""
        rm "$xxxhdpi_dir/$file"
      end

      set webp_file (string replace '.png' '.webp' $file)
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-xxhdpi" $webp_file "-resize 75%"
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-xhdpi" $webp_file "-resize 50%"
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-hdpi" $webp_file "-resize 37.5%"
      convert-image $xxxhdpi_dir "$xxxhdpi_dir/../drawable-mdpi" $webp_file "-resize 25%"
    end
  end
end

################################################################################
## Projects                                                                     
################################################################################

################################################################################
## Tools                                                                     
################################################################################

# Java quick switch
# https://stackoverflow.com/questions/64917779/wrong-java-home-after-upgrade-to-macos-big-sur-v11-0-1
alias javav "java -version"
alias java8 "set -gx JAVA_HOME (/usr/libexec/java_home -v 1.8)"
alias java11 "set -gx JAVA_HOME (/usr/libexec/java_home -v 11)"
alias java17 "set -gx JAVA_HOME (/usr/libexec/java_home -v 17)"
alias java21 "set -gx JAVA_HOME (/usr/libexec/java_home -v 21)"

## Gradle
alias gr "./gradlew"
alias grs "./gradlew --stop"
alias grad "./gradlew assembleDebug"
alias grtd "./gradlew testDebugUnitTest"
alias grccc "rm -rf .gradle/configuration-cache"

## Other
alias brewkill "rm -rf $(brew --prefix)/var/homebrew/locks" # Terminate Brew update in case it gets stuck.
alias g git
alias lg lazygit
alias ls lsd
alias dl "cd ~/Downloads"
alias dlf "open ~/Downloads"
alias finder "open ."
alias python2 "~/.pyenv/versions/2.7.18/bin/python"

# Remove duplicates from $PATH and $fish_user_paths
function dedup_paths
    # Remove duplicates from $PATH
    set -l unique_path
    for path in $PATH
        if not contains $path $unique_path
            set unique_path $unique_path $path
        end
    end
    set -gx PATH $unique_path

    # Remove duplicates from $fish_user_paths
    set -l unique_fish_user_paths
    for path in $fish_user_paths
        if not contains $path $unique_fish_user_paths
            set unique_fish_user_paths $unique_fish_user_paths $path
        end
    end
    set -U fish_user_paths $unique_fish_user_paths
end

################################################################################
## Shokz OpenSwim                                                                     
################################################################################

# Prepare a podcast or audiobook MP3 file to use on Shokz OpenSwim swimming headphones.
#
# It does 2 things:
# 1. Speeds up the tempo. I usually prefer listening to spoken content at 1.5x–2x.
# 2. Splits the file into equal-length segments to make rewind/fast-forward possible on the headphones.
#    This is a workaround for lack of built-in fine-grained rewind/fast-forward controls on the headphones.
#    The headphones can only do previous/next.
#    Now imagine doing it accidentally on a several-hours long audiobook.
#    That's why I wrote this script.
function shokz
    set tempo "1.5"
    set segment_length_s 60

    set source_file $argv
    set prefix (string split -r -m1 . $source_file)[1] # Trim file extension.
    set suffix -%03d.mp3 # 000, 001, 002, etc.
    set subdir $prefix
    set segment $subdir/$prefix$suffix

    echo "source_file=$source_file, prefix=$prefix, suffix=$suffix, subdir=$subdir, segment=$segment, tempo=$tempo, segment_length_s=$segment_length_s"

    # Create a subdirectory to keep segments in, instead of polluting the source directory.
    mkdir -p $subdir

    # Change tempo. 
    # Note that tempo is not the same as speed, as it doesn't affect pitch.
    # This keeps the sound normal instead of "chipmunking" it.
    # Then pipe the sped-up output and split the file into equal-length segments. 
    ffmpeg -i $source_file -map 0:a -filter:a "atempo=$tempo" -f mp3 pipe: | ffmpeg -f mp3 -i pipe: -f segment -segment_time $segment_length_s -segment_start_number 1 -c:a copy $segment

    # Regarding playback order, unfortunately I don't remember which one of these was true. Either:
    # 1. The headphones play tracks ordered by their "download" order, i.e. the order in which they were copied onto the device.
    # 2. Or by their "title" tag.

    # In case of 2, the following code set each segment's 'title' tag to its trimmed file name.
    cd $subdir
    set prefix tmp-
    for file in *.mp3
        set title (string split -r -m1 . $file)[1] # Trim file extension.

        # Set 'title' tag to trimmed file name.
        # New temp file has 'tmp-' prefix.'
        ffmpeg -i $file -acodec libmp3lame -aq 0 -metadata title=$title -metadata track=$title -metadata date=$title -id3v2_version 3 -write_id3v1 1 $prefix$file

        rm $file # Remove original segment.
        mv $prefix$file $file # Rename tagged segment to original name.
    end

    cd ..
end

# Shokz OpenSwim headphones have only previous and next track controls. Short segments let you seek
# in a long audiobook.

function __shokz_cut_times --description 'Segment cut times snapped to silence midpoints'
  set -l duration $argv[1]
  set -l seglen $argv[2]
  set -l window $argv[3]
  set -l mids $argv[4..-1]

  set -l cuts
  set -l last 0
  while true
    set -l target (math "$last + $seglen")
    test $target -lt $duration
    or break

    # Seeding with the window makes out-of-range midpoints lose on distance alone.
    set -l cut $target
    set -l best_distance $window
    for mid in $mids
      test $mid -gt $last
      or continue
      set -l distance (math "abs($mid - $target)")
      test $distance -le $best_distance
      or continue
      set best_distance $distance
      set cut $mid
    end

    set -a cuts $cut
    set last $cut
  end
  string join , $cuts
end

function shokz --description 'Prepare audio for Shokz OpenSwim headphones'
  if test (count $argv) -lt 1
    echo "Usage: shokz <file> [device-volume]" >&2
    return 1
  end

  set -l source_file $argv[1]
  if not test -f $source_file
    echo "shokz: file not found: $source_file" >&2
    return 1
  end
  if not command -q ffmpeg
    echo "shokz: ffmpeg not found in PATH" >&2
    return 1
  end

  set -l tempo 1.5
  set -l segment_length_s 60
  set -l segment_window_pct 0.25
  set -l do_clear true
  set -l do_eject true

  set -l name (basename (string split -r -m1 . $source_file)[1])
  set -l ff -hide_banner -loglevel warning -stats -nostdin -y

  set -l staging (mktemp -d)
  set -l processed $staging/processed.mp3
  set -l meta $staging/silences.txt
  set -l segment $staging/$name-%03d.mp3

  echo "shokz: $name -> tempo=$tempo seglen=$segment_length_s staging=$staging"

  set -l af "highpass=f=80,silenceremove=stop_periods=-1:stop_duration=2:stop_threshold=-40dB,speechnorm=p=0.95:e=6.25:l=1,aresample=44100,atempo=$tempo,silencedetect=n=-30dB:d=0.3,ametadata=mode=print:file=$meta"
  ffmpeg $ff -i $source_file -map 0:a -filter:a $af -c:a libmp3lame -q:a 4 $processed
  or begin
    rm -rf $staging
    return 1
  end

  set -l starts
  set -l ends
  for line in (cat $meta)
    set -l s (string match -rg 'lavfi\.silence_start=(.+)' -- $line)
    and set -a starts $s
    set -l e (string match -rg 'lavfi\.silence_end=(.+)' -- $line)
    and set -a ends $e
  end
  set -l mids
  for i in (seq (count $ends))
    set -a mids (math "($starts[$i] + $ends[$i]) / 2")
  end

  set -l duration (ffprobe -v error -show_entries format=duration -of csv=p=0 $processed)
  set -l window (math "$segment_length_s * $segment_window_pct")
  set -l cut_list (__shokz_cut_times $duration $segment_length_s $window $mids)

  if test -n "$cut_list"
    ffmpeg $ff -i $processed -map 0:a -c:a copy -f segment -segment_times $cut_list -segment_start_number 1 $segment
    or begin
      rm -rf $staging
      return 1
    end
  else
    cp $processed (string replace '%03d' 001 $segment)
  end
  rm $processed $meta

  set -l orig $PWD
  cd $staging
  set -l total (count *.mp3)
  for file in *.mp3
    set -l index (string replace -r '^.*-(\d+)\.mp3$' '$1' $file)
    ffmpeg $ff -i $file -c copy -metadata title="$index - $name" -metadata track=$index/$total -id3v2_version 3 -write_id3v1 1 tmp-$file
    and mv tmp-$file $file
    or begin
      echo "shokz: tagging failed for $file; segments left in $staging" >&2
      cd $orig
      return 1
    end
  end
  cd $orig

  set -l device $argv[2]
  if test -z "$device"
    for vol in /Volumes/*
      if string match -qi '*openswim*' (basename $vol)
        set device $vol
        break
      end
    end
  end
  if test -z "$device"
    echo "shokz: no OpenSwim volume found; segments left in $staging" >&2
    return 0
  end
  if not test -d $device
    echo "shokz: device volume not found: $device" >&2
    return 1
  end
  if not string match -q '/Volumes/*' -- $device
    echo "shokz: device must be a volume in /Volumes: $device" >&2
    return 1
  end

  # The glob skips dotfiles. The system files of the device stay.
  if $do_clear
    rm -rf $device/*
  end

  set -l dest $device/Media
  mkdir -p $dest
  echo "Copying segments to $dest sequentially..."
  for file in $staging/*.mp3
    echo "  -> "(basename $file)
    cp $file $dest/
    or return 1
    sync
  end

  rm -rf $staging

  if $do_eject
    diskutil eject $device
  else
    echo "Done. Eject once the OpenSwim LED stops flashing."
  end
end

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
function shokz --description 'Prepare audio for Shokz OpenSwim headphones'
  if test (count $argv) -lt 1
    echo "Usage: shokz <file> [outbase-dir] [device-volume]" >&2
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

  set -l tempo "1.5"
  set -l segment_length_s 60

  set -l name (basename (string split -r -m1 . $source_file)[1]) # Basename without extension.
  # Optional 2nd arg: destination subdirectory (relative). Segments are staged locally and
  # mirrored on the device under <arg2>/<name>/<name>-NNN.mp3. Default: <name>/ alongside source.
  set -l outbase $argv[2]
  set -l destrel $name # Path under the device root.
  if test -n "$outbase"
    set destrel $outbase/$name
  else
    set outbase (dirname $source_file)
  end
  set -l suffix -%03d.mp3 # 000, 001, 002, etc.
  set -l subdir $outbase/$name
  set -l segment $subdir/$name$suffix

  echo "source_file=$source_file, name=$name, outbase=$outbase, destrel=$destrel, subdir=$subdir, segment=$segment, tempo=$tempo, segment_length_s=$segment_length_s"

  # Create a subdirectory to keep segments in, instead of polluting the output directory.
  mkdir -p $subdir

  # Change tempo and split into equal-length segments in one pass.
  # Note that tempo is not the same as speed, as it doesn't affect pitch.
  # This keeps the sound normal instead of "chipmunking" it.
  ffmpeg -y -i $source_file -map 0:a -filter:a "atempo=$tempo" -f segment -segment_time $segment_length_s -segment_start_number 1 -c:a libmp3lame -q:a 4 $segment
  or return 1

  # Tag each segment for tag-sorting players (harmless on OpenSwim, see copy step below).
  # The index goes to the front of the title so the ID3v1 30-char truncation still keeps
  # each segment distinct; track is a real number, which also writes a valid ID3v1.1 byte.
  set -l orig $PWD
  cd $subdir
  set -l total (count *.mp3)
  set -l tmp_prefix tmp-
  for file in *.mp3
    set -l index (string replace -r '^.*-(\d+)\.mp3$' '$1' $file) # 001, 002, ...

    # Stream-copy to rewrite tags only - no re-encode, no quality loss.
    # New temp file has 'tmp-' prefix.
    ffmpeg -y -i $file -c copy -metadata title="$index - $name" -metadata track=$index/$total -id3v2_version 3 -write_id3v1 1 $tmp_prefix$file

    rm $file # Remove original segment.
    mv $tmp_prefix$file $file # Rename tagged segment to original name.
  end

  cd $orig

  # Copy to the OpenSwim. The device plays files in transmission-completion order, not by
  # name or tag (https://help.shokz.com/s/article/How-to-switch-the-MP3-playback-order-on-OpenSwim-Pro),
  # so copy one file at a time in numeric order with a sync between each. This is the only
  # thing that actually fixes playback order; dragging the whole folder does not.
  set -l device $argv[3]
  if test -z "$device"
    for vol in /Volumes/*
      if string match -qi '*openswim*' (basename $vol)
        set device $vol
        break
      end
    end
  end

  if test -z "$device"
    echo "shokz: no OpenSwim volume found under /Volumes; skipping copy." >&2
    echo "shokz: segments are in '$subdir'. To order correctly, pass the device:" >&2
    echo "shokz:   shokz <file> <dest-subdir> /Volumes/<OpenSwim>" >&2
    return 0
  end
  if not test -d $device
    echo "shokz: device volume not found: $device" >&2
    return 1
  end

  set -l dest $device/$destrel
  mkdir -p $dest
  echo "Copying segments to $dest sequentially..."
  for file in $subdir/*.mp3
    echo "  -> "(basename $file)
    cp $file $dest/
    or return 1
    sync
  end

  # Copy succeeded; the device now holds the segments, so drop the local staging.
  rm -rf $subdir
  rmdir -p (dirname $subdir) 2>/dev/null # Remove now-empty parent dirs, ignore if not empty.
  echo "Removed local staging: $subdir"
  echo "Done. Eject once the OpenSwim LED stops flashing."
end

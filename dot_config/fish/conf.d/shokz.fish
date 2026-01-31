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
    echo "Usage: shokz <file>" >&2
    return 1
  end

  set -l tempo "1.5"
  set -l segment_length_s 60

  set -l source_file $argv
  set -l prefix (string split -r -m1 . $source_file)[1] # Trim file extension.
  set -l suffix -%03d.mp3 # 000, 001, 002, etc.
  set -l subdir $prefix
  set -l segment $subdir/$prefix$suffix

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
  set -l prefix tmp-
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

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

function __shokz_cut_times --description 'Segment cut times snapped to silence midpoints'
  awk 'function abs(x){return x<0?-x:x} BEGIN{
    duration=ARGV[1]+0; seglen=ARGV[2]+0; window=ARGV[3]+0; n=0;
    for(i=4;i<ARGC;i++) mids[++n]=ARGV[i]+0;
    last=0; target=last+seglen; out="";
    while(target<duration){
      lo=target-window; hi=target+window; best=""; bestdist="";
      for(i=1;i<=n;i++){ m=mids[i];
        if(m>last && m>=lo && m<=hi){ d=abs(m-target);
          if(bestdist=="" || d<bestdist){best=m; bestdist=d} } }
      if(best!="") cut=best; else cut=target;
      out=(out==""?cut:out","cut); last=cut; target=last+seglen; }
    print out; exit }' $argv
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

  # --- Config (all knobs here) ---
  set -l tempo 1.5
  set -l segment_length_s 60
  set -l segment_window_pct 0.25   # silence-snap drift = segment_length_s * this
  set -l do_clear true             # wipe entire device before copy
  set -l do_eject true             # diskutil eject when done

  set -l name (basename (string split -r -m1 . $source_file)[1]) # basename without extension
  set -l ff -hide_banner -loglevel warning -stats -nostdin -y

  set -l staging (mktemp -d)
  set -l processed $staging/processed.mp3
  set -l meta $staging/silences.txt
  set -l segment $staging/$name-%03d.mp3

  echo "shokz: $name -> tempo=$tempo seglen=$segment_length_s staging=$staging"

  # --- Pass 1: process + detect silences ---
  set -l af "highpass=f=80,silenceremove=stop_periods=-1:stop_duration=2:stop_threshold=-40dB,speechnorm=p=0.95:e=6.25:l=1,aresample=44100,atempo=$tempo,silencedetect=n=-30dB:d=0.3,ametadata=mode=print:file=$meta"
  ffmpeg $ff -i $source_file -map 0:a -filter:a $af -c:a libmp3lame -q:a 4 $processed
  or begin
    rm -rf $staging
    return 1
  end

  # --- Parse silence intervals -> midpoints ---
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

  # --- Pass 2: split (copy, no re-encode) ---
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

  # --- Tag each segment ---
  set -l orig $PWD
  cd $staging
  set -l total (count *.mp3)
  for file in *.mp3
    set -l index (string replace -r '^.*-(\d+)\.mp3$' '$1' $file)
    ffmpeg $ff -i $file -c copy -metadata title="$index - $name" -metadata track=$index/$total -id3v2_version 3 -write_id3v1 1 tmp-$file
    rm $file
    mv tmp-$file $file
  end
  cd $orig

  # --- Locate device ---
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

  # --- Wipe device (visible entries only; dotfiles/system left) ---
  if $do_clear
    rm -rf $device/*
  end

  # --- Copy segments to Media/ sequentially ---
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

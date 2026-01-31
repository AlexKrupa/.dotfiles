function upfind --description 'Search parent directories for a file'
  if test (count $argv) -lt 1
    echo "Usage: upfind <filename>" >&2
    return 1
  end

  set -f dir (pwd)

  while [ "$dir" != "/" ]
    set -l p (find "$dir" -maxdepth 1 -name $argv[1])

    if [ -n "$p" ]
      echo "$p"
      return 1
    end

    set -f dir (dirname $dir)
  end
end

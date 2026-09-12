function upfind --description 'Search parent directories for a file'
  if test (count $argv) -lt 1
    echo "Usage: upfind <filename>" >&2
    return 1
  end

  set -f dir $PWD

  while test "$dir" != /
    if test -e "$dir/$argv[1]"
      echo "$dir/$argv[1]"
      return 0
    end

    set -f dir (path dirname $dir)
  end

  return 1
end

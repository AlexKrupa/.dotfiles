function jdk --description 'Switch Java version'
  argparse 's/silent' -- $argv
  or return

  set -l jdk_version $argv[-1]
  if test -z "$jdk_version"
    echo "Error: No JDK version specified." >&2
    return 1
  end

  set -l java_home (/usr/libexec/java_home -F -v "$jdk_version")
  or return 1
  set -gx JAVA_HOME $java_home

  if not set -q _flag_silent
    java -version
  end
end

jdk 21 --silent

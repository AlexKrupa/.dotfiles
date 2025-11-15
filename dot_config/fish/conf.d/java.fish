function jdk
  argparse 's/silent' -- $argv
  or return

  # This handles cases when --silent is passed as a first or second argument.
  set -l jdk_version $argv[-1]

  if test -n "$jdk_version"
    set -gx JAVA_HOME $(/usr/libexec/java_home -v "$jdk_version")
  else
    echo "Error: No JDK version specified." >&2  # Redirect to stderr
    return 1
  end

  if not set -q _flag_silent
    java -version
  end
end

# Set default Java version
jdk 21 --silent

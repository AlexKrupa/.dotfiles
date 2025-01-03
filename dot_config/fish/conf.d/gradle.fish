function gw --wraps=gradle
  set -l GW "$(upfind gradlew)"
  if [ -z "$GW" ]
    echo "Gradle wrapper not found."
  else if contains -- "-p" $argv
    $GW --profile --parallel $argv
  else
    $GW -p $(dirname $GW) --profile --parallel $argv
  end
end

alias grs "gw --stop"
alias grad "gw assembleDebug"
alias grtd "gw testDebugUnitTest"
alias grccc "rm -rf .gradle/configuration-cache"


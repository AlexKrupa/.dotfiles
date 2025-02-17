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

alias gws "gw --stop"
alias gwad "gw assembleDebug"
alias gwtd "gw testDebugUnitTest"
alias gwccc "rm -rf .gradle/configuration-cache"


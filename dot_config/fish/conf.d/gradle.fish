function gw --wraps=gradle --description 'Run Gradle via wrapper with profiling'
  set -l GW "$(upfind gradlew)"
  if [ -z "$GW" ]
    echo "Gradle wrapper not found."
  else if contains -- "-p" $argv
    $GW --profile --parallel $argv
  else
    $GW -p $(dirname $GW) --profile --parallel $argv
  end
end

alias grp "$EDITOR ~/.gradle/gradle.properties"
alias gri "$EDITOR ~/.gradle/init.gradle.kts"
alias grccc "rm -rf ~/.gradle/configuration-cache"
alias gws "gw --stop"
alias gwad "gw assembleDebug"
alias gwtd "gw testDebugUnitTest"

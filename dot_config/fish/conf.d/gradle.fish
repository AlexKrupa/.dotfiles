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

alias grp "$EDITOR $GRADLE_USER_HOME/gradle.properties"
alias gri "$EDITOR $GRADLE_USER_HOME/init.gradle.kts"
alias grccc "rm -rf $GRADLE_USER_HOME/configuration-cache"
alias gws "gw --stop"
alias gwad "gw assembleDebug"
alias gwtd "gw testDebugUnitTest"

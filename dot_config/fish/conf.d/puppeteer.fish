# Puppeteer (used by mmdc) uses the installed Chrome. The Homebrew formulae do not download a
# Puppeteer browser. No match leaves the variable unset.
for browser in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" (command -s google-chrome chromium)
    if test -x $browser
        set -gx PUPPETEER_EXECUTABLE_PATH $browser
        break
    end
end

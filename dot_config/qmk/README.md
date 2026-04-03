QMK CLI likely hardcodes config to `~/Library/Application Support/` on macOS via Python's platformdirs or appdirs instead of checking `XDG_CONFIG_HOME`. 

Symlink:

```sh
ln -s ~/.config/qmk ~/Library/Application\ Support/qmk
```

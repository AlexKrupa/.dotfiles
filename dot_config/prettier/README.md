# prettier config

Prettier does not support any global configuration by design; config resolves
only from the formatted file's directory upward. See
https://github.com/prettier/prettier/blob/main/docs/configuration.md

Pass this file explicitly:

```sh
prettier --config ~/.config/prettier/config.json --write FILE.md
```

Neovim (conform) references it the same way in `init.lua`.

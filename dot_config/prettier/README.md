# prettier config

[Prettier does not support any global configuration by design](https://github.com/prettier/prettier/blob/main/docs/configuration.md).
Config resolves only from the formatted file's directory upward.

Pass the config file explicitly:

```sh
prettier --config ~/.config/prettier/config.json --write FILE.md
```

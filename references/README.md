# References

Local read-only clones of prior art, kept here so any agent instance working on
this project can grep/read them directly instead of re-fetching from the web.

These are **not** committed as git submodules and **not** tracked by the main
repo's history (see `../.gitignore`) — they're plain working clones, refreshed
with `git pull` as needed. Do not edit files inside them; treat as reference-only.

## Contents

- `ubuntu-galaxy-tab-s9-ultra/` — https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra
  Ubuntu 24.04 port for the Galaxy Tab S9 Ultra Wi-Fi (SM-X910), mainline Linux
  7.2-rc3 on SM8550/Snapdragon 8 Gen 2. This is the project our port is modeled
  after — see `../PORTING_ANALYSIS.md` for what is and isn't reusable from it.

- `postmarketos-galaxy-tab-s9-ultra/` — https://github.com/agcarbajo/postmarketos-galaxy-tab-s9-ultra
  The postmarketOS base port the Ubuntu project itself was forked from. Contains
  the original kernel/DTS/driver work in its earliest, least Ubuntu-specific form.

## Adding more references

When cloning something else relevant here (e.g. Samsung's GPL kernel source
drop for `gts7`, SM8250-mainline community trees, other Tab S7 custom-kernel
repos), add a subsection above describing what it is and why it's relevant, so
future agent instances don't have to rediscover that.

## Refreshing

```sh
cd references/ubuntu-galaxy-tab-s9-ultra && git pull
cd references/postmarketos-galaxy-tab-s9-ultra && git pull
```

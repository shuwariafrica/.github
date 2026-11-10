# Shuwari Africa Ltd.

## Writing an action here

Every composite action step that runs a script is written this way:

- `shell: /usr/bin/bash --posix --noprofile --norc -e -o pipefail {0}`;
- a `run` of `set -euo pipefail` then
  `exec /usr/bin/env -i PATH=/usr/bin:/bin NAME="${NAME}" ... /usr/bin/bash --noprofile --norc "${GITHUB_ACTION_PATH}/<script>.sh"`,
  naming each variable the script reads, and keeping the script itself in a file;
- each credential, an OIDC request token among them, on descriptor 3 through a here-document
  (`exec 3<<TOKEN`), never in the whitelist or another argument list;
- the step's `env` clearing `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `LD_PRELOAD`,
  `LD_LIBRARY_PATH` and `LD_AUDIT`.

Bash imports a function from any environment variable named `BASH_FUNC_<name>%%`, and any earlier
step of a job, a third-party action included, can set one through `GITHUB_ENV`. Outside POSIX mode
such a function stands for `set`, `exec`, `:` or any tool before a script's first line, and every
bash script started after it imports it again. POSIX mode will not start when one names a special
builtin, and `env -i` hands the script none of them. The step's own `env`, which the runner merges
last, clears what bash and the loader read before the first line.

So an action's tools are those in `/usr/bin` or `/bin`, installed by the job from the image's
package manager; a tool on `GITHUB_PATH` is not reached. A step that runs a node action runs no
bash, and its `env` clears the same variables for the loader's sake.

Each action's tests are in `tests/<action>/run.sh`, which states its usage.

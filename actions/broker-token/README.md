# broker-token

A job using `broker-token` has curl and jq in `/usr/bin` or `/bin`, from apt, as GitHub's Ubuntu
images hold them. The step runs its script with `PATH=/usr/bin:/bin` and none of the job's
environment, so a tool on `GITHUB_PATH` is not reached.

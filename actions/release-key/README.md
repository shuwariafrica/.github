# release-key

A job using `release-key` or `release-key/verify` has gpg, gpgconf, sqv, curl, jq and awk in
`/usr/bin` or `/bin`, from apt (`sudo apt-get install -y sqv` adds the one GitHub's Ubuntu images
lack). Each step runs its script with `PATH=/usr/bin:/bin` and none of the job's environment, so a
tool on `GITHUB_PATH` is not reached.

#!/bin/bash

# Log ephemeral disk usage (tune EPHEMERAL_STORAGE_* from this).
# Call it right after the test run: finalize_once always exits 0, so a trailing call
# on exit is not reachable. fail() in error-handler.sh calls it on fatal errors.
log_disk_usage() {
    echo "Disk usage:"
    du -h -d1 "${TMP_DIR:-/tmp}" 2>/dev/null | sort -h | tail -n 10
    du -sh "${HOME_EX:-/app}"/.[!.]* 2>/dev/null
    return 0
}

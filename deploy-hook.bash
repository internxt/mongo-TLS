#!/bin/bash
# Deploy hook used when SSL cert was renewed successfully
# This will trigger the mongo renewal script and let us know if something went wrong

set -euo pipefail

TARGET_SCRIPT="/home/ubuntu/mongo-script/mongo-renewal-script.bash"

log_and_notify() {
    local message="$1"
    local level="${2:-INFO}"
    
    echo "[$level] $message"

    # Add any call to slack or something that let us know the status of the renewal
}

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    log_and_notify "ERROR: Script not found: $TARGET_SCRIPT" "ERROR"
    exit 1
fi

if [[ ! -x "$TARGET_SCRIPT" ]]; then
    log_and_notify "ERROR: Script not executable: $TARGET_SCRIPT" "ERROR"
    exit 1
fi

if [[ -n "${RENEWED_DOMAINS:-}" ]]; then
    log_and_notify "Detected renewed domain from certbot: $RENEWED_DOMAINS"
else
    log_and_notify "No RENEWED_DOMAINS found" "ERROR"
    exit 1
fi

# Set required environment variables, we can get these from any source or just hardcode them.
export MONGO_USER="Gradient7378"
export MONGO_PASSWORD="U&^k@w3sN@MrziqY"
export MONGO_AUTH_DB="admin"

echo "About to execute: $TARGET_SCRIPT"

if "$TARGET_SCRIPT" -c "/etc/ssl/mongodb/mongodb-test.pem" -d "$RENEWED_DOMAINS"; then
    log_and_notify "MongoDB certificate renewal completed successfully"
else
    script_exit_code=$?
    log_and_notify "MongoDB certificate renewal failed with exit code: $script_exit_code" "ERROR"
    exit $script_exit_code
fi
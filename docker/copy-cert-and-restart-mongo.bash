#!/bin/bash
set -euo pipefail

# MongoDB Certificate Renewal Script
# Only restarts MongoDB if ALL replica set members are healthy
#
# Usage: ./script.sh [OPTIONS]
#
# Options:
#   -c PATH    Certificate file (default: /etc/ssl/mongodb/mongodb-cert.pem)
#   -b PATH    Backup directory (default: /etc/ssl/mongodb/backups)
#   -l PATH    logs file (default: /var/log/mongodb/certificate-renewal.log)
#   -d PATH    domain certificate renewed (REQUIRED)
#   -q         Quiet mode (suppress non-essential output)
#
# Environment variables:
#   MONGO_USER         MongoDB username (REQUIRED)
#   MONGO_PASSWORD     MongoDB password  (REQUIRED)
#   MONGO_AUTH_DB      MongoDB authentication database (REQUIRED)

# Parse opts beforehand
CERT_FILE_ARG=""
BACKUP_DIR_ARG=""
LOG_FILE_ARG=""
RENEWED_DOMAIN_ARG=""
QUIET=false
while getopts "c:b:l:d:q" opt; do
    case $opt in
        c) CERT_FILE_ARG="$OPTARG" ;;
        b) BACKUP_DIR_ARG="$OPTARG" ;;
        d) RENEWED_DOMAIN_ARG="$OPTARG" ;;
        q) QUIET=true ;;
        l) LOG_FILE_ARG="$OPTARG" ;;
        \?) die "Invalid option: -$OPTARG" ;;
        :) die "Option -$OPTARG requires an argument." ;;
    esac
done

# Configuration
readonly MONGO_USER="${MONGO_USER:-}"
readonly MONGO_PASSWORD="${MONGO_PASSWORD:-}"
readonly MONGO_AUTH_DB="${MONGO_AUTH_DB:-}"
readonly RENEWED_DOMAIN="${RENEWED_DOMAIN_ARG:-}"
readonly LOG_FILE="${LOG_FILE_ARG:-"/var/log/mongodb/certificate-renewal.log"}"
readonly CERT_FILE="${CERT_FILE_ARG:-"/etc/ssl/mongodb/mongodb-cert.pem"}"
readonly CA_FILE="${CA_FILE_ARG:-"/etc/ssl/mongodb/mongodb-ca.pem"}"
readonly BACKUP_DIR="${BACKUP_DIR_ARG:-"/etc/ssl/mongodb/backups"}"

# MongoDB connection command
readonly MONGO_CMD=(
    mongosh
    -u "$MONGO_USER"
    -p "$MONGO_PASSWORD"
    --authenticationDatabase "$MONGO_AUTH_DB"
    --quiet
    --tls
    --tlsAllowInvalidHostnames
)

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" >> "$LOG_FILE"
    [[ "$QUIET" != "true" ]] && echo "$message"
}

die() {
    log "ERROR: $1"
    exit 1
}

validate_required_variables() {
    [[ -n "$MONGO_AUTH_DB" ]] || die "MongoDB auth db not provided. Set MONGO_AUTH_DB environment variable."
    [[ -n "$MONGO_USER" ]] || die "MongoDB user not provided. Set MONGO_USER environment variable."
    [[ -n "$MONGO_PASSWORD" ]] || die "MongoDB password not provided. Set MONGO_PASSWORD environment variable."
    [[ -n "$RENEWED_DOMAIN" ]] || die "Renewed domain not provided. Set -d opt."
}

validate_connection() {
    "${MONGO_CMD[@]}" --eval 'db.runCommand("ping")' &>/dev/null || die "MongoDB connection failed"
    log "✓ MongoDB connection successful"
}

get_current_mongo_node_domain() {
    local hostname
    hostname=$("${MONGO_CMD[@]}" --eval "
        const me = rs.status().members.find(m => m.self === true);
        print(me ? me.name.split(':')[0] : 'error');
    " 2>/dev/null)
    
    [[ "$hostname" != "error" && -n "$hostname" ]] || die "Could not determine hostname from replica set"
    echo "$hostname"
}

check_replica_health() {
    local result
    result=$("${MONGO_CMD[@]}" --eval "
        const status = rs.status();
        const members = status.members;
        const me = members.find(m => m.self === true);
        
        const healthy = members.filter(m => m.health === 1 && (m.state === 1 || m.state === 2)).length;
        const isPrimary = me && me.state === 1;
        
        if (isPrimary && healthy === members.length) {
            rs.stepDown(60);
            print('STEPDOWN_SUCCESS');
        } else {
            print('HEALTH:' + healthy + ':' + members.length + ':' + isPrimary);
        }
    " 2>/dev/null)
    
    case "$result" in
        *"STEPDOWN_SUCCESS"*)
            log "✓ Primary stepdown successful"
            sleep 10
            ;;
        *"HEALTH:"*)
            if [[ $result =~ HEALTH:([0-9]+):([0-9]+):(true|false) ]]; then
                local healthy="${BASH_REMATCH[1]}"
                local total="${BASH_REMATCH[2]}"
                
                log "Replica set: $healthy/$total healthy"
                [[ $healthy -eq $total ]] || die "Not all replicas are healthy ($healthy/$total)."
            fi
            ;;
        *)
            die "Health check failed: $result"
            ;;
    esac
}

update_certificate() {
    log "Updating MongoDB certificate and CA..."
    
    local cert_source="./certs/mongodb-cert-key-file.pem"
    local ca_source="./certs/mongodb-ca.pem"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Backup existing files
    [[ -f "$CERT_FILE" ]] && cp "$CERT_FILE" "$BACKUP_DIR/$(basename "$CERT_FILE").backup.$timestamp"
    [[ -f "$CA_FILE" ]] && cp "$CA_FILE" "$BACKUP_DIR/$(basename "$CA_FILE").backup.$timestamp"
    
    # Copy new files
    cp "$cert_source" "$CERT_FILE"
    cp "$ca_source" "$CA_FILE"
    
    # Set permissions
    chown mongodb:mongodb "$CERT_FILE" "$CA_FILE"
    chmod 400 "$CERT_FILE" "$CA_FILE"
    
    log "✓ Certificate and CA updated"
}

restart_mongodb() {
    log "Restarting MongoDB service..."
    
    systemctl restart mongod || die "Failed to restart MongoDB service"
    log "✓ MongoDB service restarted"
    
    # Wait for service to be ready
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if "${MONGO_CMD[@]}" --eval 'db.runCommand("ping")' &>/dev/null; then
            log "✓ MongoDB is ready"
            return 0
        fi
        ((attempts++))
        sleep 2
    done
    
    die "MongoDB failed to become ready after restart"
}

main() {
    # Ensure directories exist
    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
    
    log "Starting MongoDB certificate renewal process"
    log "CONFIG -> Certificate: $CERT_FILE, Backups: $BACKUP_DIR"
    
    # Validate prerequisites
    validate_required_variables
    validate_connection
    
    # Get current hostname and validate domain match
    local current_domain
    current_domain=$(get_current_mongo_node_domain)
    log "Current node domain: $current_domain"
    
    [[ "$current_domain" == "$RENEWED_DOMAIN" ]] || die "Domain mismatch: $RENEWED_DOMAIN != $current_domain"
    
    # Check health and step down if primary
    check_replica_health
    log "✓ All replicas healthy - proceeding with certificate renewal"
    
    # Update certificates
    update_certificate "$current_domain"
    
    # Check health again and restart
    check_replica_health
    log "✓ All replicas healthy - proceeding with restart"
    restart_mongodb
    
    log "Certificate renewal completed successfully"
}

main "$@"
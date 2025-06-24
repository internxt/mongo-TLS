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
        c)
            CERT_FILE_ARG="$OPTARG"
            ;;
        b)
            BACKUP_DIR_ARG="$OPTARG"
            ;;
        d)
            RENEWED_DOMAIN_ARG="$OPTARG"
            ;;
        q)
            QUIET=true
            ;;
        l)
            LOG_FILE_ARG="$OPTARG"
            ;;
        \?)
            die "Invalid option: -$OPTARG"
            ;;
        :)
            die "Option -$OPTARG requires an argument."
            ;;
    esac
done

# Configuration
readonly MONGO_USER="${MONGO_USER:-}"
readonly MONGO_PASSWORD="${MONGO_PASSWORD:-}"
readonly MONGO_AUTH_DB="${MONGO_AUTH_DB:-}"
readonly RENEWED_DOMAIN="${RENEWED_DOMAIN_ARG:-}"
readonly LOG_FILE="${LOG_FILE_ARG:-"/var/log/mongodb/certificate-renewal.log"}"
readonly CERT_FILE="${CERT_FILE_ARG:-"/etc/ssl/mongodb/mongodb-cert.pem"}"
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

prepare_environment(){
    # Ensure directories exist
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$BACKUP_DIR"
}

log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" >> "$LOG_FILE"

    if [[ "$QUIET" != "true" ]]; then
        echo "$message"
    fi
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
    if "${MONGO_CMD[@]}" --eval 'db.runCommand("ping")' &>/dev/null; then
        log "✓ MongoDB connection successful"
        return 0
    else
        die "MongoDB connection failed"
    fi
}

# Gets the domain/hostname of the current mongo node
get_current_mongo_node_domain() {
    local hostname
    hostname=$("${MONGO_CMD[@]}" --eval "
        try {
            const me = rs.status().members.find(m => m.self === true);
            print(me ? me.name.split(':')[0] : 'error');
        } catch (e) {
            print('error');
        }
    " 2>/dev/null)
    
    [[ "$hostname" != "error" && -n "$hostname" ]] || die "Could not determine hostname from replica set"
    echo "$hostname"
}

check_status_and_stepdown_if_primary() {
    log "Checking replica set health..."
    
    local result
    result=$("${MONGO_CMD[@]}" --eval "
        try {
            const status = rs.status();
            const members = status.members;
            const me = members.find(m => m.self === true);
            
            let healthy = 0;
            const total = members.length;
            const isPrimary = me && me.state === 1;
            
            // Count healthy members
            members.forEach(member => {
                if (member.health === 1 && (member.state === 1 || member.state === 2)) {
                    healthy++;
                }
            });
            
            // Handle primary stepdown
            if (isPrimary && healthy === total) {
                print('STEPDOWN_INITIATED');
                try {
                    rs.stepDown(60);
                    print('STEPDOWN_SUCCESS');
                } catch (e) {
                    print('STEPDOWN_FAILED:' + e.message);
                }
            } else {
                print('HEALTH:' + healthy + ':' + total + ':' + isPrimary);
            }
        } catch (e) {
            print('ERROR:' + e.message);
        }
    " 2>/dev/null)
    
    echo "$result"
}

update_certificate() {
    log "Updating MongoDB certificate..."
    
    local hostname="$1"
    local cert_source="/etc/letsencrypt/live/$hostname"

    # Validate source certificate exists
    if [[ ! -f "$cert_source/fullchain.pem" ]] || [[ ! -f "$cert_source/privkey.pem" ]]; then
        die "Let's Encrypt certificates not found for $hostname"
    fi
    
    # Validate the source certificates are valid BEFORE doing anything
    log "Validating source Let's Encrypt certificates..."
    
    # Validate fullchain.pem
    local cert_validation_error
    if ! cert_validation_error=$(openssl x509 -in "$cert_source/fullchain.pem" -text -noout 2>&1); then
        log "Certificate validation failed for fullchain.pem"
        log "OpenSSL error: $cert_validation_error"
        die "Source fullchain.pem is not a valid certificate"
    fi
    
    # Validate privkey.pem (try both RSA and ECDSA)
    local rsa_validation_error pkey_validation_error
    if ! rsa_validation_error=$(openssl rsa -in "$cert_source/privkey.pem" -check -noout 2>&1); then
        if ! pkey_validation_error=$(openssl pkey -in "$cert_source/privkey.pem" -check -noout 2>&1); then
            log "Private key validation failed for privkey.pem"
            log "OpenSSL RSA error: $rsa_validation_error"
            log "OpenSSL PKEY error: $pkey_validation_error"
            die "Source privkey.pem is not a valid private key"
        fi
    fi
    
    # Validate that the certificate and private key match
    local cert_pubkey key_pubkey

    if ! cert_pubkey=$(openssl x509 -in "$cert_source/fullchain.pem" -pubkey -noout 2>&1); then
        log "Failed to extract public key from certificate"
        log "OpenSSL error: $cert_pubkey"
        die "Failed to extract public key from certificate"
    fi
    
    if ! key_pubkey=$(openssl pkey -in "$cert_source/privkey.pem" -pubout 2>&1); then
        log "Failed to extract public key from private key"
        log "OpenSSL error: $key_pubkey"
        die "Failed to extract public key from private key"
    fi
    
    if [[ "$cert_pubkey" != "$key_pubkey" ]]; then
        die "Certificate and private key do not match"
    fi
    
    log "✓ Source certificates are valid and match"
    
    # Now that everything is validated, create backup of existing certificate
    if [[ -f "$CERT_FILE" ]]; then
        local backup_filename
        backup_filename="$(basename "$CERT_FILE").backup.$(date +%Y%m%d_%H%M%S)"
        local backup_file="$BACKUP_DIR/$backup_filename"
        log "Creating backup of existing certificate: $backup_file"
        cp "$CERT_FILE" "$backup_file"
        
        if [[ -f "$backup_file" ]]; then
            log "✓ Backup created successfully: $backup_file"
            
            # Set proper permissions for backup
            chmod 400 "$backup_file"
            chown mongodb:mongodb "$backup_file" 2>/dev/null || true
        else
            die "Failed to create certificate backup"
        fi
    else
        log "No existing certificate found, skipping backup"
    fi
    
    # Create new combined certificate file (we know it's valid)
    log "Combining validated fullchain.pem and privkey.pem..."
    local cat_error
    if ! cat_error=$(cat "$cert_source/fullchain.pem" "$cert_source/privkey.pem" > "$CERT_FILE" 2>&1); then
        log "Failed to combine certificate files"
        log "Error: $cat_error"
        die "Failed to combine certificate files"
    else
        log "✓ Certificate files combined successfully"
    fi
    
    # Set proper permissions
    local chown_error chmod_error
    if ! chown_error=$(chown mongodb:mongodb "$CERT_FILE" 2>&1); then
        log "Failed to set certificate ownership: $chown_error"
        die "Failed to set certificate permissions"
    fi
    
    if ! chmod_error=$(chmod 400 "$CERT_FILE" 2>&1); then
        log "Failed to set certificate permissions: $chmod_error"
        die "Failed to set certificate permissions"
    fi
    
    log "✓ Certificate permissions set correctly"
    log "Certificate updated: $CERT_FILE"
}

restart_mongodb() {
    log "Restarting MongoDB service..."
    
    if systemctl restart mongod; then
        log "✓ MongoDB service restarted successfully"
        
        # Wait for service to be ready
        log "Waiting for MongoDB to be ready..."
        local attempts=0
        local max_attempts=30
        
        while [ $attempts -lt $max_attempts ]; do
            if "${MONGO_CMD[@]}" --eval 'db.runCommand("ping")' &>/dev/null; then
                log "✓ MongoDB is ready and accepting connections"
                return 0
            fi
            
            attempts=$((attempts + 1))
            log "Waiting for MongoDB... (attempt $attempts/$max_attempts)"
            sleep 2
        done
        
        die "MongoDB failed to become ready after restart"
    else
        die "Failed to restart MongoDB service"
    fi
}

validate_if_healthy() {
    local status="$1"
    
    # If there's an error, fail immediately
    if [[ $status == *"ERROR:"* ]]; then
        die "Health check failed: ${status#*ERROR:}"
    fi
    
    # Parse and log different statuses
    case "$status" in
        *"STEPDOWN_SUCCESS"*)
            log "✓ Primary stepdown successful"
            log "Waiting for new primary election..."
            sleep 10
            ;;
        *"STEPDOWN_FAILED"*)
            die "Primary stepdown failed, cannot proceed safely"
            ;;
        *"HEALTH:"*)
            if [[ $status =~ HEALTH:([0-9]+):([0-9]+):(true|false) ]]; then
                local healthy="${BASH_REMATCH[1]}"
                local total="${BASH_REMATCH[2]}"
                local is_primary="${BASH_REMATCH[3]}"
                
                log "Replica set: $healthy/$total healthy (Primary: $is_primary)"
                
                if [[ $healthy -ne $total ]]; then
                    die "Not all replicas are healthy ($healthy/$total). Cannot proceed with certificate renewal."
                fi
            else
                die "Failed to parse health status: $status"
            fi
            ;;
        *)
            die "Unknown status: $status"
            ;;
    esac
}

validate_replicas_health(){
    local health_status
    health_status=$(check_status_and_stepdown_if_primary)
    
    validate_if_healthy "$health_status"
}

main() {
    log "CONFIG -> Backups directory location: $BACKUP_DIR"
    log "CONFIG -> Certificate file location: $CERT_FILE"
    log "CONFIG -> Logs file location: $LOG_FILE"
    log "Starting MongoDB certificate renewal process"
    
    # Validate prerequisites
    validate_required_variables
    validate_connection
    
    # Get current hostname
    local current_domain
    current_domain=$(get_current_mongo_node_domain)
    log "Detected current node domain: $current_domain"

    if [[ "$current_domain" != "$RENEWED_DOMAIN" ]]; then
        die "Renewed domain $RENEWED_DOMAIN does not match the current node domain $current_domain"
    fi

    # Check replica set health and step down if the node is the primary.
    validate_replicas_health
    log "✓ All replicas healthy - ready to proceed with certificate renewal"

    # Update cert file. This will not be applied until the node is restarted.
    update_certificate "$current_domain"

    # Validate health again and restart.
    validate_replicas_health
    log "✓ All replicas healthy - ready to proceed with node restart"
    restart_mongodb

    log "Certificate renewal process completed successfully"
}

# Execute main function
main "$@"
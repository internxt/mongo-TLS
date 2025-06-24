#!/bin/bash
set -e

if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN environment variable is required"
    exit 1
fi

echo "=== Starting certificate renewal for $DOMAIN ==="

# Verify that the certificate exists before attempting to renew
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ ! -d "$CERT_DIR" ]; then
    echo "ERROR: No existing certificate found for $DOMAIN"
    exit 1
fi

## Check if the cert is going to end in 30 days or less
if openssl x509 -in "$CERT_DIR/cert.pem" -checkend $((30 * 24 * 3600)) -noout; then
    echo "=== Certificate renewal not needed (>30 days left) ==="
    exit 0
else
    echo "=== Certificate expires within 30 days, renewal needed ==="
fi

CURRENT_EXPIRY=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)
echo "Certificate expires: $CURRENT_EXPIRY"

# Create backup before renewing
echo "=== Creating backup of current MongoDB certificates ==="

# Use current date for backup directory
BACKUP_DATE=$(date +"%Y-%m-%d")
BACKUP_TIME=$(date +"%H%M%S")
BACKUP_DIR="/backups/$BACKUP_DATE"
BACKUP_SUBDIR="$BACKUP_DIR/${DOMAIN}_${BACKUP_TIME}"

mkdir -p "$BACKUP_SUBDIR"

BACKUP_CREATED=false

if [ -f "/output-certs/mongodb-cert-key-file.pem" ]; then
    cp "/output-certs/mongodb-cert-key-file.pem" "$BACKUP_SUBDIR/mongodb-cert-key-file.pem"
    echo "MongoDB combined certificate backed up"
    BACKUP_CREATED=true
fi

if [ -f "/output-certs/mongodb-ca.pem" ]; then
    cp "/output-certs/mongodb-ca.pem" "$BACKUP_SUBDIR/mongodb-ca.pem"
    echo "MongoDB CA certificate backed up"
    BACKUP_CREATED=true
fi

if [ -d "/output-certs/cert-and-keys" ]; then
    cp -r "/output-certs/cert-and-keys" "$BACKUP_SUBDIR/cert-and-keys"
    echo "All certificate files backed up"
    BACKUP_CREATED=true
fi

if [ "$BACKUP_CREATED" = true ]; then
   echo "=== Backup completed in: $BACKUP_SUBDIR ==="
else
    echo "=== No existing certificates found to backup ==="
fi

echo "=== Running certificate renewal ==="

# Args passed to certbot command
certbot "$@"

if [ ! -f "$CERT_DIR/privkey.pem" ] || [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo "ERROR: Certificate renewal failed - files not found"
    echo "You can restore from backup: $BACKUP_SUBDIR"
    exit 1
fi

# Verify that the certificate actually changed
NEW_EXPIRY=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)
if [ "$CURRENT_EXPIRY" = "$NEW_EXPIRY" ]; then
    echo "WARNING: Certificate expiry date unchanged - renewal may not have been needed"
    echo "Original: $CURRENT_EXPIRY"
    echo "Current:  $NEW_EXPIRY"
else
    echo "=== Certificate successfully renewed ==="
    echo "Old expiry: $CURRENT_EXPIRY"
    echo "New expiry: $NEW_EXPIRY"
fi

echo "=== Recreating MongoDB certificate files ==="
OUTPUT_FILE="/output-certs/mongodb-cert-key-file.pem"

cat "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem" > "$OUTPUT_FILE"

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: Failed to create combined certificate file"
    echo "You can restore from backup: $BACKUP_SUBDIR"
    exit 1
fi

echo "=== Creating CA file for MongoDB ==="
CA_FILE="/output-certs/mongodb-ca.pem"

# Use the ca-certification's CA bundle
if [ -f "/etc/ssl/certs/ca-certificates.crt" ]; then
    echo "Using container's CA certificate bundle"
    cp "/etc/ssl/certs/ca-certificates.crt" "$CA_FILE"
else
    echo "Container CA bundle not found, downloading Mozilla CA bundle..."
    wget -O "$CA_FILE" https://curl.se/ca/cacert.pem
    
    # Add Let's Encrypt chain to ensure compatibility
    echo "Appending Let's Encrypt chain to CA bundle"
    cat "$CERT_DIR/chain.pem" >> "$CA_FILE"
fi

mkdir -p /output-certs/cert-and-keys
cp "$CERT_DIR/"* "/output-certs/cert-and-keys"

chmod -R 755 "/etc/letsencrypt/" "/output-certs/" "/backups"

echo "=== Certificate Information ==="
echo "Domain: $DOMAIN"
echo "Combined certificate created at: $OUTPUT_FILE"
echo "CA certificate created at: $CA_FILE"
echo "Certificate expires: $NEW_EXPIRY"
echo "Backup available at: $BACKUP_SUBDIR"

echo "=== Certificate renewal completed successfully ==="
echo "MongoDB configuration:"
echo "  certificateKeyFile: $OUTPUT_FILE"
echo "  CAFile: $CA_FILE"

#!/bin/bash
set -e

if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN environment variable is required"
    exit 1
fi

echo "=== Starting certificate renewal for $DOMAIN ==="

# Verificar que el certificado existe antes de intentar renovar
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

# Crear backup antes de renovar
echo "=== Creating backup of current MongoDB certificates ==="

# Usar fecha actual para el directorio de backup
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

# Renovar certificado
echo "=== Running certificate renewal ==="
certbot "$@"

# Verificar que la renovación fue exitosa
if [ ! -f "$CERT_DIR/privkey.pem" ] || [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo "ERROR: Certificate renewal failed - files not found"
    echo "You can restore from backup: $BACKUP_SUBDIR"
    exit 1
fi

# Verificar que el certificado realmente cambió
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

# Post-procesamiento para MongoDB
echo "=== Recreating MongoDB certificate files ==="
OUTPUT_FILE="/output-certs/mongodb-cert-key-file.pem"

cat "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem" > "$OUTPUT_FILE"

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: Failed to create combined certificate file"
    echo "You can restore from backup: $BACKUP_SUBDIR"
    exit 1
fi

CA_FILE="/output-certs/mongodb-ca.pem"
cp "$CERT_DIR/chain.pem" "$CA_FILE"

mkdir -p /output-certs/cert-and-keys
cp "$CERT_DIR/"* "/output-certs/cert-and-keys"

chmod -R 644 "/output-certs/"
chmod -R +X "/output-certs/"

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

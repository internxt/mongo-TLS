#!/bin/bash
set -e

if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN environment variable is required"
    exit 1
fi

if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "=== Certificate already exists for $DOMAIN ==="
fi

# We pass args to certbot
certbot "$@"

# Check if certificates were created by certbot properly
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ ! -f "$CERT_DIR/privkey.pem" ] || [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo "ERROR: Certificate files not found in $CERT_DIR"
    exit 1
fi
echo "=== Certificate obtained successfully ==="

# Combinar private key y fullchain para MongoDB
echo "=== Creating combined certificate for MongoDB ==="
OUTPUT_FILE="/output-certs/mongodb-cert-key-file.pem"
# Create combined file (privkey + fullchain)
cat "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem" > "$OUTPUT_FILE"
# Check if the combinated file was created successfully
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: Failed to create combined certificate file"
    exit 1
fi

# We need a CA file for mongodb
CA_FILE="/output-certs/mongodb-ca.pem"
cp "$CERT_DIR/chain.pem" "$CA_FILE"

mkdir -p /output-certs/cert-and-keys
# We copy all the certificates into output-certs
cp "/etc/letsencrypt/live/$DOMAIN/"* "/output-certs/cert-and-keys"

# We need to let host to read the folder and files
chmod -R 644 "/output-certs/"
chmod -R +X "/output-certs/"

echo "=== Certificate Information ==="
echo "Domain: $DOMAIN"
echo "Combined certificate created at: $OUTPUT_FILE"
echo "CA certificate created at: $CA_FILE"
echo "Certificate expires: $(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)"

echo "=== Certificate setup completed successfully ==="
echo "MongoDB configuration:"
echo "  certificateKeyFile: $OUTPUT_FILE"
echo "  CAFile: $CA_FILE"
#!/bin/bash

set -e  # Exit on any error

# Validar que existe la variable DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN environment variable is required"
    exit 1
fi

echo "=== Obtaining SSL certificate for domain: $DOMAIN ==="

# Obtener certificado usando standalone mode (puerto 80)
certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --domain "$DOMAIN" \
    --keep-until-expiring \
    --staging

# Verificar que los archivos de certificado existen
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ ! -f "$CERT_DIR/privkey.pem" ] || [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    echo "ERROR: Certificate files not found in $CERT_DIR"
    exit 1
fi

echo "=== Certificate obtained successfully ==="

# Cambiar permisos de los archivos de certbot para que sean legibles
echo "=== Adjusting certificate permissions ==="
chmod -R 755 /etc/letsencrypt/live
chmod -R 755 /etc/letsencrypt/archive
chmod 644 /etc/letsencrypt/live/$DOMAIN/*
chmod 644 /etc/letsencrypt/archive/$DOMAIN/*

# Combinar private key y fullchain para MongoDB
echo "=== Creating combined certificate for MongoDB ==="

OUTPUT_FILE="/output-certs/mongodb-combined.pem"

# Crear el archivo combinado (privkey + fullchain)
cat "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem" > "$OUTPUT_FILE"

# Crear CA file separado para MongoDB
CA_FILE="/output-certs/mongodb-ca.pem"
cp "$CERT_DIR/chain.pem" "$CA_FILE"

# Hacer el archivo combinado legible también
chmod 644 "$OUTPUT_FILE"
chmod 644 "$CA_FILE"

# Verificar que el archivo combinado se creó correctamente
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "ERROR: Failed to create combined certificate file"
    exit 1
fi

# Mostrar información del certificado
echo "=== Certificate Information ==="
echo "Domain: $DOMAIN"
echo "Combined certificate created at: $OUTPUT_FILE"
echo "CA certificate created at: $CA_FILE"
echo "Certificate expires: $(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)"

echo "=== Certificate setup completed successfully ==="
echo "MongoDB configuration:"
echo "  certificateKeyFile: $OUTPUT_FILE"
echo "  CAFile: $CA_FILE"
FROM certbot/certbot:latest

RUN apk add --no-cache bash

COPY renew.sh /renew.sh

RUN chmod +x /renew.sh

RUN mkdir -p /output-certs

ENTRYPOINT ["/renew.sh"]
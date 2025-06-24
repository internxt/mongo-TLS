FROM certbot/certbot:latest

RUN apk add --no-cache bash

COPY obtain.sh /obtain.sh

RUN chmod +x /obtain.sh

RUN mkdir -p /output-certs

ENTRYPOINT ["/obtain.sh"]

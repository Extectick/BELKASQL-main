FROM haproxy:lts-bookworm

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        keepalived \
        gettext-base \
        procps \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY docker/cloud-lb/entrypoint.sh /usr/local/bin/cloud-lb-entrypoint.sh

RUN chmod +x /usr/local/bin/cloud-lb-entrypoint.sh \
    && mkdir -p /etc/keepalived /templates

ENTRYPOINT ["/usr/local/bin/cloud-lb-entrypoint.sh"]

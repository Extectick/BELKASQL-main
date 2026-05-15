FROM haproxy:lts-bookworm

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY docker/local-haproxy/entrypoint.sh /usr/local/bin/local-haproxy-entrypoint.sh

RUN chmod +x /usr/local/bin/local-haproxy-entrypoint.sh \
    && mkdir -p /templates

ENTRYPOINT ["/usr/local/bin/local-haproxy-entrypoint.sh"]

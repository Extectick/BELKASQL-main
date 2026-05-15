FROM postgres:16-bookworm

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-psycopg2 \
        pgbackrest \
        pgbouncer \
        curl \
        jq \
        gettext-base \
        ca-certificates \
        procps \
    && pip3 install --break-system-packages --no-cache-dir "patroni[etcd3]>=4.0,<5.0" \
    && rm -rf /var/lib/apt/lists/*

COPY docker/postgres-patroni/entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
COPY docker/postgres-patroni/post-bootstrap.sh /usr/local/bin/post-bootstrap.sh

RUN chmod +x /usr/local/bin/patroni-entrypoint.sh /usr/local/bin/post-bootstrap.sh \
    && mkdir -p /etc/patroni /etc/pgbackrest /etc/pgbouncer /templates /var/lib/pgbackrest /var/log/pgbackrest \
    && chown -R postgres:postgres /etc/patroni /etc/pgbackrest /etc/pgbouncer /templates /var/lib/pgbackrest /var/log/pgbackrest

USER postgres

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]

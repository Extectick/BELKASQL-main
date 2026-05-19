# Scaling PostgreSQL DB Nodes

BELKASQL uses a fixed 3-member etcd quorum and a scalable PostgreSQL/Patroni
node set.

Keep etcd at 3 members unless you are intentionally redesigning quorum. Add
future database servers as PostgreSQL/Patroni replicas with
`db-node/docker-compose.replica.yml`.

## Add a DB node

1. Prepare the host and connect it to the private/VPN network.
2. Copy this repository to the host.
3. Create a DB env file from `db-node/.env.replica.example`.
4. Set unique values:
   - `COMPOSE_PROJECT_NAME`
   - `INTERNAL_BIND_IP`
   - `DB_CONTAINER_NAME`
   - `DB_HOSTNAME`
   - `DB_IP`
   - `NODE_NAME`
   - `NODE_API_HOST`
   - `NODE_PG_HOST`
   - exporter/container IPs
5. Point `ETCD_HOST_1`, `ETCD_HOST_2`, `ETCD_HOST_3` at the existing etcd
   members.
6. Start the node:

```bash
cd db-node
docker network inspect belkasql_belka-net >/dev/null 2>&1 \
  || docker network create --subnet 172.28.0.0/16 belkasql_belka-net
docker compose --env-file env/city-d.env -f docker-compose.replica.yml up -d --build
```

The new node should bootstrap from the current Patroni leader and appear in:

```bash
curl http://<new-node-ip>:8008/cluster
```

## Add the node to HAProxy

Edit the LB env file and append the node to `DB_NODES`:

```env
DB_NODES=city-a=10.77.0.2 city-b=10.77.0.3 city-c=10.77.0.4 city-d=10.77.0.5
```

Then recreate the LB container:

```bash
docker compose --env-file lb-node/env/cloud-lb-a.env -f lb-node/docker-compose.yml up -d --force-recreate lb
```

## Add the node to monitoring

Edit the observability env file and append the node to the target lists:

```env
POSTGRES_TARGETS=city-a=10.77.0.2:9187 city-b=10.77.0.3:9187 city-c=10.77.0.4:9187 city-d=10.77.0.5:9187
NODE_EXPORTER_TARGETS=city-a=10.77.0.2:9100 city-b=10.77.0.3:9100 city-c=10.77.0.4:9100 city-d=10.77.0.5:9100
ETCD_TARGETS=city-a=10.77.0.2:2379 city-b=10.77.0.3:2379
```

Only add the node to `ETCD_TARGETS` if it actually runs etcd.

Then recreate Prometheus:

```bash
docker compose --env-file observability-node/env/cloud-observability.env -f observability-node/docker-compose.yml up -d --force-recreate prometheus
```

## Backup behavior

pgBackRest backs up the whole PostgreSQL cluster from the active primary. New
databases created inside PostgreSQL are included automatically. A new replica
node needs S3 settings only so it can participate safely and recover if needed.

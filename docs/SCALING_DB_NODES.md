# Scaling PostgreSQL DB Nodes

BELKASQL uses a fixed 3-member etcd quorum and a scalable PostgreSQL/Patroni
node set. The intended workflow is to describe nodes in `cluster.yml`, run
`./belkasql generate`, and deploy the generated env files.

Keep etcd at 3 members unless you are intentionally redesigning quorum. Add
future database servers as PostgreSQL/Patroni replicas with
`db-node/docker-compose.replica.yml`.

## Add a DB node

1. Prepare the host and connect it to the private/VPN network.
2. Copy this repository to the host.
3. Add the node to `cluster.yml`, either manually:

```yaml
  - name: city-d
    host: 10.77.0.5
    role: db
    postgres: true
    etcd: false
    monitoring: true
    local_domain: db-city-d.internal
```

or with the helper:

```bash
./belkasql add-node city-d 10.77.0.5 --postgres --no-etcd
```

4. Generate and validate env files:

```bash
./belkasql generate cluster.yml
./belkasql diff-generated cluster.yml
./belkasql check cluster.yml
./belkasql check cluster.yml --production
```

5. Start the node on the new host:

```bash
cd db-node
docker network inspect belkasql_belka-net >/dev/null 2>&1 \
  || docker network create --subnet 172.28.0.0/16 belkasql_belka-net
docker compose --env-file env/city-d.env -f docker-compose.replica.yml up -d --build
```

Or let `belkasql apply` sync the repository and run the compose command:

```bash
./belkasql apply city-d cluster.yml --dry-run
./belkasql apply city-d cluster.yml
```

For lab configs that intentionally still contain placeholders, add
`--allow-non-production`. Do not use that flag for a real cluster.

The new node should bootstrap from the current Patroni leader and appear in:

```bash
curl http://<new-node-ip>:8008/cluster
```

## Add the node to HAProxy

`./belkasql generate` updates the LB env file automatically. The important
generated value is `DB_NODES`:

```env
DB_NODES=city-a=10.77.0.2 city-b=10.77.0.3 city-c=10.77.0.4 city-d=10.77.0.5
```

Then recreate the LB container:

```bash
docker compose --env-file lb-node/env/cloud-lb-a.env -f lb-node/docker-compose.yml up -d --force-recreate lb
```

or:

```bash
./belkasql apply lb cluster.yml
```

## Add the node to monitoring

`./belkasql generate` also updates the observability env file automatically.
The important generated values are:

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

or:

```bash
./belkasql apply observability cluster.yml
```

## Backup behavior

pgBackRest backs up the whole PostgreSQL cluster from the active primary. New
databases created inside PostgreSQL are included automatically. A new replica
node needs S3 settings only so it can participate safely and recover if needed.

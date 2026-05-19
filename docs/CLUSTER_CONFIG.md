# Central Cluster Config

`cluster.yml` is the single source of truth for node roles and addresses.
Copy `cluster.example.yml` and edit it for a concrete installation:

```bash
cp cluster.example.yml cluster.yml
./belkasql generate cluster.yml
./belkasql check cluster.yml
./belkasql check cluster.yml --production
```

The generator creates role env files:

- `db-node/env/<node>.env`
- `control-node/env/<node>.env`
- `lb-node/env/cloud-lb-a.env`
- `observability-node/env/cloud-observability.env`

It does not deploy or restart anything. Deployment is intentionally a separate
step. Use `apply` when you are ready to sync files and start containers:

```bash
./belkasql apply city-d cluster.yml --dry-run
./belkasql apply city-d cluster.yml
./belkasql apply lb cluster.yml
./belkasql apply observability cluster.yml
```

`apply` expects SSH access to the target host and Docker already installed.
It builds a clean deployment archive from repository templates plus generated
files. Local `env`, `cluster.yml`, `secrets.yml`, keys and scratch files are
not copied into the archive. A real apply is blocked unless
`./belkasql check cluster.yml --production` would pass. For a lab or example
config, use `--allow-non-production` explicitly.

## Secrets

Keep public topology in `cluster.yml`. Put private values in `secrets.yml`
next to it. `secrets.yml` is ignored by git and is merged over `cluster.yml`
when any `belkasql` command loads the config.

Example:

```yaml
postgres:
  superuser_password: replace-with-real-password
  replication_password: replace-with-real-password
  rewind_password: replace-with-real-password

backup:
  key: replace-with-s3-access-key
  secret: replace-with-s3-secret-key
```

After generation, `cluster.lock` is written with the generated file list and
a content hash. It is meant for quick drift checks and change review.

## Safe migration from existing env files

When a cluster already has hand-written `env` files, do not overwrite them
blindly. Use this sequence:

```bash
cp cluster.example.yml cluster.yml
# edit cluster.yml and secrets.yml until they describe the running cluster
./belkasql plan cluster.yml
./belkasql diff-generated cluster.yml
./belkasql check cluster.yml
./belkasql check cluster.yml --production
```

`diff-generated` compares each generated env file with the current local file
and redacts secret-looking keys by default. Use `--show-values` only on a
trusted terminal.

For an existing installation, start with an automated best-effort import:

```bash
./belkasql adopt-env --dry-run
./belkasql adopt-env
```

The command reads local ignored `env` files, writes topology to `cluster.yml`,
and writes detected secrets to `secrets.yml`. Review the result, then run
`diff-generated` and `check --production`.

For existing `etcd` clusters, preserve real member names with `etcd_name`.
Changing an existing member name in generated env without a planned etcd
membership migration can break quorum.

## Node roles

Example DB node:

```yaml
  - name: city-d
    host: 10.77.0.5
    role: db
    postgres: true
    etcd: false
    monitoring: true
```

Fields:

- `postgres: true` means run PostgreSQL/Patroni.
- `etcd: true` means this node is one of the three etcd quorum members.
- `etcd_name` pins the real etcd member/container name when it differs from
  the default `etcd-<node-name>`.
- `monitoring: true` adds the node to Prometheus target lists.
- `preferred_primary: true` documents the intended preferred primary node.
- `os: linux|windows` selects the remote shell used by `belkasql apply`.
- `repo_dir` overrides the default remote repository directory for that node.
- `ssh_user` overrides `belkasql apply --user` for that node.
- `ssh_port` overrides SSH port for that node.
- `ssh_identity_file` overrides the deploy SSH private key for that node.
- `ssh_sudo: true` makes Linux archive prepare/extract use passwordless sudo.

For non-interactive password SSH, keep passwords in ignored `secrets.yml`:

```yaml
ssh:
  identity_file: keys/belkasql_deploy_ed25519
  passwords:
    city-a: replace-with-city-a-password
    city-b: replace-with-city-b-password
    city-c: replace-with-city-c-password
```

`ssh.identity_file` is preferred over password transport for `apply` and
`preflight-remote`. Passwords can be kept only for one-time SSH key bootstrap:

```bash
./belkasql bootstrap-ssh-keys all cluster.yml --dry-run
./belkasql bootstrap-ssh-keys all cluster.yml
./belkasql preflight-remote all cluster.yml
```

The default key path is ignored by git: `keys/belkasql_deploy_ed25519`.

Example Windows DB node:

```yaml
  - name: city-a
    host: 10.77.0.2
    role: db
    os: windows
    repo_dir: D:\GitRepositories\BELKASQL-main
    ssh_user: Администратор
    ssh_port: 22
    ssh_identity_file: keys/belkasql_deploy_ed25519
    postgres: true
    etcd: true
    etcd_name: etcd-city-a
    monitoring: true
```

Current Patroni templates expect exactly three etcd endpoints. Add extra
PostgreSQL nodes with `etcd: false` unless you are redesigning the etcd quorum.

You can append a node without hand-editing YAML:

```bash
./belkasql add-node city-d 10.77.0.5 --postgres --no-etcd
./belkasql generate cluster.yml
./belkasql check cluster.yml
```

Remove a node the same way:

```bash
./belkasql remove-node city-d --config cluster.yml
./belkasql generate cluster.yml
./belkasql check cluster.yml
```

## Generated target lists

The generator writes scalable lists instead of hardcoded `CITY_A/CITY_B`
settings:

```env
DB_NODES=city-a=10.77.0.2 city-b=10.77.0.3 city-c=10.77.0.4
POSTGRES_TARGETS=city-a=10.77.0.2:9187 city-b=10.77.0.3:9187 city-c=10.77.0.4:9187
NODE_EXPORTER_TARGETS=city-a=10.77.0.2:9100 city-b=10.77.0.3:9100 city-c=10.77.0.4:9100
ETCD_TARGETS=cloud-control=10.77.0.1:2379 city-a=10.77.0.2:2379 city-b=10.77.0.3:2379
```

HAProxy and Prometheus render their runtime configs from these lists.

## Operations CLI

Useful checks before touching servers:

```bash
./belkasql plan cluster.yml
./belkasql diff-generated cluster.yml
./belkasql check cluster.yml
./belkasql check cluster.yml --production
./belkasql preflight-remote all cluster.yml
./belkasql apply city-d cluster.yml --dry-run
```

Runtime checks against the cluster:

```bash
./belkasql status cluster.yml
./belkasql doctor cluster.yml
```

Backup operations:

```bash
./belkasql backup status cluster.yml
./belkasql backup full cluster.yml
./belkasql backup diff cluster.yml
./belkasql backup incr cluster.yml
./belkasql restore-test cluster.yml
```

`backup` connects to a DB host over SSH and runs `pgBackRest` inside the
generated DB container. By default it uses the current primary. Use
`--from replica` or `--from auto` when you intentionally want a replica-local
attempt.

`restore-test` runs an isolated scratch restore into `/tmp` inside the chosen
DB container and removes the scratch directory afterwards. It validates backup
readability without touching the production PostgreSQL data directory.

# Матрица развёртывания

Эта матрица нужна как краткая шпаргалка: что именно должно жить на каждом хосте и какие каталоги/`env` относятся к роли.

Подробные пошаговые инструкции:

- классический профиль: [INSTALL.md](INSTALL.md)
- профиль DB-ingress: [INSTALL_DB_INGRESS.md](INSTALL_DB_INGRESS.md)

## Профиль 1. Классический

### Облако

Роль хоста:

- публичная точка входа для клиентов
- третий узел `etcd`
- backup storage
- центральная наблюдаемость

Что разворачивать:

- [control-node](../control-node) с `control-node/env/cloud-control.env`
- [lb-node](../lb-node) с `lb-node/env/cloud-lb-a.env`
- [storage-node](../storage-node) с `storage-node/env/minio-primary.env`
- [observability-node](../observability-node) с `observability-node/env/cloud-observability.env`

Что реально поднимется:

- `etcd-cloud`
- HAProxy и, при использовании пары LB, Keepalived
- `minio-primary`, опционально `minio-admin` и `minio-mirror`
- Prometheus, Grafana, Loki, Alertmanager

### Хост 1

Роль хоста:

- `city-a` DB-узел

Что разворачивать:

- [db-node](../db-node) с `db-node/env/city-a.env`

Что реально поднимется:

- `etcd-city-a`
- PostgreSQL + Patroni + PgBouncer
- локальный HAProxy
- exporter’ы и `promtail`

### Хост 2

Роль хоста:

- `city-b` DB-узел

Что разворачивать:

- [db-node](../db-node) с `db-node/env/city-b.env`

Что реально поднимется:

- `etcd-city-b`
- PostgreSQL + Patroni + PgBouncer
- локальный HAProxy
- exporter’ы и `promtail`

### Рекомендуемый порядок запуска

1. `control-node` в облаке
2. `storage-node` в облаке
3. `observability-node` в облаке
4. `db-node` на host 1
5. `db-node` на host 2
6. `lb-node` в облаке

Практическая оговорка:

- `health-check` для `control-node` имеет смысл после того, как оба DB-хоста уже присоединились к общему `etcd`

## Профиль 2. DB-ingress

### Хост 1

Роль хоста:

- `city-a` DB-узел
- публичный SQL ingress на `5000/5001`

Что разворачивать:

- [db-node](../db-node) с `db-node/env/city-a.env`

### Хост 2

Роль хоста:

- `city-b` DB-узел
- публичный SQL ingress на `5000/5001`

Что разворачивать:

- [db-node](../db-node) с `db-node/env/city-b.env`

### Облако

Роль хоста:

- третий узел `etcd`
- MinIO для backup’ов
- Prometheus, Grafana, Loki, Alertmanager

Что разворачивать:

- [control-node](../control-node) с `control-node/env/cloud-control.env`
- [storage-node](../storage-node) с `storage-node/env/minio-primary.env`
- [observability-node](../observability-node) с `observability-node/env/cloud-observability.env`

Чего не должно быть на cloud в этом профиле:

- `lb-node`

### Рекомендуемый порядок запуска

1. cloud `control-node`
2. cloud `storage-node`
3. host 1 `db-node`
4. host 2 `db-node`
5. `health-check` для cloud `control-node`
6. cloud `observability-node`

## Что не входит в базовую трёххостовую схему

Эти сущности лежат в репозитории, но не являются обязательной частью базового развёртывания:

- `lb-node/env/cloud-lb-b.env`
- `storage-node/env/minio-secondary.env`

Они нужны только если вы сознательно строите более широкий профиль с парой облачных ingress-узлов или отдельным вторичным MinIO.

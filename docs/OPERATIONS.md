# Эксплуатация: классический профиль

Этот документ относится к профилю, где все клиентские подключения идут через cloud ingress.

Для профиля с прямым ingress на DB-хостах используйте:

- [OPERATIONS_DB_INGRESS.md](OPERATIONS_DB_INGRESS.md)

## Основные адреса

Production-путь:

- write: `db-write.<domain>:5000`
- read: `db-read.<domain>:5001`

Локальная лаборатория:

- cloud LB A: `5000/5001`
- cloud LB B: `5100/5101`
- city A local LB: `5200/5201`
- city B local LB: `5300/5301`
- Grafana: `3000`
- Loki: `3100`
- Prometheus: `9090`
- Alertmanager: `9093`
- MinIO primary console: `9001`
- MinIO secondary console: `9002`

## Скрипты, которыми реально пользуются

- [preflight-node.sh](../preflight-node.sh)
- [deploy-node.sh](../deploy-node.sh)
- [health-check-node.sh](../health-check-node.sh)
- [deploy-local.sh](../deploy-local.sh)
- [destroy-local.sh](../destroy-local.sh)
- [backup-status.sh](../backup-status.sh)
- [test-failover.sh](../test-failover.sh)
- [disaster-recovery.sh](../disaster-recovery.sh)

## Базовые проверки по ролям

```bash
bash ./health-check-node.sh db-node db-node/env/city-a.env
bash ./health-check-node.sh control-node control-node/env/cloud-control.env
bash ./health-check-node.sh lb-node lb-node/env/cloud-lb-a.env
bash ./health-check-node.sh storage-node storage-node/env/minio-primary.env --with-admin
bash ./health-check-node.sh observability-node observability-node/env/cloud-observability.env
```

Важно:

- `health-check` хорош как быстрый базовый тест
- он не заменяет end-to-end проверку SQL, backup и DNS

## Проверка состояния кластера

```bash
docker exec city-a-db bash -lc 'patronictl -c /etc/patroni/patroni.yml list'
```

Ожидается:

- ровно один `Leader`
- второй узел `Replica` или `Sync Standby`

## Проверка SQL-пути

Write:

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-write.example.com:5000/appdb" -c "select now();"
```

Read:

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-read.example.com:5001/appdb" -c "select now();"
```

Локальный городской путь:

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-city-a.example.internal:5000/appdb" -c "select now();"
```

## Работа с backup

Быстрая проверка:

```bash
bash ./backup-status.sh
```

Что делает скрипт честно:

1. ждёт, пока кластер выйдет в состояние primary + replica
2. пытается сделать full backup с replica
3. если replica-local backup не проходит, переключается на primary
4. показывает `pgbackrest info`
5. ждёт, пока replication в MinIO secondary проявится в списке объектов

Из этого следует:

- текущий проект не гарантирует «backup всегда с replica»
- в production это нужно принимать как часть реальной схемы, а не как баг документации

Ручная проверка:

```bash
docker exec city-a-db bash -lc 'pgbackrest --stanza=belka info'
docker exec minio-admin sh -lc 'mc --insecure replicate ls primary/belka-pgbackrest'
```

## Переключение

Сценарий проверки:

```bash
bash ./test-failover.sh
```

Что делает скрипт:

1. создаёт тестовую таблицу и пишет через глобальный write-host
2. убивает текущий primary через `SIGKILL`
3. ждёт promotion второго узла
4. проверяет, что запись остаётся доступной даже без sync standby
5. возвращает старый primary
6. ждёт его rejoin как replica

Честная оговорка:

- скрипт ищет `pg_rewind` в логах, но сам допускает, что rejoin мог пройти и по другому пути

## Disaster recovery

Сценарий:

```bash
bash ./disaster-recovery.sh
```

Что он реально проверяет:

1. наличие свежего backup’а
2. чтение metadata из secondary MinIO
3. scratch restore в `/tmp/dr-restore`

Чего он не делает:

- полноценное восстановление production-ноды
- автоматическое переключение всего кластера на secondary MinIO

## Наблюдаемость

Основные URL:

- Grafana: `http://<observability-host>:3000`
- Prometheus: `http://<observability-host>:9090`
- Loki: `http://<observability-host>:3100`
- Alertmanager: `http://<observability-host>:9093`

Что полезно проверять:

- datasource’ы Grafana зелёные
- dashboard BELKASQL открывается
- Prometheus видит `postgres_exporter`, `etcd`, `haproxy`, `minio`, `node_exporter`
- Loki получает логи от `city-a-db`, `city-b-db`, `cloud-lb-a`, `minio-primary`

Текущий набор alert’ов базовый:

- `PostgresExporterDown`
- `EtcdMemberDown`
- `HAProxyMetricsDown`
- `MinIOMetricsDown`
- `HostDiskPressureHigh`

## Типовые проблемы

### Нет логов в Loki

Проверьте:

1. контейнеры `promtail`
2. доступность `LOKI_PUSH_URL`
3. доступность Docker socket внутри `promtail`

### Target’ы Prometheus красные

Проверьте:

1. опубликованные порты exporter’ов
2. firewall
3. что в `env` указаны реальные маршрутизируемые адреса
4. для MinIO, соответствует ли схема `http/https` реальному endpoint

### Через cloud-domain SQL не работает, а DB вроде жива

Проверьте:

1. контейнер `cloud-lb-a`
2. если используется второй LB, контейнер `cloud-lb-b`
3. публикацию `5000/5001`
4. DNS и VIP/Keepalived на реальных хостах

## Остановка отдельных компонентов

Остановить DB на `city-a`:

```bash
docker compose --env-file db-node/env/city-a.env -f db-node/docker-compose.yml stop db
```

Остановить локальный ingress `city-a`:

```bash
docker compose --env-file db-node/env/city-a.env -f db-node/docker-compose.yml stop local-lb
```

Остановить `cloud-lb-a`:

```bash
docker compose --env-file lb-node/env/cloud-lb-a.env -f lb-node/docker-compose.yml stop lb
```

Остановить primary MinIO:

```bash
docker compose --env-file storage-node/env/minio-primary.env -f storage-node/docker-compose.yml stop minio
```

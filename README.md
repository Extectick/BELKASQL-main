# BELKASQL

BELKASQL это стенд и набор docker-compose/`bash`-скриптов для PostgreSQL с несколькими DB-узлами, Patroni, `etcd`, резервным копированием в S3/MinIO и центральной наблюдаемостью через Prometheus, Grafana, Loki и Alertmanager.

Проект не является «готовым продуктом из коробки». Это инженерный шаблон и набор автоматизаций, которые помогают развернуть и проверить конкретную схему отказоустойчивости. Часть сценариев хорошо покрыта локальной лабораторией, часть требует ручной проверки на реальных Linux-хостах.

## Что реально есть в репозитории

- `db-node`: PostgreSQL 16, Patroni, PgBouncer, локальный HAProxy, локальный `etcd`, `postgres-exporter`, `node-exporter`, `promtail`
- `db-node/docker-compose.replica.yml`: дополнительный PostgreSQL/Patroni-узел без нового `etcd` member
- `control-node`: третий узел `etcd`, `node-exporter`, `promtail`
- `lb-node`: облачный HAProxy + Keepalived, `node-exporter`, `promtail`
- `storage-node`: MinIO, опционально `minio-admin` и `minio-mirror`, `node-exporter`, `promtail`
- `observability-node`: Prometheus, Grafana, Loki, Alertmanager
- `scripts`: deploy/preflight/health-check, локальные проверки failover/backup/DR, bootstrap для DB-ingress профиля
- `docs`: runbook’и по установке и эксплуатации

## Поддерживаемые профили

В репозитории фактически описаны два профиля на трёх хостах.

### 1. Классический профиль

- клиенты ходят только на облачный ingress
- в облаке работают `control-node`, `lb-node`, `storage-node`, `observability-node`
- на двух городских хостах работают только `db-node`

Подробнее:

- [docs/INSTALL.md](docs/INSTALL.md)
- [docs/OPERATIONS.md](docs/OPERATIONS.md)

### 2. Профиль DB-ingress

- оба DB-хоста сами принимают клиентский трафик на `5000/5001`
- облако не находится на SQL-пути клиентов
- облако остаётся свидетелем `etcd`, хранилищем бэкапов и узлом наблюдаемости

Этот профиль сейчас описан и автоматизирован заметно лучше остальных: для него есть мастер генерации `env` и более честно описанный операционный контур.

Подробнее:

- [docs/INSTALL_DB_INGRESS.md](docs/INSTALL_DB_INGRESS.md)
- [docs/OPERATIONS_DB_INGRESS.md](docs/OPERATIONS_DB_INGRESS.md)
- [docs/SCALING_DB_NODES.md](docs/SCALING_DB_NODES.md)

## Быстрый старт для локальной лаборатории

Локальная лаборатория нужна для разработки и проверки базовой логики, но не доказывает поведение VIP, DNS-failover, firewall и WAN-сети на реальных хостах.

Развёртывание:

```bash
bash ./deploy-local.sh
```

Проверки:

```bash
bash ./preflight-node.sh observability-node observability-node/env/cloud-observability.env
bash ./backup-status.sh
bash ./test-failover.sh
bash ./disaster-recovery.sh
```

Что эти проверки реально подтверждают в текущей лаборатории:

- Patroni умеет перевести лидерство между `city-a` и `city-b`
- вернувшийся старый primary обычно возвращается через `pg_rewind` или совместимое восстановление
- `pgBackRest` может сделать backup, но при неудаче standby-local сценария скрипты откатываются к backup с primary
- Prometheus видит основные цели
- Loki принимает контейнерные логи

Что эти проверки не подтверждают:

- корректность публичного DNS
- реальную работу Keepalived/VIP между разными машинами
- сетевую устойчивость на WAN
- корректность firewall/NAT

## Основные точки входа

Локально:

- `localhost:5000` — write
- `localhost:5001` — read
- `localhost:5200` / `5201` — локальный ingress `city-a`
- `localhost:5300` / `5301` — локальный ingress `city-b`
- `localhost:3000` — Grafana
- `localhost:3100` — Loki
- `localhost:9090` — Prometheus
- `localhost:9093` — Alertmanager

В production адреса зависят от выбранного профиля:

- классический профиль: клиенты используют облачные домены
- DB-ingress профиль: клиенты используют домены, которые резолвятся в оба DB-хоста

## Основные скрипты

- `preflight-node.sh`: проверяет наличие Docker, обязательные переменные `env`, валидность `docker compose config`
- `deploy-node.sh`: запускает `preflight`, затем `docker compose up -d --build`
- `health-check-node.sh`: проверяет локальные readiness/health endpoints и несколько опубликованных портов
- `deploy-local.sh`: поднимает локальную лабораторию
- `destroy-local.sh`: останавливает локальную лабораторию
- `backup-status.sh`: создаёт полный backup и проверяет состояние bucket replication
- `test-failover.sh`: проверяет отказ текущего primary и возврат узла
- `disaster-recovery.sh`: проверяет чтение метаданных и scratch restore из вторичного MinIO
- `bootstrap-db-ingress.sh`: интерактивно генерирует `env` для профиля DB-ingress
- `cleanup-db-ingress.sh`: чистит сгенерированные backup-файлы и вспомогательные артефакты bootstrap’а

## Честные ограничения проекта

- Это не Kubernetes и не оператор. Всё завязано на `docker compose`, шаблоны конфигов и shell-скрипты.
- Реальная отказоустойчивость держится на том, что между тремя хостами есть стабильная приватная сеть.
- В профиле с тремя хостами система выдерживает один отказ из здорового состояния, но не произвольные последовательности наложившихся отказов.
- Потеря `cloud` в DB-ingress профиле не обязана ломать SQL-доступ, но в этот момент деградируют backup/observability и сужается окно безопасного failover.
- Локальная лаборатория использует один Docker-host и поэтому местами отличается от production. Самый заметный пример: backup-скрипты честно умеют делать fallback с replica на primary.
- `health-check-node.sh` не доказывает, что весь профиль «готов к production»; он лишь проверяет локальные признаки живости.

## Политика `env`

- реальные `.env` игнорируются Git’ом
- для реальных файлов должны существовать `*.env.example`
- общие шаблоны лежат рядом с ролью, например [db-node/.env.example](db-node/.env.example)

## Локальная гигиена

Не храните в рабочем дереве как tracked-файлы:

- `keys/` с приватными ключами, WireGuard-конфигами и инвентарём машин
- `steps/` со временными заметками и черновыми runbook’ами
- архивы `*.tgz`, `*.rar`, `*.zip` и похожие локальные bundle-файлы

Если артефакт нужно сохранить, лучше вынести его за пределы репозитория или превратить в обезличенный документ без секретов.

## Документация

- [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md)
- [docs/DEPLOYMENT_MATRIX.md](docs/DEPLOYMENT_MATRIX.md)
- [docs/INSTALL.md](docs/INSTALL.md)
- [docs/OPERATIONS.md](docs/OPERATIONS.md)
- [docs/INSTALL_DB_INGRESS.md](docs/INSTALL_DB_INGRESS.md)
- [docs/OPERATIONS_DB_INGRESS.md](docs/OPERATIONS_DB_INGRESS.md)

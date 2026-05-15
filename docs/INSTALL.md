# Установка: классический 3-хостовый профиль

Этот runbook описывает профиль, в котором клиенты подключаются только к облачному ingress, а DB-хосты не торчат напрямую в клиентскую сеть.

Если вам нужен профиль, где клиенты ходят сразу на оба DB-хоста, используйте:

- [INSTALL_DB_INGRESS.md](INSTALL_DB_INGRESS.md)

## 1. Какая схема здесь подразумевается

Ровно три Linux-хоста:

- `cloud`: ingress, witness `etcd`, backup storage, observability
- `host-1`: DB-узел `city-a`
- `host-2`: DB-узел `city-b`

В этом профиле:

- приложение использует только облачные домены
- `host-1` и `host-2` не должны быть публичными SQL ingress-узлами
- между всеми тремя машинами обязана быть стабильная приватная связность

## 2. Что нужно развернуть на каждом хосте

### Облако

- `control-node`
- `lb-node`
- `storage-node`
- `observability-node`

### Хост 1

- `db-node` с `db-node/env/city-a.env`

### Хост 2

- `db-node` с `db-node/env/city-b.env`

## 3. Что обязательно должно быть правдой до deploy

- все три машины это Linux-хосты
- на всех хостах есть Docker Engine и Docker Compose v2
- часы синхронизированы через `chrony` или аналог
- приватные IP или внутренние DNS-имена стабильны
- cloud видит оба DB-хоста по приватной сети
- DB-хосты видят друг друга и cloud по приватной сети
- публичные домены `db-write` и `db-read` смотрят только на cloud

Без этого скрипты могут успешно пройти `preflight`, но профиль всё равно не заработает.

## 4. Что устанавливать на хосты

Минимум:

- Docker Engine
- Docker Compose v2
- `bash`
- `curl`
- `openssl`

Рекомендуется:

- `jq`
- `iproute2`
- `netcat`
- `psql`

## 5. Как копировать репозиторий

Копируйте на каждый хост весь репозиторий целиком, а не отдельные каталоги.

Причина:

- корневые скрипты ожидают текущую структуру проекта
- `promtail` использует общий конфиг из `observability-node`
- проверки и deploy-обёртки завязаны на относительные пути

Пример каталога:

```bash
/opt/belkasql
```

## 6. Сетевые требования

### Публично наружу только с cloud

- `5000` для пути записи
- `5001` для пути чтения

Опционально и только под админской защитой:

- `3000` Grafana
- `9001` MinIO Console

### Приватно между хостами

- `2379` и `2380` для `etcd`
- `6432` для PgBouncer
- `8008` для Patroni REST API
- `9000` для MinIO API
- `9090`, `9093`, `3100`, `9100`, `9187`, `8404` для observability и exporter’ов

Честная оговорка:

- наличие открытых портов само по себе недостаточно; важны также routing, MTU, DNS и firewall state

## 7. Что реально делают helper-скрипты

### `preflight-node.sh`

Проверяет:

- доступность Docker daemon
- наличие обязательных переменных в `env`
- что `docker compose config -q` проходит успешно

Не проверяет:

- реальную межхостовую связность
- DNS
- firewall
- готовность Keepalived/VIP
- NTP

### `deploy-node.sh`

- запускает `preflight`
- затем делает `docker compose up -d --build`

### `health-check-node.sh`

Проверяет локальные признаки живости:

- Patroni API и published-порты на DB-роли
- `etcdctl endpoint health` на control-role
- конфиг HAProxy и Keepalived на LB-role
- readiness MinIO
- readiness Prometheus/Loki/Grafana/Alertmanager

Но это не полноценная приёмка production-системы.

## 8. Подготовка `env` на cloud

Нужны файлы:

- `control-node/env/cloud-control.env`
- `lb-node/env/cloud-lb-a.env`
- `storage-node/env/minio-primary.env`
- `observability-node/env/cloud-observability.env`

В базовом 3-хостовом профиле не нужны:

- `lb-node/env/cloud-lb-b.env`
- `storage-node/env/minio-secondary.env`

Ключевые значения:

- в `cloud-control.env` нужно корректно заполнить `ETCD_ADVERTISE_HOST`, `ETCD_INITIAL_CLUSTER`, `ETCD_CLUSTER_TOKEN`
- в `cloud-lb-a.env` нужно указать IP обоих DB-хостов и клиентские домены
- в `minio-primary.env` нужно задать сильные MinIO-учётки и bucket
- в `cloud-observability.env` нужно задать реальные адреса DB-хостов и cloud-сервисов

## 9. Подготовка `env` на DB-хостах

На `host-1`:

- `db-node/env/city-a.env`

На `host-2`:

- `db-node/env/city-b.env`

На обоих DB-хостах важно:

- использовать одинаковые `PATRONI_SCOPE`, `ETCD_INITIAL_CLUSTER`, `ETCD_CLUSTER_TOKEN`
- указать корректный приватный адрес peer-узла
- указать MinIO endpoint cloud-хоста как backup endpoint
- заменить все пароли на production-значения

## 10. Порядок развёртывания

На cloud:

```bash
cd /opt/belkasql

bash ./preflight-node.sh control-node control-node/env/cloud-control.env
bash ./deploy-node.sh control-node control-node/env/cloud-control.env

bash ./preflight-node.sh storage-node storage-node/env/minio-primary.env --with-admin
bash ./deploy-node.sh storage-node storage-node/env/minio-primary.env --with-admin
bash ./health-check-node.sh storage-node storage-node/env/minio-primary.env --with-admin

bash ./preflight-node.sh observability-node observability-node/env/cloud-observability.env
bash ./deploy-node.sh observability-node observability-node/env/cloud-observability.env
bash ./health-check-node.sh observability-node observability-node/env/cloud-observability.env
```

На `host-1`:

```bash
cd /opt/belkasql

bash ./preflight-node.sh db-node db-node/env/city-a.env
bash ./deploy-node.sh db-node db-node/env/city-a.env
bash ./health-check-node.sh db-node db-node/env/city-a.env
```

На `host-2`:

```bash
cd /opt/belkasql

bash ./preflight-node.sh db-node db-node/env/city-b.env
bash ./deploy-node.sh db-node db-node/env/city-b.env
bash ./health-check-node.sh db-node db-node/env/city-b.env
```

После DB-хостов на cloud:

```bash
bash ./health-check-node.sh control-node control-node/env/cloud-control.env
bash ./preflight-node.sh lb-node lb-node/env/cloud-lb-a.env
bash ./deploy-node.sh lb-node lb-node/env/cloud-lb-a.env
bash ./health-check-node.sh lb-node lb-node/env/cloud-lb-a.env
```

Почему так:

- сначала нужен witness `etcd`
- затем backup storage
- затем сами DB-узлы
- и только потом имеет смысл открывать публичный ingress

## 11. Как подключается приложение

Приложение должно ходить только на cloud-домены:

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-write.example.com:5000/appdb" -c "select now();"
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-read.example.com:5001/appdb" -c "select now();"
```

Приложение не должно использовать:

- прямые IP DB-хостов
- Patroni API
- MinIO endpoint

## 12. Что проверить после развёртывания

### Состояние Patroni

```bash
docker exec city-a-db bash -lc 'patronictl -c /etc/patroni/patroni.yml list'
```

Ожидается:

- ровно один `Leader`
- второй узел `Replica` или `Sync Standby`

### Состояние backup’ов

```bash
docker exec city-a-db bash -lc 'pgbackrest --stanza=belka info'
```

### Проверка ingress

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-write.example.com:5000/appdb" -c "select now();"
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-read.example.com:5001/appdb" -c "select now();"
```

### Проверка observability

- Grafana открывается
- Prometheus targets зелёные
- Loki получает логи с cloud и обоих DB-хостов
- Alertmanager доступен

## 13. Что считать нормальным при аварии

Если падает один DB-хост:

- сервис должен выжить
- новые подключения должны восстановиться через cloud ingress
- часть активных сессий может оборваться
- приложение обязано уметь переподключаться

Если падает cloud ingress:

- DB-кластер может быть жив, но клиенты классического профиля всё равно потеряют основную точку входа

## 14. Что этот профиль не гарантирует

- защиту от произвольной серии нескольких отказов подряд
- отсутствие потерь последних транзакций в коротком окне failover
- доказанную работоспособность вашего DNS/VIP только на основании локальных тестов

Если нужна более честная модель «SQL остаётся жить даже при потере cloud», смотрите DB-ingress профиль.

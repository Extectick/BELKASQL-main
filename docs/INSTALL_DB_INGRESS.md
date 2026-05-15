# Установка: профиль DB-ingress на 3 хоста

Это основной и наиболее проработанный production-профиль в текущем репозитории.

Идея профиля:

- `host-1` и `host-2` сами принимают клиентский SQL-трафик на `5000/5001`
- `cloud` не стоит на SQL-пути клиентов
- `cloud` остаётся третьим членом `etcd`, хранилищем backup’ов и узлом наблюдаемости

## 1. Когда выбирать этот профиль

Используйте его, если хотите:

- не зависеть от отдельного cloud ingress для самих SQL-подключений
- сохранить SQL-доступ при потере cloud, пока оба DB-хоста или хотя бы один DB-хост и quorum позволяют системе жить
- иметь более простой клиентский путь: домены сразу указывают на DB-хосты

Не выбирайте его, если:

- вам нужен единый публичный ingress в облаке
- вы не готовы открывать `5000/5001` на обоих DB-хостах

## 2. Что здесь реально поднимается

### Хост 1

- `db-node` с `db-node/env/city-a.env`

Содержит:

- `etcd-city-a`
- PostgreSQL + Patroni + PgBouncer
- `local-lb` как публичный SQL ingress
- `postgres-exporter`, `node-exporter`, `promtail`

### Хост 2

- `db-node` с `db-node/env/city-b.env`

Состав симметричный `host-1`.

### Облако

- `control-node`
- `storage-node` с `minio-primary`
- `observability-node`

Не поднимается:

- `lb-node`

## 3. Что нужно до начала

Это обязательные условия:

- три Linux-хоста
- Docker Engine и Docker Compose v2 на всех трёх
- стабильная приватная связность между всеми тремя
- отдельные публичные IP у `host-1` и `host-2`
- синхронизация времени
- приватные порты `2379/2380/6432/8008/9000/...` закрыты от публичного интернета

Клиентская модель:

- `db-write.example.com` резолвится в оба публичных IP DB-хостов
- `db-read.example.com` резолвится в оба публичных IP DB-хостов

Честная оговорка:

- репозиторий не содержит DNS automation; это операторская задача вне проекта

## 4. Bootstrap env-файлов

Для этого профиля в проекте есть мастер:

```bash
bash ./bootstrap-db-ingress.sh
```

Он спрашивает:

- приватные IP / внутренние DNS имена
- публичные IP DB-хостов
- клиентские домены
- основные пароли и токены

И генерирует:

- `control-node/env/cloud-control.env`
- `db-node/env/city-a.env`
- `db-node/env/city-b.env`
- `storage-node/env/minio-primary.env`
- `observability-node/env/cloud-observability.env`

Дополнительно он умеет:

- сразу запустить `preflight`
- сразу выполнить `deploy`
- опционально сразу выполнить `health-check` на выбранной роли

Что bootstrap не делает:

- не меняет DNS у провайдера
- не настраивает firewall/VPN
- не доказывает, что публичный failover уже работает

## 5. Важная тонкость по `etcd` в этом профиле

Сгенерированные `env` намеренно используют локальный compose-алиас для локального члена `etcd`:

- на `city-a`: `ETCD_HOST_1=etcd-city-a`
- на `city-b`: `ETCD_HOST_2=etcd-city-b`

Это не косметика, а важная практическая деталь.

Если заменить локальный `etcd` на собственный внешний/VPN IP хоста, можно получить ситуацию:

- `cluster_unlocked: true`
- автоматическая promotion не происходит

Поэтому сгенерированный `env` в этой части лучше не «улучшать».

## 6. Что должно быть открыто по сети

### Публично на обоих DB-хостах

- `5000` write
- `5001` read

### Только приватно между хостами

- `2379` и `2380` для `etcd`
- `6432` для PgBouncer
- `8008` для Patroni API
- `9000` для MinIO
- порты observability/exporter’ов

Отдельно:

- `3000` Grafana и `9001` MinIO Console открывайте только если у вас есть внешняя защита

## 7. Порядок развёртывания

На cloud:

```bash
cd /opt/belkasql

bash ./preflight-node.sh control-node control-node/env/cloud-control.env
bash ./deploy-node.sh control-node control-node/env/cloud-control.env

bash ./preflight-node.sh storage-node storage-node/env/minio-primary.env
bash ./deploy-node.sh storage-node storage-node/env/minio-primary.env
bash ./health-check-node.sh storage-node storage-node/env/minio-primary.env
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

После того как оба DB-хоста живы:

```bash
bash ./health-check-node.sh control-node control-node/env/cloud-control.env
bash ./preflight-node.sh observability-node observability-node/env/cloud-observability.env
bash ./deploy-node.sh observability-node observability-node/env/cloud-observability.env
bash ./health-check-node.sh observability-node observability-node/env/cloud-observability.env
```

Почему именно так:

- witness `etcd` должен появиться до DB-узлов
- backup storage нужен до начала нормальной архивации WAL
- health-check control-node реально полезен только после появления quorum

## 8. Как подключается приложение

Приложение должно использовать только клиентские домены:

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-write.example.com:5000/appdb" -c "select now();"
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-read.example.com:5001/appdb" -c "select now();"
```

Приложение не должно использовать:

- cloud IP
- прямой Patroni API
- MinIO endpoint

## 9. Что проверить после установки

### Patroni

```bash
docker exec city-a-db bash -lc 'patronictl -c /etc/patroni/patroni.yml list'
```

Ожидается:

- один `Leader`
- один `Replica` или `Sync Standby`

### Приватная связность между DB-хостами

С `host-1`:

```bash
nc -zv <host-2-private-ip> 6432
nc -zv <host-2-private-ip> 8008
```

С `host-2` аналогично в обратную сторону.

### Резервные копии

```bash
docker exec city-a-db bash -lc 'pgbackrest --stanza=belka info'
```

### Публичный SQL ingress

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-write.example.com:5000/appdb" -c "select now();"
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-read.example.com:5001/appdb" -c "select now();"
```

### Наблюдаемость

- Grafana доступна
- Prometheus видит оба DB-хоста, cloud-control и MinIO
- Loki получает логи с cloud и обоих DB-хостов

## 10. Что происходит при отказах

### Если падает один DB-хост

Ожидаемое поведение:

- оставшийся DB-хост становится или остаётся рабочим primary
- новые SQL-подключения могут продолжаться через те же домены
- часть in-flight соединений может оборваться

### Если падает `cloud`, а оба DB-хоста живы

Ожидаемое поведение:

- SQL-доступ может остаться жив, потому что клиентский путь идёт не через cloud
- backup и централизованная observability деградируют
- если до возврата cloud потерять ещё один критичный узел, quorum/failover уже не гарантированы

### Что профиль не обещает

- переживание произвольной последовательности наложившихся отказов
- бесконечную «карусель» stop/start без возврата в здоровое состояние
- сохранение backup и observability во время любого cloud-outage

Иными словами:

- это профиль, уверенно рассчитанный на один отказ за раз
- это не «выживает вообще всё»

## 11. Финальный чек-лист

Не называйте установку готовой, пока не выполнено всё:

1. `db-write` и `db-read` резолвятся в оба публичных IP DB-хостов
2. публично открыты только `5000/5001`
3. `6432` и `8008` доступны только по приватной сети
4. оба DB-узла видят один и тот же 3-node `etcd`
5. backup’ы пишутся в MinIO на cloud
6. Grafana, Prometheus, Loki и Alertmanager здоровы
7. при выключении `host-1` можно переподключиться через домены
8. при выключении `host-2` можно переподключиться через домены
9. при выключении `cloud` SQL по доменам продолжает работать, пока оба DB-хоста живы

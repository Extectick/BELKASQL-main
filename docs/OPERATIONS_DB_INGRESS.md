# Эксплуатация: профиль DB-ingress

Этот документ описывает повседневную эксплуатацию профиля, где оба DB-хоста принимают клиентский SQL-трафик напрямую, а cloud используется как witness `etcd`, хранилище backup’ов и узел наблюдаемости.

Основной runbook установки:

- [INSTALL_DB_INGRESS.md](INSTALL_DB_INGRESS.md)

## Основные адреса

Клиентские:

- write: `db-write.<domain>:5000`
- read: `db-read.<domain>:5001`

Служебные приватные:

- Patroni API на DB-хостах: `<db-private-ip>:8008`
- PgBouncer на DB-хостах: `<db-private-ip>:6432`

Сервисы cloud:

- Grafana: `http://<cloud-host>:3000`
- Prometheus: `http://<cloud-host>:9090`
- Loki: `http://<cloud-host>:3100`
- Alertmanager: `http://<cloud-host>:9093`
- MinIO console: `http://<cloud-host>:9001`

## Что важно помнить про этот профиль

### Клиенты не ходят через cloud

Это главное отличие от классического профиля.

Следствие:

- потеря cloud не обязана немедленно ломать SQL-доступ
- но потеря cloud ухудшает условия для quorum, backup и observability

### `local-lb` на каждом DB-хосте это часть SQL-пути

Клиентский SQL идёт не напрямую в PostgreSQL, а через локальный HAProxy:

- listener `5000` для записи
- listener `5001` для чтения

Если локальный узел replica, путь записи может быть проброшен на удалённый primary.

Поэтому для здоровья профиля важна не только роль Patroni, но и доступность межузловых приватных портов.

## Базовые проверки

### Smoke checks по ролям

```bash
bash ./health-check-node.sh db-node db-node/env/city-a.env
bash ./health-check-node.sh db-node db-node/env/city-b.env
bash ./health-check-node.sh control-node control-node/env/cloud-control.env
bash ./health-check-node.sh storage-node storage-node/env/minio-primary.env
bash ./health-check-node.sh observability-node observability-node/env/cloud-observability.env
```

### Проверка Patroni

```bash
docker exec city-a-db bash -lc 'patronictl -c /etc/patroni/patroni.yml list'
docker exec city-b-db bash -lc 'patronictl -c /etc/patroni/patroni.yml list'
```

Ожидается:

- один `Leader`
- один `Replica` или `Sync Standby`

### Проверка SQL-пути

```bash
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-write.example.com:5000/appdb" -c "select now();"
psql "postgresql://appuser:<APP_USER_PASSWORD>@db-read.example.com:5001/appdb" -c "select now();"
```

## Резервные копии

Ручная проверка:

```bash
docker exec city-a-db bash -lc 'pgbackrest --stanza=belka info'
```

Честная практическая деталь:

- проект пытается делать backup с replica
- если в текущей схеме standby-local backup не проходит, скрипты переключаются на primary

Пример:

```bash
bash ./backup-status.sh
```

Этот скрипт:

1. ждёт здоровое состояние кластера
2. пытается full backup с replica
3. при неудаче делает fallback на primary
4. показывает содержимое primary и secondary bucket
5. показывает replication rules

Следствие для оператора:

- если хотите «backup только с replica без fallback», текущий проект придётся дорабатывать архитектурно, а не только документарно

## Переключение

Практическая проверка:

```bash
bash ./test-failover.sh
```

Что она проверяет:

1. запись через глобальный write-host до аварии
2. падение текущего primary
3. promotion второго узла
4. сохранение write-доступности без sync standby
5. возврат старого primary и rejoin

Это хороший операторский базовый тест, но он не заменяет реальный план отказов и обслуживания.

## Окно доступности и границы гарантии

### Что профиль обычно выдерживает

- потерю `city-a` при живых `city-b` и `cloud`
- потерю `city-b` при живых `city-a` и `cloud`
- потерю `cloud`, пока оба DB-хоста остаются живы
- возврат ранее упавшего DB-хоста после стабилизации кластера

### Что профиль не гарантирует

- потерю `cloud`, а затем потерю текущего primary до возврата `cloud`
- любой сценарий, в котором исчезает quorum `etcd`
- серию действий без паузы на полное восстановление состояния
- два наложившихся критичных отказа

Практический вывод:

- между остановками узлов нужно дождаться здорового состояния
- не стоит эмулировать второй отказ, пока после первого ещё не восстановились `Leader + Replica`

## Нюанс с `etcd` endpoint’ами

Для DB-ingress профиля важно, чтобы каждый DB-узел обращался к своему локальному `etcd` через compose-имя:

- `etcd-city-a`
- `etcd-city-b`

Если заменить это на собственный VPN/private IP узла, можно получить зависший failover.

Это одна из тех деталей, где сгенерированный `env` лучше не «причесывать» вручную без понимания причины.

## Наблюдаемость

Что полезно проверить:

- в Grafana живы datasource’ы Prometheus и Loki
- в Prometheus зелёные цели по DB, cloud-control и MinIO
- в Loki есть логи `city-a-db`, `city-b-db` и cloud-сервисов

Важно понимать:

- observability здесь централизована и завязана на cloud
- при потере cloud SQL может остаться жив, а мониторинг и централизованные логи деградируют

## Типовые проблемы

### Публичный SQL не работает, но один DB-хост жив

Проверьте:

1. DNS по-прежнему резолвит в оба публичных IP
2. на выжившем хосте слушаются `5000/5001`
3. роль Patroni на выжившем хосте
4. доступность приватных `6432/8008` между DB-хостами

### Упавший DB-хост не возвращается

Проверьте:

1. логи Patroni
2. хватает ли WAL для `pg_rewind`
3. виден ли `etcd-cloud`
4. есть ли доступ к MinIO и peer DB-хосту

### Облако недоступно

Ожидайте:

1. SQL может продолжать жить
2. backup и observability деградируют
3. второй критичный отказ до возврата cloud становится особенно опасным

## Остановка отдельных компонентов

Остановить DB на `city-a`:

```bash
docker compose --env-file db-node/env/city-a.env -f db-node/docker-compose.yml stop db
```

Остановить ingress `city-a`:

```bash
docker compose --env-file db-node/env/city-a.env -f db-node/docker-compose.yml stop local-lb
```

Остановить cloud MinIO:

```bash
docker compose --env-file storage-node/env/minio-primary.env -f storage-node/docker-compose.yml stop minio
```

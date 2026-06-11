postgres-backup
======

[![License](https://img.shields.io/github/license/qwerty-iot/coap)](https://opensource.org/licenses/MPL-2.0)

https://github.com/qwerty-iot/postgres-backup

Overview
--------
This is a simple container that performs PostgreSQL globals and per-database backups, then uploads the files to an Azure blob store.  It is intended for Kubernetes CronJob tasks that back up small PostgreSQL or TimescaleDB clusters.

Each backup run uploads:

- one globals backup with roles and other cluster-wide objects
- one custom-format dump for each database listed in `POSTGRES_DATABASES`

This makes it possible to restore one database without restoring the whole cluster.  A full restore is globals first, then all listed databases.

Backup Layout
-------------
Backups are uploaded under `BACKUP_PREFIX`:

```text
<BACKUP_PREFIX>/globals/YYYYMMDD-HHMM.sql.gz
<BACKUP_PREFIX>/databases/<database>/YYYYMMDD-HHMM.dump
```

Configuration
-------------
Azure configuration:

```text
AZURE_CONTAINER=<container name>
AZURE_CONNSTRING=<storage account connection string>
BACKUP_PREFIX=<blob prefix>
```

PostgreSQL configuration uses libpq environment variables:

```text
PGHOST=postgres
PGPORT=5432
PGUSER=root
PGPASSWORD=rootroot
PGDATABASE=postgres
POSTGRES_DATABASES="appdb thingsboard"
```

`POSTGRES_DATABASES` may be comma or whitespace separated.

Backup
------
Backup is the default task:

```sh
docker run --rm \
  -e AZURE_CONTAINER=backups \
  -e AZURE_CONNSTRING="$AZURE_CONNSTRING" \
  -e BACKUP_PREFIX=postgres/prod \
  -e PGHOST=postgres \
  -e PGUSER=root \
  -e PGPASSWORD=rootroot \
  -e POSTGRES_DATABASES="appdb thingsboard" \
  ghcr.io/qwerty-iot/postgres-backup:latest
```

Restore One Database
--------------------
If `RESTORE_NAME` is omitted, the latest backup for that database prefix is used.

```sh
docker run --rm \
  -e TASK=restore \
  -e RESTORE_SCOPE=database \
  -e RESTORE_DATABASE=appdb \
  -e AZURE_CONTAINER=backups \
  -e AZURE_CONNSTRING="$AZURE_CONNSTRING" \
  -e BACKUP_PREFIX=postgres/prod \
  -e PGHOST=postgres \
  -e PGUSER=root \
  -e PGPASSWORD=rootroot \
  ghcr.io/qwerty-iot/postgres-backup:latest
```

Restore Globals
---------------
If `RESTORE_GLOBALS_NAME` and `RESTORE_NAME` are omitted, the latest globals backup is used.

```sh
docker run --rm \
  -e TASK=restore \
  -e RESTORE_SCOPE=globals \
  -e AZURE_CONTAINER=backups \
  -e AZURE_CONNSTRING="$AZURE_CONNSTRING" \
  -e BACKUP_PREFIX=postgres/prod \
  -e PGHOST=postgres \
  -e PGUSER=root \
  -e PGPASSWORD=rootroot \
  ghcr.io/qwerty-iot/postgres-backup:latest
```

Restore Everything
------------------
Full restore applies globals first, then restores the latest backup for each database listed in `POSTGRES_DATABASES`.

```sh
docker run --rm \
  -e TASK=restore \
  -e RESTORE_SCOPE=all \
  -e AZURE_CONTAINER=backups \
  -e AZURE_CONNSTRING="$AZURE_CONNSTRING" \
  -e BACKUP_PREFIX=postgres/prod \
  -e PGHOST=postgres \
  -e PGUSER=root \
  -e PGPASSWORD=rootroot \
  -e POSTGRES_DATABASES="appdb thingsboard" \
  ghcr.io/qwerty-iot/postgres-backup:latest
```

Kubernetes CronJob
------------------
Example container environment for a CronJob:

```yaml
env:
  - name: AZURE_CONTAINER
    value: backups
  - name: BACKUP_PREFIX
    value: postgres/prod
  - name: PGHOST
    value: postgres
  - name: PGPORT
    value: "5432"
  - name: PGUSER
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: POSTGRES_USER
  - name: PGPASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: POSTGRES_PASSWORD
  - name: POSTGRES_DATABASES
    value: appdb thingsboard
  - name: AZURE_CONNSTRING
    valueFrom:
      secretKeyRef:
        name: azure-backup-secret
        key: AZURE_CONNSTRING
```

Updating Container
------------------
To update the container image:

```sh
docker build -t ghcr.io/qwerty-iot/postgres-backup:<version> .
docker push ghcr.io/qwerty-iot/postgres-backup:<version>
```

License
-------

Mozilla Public License Version 2.0

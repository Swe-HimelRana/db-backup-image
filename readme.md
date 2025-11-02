# Database Backup Tool — Instructions

This Docker image provides an **all-in-one backup utility** for multiple database engines:

* **MySQL / MariaDB**
* **PostgreSQL**
* **MongoDB**
* **Redis**

It uses built-in clients (`mysqldump`, `pg_dump`, `mongodump`, `redis-cli`)
and supports remote uploads via **rclone** or **s3cmd**.

---

## 🧱 Overview

This image is designed for automated backups — for example:

* Kubernetes CronJobs
* Docker scheduled jobs
* Manual ad-hoc dumps

You only need to provide **root/superuser credentials**, and it will:

1. Dump **all databases** from the selected DB type
2. Create a compressed `.tar.gz` archive
3. Optionally upload it to your remote storage (S3, GCS, Dropbox, etc.)

---

## ⚙️ Environment Variables

| Variable        | Required | Description                                                     |         |
| --------------- | -------- | --------------------------------------------------------------- | ------- |
| `DB_TYPE`       | ✅        | Database type — one of: `mysql`, `postgres`, `mongodb`, `redis` |         |
| `DB_HOST`       | ✅        | Database hostname or IP                                         |         |
| `DB_PORT`       | ❌        | Port (defaults per DB: 3306, 5432, 27017, 6379)                 |         |
| `DB_USER`       | ✅        | Root or superuser name                                          |         |
| `DB_PASSWORD`   | ✅        | Password for the above user                                     |         |
| `MONGO_URI`     | ❌        | Full MongoDB connection URI (overrides host/user/pass)          |         |
| `BACKUP_DIR`    | ❌        | Local backup directory (default: `/backup/output`)              |         |
| `BACKUP_PREFIX` | ❌        | Archive name prefix (default: `backup`)                         |         |
| `COMPRESS`      | ❌        | Compression type: `gzip` or `none`                              |         |
| `KEEP_LOCAL`    | ❌        | If `false`, deletes local copy after upload                     |         |
| `RCLONE_REMOTE` | ❌        | Destination remote for rclone (e.g., `s3:mybucket/backups`)     |         |
| `RCLONE_FLAGS`  | ❌        | Extra flags for rclone (default optimized for S3)               |         |
| `S3_URL`        | ❌        | Destination URL for s3cmd (e.g., `s3://mybucket/backups/`)      |         |
| `S3CMD_OPTS`    | ❌        | Extra flags for s3cmd upload                                    |         |
| `DBS_EXCLUDE`   | ❌        | Regex to skip certain DBs (e.g. `^(test                         | dev_)`) |

---

## 🚀 Basic Usage (Docker CLI)

### MySQL example

```bash
docker run --rm \
  -e DB_TYPE=mysql \
  -e DB_HOST=mysql.local \
  -e DB_USER=root \
  -e DB_PASSWORD=secret \
  -e RCLONE_REMOTE="s3:my-bucket/mysql" \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

### PostgreSQL example

```bash
docker run --rm \
  -e DB_TYPE=postgres \
  -e DB_HOST=postgres.local \
  -e DB_USER=postgres \
  -e DB_PASSWORD=secret \
  -e RCLONE_REMOTE="s3:my-bucket/pg" \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

### MongoDB example

```bash
docker run --rm \
  -e DB_TYPE=mongodb \
  -e MONGO_URI="mongodb://root:secret@mongo.local:27017" \
  -e RCLONE_REMOTE="s3:my-bucket/mongo" \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

### Redis example

```bash
docker run --rm \
  -e DB_TYPE=redis \
  -e DB_HOST=redis.local \
  -e DB_PASSWORD=secret \
  -e RCLONE_REMOTE="s3:my-bucket/redis" \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

---

## ☁️ Using in Kubernetes CronJob

You can schedule automatic backups using a Kubernetes `CronJob`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup-mysql
spec:
  schedule: "0 3 * * *"  # Every day at 03:00 UTC
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: backup
              image: yourname/db-backup:latest
              env:
                - name: DB_TYPE
                  value: "mysql"
                - name: DB_HOST
                  value: "mysql.svc.cluster.local"
                - name: DB_USER
                  valueFrom:
                    secretKeyRef:
                      name: mysql-secret
                      key: user
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: mysql-secret
                      key: password
                - name: RCLONE_REMOTE
                  value: "s3:my-backups/mysql"
                - name: KEEP_LOCAL
                  value: "false"
              volumeMounts:
                - name: rclone-config
                  mountPath: /home/backup/.config/rclone
                  readOnly: true
          volumes:
            - name: rclone-config
              secret:
                secretName: rclone-config
                items:
                  - key: rclone.conf
                    path: rclone.conf
```

---

## 📦 Output

Each run produces a timestamped archive:

```
/backup/output/
  ├── backup-mysql-2025-11-02T03:00:00Z.tar.gz
  ├── backup-postgres-2025-11-02T03:00:00Z.tar.gz
  └── ...
```

The archive contains:

* One folder per DB engine (mysql, postgres, mongodb, redis)
* Inside each: per-database dumps or data snapshots

---

## 🧩 Remote Upload Options

### Option 1 — rclone

Supports any backend rclone supports (S3, GCS, Dropbox, etc.).
Mount your `rclone.conf` at:

```
/home/backup/.config/rclone/rclone.conf
```

Example command inside container:

```bash
rclone copy /backup/output s3:my-bucket/backups --progress
```

### Option 2 — s3cmd

Supports AWS S3 or S3-compatible storage.
Mount your `.s3cfg` file at:

```
/home/backup/.s3cfg
```

Example:

```bash
s3cmd put /backup/output/backup*.gz s3://my-bucket/backups/
```

---

## 🧹 Retention (Optional)

You can add cleanup after upload by extending your CronJob:

```bash
rclone delete "${RCLONE_REMOTE}" --min-age 14d --rmdirs
```

This keeps only the last 14 days of backups.

---

## 🧰 Troubleshooting

| Symptom                                 | Possible cause                                              |
| --------------------------------------- | ----------------------------------------------------------- |
| `Access denied` (MySQL/Postgres)        | Wrong `DB_USER`/`DB_PASSWORD` or missing root role          |
| `rclone: command not found`             | Image build incomplete or wrong tag                         |
| `Permission denied` on `/backup/output` | Mount path not writable for UID 10001                       |
| Backup empty                            | DB has no accessible databases or filtered by `DBS_EXCLUDE` |

---

## 🏁 Summary

✅ One image for all DB types
✅ Dumps **all databases** with root credentials
✅ Easy to use with **rclone** or **s3cmd**
✅ Perfect for **Kubernetes CronJobs** or **Docker automation**

Enjoy automated, versioned, and cloud-ready database backups!

## About

I'm **Himel**, a Software Engineer passionate about building efficient and optimized solutions.

If you contribute or enhance this project by adding new features or improving performance, your efforts will be recognized and greatly appreciated.

📧 **Contact:** [contact@himelrana.com](mailto:contact@himelrana.com)
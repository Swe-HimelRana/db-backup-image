# Database Backup Tool — Instructions (v2)

This Docker image provides an **all-in-one backup utility** for multiple database engines:

* **MySQL / MariaDB**
* **PostgreSQL**
* **MongoDB**
* **Redis**

It uses built-in clients (`mysqldump`, `pg_dump`, `mongodump`, `redis-cli`)
and supports remote uploads via **rclone** (pCloud, S3, Dropbox, etc.) or **s3cmd**.

---

## 🧱 Overview

This image is designed for automated backups — for example:

* Kubernetes CronJobs
* Docker scheduled jobs
* Manual ad-hoc dumps

You only need to provide **root/superuser credentials**, and it will:

1. Dump **all databases** from the selected DB type
2. Create a compressed `.tar.gz` archive (named like `11-12-1996-mysql.tar.gz`)
3. Optionally upload it to your remote storage (S3, pCloud, GCS, Dropbox, etc.)
4. Automatically **delete old backups** (retention policy)

---

## ⚙️ Environment Variables

| Variable         | Required | Description                                                     |         |
| ---------------- | -------- | --------------------------------------------------------------- | ------- |
| `DB_TYPE`        | ✅        | Database type — one of: `mysql`, `postgres`, `mongodb`, `redis` |         |
| `DB_HOST`        | ✅        | Database hostname or IP                                         |         |
| `DB_PORT`        | ❌        | Port (defaults per DB: 3306, 5432, 27017, 6379)                 |         |
| `DB_USER`        | ✅        | Root or superuser name                                          |         |
| `DB_PASSWORD`    | ✅        | Password for the above user                                     |         |
| `MONGO_URI`      | ❌        | Full MongoDB connection URI (overrides host/user/pass)          |         |
| `BACKUP_DIR`     | ❌        | Local backup directory (default: `/backup/output`)              |         |
| `BACKUP_PREFIX`  | ❌        | Internal folder prefix (default: `backup`)                      |         |
| `BACKUP_NAME`    | ❌        | Name used in final filename (default: DB_TYPE)                  |         |
| `COMPRESS`       | ❌        | Compression type: `gzip` or `none`                              |         |
| `KEEP_LOCAL`     | ❌        | If `false`, deletes local copy after upload                     |         |
| `RCLONE_REMOTE`  | ❌        | Destination remote for rclone (e.g., `pcloud:MyBackups/db`)     |         |
| `RCLONE_FLAGS`   | ❌        | Extra flags for rclone (default optimized for S3)               |         |
| `S3_URL`         | ❌        | Destination URL for s3cmd (e.g., `s3://mybucket/backups/`)      |         |
| `S3CMD_OPTS`     | ❌        | Extra flags for s3cmd upload                                    |         |
| `RETENTION_DAYS` | ❌        | Automatically delete remote backups older than N days           |         |
| `DBS_EXCLUDE`    | ❌        | Regex to skip certain DBs (e.g. `^(test                         | dev_)`) |

---

## 🚀 Basic Usage (Docker CLI)

### Example — MySQL with pCloud Retention

```bash
docker run --rm \
  -e DB_TYPE=mysql \
  -e DB_HOST=mysql.local \
  -e DB_USER=root \
  -e DB_PASSWORD=secret \
  -e RCLONE_REMOTE="pcloud:Backups/mysql" \
  -e RETENTION_DAYS=15 \
  -e KEEP_LOCAL=false \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

### Example — PostgreSQL with S3 Upload

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

### Example — MongoDB using URI

```bash
docker run --rm \
  -e DB_TYPE=mongodb \
  -e MONGO_URI="mongodb://root:secret@mongo.local:27017" \
  -e RCLONE_REMOTE="s3:my-bucket/mongo" \
  -e RETENTION_DAYS=30 \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

### Example — Redis Dump

```bash
docker run --rm \
  -e DB_TYPE=redis \
  -e DB_HOST=redis.local \
  -e DB_PASSWORD=secret \
  -e RCLONE_REMOTE="pcloud:Backups/redis" \
  -e RETENTION_DAYS=10 \
  -v /path/to/rclone.conf:/home/backup/.config/rclone/rclone.conf:ro \
  -v $(pwd)/backups:/backup/output \
  yourname/db-backup:latest
```

---

## ☁️ Using in Kubernetes CronJob

Automate daily backups with retention cleanup:

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
                  value: "pcloud:Backups/mysql"
                - name: RETENTION_DAYS
                  value: "15"
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

## 📦 Output Structure

Each run produces a date-first archive:

```
/backup/output/
  ├── 02-11-2025-mysql.tar.gz
  ├── 02-11-2025-postgres.tar.gz
  └── ...
```

The archive contains:

* Folder per DB engine (mysql, postgres, mongodb, redis)
* Inside each: per-database dump files or data snapshots

---

## 🧩 Remote Upload & Retention

### rclone (Recommended)

* Works with **pCloud**, **S3**, **Google Drive**, **Dropbox**, **Backblaze**, and more.
* Mount your `rclone.conf` file at:

  ```
  /home/backup/.config/rclone/rclone.conf
  ```

#### Automatic Retention:

If `RETENTION_DAYS` is set, the container will automatically:

```bash
rclone delete "${RCLONE_REMOTE}" --min-age ${RETENTION_DAYS}d --include "*-<name>.*"
rclone rmdirs "${RCLONE_REMOTE}"
```

💡 Example: `RETENTION_DAYS=15` keeps only the last 15 days of backups in your pCloud/S3 folder.

---

### s3cmd (Alternative)

Supports **AWS S3** and **S3-compatible** services.
Mount your `.s3cfg` at:

```
/home/backup/.s3cfg
```

Example:

```bash
s3cmd put /backup/output/*.gz s3://my-bucket/backups/
```

> 🔸 For retention with `s3cmd`, use your cloud provider’s **lifecycle policies**.

---

## 🧹 Cleanup Behavior

At the end of each run:

* Temporary directories are deleted.
* Local archives are removed (if `KEEP_LOCAL=false` and upload succeeded).
* Remote files older than `RETENTION_DAYS` are automatically deleted.
* All actions and outcomes are logged with timestamps.

---

## 🧰 Troubleshooting

| Symptom                                 | Possible Cause                                              |
| --------------------------------------- | ----------------------------------------------------------- |
| `Access denied`                         | Wrong credentials or insufficient privileges                |
| `rclone: command not found`             | Image build incomplete or outdated                          |
| `Permission denied` on `/backup/output` | Volume not writable for UID 10001                           |
| Backup empty                            | DB has no accessible databases or filtered by `DBS_EXCLUDE` |
| Remote cleanup skipped                  | `RETENTION_DAYS` not set or `RCLONE_REMOTE` missing         |

---

## 🏁 Summary

✅ One image for all major databases
✅ Dumps **all databases** securely
✅ Supports **rclone** (pCloud, S3, Dropbox, etc.) and **s3cmd**
✅ Includes **automatic retention cleanup**
✅ Fully compatible with **Kubernetes CronJobs**

Enjoy automated, versioned, and cloud-retained database backups!

---

## About

I'm **Himel**, a Software Engineer passionate about building efficient and optimized automation solutions.
If you enhance this project or add new database integrations, your contribution will be recognized and appreciated.

📧 **Contact:** [contact@himelrana.com](mailto:contact@himelrana.com)

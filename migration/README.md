# Data Migration (Domino + NetApp)

This repo runs a basic migration pipeline in Domino using NetApp-backed volumes.

## What this does
A simple Extract → Transform → Load (ETL) flow:

1. **Extract**: reads source data from the mounted NetApp **raw** path
2. **Transform**: applies simple transformations and writes to **staging**
3. **Load**: writes final output to **output**
4. **QC/Reports**: produces a small migration report in **reports**
5. **Logs**: writes run logs to **logs**

## Required NetApp Volumes / Paths
These directories must exist and be writable in Domino:

- `/mnt/data/raw`
- `/mnt/data/staging`
- `/mnt/data/output`
- `/mnt/data/reports`
- `/mnt/data/logs`

If your environment mounts volumes to a different path, update `config/migration.yaml`.

## Quick start (local in Domino workspace)
From the repo root:

```bash
pip install -r requirements.txt
bash jobs/run.sh config/migration.yaml

```md
# NetApp Volume Data Migration (Domino Workspace)

This repository is a **starter data-migration pipeline** designed to run inside a **Domino Workspace** and write all data, outputs, logs, and reports to a **NetApp-backed Domino Volume**.

It is intentionally simple so you can **learn how NetApp volumes behave** (persistence, sharing, restart safety) before scaling to real migrations.

---

## Core idea (read this first)

- **Git repo** → code + configuration (versioned, auditable)
- **NetApp volume** → raw data, staging data, outputs, reports, logs (persistent)

Nothing important is stored inside the workspace container.

---

## Repository structure

```

migration/
├── README.md
├── config/
│   └── migration.yaml
├── scripts/
│   └── run_migration.py
├── jobs/
│   └── run.sh
└── requirements.txt

```

---

## NetApp directory layout (on the mounted volume)

These directories live on the NetApp volume and must exist:

```

/mnt/data/raw        # input data
/mnt/data/staging    # intermediate data
/mnt/data/output     # final migrated data
/mnt/data/reports    # QC / migration reports
/mnt/data/logs       # run logs

````

> If your volume mounts to a different base path, update `config/migration.yaml`.

---

## Prerequisites

Before running anything, make sure the following are true:

1. **A Domino Project exists**
   - Workspaces and Jobs always run inside a Project.

2. **A NetApp-backed volume exists**
   - Data Plane: NetApp  
   - Filesystem: `domino-filesystem`

3. **The volume is mounted into your Workspace**
   - When starting the workspace, attach the NetApp volume.

Verify the mount:
```bash
ls -lah /mnt/data
````

If `/mnt/data` is empty or missing, the volume is not mounted.

---

## Step-by-step: run a migration in a Domino Workspace

### Step 1 — Start a Workspace

1. Open your Domino Project
2. Go to **Workspaces**
3. Start a Workspace
4. Ensure the NetApp volume is mounted
5. Open a terminal inside the workspace

---

### Step 2 — Create NetApp folders (first run only)

```bash
mkdir -p /mnt/data/{raw,staging,output,reports,logs}
ls -lah /mnt/data
```

---

### Step 3 — Add sample input data to NetApp

Create a simple CSV in the raw directory:

```bash
cat > /mnt/data/raw/patients.csv << 'EOF'
patient_id,age,site
P001,34,NY
P002,51,MI
P003,29,CA
EOF
```

Verify:

```bash
head /mnt/data/raw/patients.csv
```

---

### Step 4 — Install dependencies

From the repository root:

```bash
pip install -r requirements.txt
```

---

### Step 5 — Review configuration

Open:

```
config/migration.yaml
```

Confirm:

* `paths.raw_dir` = `/mnt/data/raw`
* `paths.output_dir` = `/mnt/data/output`
* `inputs.source_file` = `patients.csv`

No code changes are required for the starter example.

---

### Step 6 — Run the migration

From the repo root:

```bash
bash jobs/run.sh config/migration.yaml
```

You should see a JSON summary printed at the end.

---

### Step 7 — Verify outputs on NetApp

Final output:

```bash
ls -lah /mnt/data/output
cat /mnt/data/output/patients_migrated.csv
```

Staging data:

```bash
ls -lah /mnt/data/staging
```

Migration report:

```bash
cat /mnt/data/reports/migration_report.json
```

Run log:

```bash
tail -n 50 /mnt/data/logs/migration_run.log
```

---

## Persistence test (this proves NetApp)

1. Stop the Workspace
2. Start it again (with the same volume mounted)
3. Run:

```bash
ls -lah /mnt/data/output
cat /mnt/data/output/patients_migrated.csv
```

If the files are still there, you have confirmed **persistent NetApp storage**.

---

## How to migrate real data

1. Place your real input files into:

```
/mnt/data/raw/
```

2. Update `config/migration.yaml`:

   * `inputs.source_file`
   * `inputs.expected_columns`
   * transformation rules as needed

3. Run the same command:

```bash
bash jobs/run.sh config/migration.yaml
```

---

## Common issues

### Input file not found

Check:

```bash
ls -lah /mnt/data/raw
```

### `/mnt/data` is empty

The NetApp volume is not mounted. Restart the workspace and attach the volume.

### Permission errors

Test:

```bash
touch /mnt/data/logs/test.txt
```

If this fails, volume permissions need to be fixed by an admin.

---

## Best practices (migration-ready habits)

* Keep **code and config** in Git
* Keep **all data and outputs** on NetApp
* Do not overwrite final outputs in real migrations
* Prefer timestamped outputs and reports
* Validate in a Workspace, then run as a **Domino Job**

---

## Next step

Once this works in a Workspace, create a **Domino Job** that runs:

```bash
bash jobs/run.sh config/migration.yaml
```

This makes the migration repeatable, auditable, and production-ready.

```
```

# DBAnalyzer history retention

`dbo.usp_PurgeDBAnalyzerHistory` cleans the 12 Blocking, HighResource, LoginFailed,
LongRunning, and TableRowCount history tables. The default retention period is 30
calendar dates including today, based on SQL Server local time. For example,
2026-11-17 keeps dates from 2026-10-19 onward.

```sql
USE DBAnalyzer;

-- Preview only; this is the default.
EXEC dbo.usp_PurgeDBAnalyzerHistory @RetentionDays=30;

-- Delete expired completed runs and their child rows.
EXEC dbo.usp_PurgeDBAnalyzerHistory @RetentionDays=30, @PreviewOnly=0;
```

The result lists the cutoff date and the number of selected or deleted rows for
each table. Execute outside an existing transaction; INSERT EXEC is not supported.
Preview uses the same locks as cleanup and can briefly block writers.

Cleanup selects completed runs by `analysis_date` or `snapshot_date`. Blocking
rows without an analysis date use the date of `source_time_at_start`, including
legacy runs. Child rows are deleted before their parent runs in one transaction.
Any error rolls back all deletes. A selected run with child dates inside the
retention window causes an error instead of deleting those rows.

Running runs and their child rows are preserved, even when their dates are old.
Investigate stale RUNNING records separately. Cleanup serializes with other cleanup
calls and failed-login collection through application locks. Selected parent runs
and child-date checks remain locked until the transaction ends. Schedule analysis
and cleanup separately to reduce contention.

The `_DBAnalyzer-History-Cleanup` job runs daily at 03:10 in SQL Server local time.
Deployment renames the existing `_DBAnalyzer-Blocking-Cleanup` job and its schedule,
preserving job ID and history. The step retries three times at one-minute intervals.
Unexpected extra steps, schedules, shared schedules, or duplicate cleanup jobs stop
deployment. The daily analysis job is unchanged.

Failed-login collection retains its existing inline detail cleanup, with the same
calendar-date boundary. The unified job also removes expired run records. The old
`usp_PurgeBlockingAnalysis` remains available for existing callers, but the cleanup
job no longer calls it.

TableRowCount growth summaries use only retained snapshots after cleanup. The first
retained snapshot may lose its previous comparison. The forecast already uses the
same 30-date window. Reanalyses of expired dates are eligible for the next cleanup.

For large backlogs, inspect preview counts and database log capacity before running.
This version uses one transaction and does not batch deletes.

Deploy the retention SQL before `Features/Jobs/Deploy_DBAnalyzer_CleanupJob.sql`.
`Deploy.ps1` includes both files. `Test_Retention.sql` creates isolated tempdb
fixtures with foreign keys, tests preview, date boundaries, legacy runs, running
runs, rollback after partial deletes, repeat execution, and parameter validation,
then removes the test schema. If a test fails, inspect and remove its RetentionTest
schema before rerunning.

## Lab credentials

The user authorized Windows Credential Manager target
`DBAnalyzer/WIN2019LAB/Administrator`. `Tools/LabCredential.ps1` provides native
`Load()` and `Save()` methods without third-party modules. Load credentials only
into memory and use LogonUser plus RunImpersonated for the SQL connection. Save
under the original local Windows identity after successful login, outside the
impersonated identity. Never print the password or include it in command arguments.
The credential is available to the same local Windows user on this computer.


## Verified lab deployment: 2026-11-17

Deployed to WIN2019LAB at tcp:192.168.56.202,1433. The initial cleanup removed
159 expired rows and retained dates from 2026-10-19 onward. SHA-256 signatures and
row counts of retained data matched across all 12 tables. No expired eligible rows
remained. Foreign-key constraint checks passed and the tempdb test schema was removed.
The renamed SQL Agent job completed successfully; job ID and schedule ID were preserved.
Installed procedure definitions matched the source files.

A COPY_ONLY backup with checksums was created and verified before cleanup, on the
SQL Server machine at:

`T:\SQLServerBackup\DBAnalyzer_PreRetention_E47884802F0A4F6E9F49E7289CCEB208.bak`

Detailed local results and previous procedure definitions are under
`DeploymentLogs/Retention-20261117/` (excluded from Git).

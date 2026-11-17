# Consolidate monitoring into MS_PERF_COLLECTION

The active topology uses one monitoring database:

```text
MS_PERF_COLLECTION
  dbo.WHOISACTIVE and dbo.sp_WhoIsActive: raw collection, 7-day retention
  analyzer.*: analysis tables, procedures, views, 30-date retention
```

The old `MS_PERF_COLLECTION.dbo.LoginFailed` table and its old
`dbo.usp_AnalyzeLoginFailed` procedure are removed after backup. The replacement
`analyzer.LoginFailed`, `analyzer.LoginFailedSummary`, and related run table and
procedure remain available. Legacy rows are preserved in the pre-migration backup;
they are not automatically combined with the new parser's output.

## Existing installation

1. Record job definitions, enabled states, object definitions, and database settings.
   Check for custom users, permissions, dependencies, and running analyses.
2. Pause `_DBAnalyzer-Daily`, `_DBAnalyzer-History-Cleanup`, and the optional
   `_DBAnalyzer-TestRows-Startup` job. Wait for any queued or running execution to
   finish. The raw WhoIsActive collector can remain enabled.
3. Create COPY_ONLY backups with checksums of both databases. Run RESTORE VERIFYONLY
   with checksums and retain the backup paths. Test migration against a restored copy.
4. Run `Migrate_DBAnalyzerData.sql` before deploying analyzer tables. It copies all
   source columns and data, including legacy Blocking columns. It rebuilds defaults,
   checks, indexes, and foreign keys and preserves the next identity allocations.
   Source tables remain locked until the copy commits. Errors roll back the copy.
5. Run `Verify_DBAnalyzerData.sql` while jobs remain paused. It compares ordered JSON
   SHA-256 hashes, row counts, column definitions, next identity values, indexes,
   defaults, checks, and foreign keys. Do this before running analyses in the target.
6. Deploy `Features/Deploy_AnalyzerSchema.sql`, then the Blocking, LoginFailed,
   LongRunning, HighResource, TableRowCount, and Retention feature SQL files. Run
   the data verification again. Avoid running the maintenance/backup job installer
   as part of this migration, since it rebuilds unrelated maintenance jobs.
7. Deploy both SQL files under `Features/Jobs`. They preserve existing job IDs and
   histories while changing commands to `analyzer` and the database context to
   `MS_PERF_COLLECTION`.
8. Run `Remove_LegacyLoginFailed.sql` after confirming the backup and dependencies.
   It removes the old dbo table and procedure and refuses unexpected dependencies.
9. Close SSMS connections to the old DBAnalyzer database, then run `Finalize_AnalyzerMigration.sql`. It updates the optional startup job,
   checks job/module references, and makes the old DBAnalyzer database read-only
   as a recovery copy. All active monitoring uses MS_PERF_COLLECTION.
10. Run retention and failed-login isolated tests. Execute the daily analysis,
    startup test, and cleanup jobs and verify successful histories. Remove scratch
    test databases before capturing real table-count snapshots.

`Deploy.ps1` refuses a fresh target deployment when old DBAnalyzer history exists
and the target analyzer tables have not been migrated. Migration is deliberately
separate from normal installation. Do not rerun the data migration into populated
target tables. Investigate stale RUNNING source records before migrating.

The migration expects the current 12-table installation, ordinary rowstore indexes,
and no custom object permissions, triggers, computed columns, or rowversion columns.
Unsupported source features stop the migration for review. Identity continuation
handles the existing deleted-history tables by retaining their next unused values.

## Fresh installation

Run the normal deployment. It creates MS_PERF_COLLECTION if needed, installs
WhoIsActive under dbo, creates analyzer, and installs the analysis objects there.
No separate DBAnalyzer database is created. The optional startup test deployment
also points its capture step at MS_PERF_COLLECTION.analyzer.

## Recovery

The original DBAnalyzer database is retained read-only, together with verified
backups of both databases and recorded job definitions. If a cutover fails, pause
target analysis and cleanup, decide how to preserve target-only results, restore
the recorded job definitions, and return the old database to READ_WRITE before
resuming the old jobs. Restore the collection backup only when needed, since doing
so can remove raw samples collected after that backup. Do not delete the original
database until its recovery copy is no longer required.

Raw retention deletes only dbo.WHOISACTIVE rows older than seven days. Analysis
retention deletes only the 12 analyzer tables, keeping 30 calendar dates including
today. The policies remain independent after consolidation.


## Verified lab migration: 2026-11-17

WIN2019LAB now uses MS_PERF_COLLECTION.analyzer for twelve tables, seven procedures,
and six views. Ordered data hashes, columns, indexes, defaults, checks, and foreign
keys matched before target analyses were run. Empty-table identity allocation was
verified with an actual insert in the restored test environment. Fresh installation,
retention, and failed-login regression tests passed. The daily five-step job, startup
retry, and cleanup job all succeeded. Job IDs and histories were retained; startup
retry did not insert a duplicate test batch. Raw WhoIsActive job commands and retry
settings were unchanged. No expired eligible analysis rows remained. Installed
procedure and view definitions matched all 13 source modules.

The old dbo.LoginFailed table and procedure were removed after backup. Its two legacy
rows remain available in the pre-migration collection backup. The original DBAnalyzer
database is READ_ONLY for recovery. Scratch databases and test schemas were removed.

Pre-migration backups of both databases and a post-migration collection backup were
verified with checksums. The consolidated backup is on the SQL Server machine at:

`T:\SQLServerBackup\MS_PERF_COLLECTION_Consolidated_13E23A9666734D5FBA4A3A5B50F5ADCE.bak`

Detailed results, original definitions, and backup paths are under
`DeploymentLogs/Consolidation-20261117/`, excluded from Git.

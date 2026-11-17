# VM 啟動筆數測試環境

2026-10-20 已部署於 WIN2019LAB 預設執行個體，透過 SQL Server Agent 啟動排程，自動建立新的測試資料批次。預設每次 SQL Server 啟動新增 1,000 筆，保留原有資料。

|物件|用途|
|---|---|
|`TableRowCountTestLab`|獨立測試資料庫，首次建立時設定 SIMPLE recovery|
|`dbo.SampleRows`|累積測試資料，包含批次編號、建立時間及 100 字元固定內容|
|`dbo.StartupLoadRun`|每批的 SQL Server 啟動時間、執行起訖時間及插入前後實際筆數|
|`analyzer.usp_LoadStartupTestRows`|預設插入 1,000 筆，同一次 SQL Server 啟動只允許成功插入一批|
|`_DBAnalyzer-TestRows-Startup`|第一步插入資料，第二步執行現有筆數收集 SP|
|`_DBAnalyzer-TestRows-AgentStart`|Agent 啟動時執行，freq_type=64|

## 自動執行方式

VM 正常開機後，SQL Server 與 SQL Server Agent 自動啟動，Job 插入一批資料，然後執行 `MS_PERF_COLLECTION.analyzer.usp_CaptureTableRowCount @ReturnResults=0`。兩個服務已確認為 Automatic、Running。這是 SQL Server Agent 的啟動排程，設定依據見 [Microsoft 文件](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-add-schedule-transact-sql?view=sql-server-ver17)。

SP 以 `sys.dm_os_sys_info.sqlserver_start_time` 辨識啟動批次，並使用交易執行鎖避免同時插入。同一次 SQL Server 啟動時，手動重跑、Job 重試或僅重新啟動 Agent 都不會再插入資料，但 Job 第二步仍會更新當日快照。若插入失敗，該批資料及批次紀錄全部回滾，錯誤可在 Agent Job 歷史查看；快照失敗則保留已成功插入的批次，Job 重試不會重複插入。

SQL Server 本身重新啟動也會形成新批次。從 VM 的儲存狀態恢復、暫停後繼續，若沒有重新啟動 SQL Server 與 Agent，這個啟動排程不會觸發。VM 關機期間不會補造資料或歷史快照。

每個步驟失敗最多重試 3 次、間隔 1 分鐘。預設 1,000 筆可在 Job 第一步的 `@RowsPerStartup` 調整，允許 1～100,000 筆，新設定從下一次尚未成功加載的 SQL Server 啟動生效。

## 筆數紀錄與預測

`StartupLoadRun` 使用 `COUNT_BIG(*)` 記錄測試表實際筆數。DBAnalyzer 的每日快照仍使用中繼資料估計筆數，會同時納入測試資料表與批次紀錄表。Job 第二步會收集所有原本納入範圍的使用者資料庫，並非只收集這張測試表。

同一天多次開機會累積多個測試批次，但 DBAnalyzer 仍只保留每表每日一份最新快照；每次開機的筆數變化可從批次紀錄查閱。只有第一天資料時，`vTableRowCountForecast` 的估算維持 NULL；需要後續另一個日期的有效快照才能計算。

此測試資料依開機次數成長，不保證每日固定增加；VM 開機習慣會影響線性推估結果。來源與所有批次時間以 VM 當地時間記錄。

```sql
SELECT COUNT_BIG(*) AS current_row_count
FROM TableRowCountTestLab.dbo.SampleRows;

SELECT load_run_id,sqlserver_start_time,rows_before,rows_inserted,rows_after,completed_at
FROM TableRowCountTestLab.dbo.StartupLoadRun
ORDER BY load_run_id DESC;

SELECT snapshot_date,row_count,UsedMB,captured_at
FROM MS_PERF_COLLECTION.analyzer.TableRowCountSnapshot
WHERE database_name=N'TableRowCountTestLab' AND table_name=N'SampleRows'
ORDER BY snapshot_date;
```

`Run_TableRowCountTestLab.sql` 另提供預測、Job 歷史及重試／停用指令。測試環境的部署腳本獨立於一般 GUI 部署流程，重跑不刪資料或既有 Job 歷史；若需修改 Job，請避開該 Job 正在執行時。

## 驗證結果

- 已建立測試資料庫、兩張表、插入 SP、啟用中的兩步驟 Job 與 Agent 啟動排程。
- 使用隔離 tempdb 測試物件，驗證插入失敗回滾、插入前後筆數、同次啟動重跑及模擬新啟動再次插入，測試物件已清除。
- 手動啟動實際 Job 兩次，兩次均成功；測試表由 0 增為 1,000 筆，仍只有一筆成功批次紀錄，第二次沒有重複插入。
- 當日 DBAnalyzer 快照已記錄 SampleRows 為 1,000 筆，預測 View 顯示 `INSUFFICIENT_HISTORY`、一份快照，符合預期。
- 已核對兩個服務為自動啟動，未實際重新啟動服務或 VM。真正開機觸發將於下次 VM 正常開機時發生。

本次批次結果保存於 `DeploymentLogs/StartupTestLab-20261020-result.json`。

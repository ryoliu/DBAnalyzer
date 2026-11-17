# HIGHResourceSQL 實測紀錄

- 本次執行日期：2026-11-18（本機 Asia/Taipei）。
- LAB 回報時間：2026-11-17 15:19:16；預設分析依 SQL Server 當地日期，故為 2026-11-17。
- 伺服器：`WIN2019LAB`，登入：`WIN2019LAB\Administrator`，資料庫：`MS_PERF_COLLECTION`。
- 清空前：結果 12 筆、執行紀錄 14 筆。
- 清空後：兩表皆為 0 筆；未重設流水號。
- 六組固定案例全部 PASS，包括寫入失敗回滾。
- 隔離測試物件已清除，原始採樣資料未修改。

最後以實際採樣執行分析，結果保留在 LAB：

|欄位|結果|
|---|---|
|analysis_run_id|15|
|analysis_date|2026-11-17|
|status|SUCCEEDED|
|captured_row_count|19|
|unparsed_counter_rows|0|
|request_count|12|

CPU 與讀取量第 1 名均為 Session 76 的同一 Request，觀察到的最大 CPU 為 123 ms、最大邏輯讀取量為 6,465 頁。這是既有採樣的相對排名，未另外產生高負載。

查詢本次結果：

```sql
USE MS_PERF_COLLECTION;

SELECT * FROM analyzer.HighResourceSqlAnalysisRun
WHERE analysis_run_id=15;

SELECT * FROM analyzer.HighResourceSql
WHERE analysis_run_id=15
ORDER BY CASE WHEN cpu_rank IS NULL THEN 1 ELSE 0 END,cpu_rank,logical_reads_rank;
```

排程或手動重跑同一天後，明細會被新執行結果取代；本檔記錄的是當次執行結果。

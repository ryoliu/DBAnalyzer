# 高資源 SQL 每日回顧

`analyzer.usp_AnalyzeWhoIsActiveHighResource` 分析 `MS_PERF_COLLECTION.dbo.WHOISACTIVE`，預設分析 VM 當地時間前一天，分別產生 CPU 與邏輯讀取量前 20 名 Request。

|物件|用途|
|---|---|
|`analyzer.HighResourceSql`|兩份排行榜的聯集；同一 Request 同時入榜只存一筆|
|`analyzer.HighResourceSqlAnalysisRun`|日期、Top N、來源筆數、無效計數器筆數、結果筆數與執行狀態|
|`_DBAnalyzer-Daily` 第 4 步|前面三個分析步驟成功後，分析前一天|

## 執行

`Run_HighResource.sql` 提供前一天、當天與排行榜查詢。參數如下：

|參數|預設值|用途|
|---|---|---|
|`@AnalysisDate`|前一天|也可指定今天，分析已有採樣|
|`@TopN`|20|每份排行榜最多保留的 Request 數；必須為正整數|
|`@ReturnResults`|1|回傳執行紀錄、CPU 排行榜、邏輯讀取排行榜；0 只寫表|
|`@AnalysisRunId OUTPUT`|NULL|回傳本次分析編號|

相同日期重跑會在交易內 DELETE／INSERT 取代結果，包括改變 Top N 重跑；失敗會回滾並保留原本報表。執行紀錄持續保留，舊執行編號的明細可能已被取代。兩張表尚未設定自動清除。

## 指標與分組

SP 依序處理 `#Capture` 採樣、`#Requests` 累計峰值、`#RankedRequests` 排名及 `#LatestSamples` 最後採樣，再合併寫入結果。各步驟使用具名暫存表，排名與去重規則維持不變。

- `max_cpu_ms`：Request 在當天採樣中觀察到的最大累計 CPU 時間，單位毫秒；不是 CPU 使用率。
- `max_logical_reads`：Request 在當天採樣中觀察到的最大累計邏輯讀取頁數；包含快取讀取，不是實體磁碟讀取量。
- 同一 Request 使用 `session_id`、`login_time`、`request_id`、`start_time` 識別。不同 Request 即使 SQL 文字相同仍分開排名。
- 原始字串先去除空白與千分位逗號，再轉成 bigint。缺漏、無法解析或負值保留為 NULL，來源問題記錄在 `unparsed_counter_rows`，不當作零。
- 多次採樣使用 MAX，不加總累計值。跨午夜的 Request，其累計值可能包含前一天的工作，不能當作當日新增消耗。
- 兩項指標各自獨立排名，僅正值入榜。相同值依 Request 識別欄位固定排序，每份最多 Top N 筆；預設合併結果最多 40 筆。
- `cpu_rank`、`logical_reads_rank` 是所有合格 Request 的排名。結果可能只進入其中一份 Top N，另一項排名可能大於 Top N 或為 NULL。
- 排除 `session_id <= 50`、閒置及背景工作、缺少 Request 識別資訊的採樣。SQL Agent、應用程式等使用者 Request 會保留。
- `first_observed_time`、`last_observed_time`、`observed_sample_count` 記錄當天觀察範圍。來源資訊及 SQL 文字取自最後一筆採樣，不一定是資源消耗達到峰值時的陳述式。

CPU 單位與邏輯讀取定義參考 [Microsoft sys.dm_exec_requests 文件](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-requests-transact-sql?view=sql-server-ver16)；提供的 WhoIsActive v11.32 原始碼分別由 `cpu_time`、`logical_reads` 取得這兩項 Request 計數器。

## 限制與驗證

排行榜是相對排名，未額外設定高消耗的絕對門檻。每分鐘採樣可能漏掉短查詢，也可能未捕捉執行結束前的最終累計值；這份報表不是全天 SQL 總消耗或執行次數統計。來源採樣清除後無法完整補算。未加入自訂執行鎖，同日手動分析應與排程錯開。

已用實際採樣驗證報表，另以暫存來源驗證千分位數值轉換、同一 Request 的 MAX、同 Session 不同 Request 起始時間分組、兩份排行榜聯集、同日重跑、閒置及零值排除、無效計數器保留 NULL。暫存測試資料已清除，未修改正式 WhoIsActive 採樣表。

2026-10-18 實測使用兩個各執行約 30 秒、MAXDOP 1、只操作暫存表的查詢。自動與手動 WhoIsActive 共捕捉每個 Request 各 3 次採樣：CPU 測試觀察峰值 6,376 ms、15,878 邏輯讀取頁；讀取測試觀察峰值 1,511 ms、540,198 邏輯讀取頁。Top 1 各自排名正確，排行榜聯集為兩筆，同日重跑未重複，結果與來源 MAX 完全一致。當天報表編號 8 保留供查詢；測試連線及暫存表已釋放，沒有建立永久測試資料表。

## 檔案

- `Deploy_DBAnalyzer_HighResource.sql`：兩張表與分析 SP。
- `Run_HighResource.sql`：手動分析與查詢。
- `../Jobs/Deploy_DBAnalyzer_Jobs.sql`：共用每日排程。

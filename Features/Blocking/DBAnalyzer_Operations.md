# DBAnalyzer 每日 Blocking 回顧

每天分析前一天的 WhoIsActive 資料。同一日期重跑會取代該日結果，不重複累加。

|Job|排程（VM 當地時間）|用途|
|---|---|---|
|`_DBAnalyzer-Daily`|每日 02:00|步驟 1 分析前一天 Blocking，步驟 2 收集前一天登入失敗|
|`_DBAnalyzer-Blocking-Cleanup`|每日 03:10|刪除 30 天前的日報與執行紀錄|

WhoIsActive 保持每分鐘收集、來源保留 7 天。原本每 5 分鐘的分析排程已移除。

若停機漏跑，請在來源清除前以 `@AnalysisDate` 指定漏跑日期手動補跑；每日排程只分析前一天，不自動補所有歷史日期。

## 執行與查詢

受害者名單先以 `#VictimSummary` 分組，再 LEFT JOIN 事件，方便逐段查看彙總結果。Blocking 樹的遞迴追蹤、循環偵測、特殊 Blocker、缺漏採樣及 90 秒切段邏輯保留原寫法，避免簡化後改變事件判斷。

`Run_BlockingAnalyzer.sql` 提供範例。SP 只有三個參數：`@AnalysisDate`、`@ReturnResults`、`@AnalysisRunId OUTPUT`。不指定日期即分析 VM 當地時間的前一天；指定當天則產生尚未完整的當日日報。時間不自動轉換為台灣時間。

報表查 `analyzer.vBlockingIncident`、`analyzer.vBlockingDetail`，以 `analysis_date` 篩選日期。執行紀錄查 `analyzer.BlockingAnalysisRun`。`is_current_daily=1` 表示該日期目前有效的日報，成功重跑前的執行紀錄保留，但其事件與明細被取代。事件編號只屬於該次日報，不保證重跑後不變。

已移除增量進度、處理位置更新及跨次事件合併。每次只讀指定日的資料並重新分組。分析及清除 SP 均已移除應用程式執行鎖（sp_getapplock／sp_releaseapplock）。寫入仍使用交易，重跑失敗時上一份日報完整保留。同一日期的分析應依序執行，避免手動執行與排程重疊。

跨午夜的同一阻塞會分成兩天呈現。Duration 是該日首次至最後觀察時間的跨度，不是精確的鎖等待時間。採樣間隔超過 90 秒會切段。`captured_sample_count=0` 表示沒有來源採樣，不能解讀為當天沒有 blocking。

每日清除依 VM 日期刪除 `analysis_date` 早於今日減 30 天的 DAILY 資料，依序刪明細、摘要及執行紀錄。日報尾端未確認解除的事件也按日報日期清除。升級前的 LEGACY／INCREMENTAL 歷史保留，不加入每日 View，亦不由日報清除 SP 刪除；舊的進度表 dbo.BlockingAnalysisState 已移除，舊增量欄位保留但不再使用。

## 檔案

- `Deploy_DBAnalyzer_Daily.sql`：每日分析 SP、清除 SP、View 及必要欄位。
- `../Jobs/Deploy_DBAnalyzer_Jobs.sql`：共用每日分析與清除排程。
- `Run_BlockingAnalyzer.sql`：執行及報表範例。


已驗證：實際 blocking 的事件與明細、同日重跑防重、不同日期互不影響、替換途中失敗回滾、空資料日與 30 天清除。測試用資料庫已移除。

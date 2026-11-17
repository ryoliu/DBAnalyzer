# 長時間 SQL 每日回顧

`analyzer.usp_AnalyzeWhoIsActiveLongRunning` 分析 `MS_PERF_COLLECTION.dbo.WHOISACTIVE`，預設收集 VM 當地時間當天 00:00 至本次執行開始時、已執行至少 300 秒的 Request。

|物件|用途|
|---|---|
|`analyzer.LongRunningSql`|每個日期、每個 Request 一筆結果|
|`analyzer.LongRunningSqlAnalysisRun`|執行日期、門檻、來源筆數、結果筆數、狀態與錯誤|
|`_DBAnalyzer-Daily` 第 3 步|每日 VM 當地時間 00:00～23:59:59 每 10 分鐘執行的共用 Job，前兩步成功後執行|

## 使用

`Run_LongRunning.sql` 包含前一天、當天及報表查詢範例。SP 參數如下：

|參數|預設值|用途|
|---|---|---|
|`@AnalysisDate`|今天|指定過去日期時分析完整日；今天截止於執行開始時|
|`@MinDurationSeconds`|300|最低執行時間，單位秒；必須為正整數|
|`@ReturnResults`|1|設為 0 只寫入資料表|
|`@AnalysisRunId OUTPUT`|NULL|回傳本次執行編號|

同一日期重跑會 DELETE／INSERT 取代該日結果，包括使用不同門檻重跑。寫入失敗會回滾，保留上一份報表。執行紀錄持續保留，舊執行編號的明細可能已被取代。尚未設定這兩張表的自動清除。

## 判讀

SP 依序建立採樣 `#Capture`、Request 彙總 `#Requests`、採樣排序 `#LatestSamples`，最後寫入報表。各步驟分開呈現；Request 分組、300 秒預設門檻及最後採樣的選取規則維持不變。

- Request 以 `session_id`、`login_time`、`request_id`、`start_time` 分組。相同 Session 的不同 Request 起始時間會分開記錄。
- 只分析 `session_id > 50` 且具有完整 Request 識別欄位的採樣；排除 `sleeping`、`dormant`、`background`。閒置未提交交易應由其他分析處理。
- `max_elapsed_seconds` 是最後觀察到的最長已執行時間，以 `collection_time - start_time` 計算，包含執行及等待時間。不是 CPU 時間，也不是已確認的最終耗時。
- `first_observed_time`、`last_observed_time` 為當天該 Request 所有有效採樣的首次／末次時間，包含尚未達門檻的採樣；`observed_sample_count` 為不同採樣時間數。
- `last_status`、`last_wait_info`、SQL 文字與來源資訊取自最後一筆採樣。Request 若包含多個陳述式，最後 SQL 文字不代表整個 Request 執行過的所有 SQL。
- 每分鐘採樣可能漏掉短暫活動，無法確認精確完成時間，也不統計執行次數。沒有結果不代表整天沒有慢查詢。
- 跨午夜仍執行的 Request 會分別出現在各日報表；已執行時間仍從原始 Request 開始時間起算。
- 沒有加入應用程式執行鎖。同日手動分析應與排程錯開；來源採樣已清除的日期無法完整補算。

## 檔案

- `Deploy_DBAnalyzer_LongRunning.sql`：兩張表與分析 SP。
- `Run_LongRunning.sql`：執行與查詢範例。
- `../Jobs/Deploy_DBAnalyzer_Jobs.sql`：共用每日排程。

## 驗證

已在 WIN2019LAB 部署，並以一個不修改資料的等待查詢驗證：未達 300 秒時不列入；超過門檻後 6 次採樣合併成 1 筆，最長觀察時間 345.393 秒。同日重跑仍只有 1 筆。測試查詢已自然結束，未留下測試帳號或測試腳本。完整佈署流程及 SQL Server Agent 三個分析步驟均執行成功。

當天的截止時間在每次 SP 開始時固定，使用起點包含、截止不包含的區間。指定過去日期仍分析完整日。午夜後預設日期轉為新的一天，前一日尾段不會自動補跑。

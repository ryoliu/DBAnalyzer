# LongRunningSql 測試

## 執行方式

在 PowerShell 7 執行：

```powershell
Set-Location C:\DBAnalyzer
.\Features\Tests\Test_LongRunningSQL.ps1
```

要完整驗證「真實執行超過 30 秒 → WhoIsActive 採樣 → LongRunningSql 寫入」，執行：

```powershell
.\Features\Tests\Test_LongRunningSQL.ps1 -LiveRequest
```

`-LiveRequest` 會另開連線執行 45 秒的 `WAITFOR`，以唯一的 Application Name 識別，在約 35 秒時使用正式 WhoIsActive 程序採樣該 Session，再執行當天分析並檢查正式表有該 Request、耗時至少 30 秒。查詢自然結束後釋放連線；真實採樣與分析結果保留，依既有保留政策清除。

固定連線 `WIN2019LAB`（`192.168.56.202,1433`），使用已授權的 Windows 認證管理員項目 `DBAnalyzer/WIN2019LAB/Administrator`。不需要在腳本填入密碼，不安裝額外套件。

每組成功會顯示 `PASS`；結果不符時會拋出錯誤，PowerShell 以失敗結束。

## 判定規則

預設門檻為 30 秒，等於門檻也會列入。

- 耗時為 `collection_time - start_time`，包含執行及等待時間。
- 同一 Request 多次採樣取最長觀察耗時，不加總。
- 使用 Session ID、登入時間、Request ID、開始時間識別 Request。
- 來源資訊、等待資訊與 SQL 文字取最後一次採樣。
- 採樣次數計算不同採樣時間；包含尚未達門檻的有效採樣。

## 執行流程與資料影響

1. 以 Windows 模擬登入連線，先查詢伺服器、原始登入帳號、資料庫存取權及伺服器時間。
2. 在 `tempdb` 建立獨立 schema，複製空的 WHOISACTIVE 結構及專案的結果表結構。
3. 複製 LAB 已部署的分析程序，將來源與結果物件指向隔離 schema。只在副本將分析時鐘改由測試表提供，以驗證固定截止時間；其他分析邏輯不變。
4. 寫入固定資料，執行七組案例並比對預期結果。
5. 呼叫 LAB 原本的程序，以預設門檻分析伺服器當天的真實採樣，檢查成功狀態並保留結果。
6. 刪除隔離測試物件；案例失敗也會進行清理。

腳本不預先清空分析表，不修改 LAB 原本的程序。預設不寫入 `dbo.WHOISACTIVE`；指定 `-LiveRequest` 時會透過 WhoIsActive 新增真實採樣。第 5 步會取代當天既有 LongRunningSql 明細，並新增執行紀錄；其他日期結果保留。請與每日分析排程及其他手動分析錯開。

預設只執行固定案例及既有採樣分析。指定 `-LiveRequest` 才會額外執行 45 秒等待查詢，不建立測試業務資料或阻塞其他連線。

## 測試案例

|組別|測試內容|預期結果|
|---|---|---|
|1|30 秒門檻、耗時精度、Request 分組、重複採樣、排除條件、歷史日期邊界|有效來源 11 筆，結果 7 筆；低於 30 秒排除，等於 30 秒列入；逐筆比對 Request、耗時及採樣數|
|2|尚未達門檻的早期採樣、最後採樣的 SQL、帳號、主機、程式、等待與阻塞資訊|首次採樣仍保留 29 秒時的資料；最大耗時 345.393 秒；最後資訊為 suspended、LCK_M_S、阻塞 Session 200|
|3|門檻改為 400 秒，並重跑同一天|只剩 3 筆且屬於最新執行編號；歷史執行紀錄保留|
|4|沒有來源的歷史日期|成功，來源與結果為 0，其他日期的 3 筆結果不變|
|5|門檻為 0、負數、NULL；未來日期；既有交易|分別回報 58002、58001、58000，原資料不變|
|6|只在隔離結果表加入限制，刻意使寫入失敗|回滾結果取代作業，保留原本 3 筆明細及執行編號；失敗紀錄為 FAILED、錯誤 547|
|7|將時鐘固定在當天 00:10，測試未指定日期與跨午夜 Request|納入午夜及 00:09:59 採樣；排除剛好 00:10 及之後採樣；耗時從原始開始時間計算|

排除條件包括 Session ID 不大於 50、sleeping／dormant／background、缺少登入時間或 Request ID、開始時間晚於採樣時間，以及分析日期外的資料。

第 6 組的 FAILED 是預期的隔離測試結果，不代表 LAB 正式分析失敗。

## 本次實測結果（30 秒門檻）

### 真實查詢完整流程

已執行 `Test_LongRunningSQL.ps1 -LiveRequest`，七組固定案例與真實查詢驗證全部 PASS。LAB 查詢開始時間為 `2026-11-17 15:41:43`，執行 45 秒 WAITFOR，已自然結束並釋放連線。

|欄位|結果|
|---|---|
|analysis_run_id|20|
|session_id|77|
|min_duration_seconds|30|
|max_elapsed_seconds|35.380|
|observed_sample_count|2|
|last_wait_info|WAITFOR|
|program_name|DBAnalyzer LongRunning Test b9b6f0d9edc04e1e8f1e79fe89c78c8f|

本次來源 25 筆、結果 4 筆，其中 3 筆為既有 Blocking 測試採樣，新增的第 4 筆才是本次專用 LongRunning 測試。35.380 秒是最後採樣觀察到的耗時，不是查詢完成的 45 秒。

測試結果保留在正式分析表，可依 Application Name 查詢，避免與舊 Blocking 資料混淆：

```sql
USE MS_PERF_COLLECTION;

SELECT analysis_run_id,session_id,max_elapsed_seconds,observed_sample_count,
       last_wait_info,program_name,last_sql_text
FROM analyzer.LongRunningSql
WHERE program_name=N'DBAnalyzer LongRunning Test b9b6f0d9edc04e1e8f1e79fe89c78c8f';
```

### 調整預設值後的既有採樣重算

2026-11-18（本機 Asia/Taipei）已將預設門檻改為 30 秒並部署至 LAB。LAB 回報時間為 `2026-11-17 15:37:10`，七組案例全部 PASS，隔離物件已清除。

以未指定門檻的呼叫重新分析當天資料：

|欄位|結果|
|---|---|
|analysis_run_id|18|
|analysis_date|2026-11-17|
|status|SUCCEEDED|
|min_duration_seconds|30|
|captured_row_count|21|
|request_count|3|

三個 Request 的最長觀察耗時分別為 177.667、56.273、49.383 秒，結果保留於 `analyzer.LongRunningSql`。Session ID 相同但 Request 識別欄位不同時會分開記錄。

```sql
USE MS_PERF_COLLECTION;

SELECT * FROM analyzer.LongRunningSqlAnalysisRun WHERE analysis_run_id=18;
SELECT * FROM analyzer.LongRunningSql WHERE analysis_run_id=18
ORDER BY max_elapsed_seconds DESC;
```

每日排程未指定門檻，因此也會使用新的 30 秒預設值。WhoIsActive 仍每分鐘採樣，持續 30 秒但落在兩次採樣之間的 Request 仍可能漏掉。

## 先前實測結果（300 秒門檻）

本機執行日期：2026-11-18（Asia/Taipei）。LAB 回報時間為 `2026-11-17 15:29:51`，故實際分析使用 LAB 日期 `2026-11-17`。

七組案例全部 PASS，隔離測試物件已清除。最後的真實採樣分析結果如下：

|欄位|結果|
|---|---|
|analysis_run_id|16|
|analysis_date|2026-11-17|
|status|SUCCEEDED|
|min_duration_seconds|300|
|captured_row_count|20|
|request_count|0|

當次採樣沒有 Request 達到 300 秒，結果 0 筆符合預期；不能據此推論整天沒有慢查詢。

```sql
USE MS_PERF_COLLECTION;

SELECT * FROM analyzer.LongRunningSqlAnalysisRun
WHERE analysis_run_id=16;

SELECT * FROM analyzer.LongRunningSql
WHERE analysis_run_id=16
ORDER BY max_elapsed_seconds DESC;
```

同一天再次分析會取代明細；上表是這次執行的紀錄。

## 檔案

|檔案|用途|
|---|---|
|`Test_LongRunningSQL.ps1`|連線、建立隔離區、執行案例、真實採樣分析及清理|
|`LongRunningSQL_Cases.sql`|固定資料、預期結果與七組斷言；由 PowerShell 載入執行|
|`LongRunningSQL_README.md`|執行方式、案例與本次結果|

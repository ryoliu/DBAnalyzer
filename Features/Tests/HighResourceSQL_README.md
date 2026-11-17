# HIGHResourceSQL 測試

## 執行方式

在 PowerShell 7 執行：

```powershell
Set-Location C:\DBAnalyzer
.\Features\Tests\Test_HighResourceSQL.ps1 -ClearResults
```

`-ClearResults` 會先刪除 `MS_PERF_COLLECTION` 內以下兩張表的所有資料，再執行測試：

1. `analyzer.HighResourceSql`
2. `analyzer.HighResourceSqlAnalysisRun`

先刪明細，再刪執行紀錄；兩者在同一交易內完成，不重設流水號。刪除後不提供還原。若每日分析工作正在執行或排隊，腳本會停止，避免同時清除。

只想重測、不先清空時：

```powershell
.\Features\Tests\Test_HighResourceSQL.ps1
```

兩種執行方式最後都會呼叫 LAB 原本的分析程序，重建當天結果並新增執行紀錄。相同日期的舊結果會由程序取代。

固定連線 `WIN2019LAB`（`192.168.56.202,1433`），使用已授權的 Windows 認證管理員項目 `DBAnalyzer/WIN2019LAB/Administrator`。不需要輸入密碼，不安裝額外套件。

## 測試方式

先確認伺服器、登入帳號與資料庫存取，再依參數決定是否清空。固定案例在 `tempdb` 的獨立 schema 執行，使用 LAB 已部署程序的定義副本，以及專案的結果表結構。

案例結束後自動刪除隔離測試物件；案例失敗也會進行清理。測試不修改 `dbo.WHOISACTIVE`，不修改 LAB 原本的程序，也不建立其他資料庫。

最後以 LAB 真實採樣執行預設當天分析，檢查成功狀態並輸出結果。這一步是實際資料的執行驗證，不會另外製造 CPU 或大量讀取負載。

## 案例

|組別|測試內容|預期結果|
|---|---|---|
|1|CPU 與讀取量各取 Top 1；多次採樣、千分位、同分排序、最後採樣資訊、日期邊界與排除條件|聯集 2 筆；CPU 使用 MAX 9,000，不加總；來源 13 筆、無效計數器 5 筆|
|2|提高為 Top 20，逐筆比較預期結果與兩種名次|共 10 筆；不同登入時間、Request ID、開始時間各自分組；零值不入榜；無效值保留 NULL|
|3|縮回 Top 1 並重跑同一天|明細維持 2 筆且屬於最新執行編號；歷史執行紀錄保留|
|4|分析沒有來源的過去日期|成功、來源與結果皆為 0，其他日期結果不變|
|5|Top N 為 0、負數、NULL；未來日期；在既有交易內執行|分別回報 58302、58301、58300，原資料不變|
|6|只在隔離結果表加上限制，刻意使明細寫入失敗|回滾 DELETE／INSERT，原本 2 筆結果保留，執行紀錄為 FAILED、錯誤 547|

無效計數器案例包括文字、負數、NULL、空白及 bigint 溢位。排除案例包括系統 Session、sleeping／dormant／background、缺少登入時間或 Request ID、開始時間晚於採樣時間，以及分析日期外的採樣。

每組成功會顯示 `PASS`；SQL 斷言不符時會拋出錯誤，PowerShell 以失敗結束。FAILED 狀態是第 6 組刻意製造的隔離測試結果。

## 檔案

|檔案|用途|
|---|---|
|`Test_HighResourceSQL.ps1`|連線、選擇性清空、建立隔離區、執行案例、實際分析及清理|
|`HighResourceSQL_Clear.sql`|清空 LAB 的兩張 HighResource 表|
|`HighResourceSQL_Cases.sql`|固定資料、預期結果與六組斷言；透過 PowerShell 執行|
|`HighResourceSQL_Result.md`|本次實測紀錄|

清空前仍應與其他手動分析錯開；腳本只檢查每日排程工作，沒有暫停 SQL Agent 或其他分析連線。

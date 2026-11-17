# 登入失敗每日收集

以現有版本 B 為基礎，保留三張表、分類 View 與每日排程。部署不刪表，也不立即執行收集或清理。

|物件|用途|
|---|---|
|`analyzer.usp_AnalyzeLoginFailed`|收集指定日期，預設當天 00:00 至執行開始時|
|`analyzer.LoginFailed`|時間、帳號、來源、原因、Error、State 與原文|
|`analyzer.LoginFailedSummary`|依日期、分類、Error、State 彙總|
|`analyzer.vLoginFailedClassified`|明細加上原因文字與 Error State 分類|
|`analyzer.LoginFailedAnalysisRun`|每次執行的狀態、稽核設定、讀取檔案數、筆數與錯誤|

## 執行與參數

```sql
EXEC MS_PERF_COLLECTION.analyzer.usp_AnalyzeLoginFailed;

-- SQL Agent: collect the current day up to execution start without result sets.
EXEC MS_PERF_COLLECTION.analyzer.usp_AnalyzeLoginFailed @ReturnResults=0;

-- Increase limits for a historical date only if its source logs still exist.
EXEC MS_PERF_COLLECTION.analyzer.usp_AnalyzeLoginFailed
    @AnalysisDate='20261016', @MaxArchiveNo=20, @RetentionDays=90;
```

|參數|預設|說明|
|---|---|---|
|`@AnalysisDate`|昨日|目標伺服器當地日期；允許今天的部分資料|
|`@ReturnResults`|1|回傳執行紀錄、明細、彙總；排程使用 0|
|`@AnalysisRunId OUTPUT`|NULL|取得本次執行編號|
|`@MaxArchiveNo`|10|最大封存編號，包含目前檔案 0，因此最多 11 個檔案|
|`@RetentionDays`|30|成功收集後，刪除當地今日減去指定天數以前的明細與彙總|

原本前三個參數的位置不變。超過保留範圍的分析日期會被拒絕，避免剛補收就遭清除；需要補收較早日期時，同時提高保留天數。減少保留天數會在下一次成功收集時清除較舊資料。執行紀錄持續保留。

共用 Job `_DBAnalyzer-Daily` 每日當地時間 00:00～23:59:59 每 10 分鐘執行，第二步使用 `@ReturnResults=0`，現有 Job 不需變更。失敗最多重試 3 次，間隔 1 分鐘。

## 收集與資料保護

維持五段流程：記錄執行及檢查稽核、讀取 ERRORLOG、解析訊息、唯一配對錯誤標頭、以交易更新明細及彙總。

從目前 ERRORLOG 依序讀取封存檔，取得截至分析結束時間的資料。今天的結束時間固定為本次執行開始時，其他日期使用隔日 00:00。只有目標日 00:00（包含）至隔日 00:00（不包含）的登入失敗訊息會寫入明細。

每個檔案讀完後檢查最早訊息時間；讀到早於目標日 00:00 的檔案就停止；若最早訊息剛好等於 00:00，會繼續讀前一個封存檔，避免漏掉同一時間的事件。沒有到達目標日起點、必要的封存編號中斷、讀取失敗，或掃描上限不足時，整次失敗並保留當日原有資料。若來源已輪替移除，提高上限也無法復原。

讀取前後比對封存檔的編號、時間、大小，並重新讀取目前檔案的最早訊息以檢查是否被重設；偵測到變更就失敗並保留舊資料。這是正常 ERRORLOG 輪替下的來源涵蓋檢查，無法證明檔案未曾被人工改寫，也無法證明過去整天的登入稽核都已啟用。SQL Server 停機期間沒有登入事件，不能要求每個小時都有訊息。

確認來源涵蓋範圍後，才在同一交易內取代指定日期的明細、重建彙總、清除過期資料並更新成功狀態。完整來源的零筆結果可更新為零；來源不足不會被當成零筆。交易失敗會回滾，執行紀錄另記為 FAILED。

為維持單次讀取及取得涵蓋依據，保留未使用關鍵字篩選的讀取方式；較早的訊息只供涵蓋檢查，不寫入明細。最早讀取的檔案可能包含目標日前的資料，單檔很大時仍可能增加 I/O 與 TempDB 使用，封存數量上限不代表單檔大小上限。

使用一個 session 層級的 `sp_getapplock`，讓不同日期的收集與歷史清理依序執行。已有收集執行時，第二個執行立即失敗並留下紀錄，可稍後重試。成功與例外路徑均釋放鎖；連線中斷時由 SQL Server 釋放。手動取消查詢不一定進入 CATCH，若取消後仍保留連線，應中斷該連線以釋放 session 鎖。

## 稽核與解析

維持 Windows SQL Server、sysadmin 執行及英文 ERRORLOG 的使用範圍。改以唯讀 `xp_instance_regread` 取得執行個體的 AuditLevel，取代 `xp_loginconfig`；值必須為 2（failure）或 3（all），無法取得或權限不足時失敗，不略過檢查。此方式仍使用擴充預存程序，並非新增跨平台支援。

讀到的是登錄設定，修改稽核需要重啟 SQL Server 才生效。因此必須由 DBA 確認設定已生效，且分析日期期間有啟用失敗登入稽核；來源涵蓋檢查不能取代這項確認。參考 [Microsoft 登入稽核說明](https://learn.microsoft.com/sql/ssms/configure-login-auditing-sql-server-management-studio)。

每一行 `Login failed for user ...` 視為一筆失敗，保留完整 `raw_message`，不使用 DISTINCT 刪除同時發生的重複事件。帳號不再依賴 Reason，支援沒有 Reason 的標準訊息與帳號內的單引號。來源可為 IP、主機文字或 `<local machine>`，不強制轉成 IP。格式不符時保留原文與 NULL 欄位。

同一檔案、時間與 ProcessInfo 只有一筆登入失敗及一筆錯誤標頭時，才補上 Error、Severity、State。無法唯一配對時保留 NULL。分類規則沿用原有 View：先依 Reason，再依 Error 18456 的 State 回退，不把分類當成已驗證根因。規則參考 [Microsoft Error 18456 文件](https://learn.microsoft.com/en-us/sql/relational-databases/errors-events/mssqlserver-18456-database-engine-error?view=sql-server-ver17)。

## 查詢與驗證狀態

`Run_LoginFailed.sql` 提供執行、明細、分類彙總、帳號與來源統計、執行紀錄及分類回查。無事件的日期沒有彙總列，請看執行紀錄確認是否成功收集。帳號／來源的唯一數不可跨分類直接加總。

部署 SQL 與操作查詢已通過本機既有 ScriptDom 的 SQL Server 2016（130）及 2019（150）語法解析，`git diff --check` 通過，未安裝額外套件。語法解析不等於資料庫編譯或行為驗證。

2026-10-20 已透過 `LogonUser`、`WindowsIdentity.RunImpersonated` 與 .NET `SqlConnection`，使用 Windows 驗證連線至 WIN2019LAB（SQL Server 2019，15.0.4198.2）。將本次部署 SQL 載入 tempdb 的獨立測試 schema，編譯及執行均成功；未更新 DBAnalyzer 的既有 SP、View 或資料表。

|測試|結果|
|---|---|
|真實 ERRORLOG 收集昨日、再次收集|均為 0 筆，未累加|
|重讀 2026-10-16／2026-10-17 真實 ERRORLOG|分別為 6／5 筆，帳號、來源、原因、Error、Severity、State、原文及重複數與既有資料一致|
|沒有 Reason、帳號含單引號、空帳號、格式異常|正確解析或保留 NULL 及原文|
|唯一錯誤標頭／多筆模糊配對／合法重複訊息|唯一才填入 State，模糊配對維持 NULL，重複事件保留|
|完整來源但沒有失敗事件|當日明細及彙總正確更新為零|
|來源不足、封存上限不足、封存編號中斷|執行失敗，保留舊明細、彙總及過期待清理資料|
|模擬讀取失敗、封存輪替、目前檔案重設|執行失敗，留下失敗紀錄並保留舊資料|
|兩個相鄰封存檔都有午夜事件|兩筆事件均保留；次日 00:00 事件不列入當日|
|30 天保留邊界|邊界當日保留，更早明細及彙總清除，執行紀錄保留|
|模擬彙總寫入失敗|明細、彙總及清理全部回滾，失敗紀錄保留，執行鎖釋放|
|第二個連線同時收集|立即拒絕並記錄失敗，原有資料保留|

輪替、重設與錯誤情境使用模擬來源，未實際輪替伺服器 ERRORLOG。測試結束已移除測試 schema 及所有測試物件，測試期間既有 DBAnalyzer 歷史筆數與 SP 定義確認未變。本次為 SQL Server 2019 實機測試；SQL Server 2016 仍僅完成語法解析。

2026-10-20 已將本次修改部署至 WIN2019LAB 的 DBAnalyzer。部署在單一交易內完成，確認 SP 與分類 View 定義符合來源檔（僅正規化 SQL Server 儲存的 CREATE 宣告），SP 五個參數確認完成。部署前後均為 11 筆明細、5 筆彙總（合計 11 次失敗）及 22 筆執行紀錄；未立即收集、重算或清理歷史。既有每日 Job 於下次執行時使用新版本，預設封存上限為 10、保留天數為 30。舊定義與部署前後筆數保存在 `DeploymentLogs/LoginFailed-20261020T045427708Z/`。

可使用 `Test_LoginFailed.ps1` 重現測試（Windows 上的 PowerShell 7，sysadmin 權限）。腳本會提示輸入密碼，不儲存密碼；測試直接載入部署檔，僅替換測試 schema，模擬情境再替換 ERRORLOG 讀取程序。若來源已不涵蓋歷史日期，會明確回報無法重讀。

```powershell
pwsh -NoProfile -File C:\DBAnalyzer\Features\LoginFailed\Test_LoginFailed.ps1
```

當天的截止時間在每次 SP 開始時固定，使用起點包含、截止不包含的區間。指定過去日期仍分析完整日。午夜後預設日期轉為新的一天，前一日尾段不會自動補跑。

# 登入失敗每日收集

已部署於 `WIN2019LAB` 預設執行個體的 `DBAnalyzer`。

|物件|用途|
|---|---|
|`dbo.usp_AnalyzeLoginFailed`|讀取指定日期的登入失敗訊息，預設前一天|
|`dbo.LoginFailed`|登入失敗明細：時間、帳號、來源、原因、錯誤資訊與原文|
|`dbo.LoginFailedSummary`|依日期、分類、Error、State 彙總失敗次數、帳號數、來源數及起訖時間|
|`dbo.vLoginFailedClassified`|明細加上失敗分類，供摘要回查原始訊息|
|`dbo.LoginFailedAnalysisRun`|每次執行的日期、狀態、稽核設定、讀取檔案數、筆數與錯誤|
|Job `_DBAnalyzer-Daily`|每天 VM 當地時間 02:00 啟動，步驟 1 分析 Blocking，步驟 2 收集登入失敗|

## 執行

執行 `EXEC DBAnalyzer.dbo.usp_AnalyzeLoginFailed;` 即收集前一天。可指定 `@AnalysisDate`，也可用 `@ReturnResults=0` 只寫表。`@AnalysisRunId OUTPUT` 可取得執行編號。指定今天會取得執行當下可讀的部分日報。

時間範圍為指定日 00:00（包含）至隔日 00:00（不包含），以 VM 當地時間為準。每次先讀取目前及所有可用封存 SQL Server ERRORLOG，再在同一交易中取代指定日期的明細並重建摘要。重跑不累加；失敗會回滾，保留該日原有明細與摘要。執行紀錄持續保留。

沒有加入 `sp_getapplock` 或其他自訂執行鎖。同日分析應依序執行，避免手動與排程同時收集。Job 失敗最多重試 3 次、間隔 1 分鐘；漏跑日期需在來源仍可用時手動補跑。

## 訊息解析

SP 已改為五段直線流程：記錄執行與檢查稽核、WHILE 讀取各個 ERRORLOG、以具名字串位置及 UPDATE 解析、以 GROUP BY／JOIN 配對錯誤標頭、在交易內取代明細並重建摘要。SP 本身不使用 CROSS APPLY、OUTER APPLY 或 PARSENAME，不增加其他輔助 SP；分類仍沿用既有的 vLoginFailedClassified。

已比對 12 組訊息格式與原版解析結果，並驗證實際 6 筆登入失敗的明細、Error／State 及摘要完全一致，同日重跑沒有累加。

此版本配合目前伺服器的英文 ERRORLOG，將 `Login failed for user ...` 每一行視為一筆失敗訊息，保留完整 `raw_message`。從原文擷取 `login_name`、`client_address`、`failure_reason`。來源可能是 IP、主機文字或 `<local machine>`，不強制當成 IP。

同一檔案、時間與 ProcessInfo 只有一筆登入失敗及一筆對應錯誤標頭時，補上 `error_number`、`severity`、`error_state` 及 `error_header`。若無法明確配對或格式不同則保留 NULL，不猜測；原始登入失敗訊息仍保存。合法的同時重複失敗訊息不會用 DISTINCT 刪除。

稽核設定必須包含失敗登入，目前已確認為 `failure`。SP 只檢查，不修改設定。此功能收集 SQL Server 的登入失敗，不收集 Windows／RDP 的登入失敗。

只能收集尚未被清除的 ERRORLOG；每日收集無法復原已輪替移除的記錄。讀取失敗會讓整次執行失敗，不會跳過檔案後宣告完整成功。封存檔案編號代表本次收集時的編號，日後輪替會改變。此版本未另外設定結果表的自動清除期限。

## 檔案及驗證

- `Deploy_DBAnalyzer_LoginFailed.sql`：明細、摘要、執行紀錄表、分類 View 與收集 SP。
- `../Jobs/Deploy_DBAnalyzer_Jobs.sql`：共用每日排程；步驟失敗重試後仍不成功則停止 Job。
- `Run_LoginFailed.sql`：執行、明細、彙總及執行紀錄查詢。

已以現有 ERRORLOG 驗證：2026-10-16 有 6 筆登入失敗，Error 18456、Severity 14、State 73，原因為 SSMS 使用已改名的 BlockingAnalyzer 資料庫。另於 2026-10-17 產生不存在帳號、密碼錯誤、停用帳號、指定不存在資料庫四種實際登入失敗，分析編號 8 正確收集分類，測試帳號已移除。

## 摘要分類

每個「日期＋failure_category＋Error＋State」一列；無事件的日期沒有摘要列，請看執行紀錄確認當日是否已成功收集。`failure_count` 是失敗訊息筆數；`affected_login_count`、`affected_client_count` 只計算非 NULL 且非空白的可識別帳號／來源。帳號或來源可能跨分類重複，不宜直接加總成全日唯一數。

|failure_category|意義|
|---|---|
|DATABASE_ACCESS_FAILED|無法開啟或存取指定資料庫|
|LOGIN_NOT_FOUND|登入名稱不存在或無效|
|PASSWORD_MISMATCH|密碼不符或無效|
|LOGIN_DISABLED|原因文字明確指出帳號停用|
|LOGIN_DISABLED_OR_BAD_PASSWORD|State 7：停用與密碼錯誤的複合狀況|
|PASSWORD_EXPIRED|密碼過期|
|PASSWORD_CHANGE_REQUIRED|必須變更密碼|
|ACCOUNT_LOCKED|帳號被鎖定|
|AUTHENTICATION_MODE_MISMATCH|原因文字指出僅允許 Windows 驗證|
|AUTHENTICATION_METHOD_MISMATCH|使用 SQL 驗證嘗試登入 Windows 帳號|
|AUTHENTICATION_CONFIGURATION|State 58：驗證設定問題，無法單憑 State 限定根因|
|SERVER_ACCESS_FAILED|伺服器存取或驗證檢查失敗|
|WINDOWS_AUTHENTICATION_FAILED|不受信任網域、SSPI 或 Windows 驗證問題|
|CONTAINED_USER_SID_MISMATCH|State 62：包含資料庫的帳號 SID 問題|
|OTHER|沒有足夠資訊明確分類|

分類先依原因文字，再依明確的 Error／State；State 回退規則限定 Error 18456。State 73 不直接假定為資料庫問題，本次 6 筆是根據 `Failed to open the database` 文字分類。摘要提供的是診斷分類，不代表已驗證具體根因；原文仍應保留查核。

規則參考 [Microsoft Error 18456 文件](https://learn.microsoft.com/en-us/sql/relational-databases/errors-events/mssqlserver-18456-database-engine-error?view=sql-server-ver17)。以 20 組暫存測試資料驗證分類，並以四種實際登入失敗驗證收集與摘要；排程已合併至每日 02:00 的共用 Job。

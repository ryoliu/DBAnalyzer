# DBAnalyzer GUI 部署

將整個 DBAnalyzer 資料夾複製到部署電腦，保留子資料夾結構。

## 使用方式

1. 雙擊 **Deploy_GUI.cmd** 開啟部署視窗。
2. 在 **SQL Server Instance** 輸入目標，例如：
   - WIN2019LAB
   - WIN2019LAB\LAB2
   - tcp:192.168.56.104,1433
3. Lab 使用自簽憑證時，勾選 **Trust server certificate**。
4. 畫面會列出 **WhoIsActive、Blocking、LoginFailed、LongRunning、HighResource**。按 **Deploy** 依序佈署全部項目，下方會顯示執行進度及成功／失敗訊息。

使用目前 Windows 程序的帳號進行 Windows 驗證，該帳號須有 SQL Server sysadmin 權限。Instance 輸入框不會變更登入身分。

建議在 SQL Server VM 內使用 Administrator 開啟 GUI。若要從目前電腦使用 VM 帳號連線，可先執行：

```powershell
runas /netonly /user:WIN2019LAB\Administrator "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\DBAnalyzer\Deploy_GUI.ps1"
```

輸入密碼後會開啟 GUI，不會將密碼存入檔案。在 Instance 輸入 VM IP，例如 tcp:192.168.56.104,1433。

## 檔案

|檔案|用途|
|---|---|
|Deploy_GUI.cmd|雙擊開啟 GUI|
|Deploy_GUI.ps1|Instance 輸入、部署按鈕、進度與結果畫面|
|Deploy.ps1|執行環境檢查及 SQL 的部署核心|
|Check_Environment.sql|SQL 環境檢查，可單獨於 SSMS 執行|

GUI 在背景執行 Deploy.ps1，不會顯示額外 PowerShell 視窗。執行期間按鈕與 Instance 輸入框會暫停操作，完成後恢復。詳細紀錄存於 DeploymentLogs，畫面底部也會顯示該次紀錄路徑。

功能與共用排程集中放在 `Features`：

```text
DBAnalyzer/
  Features/
    WhoIsActive/
    Blocking/
    LoginFailed/
    LongRunning/
    HighResource/
    Jobs/
  Deploy_GUI.cmd
  Deploy_GUI.ps1
  Deploy.ps1
  Check_Environment.sql
  AGENTS.md
  README.md
  DeploymentLogs/
```

## 部署順序

1. Features/WhoIsActive/Deploy_WhoIsActive.sql：缺少時建立收集資料庫與表。
2. Features/WhoIsActive/WhoIsActive_11_Deployment_In_Once.sql：只擷取 SP 批次，缺少時安裝。
3. Features/WhoIsActive/Deploy_WhoIsActiveJob.sql：缺少時建立每分鐘收集及保留 7 天的 Job。
4. Check_Environment.sql
5. Features/Blocking/Deploy_DBAnalyzer_Daily.sql
6. Features/LoginFailed/Deploy_DBAnalyzer_LoginFailed.sql
7. Features/LongRunning/Deploy_DBAnalyzer_LongRunning.sql
8. Features/HighResource/Deploy_DBAnalyzer_HighResource.sql
9. Features/Jobs/Deploy_DBAnalyzer_Jobs.sql

SQL 發生錯誤會停止並顯示檔名與批次。已完成的 SQL 不會整套回滾，修正後可重新部署。部署時請避開排程執行時間。

## 前置條件

- Windows PowerShell 5.1 或更新版本，不需額外模組或 sqlcmd。
- SQL Server 2019 或更新版本，執行帳號有 sysadmin 權限。
- SQL Server Agent 已啟動。
- WhoIsActive 原始佈署檔須保留在套件中。首次安裝會建立收集環境；已有的收集 Job 必須啟用且具有啟用中的排程。
- 登入稽核包含 failed logins，目前解析版本使用英文 ERRORLOG。

套件建立 WhoIsActive 收集環境、DBAnalyzer、分析物件及排程，不加入應用程式執行鎖，也不立即重算日報。既有 WhoIsActive 表、SP 與收集 Job 保留，不覆寫原本的收集參數及頻率。

WhoIsActive 沿用提供的 v11.32 原始碼及授權。GUI 不直接執行整份舊版安裝檔，避免其中刪除資料表及重建 Job 的操作；也不執行舊版安裝檔中的輔助函式、測試採樣及既有資料庫設定變更。

## 排程

|功能|目標伺服器當地時間|
|---|---|
|WhoIsActive 收集（首次安裝預設）|每分鐘，保留 7 天|
|`_DBAnalyzer-Daily`：依序分析前一天 Blocking、登入失敗、長時間 SQL、高資源 SQL|每日 02:00|
|Blocking 清除 30 天前日報|每日 03:10|

每日分析 Job 有四個步驟，各自失敗最多重試 3 次、間隔 1 分鐘；仍失敗則停止 Job。部署會將既有 Blocking Job 改名並保留其歷史，移除原本 LoginFailed Job 及其 Job 歷史；DBAnalyzer 中的分析資料與執行紀錄保留。

長時間 SQL 預設門檻為 300 秒，將同一 Request 的採樣合併成一筆，排除閒置連線與系統背景工作。說明及手動執行範例見 `Features/LongRunning` 資料夾。

高資源 SQL 分別保留 CPU 及邏輯讀取量前 20 名，以同一 Request 的累計採樣最大值排名，不重複加總。說明及查詢範例見 `Features/HighResource` 資料夾。

## SQL 可讀性

分析 SP 以具名暫存表分開擷取、彙總、排名及寫入，登入錯誤標頭使用具名位置解析；每日 Job 將新建與既有步驟的共同設定集中在同一處。Blocking 樹與事件切段、分類規則、交易及錯誤處理保留必要邏輯，WhoIsActive 目錄不修改。

已使用同一份採樣快照比對 11 組新舊分析結果與執行計數；排除執行編號、流水號及執行時間後結果一致。另比對 Job 首次建立及既有 Job 更新後的步驟、擁有者、頻率、重試及失敗處理設定。

## 命令列方式

仍可直接執行部署核心：

```powershell
C:\DBAnalyzer\Deploy.ps1 -ServerInstance 'WIN2019LAB' -TrustServerCertificate
```

已驗證 GUI 的空白輸入檢查、Instance／憑證參數傳遞、背景執行、執行中關閉保護、成功與失敗狀態。每日分析已合併為一個 Job，歷史清除維持獨立 Job。

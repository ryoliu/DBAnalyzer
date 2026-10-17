# DBAnalyzer GUI 部署

將整個 SqlAddm 資料夾複製到部署電腦，保留子資料夾結構。

## 使用方式

1. 雙擊 **Deploy_GUI.cmd** 開啟部署視窗。
2. 在 **SQL Server Instance** 輸入目標，例如：
   - WIN2019LAB
   - WIN2019LAB\LAB2
   - tcp:192.168.56.104,1433
3. Lab 使用自簽憑證時，勾選 **Trust server certificate**。
4. 按 **Deploy**，下方會顯示執行進度及成功／失敗訊息。

使用目前 Windows 程序的帳號進行 Windows 驗證，該帳號須有 SQL Server sysadmin 權限。Instance 輸入框不會變更登入身分。

建議在 SQL Server VM 內使用 Administrator 開啟 GUI。若要從目前電腦使用 VM 帳號連線，可先執行：

```powershell
runas /netonly /user:WIN2019LAB\Administrator "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\SqlAddm\Deploy_GUI.ps1"
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

## 部署順序

1. Check_Environment.sql
2. Blocking/Deploy_DBAnalyzer_Daily.sql
3. LoginFailed/Deploy_DBAnalyzer_LoginFailed.sql
4. Jobs/Deploy_DBAnalyzer_Jobs.sql

SQL 發生錯誤會停止並顯示檔名與批次。已完成的 SQL 不會整套回滾，修正後可重新部署。部署時請避開排程執行時間。

## 前置條件

- Windows PowerShell 5.1 或更新版本，不需額外模組或 sqlcmd。
- SQL Server 2019 或更新版本，執行帳號有 sysadmin 權限。
- SQL Server Agent 已啟動。
- MS_PERF_COLLECTION.dbo.sp_WhoIsActive、WHOISACTIVE 表及收集排程已建立並啟用。
- 登入稽核包含 failed logins，目前解析版本使用英文 ERRORLOG。

套件建立 DBAnalyzer、分析物件及排程，不安裝 WhoIsActive 收集環境，不加入應用程式執行鎖，也不立即重算日報。

## 排程

|功能|目標伺服器當地時間|
|---|---|
|`_DBAnalyzer-Daily`：依序分析前一天 Blocking、登入失敗|每日 02:00|
|Blocking 清除 30 天前日報|每日 03:10|

每日分析 Job 有兩個步驟，各自失敗最多重試 3 次、間隔 1 分鐘；仍失敗則停止 Job。部署會將既有 Blocking Job 改名並保留其歷史，移除原本 LoginFailed Job 及其 Job 歷史；DBAnalyzer 中的分析資料與執行紀錄保留。

## 命令列方式

仍可直接執行部署核心：

```powershell
C:\SqlAddm\Deploy.ps1 -ServerInstance 'WIN2019LAB' -TrustServerCertificate
```

已驗證 GUI 的空白輸入檢查、Instance／憑證參數傳遞、背景執行、執行中關閉保護、成功與失敗狀態。每日分析已合併為一個 Job，歷史清除維持獨立 Job。

# 每日資料表筆數、容量與增長

`analyzer.usp_CaptureTableRowCount` 擷取所有使用者資料庫中資料表的中繼資料估計筆數與 `UsedMB`，排除 `DBAnalyzer`、`MS_PERF_COLLECTION`、系統資料庫及資料庫快照。新建的使用者資料庫會自動納入，不需要逐一設定名稱。

|物件|用途|
|---|---|
|`analyzer.TableRowCountSnapshot`|每個日期、每個資料表的筆數及 UsedMB 快照|
|`analyzer.TableRowCountRun`|執行狀態、資料庫數、表數、筆數／容量缺值表數及錯誤|
|`analyzer.vTableRowCountGrowth`|與前一份有效快照比較的筆數與容量淨增減|
|`analyzer.vTableRowCountGrowthSummary`|第一份至最後一份有效快照的筆數及容量平均每日增長|
|`analyzer.vTableRowCountForecast`|最近 30 個日曆日期的筆數趨勢，估算最新快照之後 7 天及 30 天的筆數|
|`_DBAnalyzer-Daily` 第 5 步|每日 VM 當地時間 00:00～23:59:59 每 10 分鐘執行，前四步成功後更新當天快照|

## 執行與日期

`Run_TableRowCount.sql` 包含手動擷取及查詢範例。SP 參數只有 `@ReturnResults`（預設 1）及 `@CaptureRunId OUTPUT`。Job 使用 `@ReturnResults=0` 只寫表。

這是執行當下的快照，以 VM 當地日期記錄；前四個分析步驟處理當天截至各步驟執行開始時的累積資料，快照則記錄擷取當下的狀態。本 SP 不提供歷史日期參數，無法事後還原昨天的筆數。同日重跑會取代當天快照，執行紀錄則持續保留。

## 取得筆數與 UsedMB

使用 `sys.dm_db_partition_stats`：筆數只加總 `index_id IN (0,1)` 的 Heap／Clustered Index 各分割區；UsedMB 則加總此表所有索引分割區的 `used_page_count`，每頁 8 KB，除以 128 換算成 MB。兩者分別計算，不會因新增非叢集索引而把筆數重複算入。

UsedMB 包含這些分割區的資料頁、索引、LOB 與 Row-overflow 已使用頁面，不再另外加總 LOB，以免重複計算。保留七位小數，可完整表達單頁 0.0078125 MB。這是已使用頁面容量，不是 ReservedMB、資料庫檔案大小或交易記錄大小，也不包含 FILESTREAM 等非分割區頁面儲存。定義參考 [Microsoft 文件](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-partition-stats-transact-sql?view=sql-server-ver17)。

筆數仍為估計值，不執行 COUNT_BIG 全表掃描。筆數不變時，索引新增、欄位資料長度或儲存配置改變，都可能讓 UsedMB 改變。

一般空表筆數記為 0，但若仍有已使用頁面，UsedMB 可大於 0。記憶體最佳化資料表或無法取得中繼資料時保留 NULL，不當成 0；筆數缺值計入 `unavailable_table_count`，容量缺值計入 `unavailable_size_table_count`。

若任何目標資料庫離線或讀取失敗，整次執行記錄 FAILED 與失敗資料庫，不取代當天原有快照。全部資料庫讀完後才用交易 DELETE／INSERT，避免把部分結果當成完整快照。資料庫與資料表之間不是同一個交易時間點，請以各筆 `captured_at` 判讀。

## 平均增長算法

- 兩次快照淨增減：本次筆數減前次有效筆數。
- 區間平均每日淨增長：兩次淨增減除以相隔的日曆天數。
- 整體平均每日淨增長：最後有效筆數減第一份有效筆數，再除以兩份快照相隔的日曆天數。
- 平均值保留三位小數，負值表示筆數淨減少。這是淨增減，無法分別計算 INSERT／DELETE 次數。

容量使用相同算法，但只採用 UsedMB 有值的日期，與筆數的有效日期各自獨立：

- 明細：`net_used_mb_change`、`size_elapsed_days`、`avg_daily_used_mb_growth`。
- 摘要：`first_used_mb`、`last_used_mb`、`total_used_mb_growth`、`size_elapsed_days`、`avg_daily_used_mb_growth`。
- 容量日期與筆數日期可能不同，請同時查看 `first_size_snapshot_date`、`last_size_snapshot_date`。
- 容量平均保留七位小數，負值表示已使用容量減少。刪除資料不一定立即釋放頁面，容量也不一定與筆數同步下降。

例如 1 日 100 筆、2 日 130 筆、4 日 190 筆：2 日至 4 日增加 60 筆、相隔兩天，平均每日增加 30 筆；整體也為 `(190 - 100) / 3 = 30`。漏跑的日期不會補造快照。

只有一份有效快照時，平均值為 NULL，等待後續日期資料；同一天重跑不會產生第二天的增長。

升級前的快照沒有 UsedMB，會保留 NULL，不以目前容量回填歷史，也不回填成 0。容量平均從第一份有效容量快照開始計算。

使用 database ID、database GUID、table object ID 與建表時間辨識同一張表。改名會延續歷史，刪除重建則建立新的基準。已刪除的表仍保留歷史摘要，請看 `last_snapshot_date`，不要把歷史摘要當成目前資料表清單。

未加入自訂執行鎖，手動擷取應與排程錯開。此功能尚未設定自動清除快照或執行紀錄。

## 筆數線性估算

`analyzer.vTableRowCountForecast` 是查詢 View，不另外收集或儲存預測結果，也不修改既有平均增長 View。使用 VM 當地今日及前 29 個日期的快照；較早與未來日期不納入。僅列出這個範圍內最新一批快照中的資料表，因此已不在最新快照清單中的舊表不會繼續顯示。若最近 30 個日期都沒有快照，回傳空結果。

同一張表仍以 database ID、database GUID、table object ID、建表時間識別。改名延續趨勢並顯示最新名稱；刪除重建或資料庫 GUID 改變時分開計算。

```text
Daily growth = (Last valid row count - First valid row count) / Elapsed calendar days
Estimated rows = MAX(0, Latest row count + Daily growth * Forecast days)
```

只使用區間首末有效值計算每日淨增長，不對各區間成長率直接取平均，也不擬合迴歸線。中間波動不反映在預測中；漏跑日不補造資料，仍使用實際相隔日曆天數作分母。

至少兩個不同日期的有效筆數才能估算。中間筆數為 NULL 的快照跳過，但若最新快照筆數未知，整筆估算保持 NULL，不拿舊筆數冒充最新筆數。筆數為零屬於有效資料。每日淨增長保留六位小數，估算筆數四捨五入至整數，以 decimal(28,0) 回傳，負值歸零；每日淨增長本身保留負值。

|欄位|說明|
|---|---|
|`snapshot_count`|最近 30 個日期內，有效筆數快照的數量|
|`first_snapshot_date`|第一份有效筆數的日期|
|`last_snapshot_date`、`captured_at`|最新一批快照日期與該表擷取時間|
|`snapshot_age_days`|最新快照距 VM 當地今日的日曆天數|
|`observed_days`|第一份至最後一份有效筆數的相隔天數|
|`first_row_count`、`last_row_count`|區間第一個有效筆數與最新快照筆數|
|`avg_daily_net_growth`|區間平均每日淨增長；資料不足或最新筆數未知時為 NULL|
|`forecast_status`|`ESTIMATE`、`INSUFFICIENT_HISTORY` 或 `UNKNOWN_COUNT`|
|`forecast_date_7d`、`estimated_row_count_7d`|最新快照之後 7 天的目標日期與估算筆數|
|`forecast_date_30d`、`estimated_row_count_30d`|最新快照之後 30 天的目標日期與估算筆數|

預測日期從最新快照起算，不從查詢當日開始算。快照過期時仍顯示原基準日期的估算，請搭配 `snapshot_age_days` 與目標日期判讀。`ESTIMATE` 僅代表資料足以計算，不代表已驗證準確度；尤其只有兩份快照、觀察一天時，只是在延伸一天的淨增減。定期清檔、大批匯入、成長模式改變均可能使推估偏離實際。

```sql
SELECT database_name,schema_name,table_name,forecast_status,
 first_snapshot_date,last_snapshot_date,snapshot_age_days,snapshot_count,observed_days,
 last_row_count,avg_daily_net_growth,
 forecast_date_7d,estimated_row_count_7d,forecast_date_30d,estimated_row_count_30d
FROM MS_PERF_COLLECTION.analyzer.vTableRowCountForecast
ORDER BY estimated_row_count_30d DESC,database_name,schema_name,table_name;
```

## 驗證

已在 WIN2019LAB 擷取 Core、Monitor、BlockingTestLab，共 3 個資料庫、14 張資料表，排除監控資料庫。同日重跑沒有累加快照。平均值另以暫存資料驗證漏跑、資料減少、改名、重建、第一天空表及未知筆數；未在正式資料表製造歷史筆數。

UsedMB 已驗證筆數不變而容量增加、容量減少、歷史容量缺值及獨立日期區間。另建立含 LOB 的 100 筆測試表，新增非叢集索引後筆數仍為 100，UsedMB 從 0.9765625 增為 0.9921875，正確包含索引的 2 個使用頁面與 123 個 LOB 使用頁面。測試表已移除，正式當日快照已重新擷取。

2026-10-20 已在 WIN2019LAB 的隔離 tempdb schema，以實際 View 定義驗證 30 日期邊界、漏跑、缺值、單份歷史、負成長、空表、小數四捨五入、大筆數、改名、資料表／資料庫重建、舊表排除、未來日期、過期快照及空歷史。測試交易已回滾，測試物件已清除。

測試通過後只部署新增的 `vTableRowCountForecast`。既有 28 筆快照、9 筆執行紀錄，以及收集 SP 與兩個成長 View 的定義雜湊部署前後相同；未執行收集。實際回傳 14 張表，每張表有 2026-10-18、2026-10-19 兩份快照，觀察跨度均為 1 天，尚非 30 天的歷史樣本。部署紀錄保存於 `DeploymentLogs/TableRowCountForecast-20261020T045948437Z/`。

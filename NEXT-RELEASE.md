# 補貨流程更新：啟用與驗收

目標：沿用現有 App、life-tools、household 與會員權限。004 已於 2026-10-04 由使用者確認成功，正式資料庫 catalog 與安全回歸亦已核對；前端資產版本為 v5，發布狀態以 GitHub Pages 部署結果為準。

## 使用方式

- 待購數量：進入「該買了」預設 ×1，以 −／＋調整到 1～999。每次操作等待雲端確認，失敗時不假裝已儲存。數量不是庫存，不記錄消耗。取消待購或已補貨後重設為 1。新補貨歷史保存本次 `purchased_quantity`，舊歷史不猜數量。
- 還很多：可能快沒了／順便補卡片一鍵延後 7 天，不改補貨日期、不插入補貨歷史。期間仍可從一般品項標記快沒了；標記快沒了、取消待購或補貨會清除延後欄位。編輯名稱／分類／途徑保留延後。
- 順便補：選擇具名購買途徑時，原第二區改為「可能可以順便補」，包含已達提醒門檻與未來 7 天內將達門檻的品項。只取搜尋＋分類＋該途徑交集，排除延後期間與已待購品項。選「全部」或「尚未設定」仍顯示原本「可能快沒了」。不建立第二個購物頁，也不自動改狀態。
- 最近動態：首頁下方預設收合，各家庭最近 20 筆。記錄新增、編輯（含來源編輯）、待購、補貨、還很多、取消待購、封存。數量每次加減不記動態，避免噪音。使用者只看到你／另一位成員／先前成員，不讀取其他成員 Email。
- 一般卡片略減 padding；48px 按鈕範圍不變。底部增加 safe spacing。常用品整個標題按鈕本來就可點，保留原實作。

## 預測選擇

原本各不同 UTC 日期補貨間隔的 arithmetic mean 用於 80% 提醒。現在原始歷史／平均不變，預測與 80% 提醒改用間隔中位數。同一 UTC 日只合併「計算用」的日期，原始歷史保留。

| 方法 | 35、38、80、37 天 | 少量資料的取捨 |
| --- | --- | --- |
| 算術平均 | 47.5 天 | 單次囤貨拉長預測 |
| 中位數（採用） | 37.5 天 | 無需選權重，對單一極端值穩定 |
| 去掉最高最低的 trimmed mean | 37.5 天 | 需決定何時開始修剪；2～3 段不適合丟樣本 |
| 依時間順序權重 1、2、3、4 | 49.9 天 | 最近極端值仍會被放大，權重任意且較難解釋 |

沒有兩個不同日期就不預測；只有一段間隔標為「初步估計」。歷史視窗顯示中位數估計、原始平均與間隔筆數。待購數量不拿來推算消耗量或庫存。

## 執行 migration

1. Supabase Dashboard → Organization「奇妙小東西」→ Project「life-tools」→ 左側 **SQL Editor** → **New query**。
2. 打開 `supabase/004_restock_flow.sql`，複製整份（含 BEGIN 到 COMMIT），貼入，以預設 postgres 身分按 **Run**。不要重新執行 001／002／003。
3. 成功後回覆「004 SQL 已成功」。失敗請貼錯誤，不要選取部分重跑；本 migration 不是重複執行用的腳本。
4. 確認後再核對 schema、執行 `supabase/security-check-flow.sql` 及既有 security-check-sources.sql 的角色／JWT 回歸；驗收完才發布前端。安全驗收只建立帶 __FLOW_TEST_ 名稱的暫時資料，最後 ROLLBACK，不更動現有用品或 Auth。

官方 SQL Editor／Function 操作：[Supabase Database Functions](https://supabase.com/docs/guides/database/functions)。RLS 原則：[Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)。

### Schema／權限影響

- `restock_items`：新增 `purchase_quantity integer NOT NULL DEFAULT 1`（1～999）及 `snoozed_until timestamptz`。既有品項取得 1／NULL；名稱、狀態、ID、版本、補貨日期不被更新。
- `restock_history`：新增 nullable `purchased_quantity`；既有歷史保持 NULL，未填假的購買數量。
- `restock_activity`：獨立家庭動態表、item_name 快照、actor_id、事件、時間與可選數量。新增 household＋日期＋ID index、家庭成員 SELECT RLS。新表沒有前端 INSERT／UPDATE／DELETE 權限，anon 無讀寫。
- 新 RPC：`restock_set_purchase_quantity(uuid,bigint,integer)`、`restock_snooze_item(uuid,bigint)`。兩者都有 auth.uid、會員列鎖、item 列鎖、封存及 version 檢查；不允許跨家庭、NULL／過期 version。
- 既有 `restock_add_item`／`restock_update_item`／`restock_delete_item`／`restock_change_item` 維持簽章，加入同交易動態；補貨／取消待購重設數量與 snooze。sources 版新增／編輯 RPC 繼續呼叫原基礎 RPC，無效來源會一起回滾動態。
- `restock_snapshot` 維持 SECURITY INVOKER／原 RLS，schema_version=4，增加每家庭最近 20 筆 activity。
- 無 DROP／TRUNCATE、無重建、無 Auth／life_ 共用表變更，原 RLS 及表寫入限制不放寬。暫時鎖表失敗會回滾，鎖等待上限 5 秒。

### 回退

若 migration 發生錯誤，交易會回滾，若 Dashboard 仍在失敗交易請先另開 query 執行 ROLLBACK；停止並提供錯誤。

若 migration 成功但需暫停新功能：先將網站回到原 `91defb9` 版本，再由管理者執行 `supabase/rollback-004-preserve-data.sql`。這是「功能回退」：恢復原 RPC／schema_version=3，撤銷兩個新 RPC 與 activity 表的前端權限；保留所有新欄位、新補貨數量與動態資料，不 DROP／清空。不直接重跑 004，重新啟用需另行產生相容腳本。

## 本機驗證／待正式驗證

- Node 測試 25/25、app.js 語法檢查通過：原 17 項＋中位數極端值、少量紀錄、7 天到期邊界、順便補交集／無重複、操作者／20 筆限制與跨月時間。
- 45 品項、共享記憶體模擬後端：A 加減 1→2→3→2，B 讀取 2、加到 3，A 同步看到；A 補貨歷史保留 ×3、再次待購 ×1。
- A 還很多前後洗衣精兩筆歷史一致、上次日期不變；提示移到一般區並顯示再評估日期。選好市多只推薦洗衣精與廚房紙巾；紙巾可直接轉待購 ×1，B 補貨後 A/B 動態操作者顯示不同但正確。
- UI 模擬之外，004 已在正式資料庫完成。security-check-flow.sql 的全部斷言與 security-check-sources.sql 已通過；測試交易完整 ROLLBACK，核對無測試品項殘留。確認新 activity RLS 啟用、anon 無 SELECT、authenticated 無直接 INSERT／UPDATE／DELETE、新 RPC anon 無 EXECUTE。
- 真正 iPhone Safari、主畫面 safe area／鍵盤、多支手機的正常網路及同時操作仍待人工驗收。
- 模擬 B 編輯草稿遇 A 數量變更時，草稿保留、儲存停用；新增多途徑／待購數量、具名刪除確認／取消／封存、編輯保留數量通過。手機文件375px無橫向溢出、數量按鈕48px、標題整列可點，滑到底最後卡片可完全顯示於浮動新增按鈕上方。

## 已知限制與刻意延後

- RPC 每次加減一次雲端請求；沿用全頁寫入鎖，避免連按／靜默覆寫，不新增離線待同步隊列。
- 近期提醒由裝置時鐘計算，7 天 snooze 截止由資料庫時間決定。裝置時間嚴重不準可能影響前端預測。
- 動態只顯示 20 筆，但資料庫保留事件；沒有自動清理／無限瀏覽，未來量大時再定保存策略。
- 平均／中位數使用所有補貨間隔；日後生活習慣明顯改變，可能考慮最近有限段中位數，但本版不引入任意窗口。
- 無預先回填舊動態；舊補貨數量未知保持 NULL。
- 尚未做封存還原、成員暱稱、精確庫存、剩一些、AI、價格、GPS、通知、聊天或統計頁。

# 刪除購買途徑（006 已完成）

## 現況與範圍

已在正式資料庫只讀核對：`restock_item_sources(source_id,household_id)` 指向 `restock_sources(id,household_id)` 的 FK 是 ON DELETE CASCADE。只有來源的關聯被連帶移除；用品／歷史沒有指向來源的 FK。不需要改 FK。
首頁購物 chips 不加刪除按鈕；僅管理介面顯示「改名／刪除」。二次確認顯示來源名稱、目前用品數、不可復原與封存標籤也會移除。焦點預設取消。

## SQL 做什麼

1. 新增 `restock_delete_source(uuid,uuid,bigint,uuid[])`：檢查 auth.uid、會員、來源所屬家庭、source version、確認時的目前用品 ID 集合。
2. 來源被改名、數量改變或同數量但不同品項時拒絕刪除，要求重新確認。
3. 真正呼叫時刪來源、由 FK 清除其所有關聯；每個受影響品項 version +1，避免其他手機編輯舊標籤時無聲覆寫。只改 version，名稱、分類、數量、歷史、日期不動。
4. 更新原來源版新增／修改 RPC，使其在鎖品項前，依 ID 鎖定選擇的來源。與刪除的「來源→品項」鎖順序一致。原簽名、原會員／version驗證、來源驗證、原子性保持，其他 RPC 不改。
5. 原 RLS、table grants 不改；新 RPC 僅 authenticated 可執行。migration 本身不刪資料、不改 Auth／life_／其他 App。
6. 先核對 FK，若漂移到其他 child table 或不再 CASCADE，整份失敗。交易內錯誤不部分提交。

## 操作步驟

Supabase Dashboard → life-tools → SQL Editor → New query。
開啟 `supabase/006_delete_purchase_sources.sql`，貼上全文，以 postgres 角色按 Run。先完成 005；不要重跑 001～005。
成功回報「006 SQL 已成功」；失敗貼錯誤訊息，不分段重跑。
本 life-tools 已完成 006；不要再執行。以下安裝說明僅供尚未啟用的其他環境參考。
SQL 確認成功後，才執行最後 ROLLBACK 的 `security-check-delete-sources.sql`，驗收後部署原 GitHub Pages。

## 回退／復原

安裝出錯會整筆回滾。若提交後需要停用，先退前端至 v6，再撤銷新刪除 RPC 的 authenticated EXECUTE；更新後的來源儲存 RPC 可保持，其原介面相容，不必破壞既有資料或 RLS。
已由使用者確認刪除的來源與關聯不能藉由功能回退還原。可以手動重建來源並重新勾選品項；精確復原需資料備份。006 不加入恢復／垃圾桶功能。
不要使用 rollback-004-preserve-data.sql，它與本次功能不相容。

## 本次檔案

- app.js：管理刪除、取消優先確認、同步期間衝突偵測、成功／錯誤重新整理。
- index.html：刪除確認 dialog、v7 資產版本。
- styles.css：管理列名稱可換行、操作按鈕48px觸控目標。
- list.mjs：目前用品使用數集合與來源消失後篩選回全部。
- tests/sources.test.mjs：數量、家庭隔離、封存排除、三條件交集及同步回退。
- supabase/006_delete_purchase_sources.sql：增量 RPC migration。
- supabase/security-check-delete-sources.sql：正式啟用後的交易回滾驗收。

不改登入、歷史、週期預測、九分類、首頁主要補貨按鈕。新功能影響管理頁與來源選擇／篩選同步。
資料庫實際刪除、A/B快照與權限驗收待 SQL 成功；實際兩手機10秒同步、iPhone Safari、真實並行操作需另外驗收，不將純函式測試當成實機通過。
2026-10-06：使用者確認 006 成功。正式 security-check-delete-sources.sql 通過並完整 ROLLBACK：空來源／有品項來源刪除、品項／封存／歷史／其他關聯保留、版本衝突、B 快照、跨家庭／非成員／anon／直接 table DELETE 拒絕。原 security-check-sources.sql 回歸亦通過並回滾。測試品項、来源與 household 殘留均為 0。
正式確認 sources／links 的 RLS 啟用、authenticated 無直接 DELETE、三個 RPC 匿名不可執行且固定空 search_path。
本機 29/29 自動測試與 app.js 語法檢查通過。先前預覽連線問題已排除；390px 模擬資料測試確認使用數量23、取消不刪除、確認後來源從管理與 chips 消失，45 個用品保留，頁面375px無橫向溢出。截圖不含正式家庭資料。
實際 iPhone Safari、兩手機10秒同步、兩交易同時操作仍需實測；資料庫角色／快照驗收不等於實機驗收。

# 使用分類更新（005 已完成）

新分類：浴廁、清潔、廚房、食品常溫、飲料、冷藏、冷凍、個人用品、其他。
廚房維持用品用途；購買途徑仍是獨立的多選關聯。

## 執行方式

Supabase Dashboard → life-tools → SQL Editor → New query。
將 `supabase/005_usage_categories.sql` 全文貼上，使用 postgres 角色按 Run。
不要分段執行，也不要重跑 001～004。請先確認 004 已完成。
本 life-tools 已於 2026-10-06 完成 005，無需重跑。以下執行步驟僅供其他尚未升級環境參考。
執行期間可暫停操作 App，完成與部署後兩支手機重新載入。

## 資料影響

- 整份在單一交易內，5 秒鎖等待／30 秒執行上限；遇到錯誤整筆不提交。
- 僅更換 `restock_items_category_check`，先移除舊 CHECK，再轉換食品，再建立新 CHECK。交易鎖保護中間狀態。
- 所有 household 的 `食品`（包含封存品項）轉為 `食品常溫`；受影響品項 version +1，避免舊編輯畫面無聲覆寫。
- 品項 ID、名稱、狀態、待購量、上次補貨日期、建立時間、snooze、封存狀態不變；其他分類與 version 不變。
- 品項前後資料在交易內逐列驗收，只允許預期分類／version 變更。
- 不讀名稱推測冷藏／冷凍；使用者部署後自行編輯。
- 不刪表、品項、歷史、來源、Auth 或 household；不改其他 App。
- 不新增／放寬 RLS，不開放直接 table UPDATE/DELETE。
- 更新 `restock_add_item`、`restock_update_item`，沿用原簽名、會員檢查、鎖、version、活動事件、authenticated 權限。
- 來源版 RPC 原樣透過這兩個 RPC 處理，因此來源關聯及原子性保持。
- 舊版手機傳入 `食品` 時，RPC 正規化為 `食品常溫`，資料庫不保留舊分類。舊版分類篩選仍需重新載入新網站才能完整顯示。

## 回退

交易內發生錯誤會回滾，不需要執行其他回退檔。若 SQL Editor 留在 aborted transaction，可另開 query 執行 `ROLLBACK;`，再回報錯誤。
提交後優先修正前端／RPC，不提供將九分類一律改回食品的自動回退，因為這會丟失使用者的新分類選擇。
若確實要回舊分類，需先備份並另外審核可保留分類對照的 SQL；不要執行 `rollback-004-preserve-data.sql`，它屬於上一版且會恢復舊的分類驗證。

## 檔案與驗收

- `list.mjs`：九分類共用清單及穩定排序。
- `app.js`：新增、修改、首頁 chips、浮動 select 共用清單；新增仍預設其他。
- `index.html`：移除重複硬編碼表單選項；前端載入 v6。
- `tests/list.test.mjs`：新分類搜尋／來源交集、狀態優先與穩定排序。
- `supabase/005_usage_categories.sql`：增量 migration。
- `supabase/security-check-categories.sql`：005 後執行，測試新增／編輯、A/B、權限、歷史及購買途徑，最後 ROLLBACK。

其他登入、歷史、購買途徑管理、預測程式不修改。沿用可水平滑動的 chips，不縮小文字、不加頁面。
2026-10-06 使用者執行 005 結果：69 個食品轉為食品常溫，153 個品項通過前後保留檢查。之後正式查詢確認總數仍為 153、舊食品值 0、新九分類 CHECK 生效。
本機已完成 27/27 自動測試與 app.js 語法檢查。
正式 security-check-categories.sql 驗收無錯誤並完整 ROLLBACK：新分類新增／編輯、同家庭 A/B 快照、歷史／日期／來源保留、過期 version 拒絕、非成員新增／修改／刪除拒絕、anon 與直接改表拒絕、舊食品輸入正規化皆通過。
RLS 啟用；authenticated 無直接 UPDATE/DELETE，anon 無 table SELECT。此驗收是資料庫角色與快照驗證，不是實際兩手機網路同步測試。
原生 iPhone Safari／主畫面、兩手機 10 秒同步仍需實機驗收。

部署後建議：先核對舊食品已轉為食品常溫；新增飲料，再將現有雞肉編輯成冷凍；選冷凍＋名稱＋好市多，標快沒了並補貨；另一支手機確認結果及歷史保留。

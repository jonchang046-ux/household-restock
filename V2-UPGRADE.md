# 現有補貨助手升級 v2

本次直接修改原 repository `jonchang046-ux/household-restock`。沿用原 GitHub Pages 網址、life-tools Project、帳號、家庭、品項與歷史；不新增另一個正式網站。

## 目前進度

2026-10-03：使用者已執行 002 migration，已核對正式欄位與 RPC，並透過 Supabase 連線執行 `security-check-v2.sql` 全部斷言成功、測試交易回滾。12 項本機測試通過。本次提交為原站的 v2 發布版本；實際雙手機／Safari 驗收仍待使用者完成。以下 migration 步驟保留供維護參考，現在不需重跑。

## 為何使用封存

已唯讀核對正式結構：`restock_history (item_id, household_id)` 指向 `restock_items (id, household_id)` 的外鍵是 `ON DELETE CASCADE`。直接刪除品項會失去歷史，故保留外鍵，讓 App 的刪除 RPC 只寫入封存時間。

- 新增 nullable `restock_items.archived_at`，既有列保持 NULL，仍為目前用品。
- 編輯只更新名稱、分類與 version，不更換 ID、不動日期及歷史。
- 刪除只寫入 archived_at、version，不實際 DELETE。保留品項可讓歷史繼續 JOIN 到有意義的名稱與分類。
- 首頁快照不傳回封存品項及其歷史；資料仍保存於原表，家庭成員的原有 RLS 讀取範圍保持不變。
- 尚無還原或封存歷史瀏覽介面。管理者的實體 DELETE 仍會 cascade，勿用它代替 App 封存。

## 第一步：執行完整 migration

1. Supabase Dashboard → Organization「奇妙小東西」→ Project **life-tools**。
2. 左側 **SQL Editor → New query**，確認專案 ref 是 `cbnnspstbkkacqmurwiu`。
3. 開啟 `supabase/002_restock_v2.sql`，複製**完整檔案**，包含 `begin;` 到 `commit;`，貼上並按 **Run**（postgres）。不要執行 001。
4. 成功後回覆「v2 SQL 已成功」。若錯誤，貼錯誤文字，先不要發布前端或反覆重跑。

SQL 不清空、不重建表，不更新既有業務列，不動 auth.users、life_ 表或其他 App。它新增欄位與本 App RPC、替換本 App 的快照及狀態 RPC。DDL 可能短暫鎖表；設有 5 秒鎖等待及 30 秒語句上限，整份交易成功才提交，失敗回滾。可重複執行且不覆蓋封存值。

## RPC 與 RLS

- 新增 `restock_update_item(uuid,bigint,text,text)`、`restock_delete_item(uuid,bigint)`。
- 每次寫入都檢查 auth.uid、item 所屬 household membership、未封存及相同 version；鎖定 item 並鎖住 membership 至交易結束。成功後 version + 1。
- 所有寫入 RPC 為 SECURITY DEFINER、空 search_path、完整限定資料表名稱；只授權 authenticated 執行。anon 與 PUBLIC 無 EXECUTE。
- 修改 `restock_change_item`，拒絕對已封存品項補貨或標記；原補貨與歷史交易邏輯不變。
- `restock_snapshot` 繼續 SECURITY INVOKER，沿用原有 RLS，只加上封存篩選。
- 不新增資料表 UPDATE／DELETE grant，不放寬或新增 RLS policy，不修改共用 Auth 設定。
- 過期版本被拒絕；編輯視窗保留草稿，明確按「捨棄輸入，載入最新資料」才能用新版重編。刪除若版本改變，必須取消並重新確認。

## 第二步：資料庫驗證與原站發布

migration 成功後，先在 SQL Editor 執行 `supabase/security-check-v2.sql`。此測試以既有兩位同家庭成員模擬 JWT，新增一筆暫時品項與歷史，最後 ROLLBACK；不碰既有品項、不建立或修改 Auth 使用者。它驗證 A/B 共享、版本拒絕、非成員與 anon 拒絕、直接表寫入被拒絕、編輯及封存保留歷史。成功應有 PASS notice；錯誤不得視為通過。這是資料庫角色測試，不是實際雙手機登入或同時交易壓測。

驗證成功後才將修改推送至**原 repository 的 main**，沿用既有 GitHub Pages 部署。沒有新套件或 build 流程；不需改 config.js、Auth URL 或重新建立帳號／家庭。舊前端在 migration 後仍可正常新增、標記與補貨。

## 第三步：兩支手機驗收

請另新增明確命名的「v2 測試品項」，避免改動日常品項。

1. A/B 原帳號登入同家庭；A 用「⋯ → 修改品項」改名及分類。B 等 10 秒或重新整理可見；B 再改，A 也可見。
2. A 開啟編輯並保留草稿，B 修改同品項。A 同步後應提示衝突、停用儲存；載入最新資料才可重編。即使同步前按儲存，伺服器也拒絕過期 version。
3. 搜尋「洗」；分別切清潔、廚房，確認名稱與分類同時限制，狀態區塊保留。清除篩選恢復全部；重新整理不打亂順序。
4. 標記快沒了、已補貨、查看「⋯ → 補貨紀錄」，再改名，原紀錄與週期仍在。
5. 刪除視窗應顯示正確名稱；按取消品項仍在。再次確認刪除後 A/B 都不再看到目前品項；SQL 測試負責驗證歷史仍在資料表。
6. 未加入此家庭的 C 不得看到家庭資料；RPC 越權拒絕由上述 SQL 回歸測試驗證。
7. iPhone Safari 與加入主畫面模式都測試：鍵盤輸入、橫向分類滑動、對話框取消與儲存、一鍵補貨。離線操作不得顯示成功。

## 檔案與影響範圍

| 檔案 | 變更 |
| --- | --- |
| index.html | 搜尋、分類列、品項操作／修改／刪除確認視窗 |
| styles.css | 沿用色系，新增手機可滑分類與次要操作樣式 |
| app.js | 編輯、封存 RPC、版本衝突提示與既有同步整合 |
| list.mjs | 前端搜尋、分類交集、分類／名稱／ID 穩定排序 |
| supabase/002_restock_v2.sql | 加欄位及本 App RPC，保留資料及原 RLS |
| supabase/security-check-v2.sql | migration 後執行的回滾式驗收 |
| tests/list.test.mjs | 搜尋、分類、排序、封存及週期回歸 |
| README.md、V2-UPGRADE.md、VALIDATION.md | 升級步驟、功能說明與驗證邊界 |

api.mjs、cycle.mjs、config.js、001 migration 與圖示保持原樣。只影響此 App 的清單與相關 RPC，不變更其他網站頁面或其他 App 資料。大量歷史分頁、封存還原、邀請、通知、AI、條碼及自動購物仍未加入。

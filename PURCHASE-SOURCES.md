# v2 擴充：購買途徑

狀態：2026-10-04 使用者確認 003 執行成功；正式 Supabase 回歸測試回傳 PASS，所有測試資料已回滾。本次提交為原站購買途徑發布版本，雙手機實測仍待完成。

## 使用方式

- 「使用分類」保留浴廁／清潔等用途分類。新增的「購買途徑」是獨立維度。
- 在「該買了」標題下直接選購買途徑；與首頁名稱搜尋、使用分類取交集，三個狀態區塊都套用相同條件。仍依原狀態、分類、名稱、ID 排序。
- 「全部」只清除途徑條件；首頁「清除篩選」同時清除三個條件。
- 「管理購買途徑」可新增或改名，例如全聯、好市多、附近藥局。清單來自該 household 的資料庫，前端沒有商店白名單、也不自動替家庭建立商店。
- 新增／修改品項依序填名稱、使用分類、購買途徑；途徑可多選或全部不選。已建立的選項可重複使用，表單內也能開啟管理視窗。
- 品項卡顯示途徑名稱。尚未設定者仍可新增、補貨、標記快沒了；另有「尚未設定」篩選可協助補齊。
- 本次提供來源新增與改名；沒有來源刪除／合併、店內排序、價格比較或各途徑獨立補貨週期。品項封存與既有補貨歷史照原規則保留。

## 資料與安全設計

`restock_sources` 保存 household、名稱、version、建立時間；同一家庭不允許大小寫及頭尾空白不同的重複名稱。其他家庭可有自己的同名途徑。

`restock_item_sources` 使用 `(item_id, source_id)` 主鍵，一筆一個關聯；兩組包含 household_id 的複合外鍵，從資料庫層阻擋跨家庭關聯。沒有逗號字串欄位，也沒有修改既有 restock_items schema 或其既有列。

新表啟用 RLS：僅 authenticated 家庭成員可 SELECT，anon 無權限，沒有直接 INSERT／UPDATE／DELETE 權限。寫入只經過以下 RPC，空 search_path、auth.uid 及 membership 檢查，明確撤銷 PUBLIC/anon EXECUTE：

- `restock_save_source`：新增或改名，改名使用 source version 防止覆寫。
- `restock_add_item_with_sources`：呼叫原新增流程後，在同交易保存多選途徑；任何無效途徑都使整筆新增回滾。
- `restock_update_item_with_sources`：沿用原 item 鎖、membership 鎖、封存與版本檢查，名稱／分類／關聯同交易儲存，version 只加一次，不更換 ID、不修改補貨歷史。
- `restock_snapshot`：沿用 SECURITY INVOKER 和 RLS，追加 sources 與 item_sources；封存品項的關聯留在表中但不回傳首頁。

舊 RPC 簽章與功能保持可用，舊版手機改名不會清除購買途徑。途徑改名不改來源 ID，所以所有關聯維持有效。來源改名及品項同時修改各自有版本保護。

## 需要你執行的 migration

1. Supabase Dashboard → **life-tools → SQL Editor → New query**。
2. 開啟 `supabase/003_purchase_sources.sql`，複製整份，包含 begin 到 commit；貼上以 postgres 按 **Run**。不要重跑 001 或 002。
3. 成功後回覆「購買途徑 SQL 已成功」。若失敗，貼上錯誤，先不要重試或發布前端。

SQL 只新增兩張 restock_ 表、索引、SELECT RLS、三個 RPC，並擴充本 App 快照。**不清空／重建既有表、不更新既有品項／歷史、不建立商店種子資料、不動 Auth 使用者、life_ 共用表或其他 App。**既有品項在沒有關聯的情況下自然顯示尚未設定。

整份使用交易，5 秒鎖等待、30 秒語句超時；失敗回滾。本次為一次性 migration；若已存在同名表會停止，不會靜默覆蓋。正式 SQL 成功後再驗證並發布原網站。

## 驗證狀態與待辦

- Node 17 項測試通過；原週期、登入、清單測試保留。新增測試覆蓋多途徑、三條件交集、未設定、家庭區分、改名保留關聯及排序穩定。
- 本機瀏覽器（模擬後端）已驗證：三條件只留下衛生紙、多選修改、新增自訂途徑後回到原表單、重用多個途徑、留空、A/B 同步、來源改名後原品項更新顯示、過期來源草稿停用儲存。
- 桌面 1280px 與 390px iframe 手機驗收通過：手機內容可用寬 375px，文件無橫向溢出；途徑 chips 可滑動，編輯視窗寬／內容寬皆為 335px。這是瀏覽器尺寸驗證，不是 iPhone 實機。
- 正式資料庫已執行完整 security-check-sources.sql 並回傳 PASS：家庭隔離、複合外鍵、匿名拒絕、直接寫入拒絕、多選、版本衝突、錯誤回滾、舊手機相容及歷史保存皆通過。這是資料庫角色／JWT 模擬驗證，不代表真實雙手機或並行交易壓測已完成。
- `supabase/security-check-sources.sql` 已提供：003 成功後驗證雙向共享、來源版本、item 版本、非成員／匿名拒絕、跨家庭來源及複合 FK、重複名稱、多選去重、錯誤回滾、清空途徑、舊手機相容、封存關聯與歷史保存。測試暫時新增品項、來源及另一個測試家庭，最後全部 ROLLBACK；不動既有品項或 Auth 使用者。
- 發布後仍需兩支手機：A 新增來源 → B 可見；A 為品項選兩個來源 → B 分別篩選都看得到；B 改來源名 → A 名稱更新；三條件交集；原快沒了／已補貨／紀錄；iPhone Safari 與主畫面模式。

## 修改檔案

| 檔案 | 修改重點 |
| --- | --- |
| index.html | 該買了途徑 chips、名稱／使用分類／多選表單、來源管理視窗、資產版本標記 |
| styles.css | 手機滑動 chips、多選按鈕、途徑名稱換行，保留原配色 |
| app.js | 家庭來源管理、多選 RPC、來源版本衝突、背景同步保留草稿 |
| list.mjs | 家庭來源查詢、關聯取值、三條件交集 |
| supabase/003_purchase_sources.sql | 非破壞性新增結構及限定 RPC |
| supabase/security-check-sources.sql | migration 後的回滾式資料庫驗收 |
| tests/sources.test.mjs | 五項來源與交集單元測試 |
| README.md、PURCHASE-SOURCES.md | 升級指引與測試邊界 |

沒有新增套件、沒有修改 build、沒有重建另一個正式網站。影響限於本 App 的品項清單、表單與快照。

# 驗證紀錄

日期：2026-09-29

## 已驗證

- Node 內建測試：7 項通過。涵蓋無歷史／單一日期、80% 提醒邊界、確定待購優先、同日補貨、不同品項隔離、不規則間隔、登入資料保存、並行 session 更新、登入失效清除及網路失敗保留重試資訊。
- JavaScript 語法檢查通過。
- 本機瀏覽器以模擬 Supabase 回應測試：登入、三組清單、已補貨移出待購並記錄日期、新增洗碗精直接加入待購、補貨紀錄視窗。瀏覽器沒有記錄前端錯誤。
- 390 × 844 手機尺寸視覺檢查：主要操作、卡片與新增按鈕可見。
- 使用你提供的 publishable key 對真實 Supabase 呼叫 `restock_snapshot`，未附使用者 JWT：回傳 HTTP 401，`permission denied for function restock_snapshot`，未取得資料。
- 使用者已確認 migration SQL 執行成功，兩個帳號建立且 Auto Confirm。

## 尚待驗證

- `supabase/security-check.sql` 完整資料庫權限回歸測試：檔案已提供，尚未取得執行結果。
- 真實帳號登入、共同家庭、兩支實體手機同步、同時補貨競態與非成員隔離：需部署後以帳號 A、B、C 驗收。
- 真實 iPhone Safari 加入主畫面後的行為。
- GitHub Pages 發布：等待目標 repository；目前提供部署檔案，不代表已上線。

模擬資料與測試伺服器存於工作目錄，不包含在部署資料夾或 ZIP，也不會寫入你的 Supabase。

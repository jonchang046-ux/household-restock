# 驗證紀錄

## 長清單介面優化：2026-10-04

- 僅修改 index.html、app.js、styles.css 與此驗收紀錄；無 schema、RPC、RLS、Auth 或正式資料變更，無新增套件。
- JavaScript 語法檢查、既有 Node 測試 17/17 通過。補貨週期、80% 提醒、分組排序、搜尋／分類／購買途徑交集維持原有模組。
- 本機使用真實前端與共享記憶體模擬後端、44 個品項：一般區預設收合、展開／再收合、搜尋及分類自動展開、三條件交集、清除篩選恢復使用者未篩選時選擇、重新整理保留手動收合皆通過。重新載入頁面恢復預設收合。
- 390px iframe 手機預覽（文件可用寬 375px）：一般無歷史卡片約 146px，主要按鈕保留 48px 觸控高度；無全頁橫向溢出。下滑約 1406px 後搜尋列仍在 top 0、高約 62px，家庭資訊／完整分類列已滑出；提示訊息位於搜尋列下方，不遮住搜尋。
- 桌面 viewport 1024px（文件可用寬 1009px）：無橫向溢出，一般無歷史卡片約 92px，仍有快沒了與已補貨。
- 模擬 A 的快沒了操作由 B 背景輪詢看到，B 可補貨；一般卡片→待購→補貨→歷史視窗正常。編輯視窗、具名刪除確認與取消保留品項正常，可能快沒了的平均 20 天提示仍在。前端 console 無 error。
- 以上是本機模擬與瀏覽器尺寸驗證，未操作正式 Supabase；本次未重跑正式 RLS／SQL 回歸。實體 iPhone Safari、主畫面 safe area、鍵盤出現後 sticky 行為及兩支手機仍需使用者驗收。

## v2：2026-10-03

- 首次 Pages 部署成功，公開 index.html／app.js／styles.css／list.mjs HTTP 200 且內容與發布檔一致。瀏覽器重新載入後觀察到舊程式快取（新視窗節點存在但分類按鈕未初始化），故 index.html 對 app.js 與 styles.css 加上 `?v=2`，避免新 HTML 搭配舊資產。

- 唯讀核對 GitHub 原始碼與正式 Supabase catalog：歷史外鍵 ON DELETE CASCADE、version、現有 RPC、SELECT-only grants 與 RLS。未執行正式資料變更。
- Node 內建測試 12/12 通過（既有 7 項、新增 5 項）；app.js 語法檢查通過。新增涵蓋部分名稱、搜尋與分類交集、無結果、NFKC、非目前家庭／封存排除、排序穩定及原陣列不變、編輯名稱不影響歷史週期。
- 本機兩個來源視窗使用共享記憶體模擬後端，載入真實前端檔案與 api.mjs。A 修改、B 讀取與反向修改通過；A 未儲存草稿遇到 B 更新後保留草稿、停用儲存、載入最新資料通過。這不是正式 Supabase RLS 測試。
- 瀏覽器驗證搜尋「洗」＋「清潔」只顯示洗衣精，仍保留可能快沒了與平均 20 天提示；改名／分類後原兩筆歷史與週期仍在。
- 具名刪除二次確認、預設聚焦取消、取消後品項仍在、確認封存後兩視窗都移除通過。
- 原有「快沒了 → 已補貨 → 補貨紀錄」通過；沒有觀察到前端 console error。
- 窄手機畫面實際 innerWidth 約 319px、文件寬 304px，無全頁橫向溢出；分類列本身可水平滑動。嘗試 viewport override 未使工具實際寬度改變，因此不宣稱桌面或 390px 驗證成功。iPhone 實機／Safari／主畫面與桌面仍待驗收。
- 使用者確認 002 migration 成功後，已核對正式 archived_at 欄位及新 RPC；透過 Supabase execute_sql 執行完整 security-check-v2.sql，所有斷言成功、交易回滾。驗證同家庭 A/B 互相更新及快照可見、過期／空 version 拒絕、輸入驗證、直接表 UPDATE/DELETE 拒絕、非成員及 anon 拒絕、修改及封存保留原 ID／日期／歷史、封存不在快照且不能再補貨。執行後確認無原測試名稱殘留。這是正式 PostgreSQL 的角色／JWT 模擬測試，不代表兩支手機或真正並行交易已測。
- 安全 advisors 已檢查：本 App 的 authenticated SECURITY DEFINER 可呼叫提示符合既有 RPC 設計，成員檢查及 EXECUTE 範圍已由回歸測試驗證。另有共用 `rls_auto_enable` 匿名可執行提示及 Auth 洩漏密碼保護未啟用，未改動本次範圍外設定。參考：[函式權限提示](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable)、[密碼保護](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)。
- SQL 測試只寫入暫時品項／歷史並 ROLLBACK，使用既有會員模擬身分，不更動 Auth 或現有業務列。另需雙手機驗收，不能取代真實同時交易測試。

## 以下為 v1 既有紀錄

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

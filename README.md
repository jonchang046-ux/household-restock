# 家裡補一下：啟用與驗收

**九分類更新（v6）：請閱讀 [CATEGORY-UPGRADE.md](CATEGORY-UPGRADE.md)。本 life-tools 已完成 005 與安全驗收，69 個食品轉為食品常溫，153 個品項保留，不需要重跑 SQL。既有品項可自行編輯成飲料／冷藏／冷凍。**

**補貨流程更新（v5）：請閱讀 [NEXT-RELEASE.md](NEXT-RELEASE.md)。待購數量、7 天還很多、中位數預測、順便補與最近動態，需要 `004_restock_flow.sql`。本 life-tools 已完成 004 與安全驗收，無需重跑；其他環境需先完成 SQL 與驗收。不要重跑初始建置 SQL。**

**購買途徑擴充：請閱讀 [PURCHASE-SOURCES.md](PURCHASE-SOURCES.md)。此功能另需 `003_purchase_sources.sql`，來源可由家庭自行新增／改名，品項可多選，並與名稱搜尋、使用分類組合篩選。發布前請先完成 migration 驗證。**

**既有網站升級 v2：請先閱讀 [V2-UPGRADE.md](V2-UPGRADE.md)。只執行 `002_restock_v2.sql`，不要重跑 001、重建帳號或家庭。以下初始建置步驟只供新環境參考。**

這是獨立、手機優先的靜態 HTML／CSS／JavaScript App，可直接放上 GitHub Pages，沒有 npm 套件或 build 步驟。後端使用你現有的 life-tools Supabase Project。

## 1. 建立資料庫（一次完成）

1. 開啟 Supabase Dashboard，選 Organization「奇妙小東西」→ Project「life-tools」。
2. 左側 **SQL Editor → New query**。
3. 開啟 `supabase/001_household_restock.sql`，複製整份、貼上、按 **Run**。
4. 成功後不要再執行。這是一次性 migration，若物件已存在會整筆回滾，不會覆蓋既有表。若有同名表，先檢查其結構再決定如何整合。
5. 到 **Database → Tables** 確認四張表已建立並啟用 RLS：`life_households`、`life_household_members`、`restock_items`、`restock_history`。

`config.js` 已填入你提供的 Project URL 和 publishable key。這兩項會公開；不要填 database password、`service_role` 或 `sb_secret_`。本 App 刻意只接受新式 `sb_publishable_` 公開金鑰。

## 2. 建立兩個登入帳號

第一版使用 Email＋密碼登入，帳號由 Dashboard 建立，避免註冊確認信與寄信服務設定成為測試障礙。

1. 到 **Authentication → Sign In / Providers → Email**（部分 Dashboard 顯示 Providers），確認 Email 登入已啟用。不需要開啟匿名登入。
2. 到 **Authentication → Users → Add user → Create new user**。
3. 輸入帳號 A 的 Email、由你設定的強密碼，開啟 **Auto Confirm User**，建立。
4. 重複建立帳號 B。密碼不要貼在對話或放進網站檔案。
5. 各自使用自己的 Email／密碼登入。此流程不需要寄驗證信，也不依賴公開註冊。

App 第一版沒有自助註冊、忘記密碼或密碼重設頁面。帳號管理先由專案管理者處理。不要為這個 App 任意關閉整個 life-tools 的註冊設定，以免影響其他工具。

## 3. 發布到 GitHub Pages

1. 在 GitHub 建立新的 repository，例如 `household-restock`。選公開 repository 時，所有上傳內容可被任何人閱讀；此資料夾不含私密金鑰或家庭資料。
2. **Add file → Upload files**，上傳本資料夾內容（不是最外層資料夾），使 `index.html` 位於 repository 根目錄，保留 `supabase` 子資料夾。
3. **Settings → Pages → Build and deployment → Source: Deploy from a branch**。
4. 選 **main / (root)**，按 Save，等待 Pages 顯示部署完成。
5. 開啟 Pages 顯示的 HTTPS 網址，例如 `https://你的帳號.github.io/household-restock/`。
6. 到 Supabase **Authentication → URL Configuration**：將 **Site URL** 設定為你希望作為 life-tools 預設登入返回的網址；若已有其他 App 使用它，保留原值。將這個 App 的完整 HTTPS 網址加入 **Redirect URLs**，包含最後的 `/`，不要加入寬鬆萬用字元。

目前 Email＋密碼登入不使用重新導向，因此不用更動其他 App 的 Site URL 也能使用。Redirect URLs 是為未來確認信／重設流程保留的設定。

所有資產均為相對路徑，可放在 Pages 子目錄。不要用檔案總管直接開 `index.html`；ES modules 必須由 HTTP／HTTPS 提供。此 App 不提供離線寫入或背景通知；不連網時會顯示錯誤，不會宣稱資料已儲存。

## 4. 讓兩個帳號加入同一 household

1. 手機 A 開啟網站並登入帳號 A。
2. **家庭與帳號 → 建立新家庭**，例如「我們家」。這會同時建立 household 與 A 的 owner membership。
3. 在同一視窗複製「目前家庭 ID」。
4. 手機 B 登入帳號 B，開啟「家庭與帳號」，複製「我的使用者 ID」。B 不需要建立另一個家庭。
5. 在 Supabase **SQL Editor → New query** 貼上以下 SQL，把兩個值換成剛複製的 ID，再 Run：

```sql
insert into public.life_household_members (household_id, user_id, role)
values (
  '貼上手機A的家庭ID'::uuid,
  '貼上手機B的使用者ID'::uuid,
  'member'
)
on conflict (household_id, user_id) do nothing;
```

6. 手機 B 按「重新整理」，應顯示同一個家庭。

家庭 ID 本身不是邀請碼，知道 ID 不會取得權限。前端無法自行新增 membership。只有你在 SQL Editor 執行的管理操作能加人。未來可在共用層加上邀請表、到期時間、受邀 Email 與接受函式，不必更改消耗品與歷史的關聯。

若需要移除成員，由管理者使用 SQL Editor，僅移除指定 membership：

```sql
delete from public.life_household_members
where household_id = '指定家庭ID'::uuid
  and user_id = '要移除的使用者ID'::uuid;
```

移除後下一次伺服器讀寫即受限制；手機畫面在下一次同步時清除該家庭，不會遠端刪除使用者過去已看到或保存的內容。

## 5. 兩支手機驗收清單

1. A 新增「衛生紙」，分類「浴廁」，不填數量。B 在 10 秒內（或重新整理）應看到。
2. A 按「快沒了」。A、B 的「該買了」都出現衛生紙。
3. B 按「已補貨」。待購品項消失，「其他常用品」出現衛生紙，顯示上次補貨日期。
4. A 開啟品項「⋯ → 補貨紀錄」，應有一筆補貨紀錄。再次實際補貨會保留新的一筆，不會覆寫歷史。
5. 誤標時按「⋯ → 取消待購」；不會新增補貨紀錄。
6. 兩台在尚未同步、同一品項同一版本下同時按「已補貨」，應只有一筆寫入；另一台收到「家人已更新」訊息。若一台已同步新版本後再按，視為新的補貨操作。
7. 新增未加入家庭的帳號 C：不得看到 A／B 的家庭或品項。C 自己建立家庭後，也只能看到自己的資料。
8. A 登出後清單清空，重新開啟必須登入。重新整理或重開已登入的 App 會保留登入狀態。
9. 手機關閉網路再操作，應顯示未確認／同步失敗，不應把未成功寫入的動作顯示成成功；恢復網路後重新同步。
10. Safari → 分享 → **加入主畫面**。由新圖示開啟，可獨立視窗操作；若 Safari 與主畫面 App 使用不同儲存空間，需要各自登入。

## 6. 週期與資料設計

- 使用者：沿用 `auth.users`，不另存 Email、密碼或複製一份登入系統。
- 共用層：`life_households`＋`life_household_members`，支援一人多家庭；`owner/member` 預留未來角色管理。
- App 層：`restock_items`＋不可由前端直接改寫的 `restock_history`。
- 資料庫存確定的 `normal/low`；`possible` 是依歷史及目前時間衍生的顯示狀態，不會變成待購或持久化過期狀態。
- 至少兩個不同 UTC 日期的補貨紀錄，取相鄰日期間隔的算術平均。相同 UTC 日期合併後計算，原始每筆歷史仍保留。
- 經過平均週期的 80% 時顯示「可能快沒了」；只有一段間隔時標「初步估計」。顯示日期使用手機時區；計算日期固定 UTC，避免兩手機不同時區改變平均。
- 新增品項不代表今天買過，不會捏造第一筆補貨日期。
- 順序：確定待購 → 可能快沒了 → 其他常用品；同組依分類選項順序、中文名稱、item ID 穩定排序。搜尋名稱與分類篩選可同時使用。
- v2 的「刪除」只設定 `archived_at` 並增加 version，保留原 item ID、名稱、分類、日期與補貨歷史。已封存品項不出現在目前清單；此版沒有封存紀錄瀏覽或還原 UI。
- 每 10 秒、回到前景、網路恢復、操作完成時同步。這是輪詢，不是 Supabase Realtime；不用另開 Realtime publication。

## 7. 安全與維護

- 四張表皆啟用 RLS；authenticated 只獲得 SELECT，且只能讀自己的家庭。anon 沒有表或 App RPC 存取權。
- 寫入僅通過有明確 EXECUTE grant 的 RPC，內部檢查 `auth.uid()` 與 membership，固定空 `search_path`。RPC 不能指定操作者或補貨時間。
- 補貨歷史與狀態更新在同一資料庫交易內。row lock＋version 防止同版本重複補貨及過期操作覆蓋。
- 不開放前端 membership INSERT／UPDATE／DELETE；不提供資料表直接寫入的政策。RLS 與表 grants 之外，security definer RPC 必須自己檢查成員資格，不能只仰賴 RLS。
- 登入透過 Supabase Auth REST；瀏覽器只保存 Supabase session，不保存密碼。refresh token 透過瀏覽器 Web Locks 協調同來源分頁，沒有 Web Locks 時同頁請求仍共用一次刷新。
- 所有品項名稱以 `textContent` 顯示，避免把輸入當 HTML。App 沒有第三方前端程式或 CDN 依賴。
- 目前快照一次載入家庭的完整歷史，適合小型私人 MVP；大量歷史需第二版分頁／伺服器聚合。
- 尚未增加封存品項還原／歷史瀏覽、成員管理 UI、自助註冊／密碼重設、正式邀請、離線佇列、通知、條碼、AI、自動購物、複雜統計。

## 8. 測試與檔案

- `index.html`、`styles.css`：手機優先介面、登入、家庭、快速新增、紀錄視窗。
- `app.js`：一鍵操作、清單分組、同步與錯誤處理。
- `api.mjs`：Supabase Auth、session 更新及 RPC。
- `cycle.mjs`：可獨立測試的週期估計。
- `list.mjs`：名稱搜尋、分類交集、穩定排序與狀態分組。
- `config.js`：公開連線設定。
- `manifest.webmanifest`、`icon.svg`、`icon-*.png`：主畫面資訊與圖示。
- `supabase/001_household_restock.sql`：完整一次性 migration。
- `supabase/002_restock_v2.sql`：既有網站的非破壞性 v2 migration。
- `supabase/security-check-v2.sql`：v2 權限與歷史保留回歸測試，使用既有成員，測試資料最後 ROLLBACK。
- `supabase/security-check.sql`：migration 後可手動執行的權限回歸測試，最後 ROLLBACK，不保留測試使用者或資料。只在 SQL Editor 執行，勿透過前端。
- `tests/core.test.mjs`、`tests/list.test.mjs`：Node 內建測試，不需套件；在本資料夾執行 `node --test tests/core.test.mjs tests/list.test.mjs`。

獨立目錄與 `life_`／`restock_` 命名不會修改其他頁面。共用 Project 的 Auth 設定可能影響其他 App，因此沿用現有設定，只加入必要的網址與成員。

官方參考：[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)、[Database functions](https://supabase.com/docs/guides/database/functions)、[API keys](https://supabase.com/docs/guides/getting-started/api-keys)、[Email／password Auth](https://supabase.com/docs/guides/auth/passwords)。

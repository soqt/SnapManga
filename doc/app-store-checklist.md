# LifeManga 上架 App Store 检查清单

> 代码和数据库已准备就绪。以下是在生产环境真正上线前必须手动完成的配置。

## 1. 创建生产环境 Supabase 项目

1. 在 [Supabase Dashboard](https://supabase.com/dashboard) 新建项目（建议选离用户近的 region，如 `us-east-1`）。
2. 本地连接生产项目：
   ```bash
   cd /Users/samwang/Developer/LifeManga/supabase
   supabase link --project-ref <your-project-ref>
   ```
3. 推送数据库 migration：
   ```bash
   supabase db push
   ```
4. 部署 Edge Functions：
   ```bash
   supabase functions deploy
   ```

## 2. 配置 Edge Function Secrets

在 Supabase Dashboard → Project Settings → Edge Functions → Secrets 中设置：

| Secret | 说明 |
|--------|------|
| `OPENAI_API_KEY` | OpenAI API Key（用于调用 gpt-image-2） |
| `OPENAI_ORG_ID` | （可选）OpenAI Organization ID |
| `APPLE_SHARED_SECRET` | App Store Connect → App → 功能 →  App 内购买项目 →  App 专用共享密钥 |

## 3. 配置 Sign in with Apple

### 3.1 Apple Developer
1. 在 Apple Developer → Certificates, Identifiers & Profiles 中确认 App ID 启用了 **Sign in with Apple**。
2. 注册/确认 **Bundle ID**（如 `com.yourcompany.lifemanga`）。
3. 生成/下载 **Apple Services ID** 的 private key（p8），记下 Key ID 和 Team ID。

### 3.2 Supabase Auth
1. Supabase Dashboard → Authentication → Providers → Apple。
2. 填写：
   - Client ID（即 App 的 Bundle ID）
   - Secret Key（p8 文件内容）
   - Key ID
   - Team ID
3. Authorized Redirect URI 可填写：`https://<your-project>.supabase.co/auth/v1/callback`

### 3.3 iOS 工程
- 检查 `LifeManga.xcodeproj` 中 Bundle Identifier 与 Supabase 中填写的 Client ID 一致。
- 在 Xcode → Signing & Capabilities 中添加 **Sign in with Apple** capability。

## 4. 替换 iOS 中的 Supabase 配置

编辑 `LifeManga/LifeManga/Services/SupabaseConfig.swift`：

```swift
static let supabaseURL = URL(string: "https://<your-project>.supabase.co")!
static let supabaseKey = "<your-anon-public-key>"
```

> 不要把 `service_role` key 放进 App，只用 publishable/anon key。

## 5. App Store Connect 配置

1. 创建 App 记录，Bundle ID 与 Xcode 一致。
2. 在 **App 内购买项目** 中创建三个消耗型商品：
   - `credits_10`
   - `credits_60`
   - `credits_150`
3. 填写本地化名称、价格、截图。
4. 生成 **App 专用共享密钥**（见第 2 步）并填入 Supabase secret。
5. 在 **App 隐私** 中根据 `PrivacyInfo.xcprivacy` 和 `doc/privacy.md` 填写数据收集声明。

## 6. 隐私政策和服务条款

1. 将 `doc/privacy.md` 和 `doc/terms.md` 部署到可公开访问的 URL。
2. 推荐方案：
   - GitHub Pages
   - Vercel
   - Cloudflare Pages
3. 把 `SettingsView.swift` 和 `AuthView.swift` 中的链接替换为真实地址（当前为 `https://lifemanga.app/privacy` 和 `https://lifemanga.app/terms`）。

## 7. Xcode 最终检查

- [ ] Bundle Identifier 正确
- [ ] Sign in with Apple capability 已添加
- [ ] App Icon 已配置（`Assets.xcassets/AppIcon`）
- [ ] Launch Screen / Launch Screen storyboard 正常
- [ ] App 版本号、版权信息已填写
- [ ] 关闭调试配置，Archive 时使用 Release scheme
- [ ] 在真机上测试登录、购买、生成、删除账号流程

## 8. 提审前测试清单

- [ ] Sign in with Apple 在新设备上正常
- [ ] 内购沙盒账号可完成购买并到账 credits
- [ ] 生成图片扣除 credits 正确
- [ ] credits 不足时提示购买
- [ ] 创建工程/作品/角色后可在 Supabase 数据库看到对应元数据
- [ ] 删除账号后云端数据被清空
- [ ] 隐私政策和服务条款链接可正常打开

## 9. 上线后

- 在 Supabase 中监控 `generation_jobs`、`credit_transactions` 表，观察成本和异常。
- 定期检查 OpenAI 账单，优化提示词和默认参数以控制成本。
- 根据用户反馈调整 credits 价格和包大小。

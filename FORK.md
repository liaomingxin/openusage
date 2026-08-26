# Fork 维护手册

`liaomingxin/openusage`（fork）↔ `robinebers/openusage`（上游）的日常开发、发布、同步流程。

## 分支模型

| 分支 | 用途 |
|---|---|
| `main` | fork 的主干 = 上游 main + 自己的提交（kimi provider、个人 CI 等）。**直接在上面做小改动，功能开发切 feature 分支** |
| `feat/*`、`docs/*` | 功能分支，完成后快进/合并回 `main` 并推送 |
| tag `v*.*.*-kimi.N` | 个人发布版本，触发 `personal-release.yml` 自动构建 DMG |

Remote 配置（已配好）：

```
origin    → https://github.com/liaomingxin/openusage.git   （fork，可推送）
upstream  → https://github.com/robinebers/openusage.git   （上游，只读）
```

## 日常开发

```bash
# 从最新 main 切分支（功能开发都走这里）
git checkout main && git pull origin main
git checkout -b feat/xxx

# ……开发、测试……
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # 本机装了 Xcode 但 xcode-select 仍指向 CLT 时需要
swift test                          # 全量测试
swift test --filter "Kimi"          # 只跑 kimi 相关
./script/build_and_run.sh           # 构建并启动 dev app（bundle id .dev，与正式安装互不干扰）

# 完成后合回 main（保持线性历史）
git checkout main
git merge --ff-only feat/xxx
git push origin main
```

**并行会话注意**：orca worktree 里的分支（`feature/fix-grok-icon` 等）是其他会话的工作区，
别在主工作区动它们；它们改过 `DefaultLayout.swift` 的话，合并时会有一点点冲突要手动解。

## 打包发布（个人多设备自用）

一条链：**推 tag → CI 自动构建 → Release 出 DMG**。

```bash
git tag v0.7.10-kimi.4        # 版本号：上游版本-kimi.序号，序号递增（已发到 kimi.3）
git push origin v0.7.10-kimi.4
# 几分钟后：https://github.com/liaomingxin/openusage/releases
```

**分支名不影响发版**：Orca worktree 建出来的分支带 `liaomingxin/` 前缀（如
`liaomingxin/sync-upstream`），`personal-release.yml` 只认 `v*-kimi.*` tag，不认分支名，
所以前缀无所谓——合回 `main` 再打 tag 就行。

- workflow：`.github/workflows/personal-release.yml`（复用 `build_and_run.sh` 的 staging，
  ad-hoc 签名，**不需要任何证书/secrets**）
- tag 规则 `v*-kimi.*` 与上游 `v0.7.x` 永不冲突
- bundle id 用正式的 `com.robinebers.openusage`：个人安装可直接替换官方 app，设置/钥匙串授权延续

**其他设备安装/更新**（每台一次）：

```bash
# 下载 DMG → 拖入 /Applications → 跑一次：
xattr -rd com.apple.quarantine /Applications/OpenUsage.app
```

（U 盘/Finder 直拷不会带隔离属性，可跳过 xattr；AirDrop/网盘下载需要。）

**不要用的路径**：上游的 `.github/workflows/release.yml` 需要 Developer ID + 公证 + Sparkle
secrets（只有上游作者有），fork 上跑不了；发版**只走 personal-release.yml**。
上游 workflow 里其余的 ci.yml / deploy-pages.yml 在 fork 上会失败或无意义，忽略即可。

## 同步上游更新

**上次同步**：上游 `v0.7.10-beta.3`（tip `16e497d`），2026-08-26 以 merge commit `a729d68` 合入。

```bash
git fetch upstream
git checkout main
git merge upstream/main        # fork main 有自己的提交，不再用 --ff-only，会产生 merge commit
git push origin main
```

**冲突高发文件与解法**：

| 文件 | 冲突场景 | 解法 |
|---|---|---|
| `Sources/OpenUsage/Stores/DefaultLayout.swift` | 上游增删 metric 或其他分支（如 grok 钉菜单栏）同改 | 合并两边的数组项，保持 kimi 的三行（metricIDs/pinned/expanded） |
| `Sources/OpenUsage/Providers/ProviderCatalog.swift` | 上游新增 provider；或上游改 `make()` 的签名（2026-08 加了 `claudeCards:`/`claudeIdentityKeys:`，fork 又加了 `claudeSwapCards:`） | 合并两边参数与数组，顺序固定为 **Claude 卡 → fork 的 claude-swap 卡 → `CodexProvider()` → fork 的额外 Codex 卡 → Cursor → 字母序尾巴（kimi 在 Grok 后）** |
| `Sources/OpenUsage/Services/ProviderAccountAssembly.swift` | **最难的一个。** 上游加 Claude 多账号卡（`ClaudeAccountCard`、Desktop 组织发现），fork 加 Codex 额外卡（`CodexExtraCard`、`mergedObservations`）和 claude-swap 卡（`ClaudeSwapCard`），两边改同一批函数 | **三边都留**：一个 `make(observer:accountsStore:families:extraCodex:claudeSwap:desktop:listDesktopOrganizationDirectories:)`，先塞额外 Codex observation，再塞 claude-swap 槽位 observation（family 是 `claude`），再跑 Claude Desktop 组织发现，然后**只 reconcile 一次**（走 `mergedObservations`，同一身份合成一条记录），最后三份卡各建一份。上游原来的两处 early return 要改成「发现流程的判断条件」，否则那些分支会漏掉额外卡 |
| `Sources/OpenUsage/Services/ProviderAccountAssembly.swift`（体量） | 已经 430+ 行、装着三套卡片模型，上游一改这里必冲突 | 冲突太痛时把「发卡」那段（`reconcile` 之后到 `return` 之间）抽成 `ProviderAccountCards` 辅助类型，冲突面就只剩观测拼装那几行；现在还在 ~500 行门槛内，先不动 |
| `Sources/OpenUsage/App/AppContainer.swift`、`Sources/OpenUsage/Services/UsageReader.swift` | `ProviderCatalog.make(...)` 调用点，两边各加各的参数 | 四个参数一起传：`extraCodexCards:` + `claudeCards:` + `claudeSwapCards:` + `claudeIdentityKeys:`；`UsageReader` 里保留上游把 `ProviderEnablementStore(defaults:)` 放在 registry 之后的位置 |
| `Tests/OpenUsageTests/LocalLimitsAPITests.swift` | 上游新增 provider 的 key 清单 | expected 字典里补上两边的条目 |
| `Sources/OpenUsage/Providers/ErrorCategory.swift` | 同上 | 保留两边的 CategorizedError 扩展 |
| `Sources/OpenUsage/Providers/Kimi/`（整个目录） | **上游官方也实现了 kimi** | 二选一：保留自己的版本（删上游的），或采用上游的（删 `Providers/Kimi/`、DefaultLayout/Catalog/测试里的 kimi 条目） |

合并后必做：`swift test` + `./script/build_and_run.sh` 起一次确认，再打下一个 `-kimi.N` tag 发布。

## 当前 fork 独有的东西（合并上游时的自查清单）

- `Sources/OpenUsage/Providers/Kimi/`：Kimi Code provider（OAuth 读 `~/.kimi-code/`，Session/Weekly/Booster）
- `DefaultLayout.swift`、`ProviderCatalog.swift`、`ErrorCategory.swift`、`LocalLimitsAPITests.swift`、`ProviderMarksTests.swift` 里的 kimi 条目
- `docs/providers/kimi.md`、`docs/research/kimi-code-usage-api.md`
- Codex 多账号：扫描 `~/.cli-proxy-api/codex-*.json`，额外 ChatGPT 登录各自一张卡（`codex@<hash>`），布局跟默认 Codex 卡绑定
- **claude-swap 多账号（fork 独有，未来必冲突）**：扫描 `~/.claude-swap-backup/configs/.claude-config-<N>-<email>.json`
  （cswap 的备份快照，隐藏文件），非当前登录的账号各自一张卡（`claude@<hash>`）。数值**两层**：
  - **实时层（首选）**：从 keychain service `claude-swap`、account `account-<slot>-<email>`
    （旧版别名 `account-None-<email>`）里**只读**取出 accessToken + 计划名
    （`subscriptionType`/`rateLimitTier`，只是标签、不是凭证，用来显示「Max 20x」徽章），
    走 `ClaudeUsageClient.fetchUsage` + `ClaudeUsageMapper`，和正式 Claude 卡同一个接口同一个 mapper，
    所以有 Session/Weekly/Fable/Sonnet/**Extra Usage**。
    429 会按 `Retry-After`（默认 5 分钟）暂停实时层，手动刷新也照样等；钥匙串**被拒**（不是「没这项」）
    会停 1 小时不再读，免得每 5 分钟弹一次授权框，手动刷新清掉这个冷却。
    token 被 Anthropic 拒掉时，除了写日志还会在卡片上挂琥珀色警告（提示跑 `cswap` 重新登录）。
  - **缓存层（兜底）**：token 过期 / 被拒 / keychain 读不到 / 网络挂了，就退回只读
    `~/.claude-swap-backup/cache/usage.json`（Session/Weekly/Fable，超过 2h 不新鲜就显示 No data）。
  - **绝不刷新、绝不写 cswap 的 OAuth token**：不解析 refreshToken、不建 `ClaudeAuthStore`、
    配置里根本没有 token endpoint（`ClaudeSwapOAuth.readOnlyConfig` 的 refreshURL 故意指回 usage URL）。
    刷新会和 cswap 自己的轮换打架，把它的 refresh token 弄废。结构性回归测试见
    `ClaudeSwapLiveUsageTests.testClaudeSwapSourcesBuildNoAuthStoreAndNameNoTokenEndpoint`
    与 `UsageOnlyHTTPClient`（任何非 GET usage 的请求直接 XCTFail）。
  - `hasLocalCredentials()` 永远只看配置快照文件，**不读 keychain**，免得首次运行检测就弹授权框。

  相关文件：`Providers/Claude/ClaudeSwap{Discovery,CredentialReader,UsageClient,UsageMapper,Provider}.swift`、
  `Tests/OpenUsageTests/ClaudeSwap{Tests,CardTests,LiveUsageTests}.swift`、
  `docs/providers/claude.md` 的「claude-swap accounts」一节、`docs/privacy.md`。
  另外为了列出隐藏的 `.json` 快照，`TextFileAccessing.jsonFilePaths` 加了 `includingHidden:` 参数
  （`SystemClients.swift` + `TestSupport.swift` 的 `FakeFiles`），合上游时注意保留
- **`ProviderAccountAssembly.swift` / `ProviderCatalog.swift` 现在是「共管文件」**：同时装着上游的
  Claude 账号卡（`ClaudeAccountCard`、Desktop 组织发现、`allowsUnattributedPiUsage`）和 fork 的
  Codex 额外卡（`CodexExtraCard`、`extraCodexCards`）**以及 claude-swap 卡（`ClaudeSwapCard`、
  `claudeSwapCards`）**。三份卡都在同一次 `mergedObservations` → 单次 reconcile 里产生；
  claude-swap 的槽位以 `.credentialFile` observation 进入 **claude** family，和默认 home / Desktop
  同身份时只挂 source、不出第二张卡。以后每次合上游都必须三边都活下来——只留一边就等于悄悄删功能，
  回归测试见 `ProviderAccountAssemblyTests` 的
  `testExtraCodexCardsAndClaudeOrganizationCardComeFromOneReconcilePass` 与
  `testClaudeSwapAndCodexExtraCardsComeFromOneReconcilePass`。
  卡片顺序固定为 **Claude 卡 → claude-swap 卡 → `CodexProvider()` → 额外 Codex 卡 → Cursor → 字母序尾巴**
- 两种额外卡的**钉菜单栏规则已和上游统一**：每张账号卡都自带 Session/Weekly 两个钉（上限按卡计）。
  Claude 卡由 `AppContainer` 预展开 `pinnedMetricIDs`，Codex 额外卡由 `LayoutStore.init` 里的
  `DefaultLayout.includingInstances` 翻译，两条路径去重后落到同一份默认钉列表
- `.github/workflows/personal-release.yml`
- tag 序列 `v0.7.10-kimi.N`

## 已知坑

- **本机工具链**：`xcode-select` 指向 CLT；Xcode 装在 `/Applications/Xcode.app`，构建/测试前
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（或干脆 `sudo xcode-select -s` 切过去）
- **Provider SVG 图标**：解析器只支持 `M/L/H/V/C/S/Q/T/Z`，**不支持圆弧 `A/a`**——新图标用贝塞尔写
- **本地 API 端口**：`127.0.0.1:6736` 只有一个实例能绑；dev 和正式版同时跑时，curl 打到的可能是旧实例
- **正式版 app 与 dev 版**：同机共存没问题（bundle id 不同），但装了正式版时注意别 curl 到旧实例
- **claude-swap 卡的钥匙串授权可能每次升级都要重点一次**：`personal-release.yml` 出的 DMG 是
  ad-hoc 签名，每次构建的签名标识都不一样，所以 macOS 对 `claude-swap` 这个钥匙串条目的
  「始终允许」授权**不一定能跨版本延续**——升到新的 `kimi.N` 后可能再弹一次授权框（点一次
  Always Allow 即可）。dev 构建用的是稳定的 Apple Development 身份，授权可以延续。
  暂不解决（要解决得上真 Developer ID 签名），记录在此备查

## 可选：回馈上游

kimi provider 质量够高（22 测试 + 真机验证 + 完整文档），随时可以提 PR 给 `robinebers/openusage`：
按仓库 PR 模板写（TL;DR / What was happening / What this changes / Tests / Screenshots），
UI 有视觉变化的必须带截图。上游如果收录，后续同步冲突也会消失。

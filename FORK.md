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
| `Sources/OpenUsage/Providers/ProviderCatalog.swift` | 上游新增 provider；或上游改 `make()` 的签名（2026-08 加了 `claudeCards:`/`claudeIdentityKeys:`） | 合并两边参数与数组，顺序固定为 **Claude 卡 → `CodexProvider()` → fork 的额外 Codex 卡 → Cursor → 字母序尾巴（kimi 在 Grok 后）** |
| `Sources/OpenUsage/Services/ProviderAccountAssembly.swift` | **最难的一个。** 上游加 Claude 多账号卡（`ClaudeAccountCard`、Desktop 组织发现），fork 加 Codex 额外卡（`CodexExtraCard`、`mergedObservations`），两边改同一批函数 | **两边都留**：一个 `make(observer:accountsStore:families:extraCodex:desktop:listDesktopOrganizationDirectories:)`，先塞额外 Codex observation，再跑 Claude Desktop 组织发现，然后**只 reconcile 一次**（走 `mergedObservations`，同一身份合成一条记录），最后两份卡各建一份。上游原来的两处 early return 要改成「发现流程的判断条件」，否则那些分支会漏掉 Codex 额外卡 |
| `Sources/OpenUsage/App/AppContainer.swift`、`Sources/OpenUsage/Services/UsageReader.swift` | `ProviderCatalog.make(...)` 调用点，两边各加各的参数 | 三个参数一起传：`extraCodexCards:` + `claudeCards:` + `claudeIdentityKeys:`；`UsageReader` 里保留上游把 `ProviderEnablementStore(defaults:)` 放在 registry 之后的位置 |
| `Tests/OpenUsageTests/LocalLimitsAPITests.swift` | 上游新增 provider 的 key 清单 | expected 字典里补上两边的条目 |
| `Sources/OpenUsage/Providers/ErrorCategory.swift` | 同上 | 保留两边的 CategorizedError 扩展 |
| `Sources/OpenUsage/Providers/Kimi/`（整个目录） | **上游官方也实现了 kimi** | 二选一：保留自己的版本（删上游的），或采用上游的（删 `Providers/Kimi/`、DefaultLayout/Catalog/测试里的 kimi 条目） |

合并后必做：`swift test` + `./script/build_and_run.sh` 起一次确认，再打下一个 `-kimi.N` tag 发布。

## 当前 fork 独有的东西（合并上游时的自查清单）

- `Sources/OpenUsage/Providers/Kimi/`：Kimi Code provider（OAuth 读 `~/.kimi-code/`，Session/Weekly/Booster）
- `DefaultLayout.swift`、`ProviderCatalog.swift`、`ErrorCategory.swift`、`LocalLimitsAPITests.swift`、`ProviderMarksTests.swift` 里的 kimi 条目
- `docs/providers/kimi.md`、`docs/research/kimi-code-usage-api.md`
- Codex 多账号：扫描 `~/.cli-proxy-api/codex-*.json`，额外 ChatGPT 登录各自一张卡（`codex@<hash>`），布局跟默认 Codex 卡绑定
- **`ProviderAccountAssembly.swift` / `ProviderCatalog.swift` 现在是「共管文件」**：同时装着上游的
  Claude 账号卡（`ClaudeAccountCard`、Desktop 组织发现、`allowsUnattributedPiUsage`）和 fork 的
  Codex 额外卡（`CodexExtraCard`、`extraCodexCards`）。以后每次合上游都必须两边都活下来——
  只留一边就等于悄悄删功能，回归测试见
  `ProviderAccountAssemblyTests.testExtraCodexCardsAndClaudeOrganizationCardComeFromOneReconcilePass`
- 两种额外卡的**钉菜单栏规则不一样**：Claude 账号卡由 `AppContainer` 预展开 `pinnedMetricIDs`，
  每张自带 Session/Weekly 两个钉；Codex 额外卡不继承钉，钉位留给默认 Codex 卡
- `.github/workflows/personal-release.yml`
- tag 序列 `v0.7.10-kimi.N`

## 已知坑

- **本机工具链**：`xcode-select` 指向 CLT；Xcode 装在 `/Applications/Xcode.app`，构建/测试前
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（或干脆 `sudo xcode-select -s` 切过去）
- **Provider SVG 图标**：解析器只支持 `M/L/H/V/C/S/Q/T/Z`，**不支持圆弧 `A/a`**——新图标用贝塞尔写
- **本地 API 端口**：`127.0.0.1:6736` 只有一个实例能绑；dev 和正式版同时跑时，curl 打到的可能是旧实例
- **正式版 app 与 dev 版**：同机共存没问题（bundle id 不同），但装了正式版时注意别 curl 到旧实例

## 可选：回馈上游

kimi provider 质量够高（22 测试 + 真机验证 + 完整文档），随时可以提 PR 给 `robinebers/openusage`：
按仓库 PR 模板写（TL;DR / What was happening / What this changes / Tests / Screenshots），
UI 有视觉变化的必须带截图。上游如果收录，后续同步冲突也会消失。

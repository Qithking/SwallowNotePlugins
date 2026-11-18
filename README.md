# SwallowNote 插件

> SwallowNote 插件生态独立仓库：插件系统文档、示例插件、内置插件、SDK 与工具链、市场索引与 CI 发布

## 仓库结构

```
.
├── sdk/                       # SDK、工具链与插件系统文档
│   ├── plugin-system/         # 插件系统开发文档（API 说明）
│   ├── plugin-sdk/            # @swallow-note/plugin-sdk — 零依赖前端 SDK
│   ├── plugin-kit/            # @swallow-note/plugin-kit — swallow-plugin CLI
│   ├── plugin-rpc/            # 后端共享 RPC crate
│   └── plugin-template/       # Vite + React 起步模板（含示例市场 plugin-marketplace/）
├── plugin-samples/            # 示例插件源码（12 个）
├── package/                   # 内置插件工程（含市场索引 repo.json）
│   ├── ai/ export/ mindmap/ picgo/ wenyan/ secret-disk/
│   └── repo.json              # 官方市场索引（CI 发布时自动回填）
└── .github/workflows/         # plugin-release.yml：tag 触发的多平台构建与发布
```

## 插件系统文档（sdk/plugin-system）

| 文档 | 简介 |
| --- | --- |
| [plugin-system/README.md](sdk/plugin-system/README.md) | 插件系统总览与架构 |
| [plugin-system/DEVELOPER_GUIDE.md](sdk/plugin-system/DEVELOPER_GUIDE.md) | **完整开发指南**（推荐主入口） |
| [plugin-system/quickstart.md](sdk/plugin-system/quickstart.md) | 5 分钟上手：第一个插件 |
| [plugin-system/manifest.md](sdk/plugin-system/manifest.md) | manifest 字段说明 |
| [plugin-system/lifecycle.md](sdk/plugin-system/lifecycle.md) | 生命周期钩子 |
| [plugin-system/events.md](sdk/plugin-system/events.md) | 事件总线 |
| [plugin-system/storage.md](sdk/plugin-system/storage.md) | 持久化存储 |
| [plugin-system/settings.md](sdk/plugin-system/settings.md) | 设置面板 |
| [plugin-system/context-menu.md](sdk/plugin-system/context-menu.md) | 右键菜单贡献 |
| [plugin-system/backend.md](sdk/plugin-system/backend.md) | Rust 后端（可选） |
| [plugin-system/standalone-development.md](sdk/plugin-system/standalone-development.md) | 独立开发指南（不 clone 主应用源码） |

## 示例插件（plugin-samples）

| 示例 | 能力 |
| --- | --- |
| [hello-world](plugin-samples/hello-world) | 最小可运行插件 |
| [storage-counter](plugin-samples/storage-counter) | 持久化存储 |
| [event-listener](plugin-samples/event-listener) | 事件订阅 |
| [settings-dialog](plugin-samples/settings-dialog) | 设置面板 |
| [context-menu-item](plugin-samples/context-menu-item) | 右键菜单贡献 |
| [full-stack](plugin-samples/full-stack) | 综合示例（5 项能力） |

## 内置插件（package/）

| 插件 | 能力 |
| --- | --- |
| [package/ai](package/ai) | AI 助手、Rust 后端 |
| [package/wenyan](package/wenyan) | 自定义主题、公众号排版、编辑器工具栏、设置 API |
| [package/secret-disk](package/secret-disk) | 加密笔记、编辑器 Tab API、Rust 后端 |
| [package/mindmap](package/mindmap) | 思维导图编辑器、自定义文件编辑器 |
| [package/picgo](package/picgo) | 图床上传、设置 API、面板交互 |
| [package/export](package/export) | 导出 Markdown/DOCX、Rust 后端 |

## 开发工具链（sdk/）

| 工具 | 简介 |
| --- | --- |
| [sdk/plugin-sdk](sdk/plugin-sdk) | `@swallow-note/plugin-sdk` — 零依赖 SDK，无需 clone SwallowNote 源码 |
| [sdk/plugin-kit](sdk/plugin-kit) | `@swallow-note/plugin-kit` — `swallow-plugin` CLI（create/build/package）与 `definePluginViteConfig` 构建配置 |
| [sdk/plugin-rpc](sdk/plugin-rpc) | 插件后端共享 RPC crate — `PluginBackend` trait + `run()` + 标准错误码，Rust 后端直接依赖 |
| [sdk/plugin-template](sdk/plugin-template) | Vite + React 起步项目，开箱即用 dev preview |

## 发布流程

内置插件与市场索引通过 GitHub Actions 自动发布：

1. 更新插件版本（`package/<插件>/package.json` 与 manifest）
2. 打 tag `plugin-v*` 并推送
3. CI（[.github/workflows/plugin-release.yml](.github/workflows/plugin-release.yml)）在三平台构建插件后端 → `swallow-plugin package` 打包 → ed25519 签名 → 同步 `package/repo.json` → zip 与索引上传到 GitHub Release

应用内插件市场的官方源地址：

```
https://github.com/Qithking/SwallowNotePlugins/releases/latest/download/repo.json
```

签名验证公钥见 [sdk/plugin-template/plugin-marketplace/pubkey.b64](sdk/plugin-template/plugin-marketplace/pubkey.b64)；签名私钥经 `SWALLOWNOTE_PLUGIN_SIGNING_KEY`（CI Secret / 本地环境变量）提供，**严禁提交**。

---

## 快速链接

- **我想独立开发一个插件** → [sdk/plugin-template](sdk/plugin-template)（推荐先看这个）
- **我想看 SDK API 文档** → [sdk/plugin-sdk/README.md](sdk/plugin-sdk/README.md)
- **我想用 kit 脚手架/构建/打包** → [sdk/plugin-kit/README.md](sdk/plugin-kit/README.md)
- **我要写插件 Rust 后端** → [sdk/plugin-rpc/README.md](sdk/plugin-rpc/README.md)
- **我想写一个插件（项目内开发）** → [sdk/plugin-system/quickstart.md](sdk/plugin-system/quickstart.md)
- **我想看一个能跑的插件** → [plugin-samples/hello-world](plugin-samples/hello-world)
- **我想知道 manifest 怎么写** → [sdk/plugin-system/manifest.md](sdk/plugin-system/manifest.md)
- **我想了解某个内置插件的实现** → [package/](package/) 下对应插件目录
- **我想贡献命令面板条目** → [DEVELOPER_GUIDE.md#命令面板贡献](sdk/plugin-system/DEVELOPER_GUIDE.md#命令面板贡献)
- **我想注册自定义文件编辑器** → [DEVELOPER_GUIDE.md#自定义文件编辑器](sdk/plugin-system/DEVELOPER_GUIDE.md#自定义文件编辑器)
- **我想用编辑器 Tab API** → [DEVELOPER_GUIDE.md#编辑器-tab-api](sdk/plugin-system/DEVELOPER_GUIDE.md#编辑器-tab-api)
- **我想用设置 API** → [DEVELOPER_GUIDE.md#设置-api](sdk/plugin-system/DEVELOPER_GUIDE.md#设置-api)
- **我想用 Frontmatter API** → [DEVELOPER_GUIDE.md#frontmatter-api](sdk/plugin-system/DEVELOPER_GUIDE.md#frontmatter-api)
- **我想用某个具体 API** → 上方表格里找对应文档
- **有问题先看 API 参考** → 每个文档底部都有对应源代码引用

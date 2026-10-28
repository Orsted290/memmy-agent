# Windows Codex Hook 一键验收包

此包用于在真实 Windows x64 环境验收 Codex Hook 修复。包内安装器是专用 unsigned 验收构建，不用于日常安装。

## 一键运行

1. 将 ZIP 解压到一个可写目录，确保本目录中的文件和 `Memmy-*-codex-acceptance.exe` 在同一文件夹。
2. 双击 `Run-Windows-Codex-Hook-Acceptance.cmd`。
3. 首次运行时，浏览器会为临时 Codex 配置完成登录；登录后脚本自动继续。
4. 结束后查看 `output/windows-codex-hook-<runId>.json`。只有 `status` 为 `PASS` 才算验收通过。

也可在 Windows Codex 中打开此目录，并使用 [`Codex-Task.md`](./Codex-Task.md) 的指令让 Codex 启动脚本、等待完成并汇总报告。

## 自动验收内容

- 将 Memmy 安装到本次运行的临时目录，并启动隔离验收构建。
- 把真实 `codex.exe` 暂时映射到隔离的 `%LOCALAPPDATA%\OpenAI\Codex\bin` 回退目录，同时从 Memmy 的 `PATH` 中移除 Codex 路径，且不设置 `MEMMY_CODEX_EXECUTABLE`。这样安装请求必须通过 Windows 可执行文件回退发现路径。
- 使用 Memmy 本地 API 的 Hook 安装入口。成功响应表示 Codex app-server 已发现并信任 5 个 Hook；脚本也检查 `hooks.json` 中存在 5 条 Hook 命令。
- 使用隔离 `CODEX_HOME` 运行真实 Codex CLI 对话，并通过 Memmy Memory API 读取数据库视图，确认带唯一标记的用户问题和回答已落盘。
- 删除临时 Codex 的 `sessions` 目录后调用卸载入口，确认 Hook 配置、运行文件和 `AGENTS.md` 标记已清除。
- 启动新的 Codex CLI 进程完成第二轮对话，确认卸载后没有新 Hook 记忆或任务写入。
- 结束后调用 Memmy NSIS 卸载器，并删除隔离目录。验收登录、Codex 会话、Memmy 数据库和临时安装均位于本次临时目录。
- 验收安装器使用独立 Windows App ID，不扫描或迁移正式 Memmy 安装/数据，也不创建快捷方式、不改用户 PATH 或登录启动项。脚本会比对安装前后的 HKCU 用户 PATH 和两种 Memmy 登录项，并检查验收卸载注册是否清除。
- 清理前在同一个临时 `CODEX_HOME` 执行 `codex logout`，尝试移除本次登录写入的凭证文件或凭证库项目；宿主环境中的 API Key 和自定义 API 地址不会传给验收进程。

## 前置条件

- Windows 10/11 x64。
- 安装了 Windows Codex CLI（脚本可从常见安装位置查找 `codex.exe`）。自定义位置可用参数 `-CodexExecutable "绝对路径\\codex.exe"` 指定。
- Node.js 22 或更新版本，用于执行 Memmy 安装的 Hook。
- 能访问 Codex 模型服务。临时 CODEX_HOME 不会读取、复制或复用现有 `%USERPROFILE%\.codex` 的认证信息，因此首次验收需要在浏览器完成一次临时登录。

如果 Windows SmartScreen 提示 unsigned 安装器，确认文件来自本验收包后选择继续运行。脚本不需要管理员权限。

## 安全边界和证据

- 脚本在 `%TEMP%\Memmy Codex Hook Acceptance <runId>` 下创建一次性测试环境；不会更改真实 `%USERPROFILE%\.codex`、AppData 或 Memmy 用户数据库。Codex 的临时登录在清理前执行 `codex logout`。
- 它只在临时目录建立一个 Junction，指向用户明确选择的 Codex CLI 所在目录；结束时先删除 Junction 本身，再清理临时目录，不递归进入真实 Codex 安装目录。
- 报告记录安装器 SHA-256、Codex/Node 版本、逐项 PASS/FAIL 和隔离清理结果，不记录 API Token 或 Codex 登录数据。Codex 对话记录和临时认证不会打包进报告。
- `WIN-HKCU-ISOLATION-01` 若检测到 PATH 或登录项与安装前快照不同，会在 JSON 报告中失败并提示人工检查；脚本不会自动覆盖用户的注册表值。
- `PASS` 表示 Windows 原生 Codex CLI、Memmy 打包应用、安装 Hook、真实对话写入、丢失 sessions 后卸载以及卸载后反测均已完成。它不等同于人工逐像素检查 Memmy 界面。

失败时脚本仍会生成 JSON 报告并尝试卸载应用、停止本次创建的子进程和清理临时配置；若 Junction 无法安全移除，会保留隔离目录并在报告中标记，避免误删真实 Codex 文件。

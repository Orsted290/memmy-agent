# Windows Codex 执行指令

在此文件夹的 Windows Codex 中粘贴：

> 请在当前文件夹运行 `Run-Windows-Codex-Hook-Acceptance.cmd`，等待脚本完整结束，然后读取最新的 `output/windows-codex-hook-*.json` 并按其中的逐项检查汇总结果。不要读取或复制我现有的 `%USERPROFILE%\.codex` 配置，不要手动编辑验收脚本或安装器。如果脚本要求浏览器登录，请提示我完成隔离临时 Codex 配置的登录后继续。最终明确报告 PASS/FAIL、失败检查 ID 和 JSON 报告路径。

脚本通过真实 Windows Codex CLI 和 Memmy 本地 API 完成自动验收。Codex 应等待脚本返回，不要把启动进程成功当成验收通过；最终结论以报告中的 `status` 和全部 `checks` 为准。

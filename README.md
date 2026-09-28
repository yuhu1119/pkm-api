# 产品知识模型 · 后端（SpeedLoop Lua）

独立后端项目：**不要**和原 FastAPI 仓库混部。平台 Git 同步目录必须是 `workers/` + `modules/`。

## 在平台上做什么

1. 新建 **后端项目**，记下项目 code（前端 `VITE_API_BASE` 要用 `/{code}`）。
2. 绑定本仓库，Workers 路径 `workers`，Modules 路径 `modules`。
3. 环境变量：
   - `DB_CONFIG_ID`：已申请的 MySQL 配置 ID
   - `ADMIN_USERNAMES`（可选）：这些 SSO 账号首次进入即为管理员
4. 在 SQL 控制台执行 `sql/schema.sql`。
5. 同步 Git 后，路由由脚本头部 `@route` 自动注册。实际路径为 `/{项目code}/api/...`。

## 认证

- `/api/*`：`require_sso_auth true`，用 `ctx.user` 落本地 `users` 表。
- `/v1/*`：不走 SSO，校验 `Authorization: Bearer pkm_...` 或 `X-Api-Key`。
- `/api/health`：无需登录。

第一个访问系统的 SSO 用户成为 `admin`，其余默认 `editor`。角色与模型权限在前端「系统设置」里改。

## 文档接入

本期只收 **纯文本**（`.txt` / `.md` / `.html` 或粘贴正文）。Word / PDF / Excel 原文件解析后续迭代。技能与模版下载为 **CSV**。

## 大模型

系统设置里填 OpenAI 兼容 Base URL（需含 `/v1`）与模型名，抽取与问答走 `ctx.http`。单次请求受平台约 30s 限制，过长正文会截断。

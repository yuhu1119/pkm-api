# 产品知识模型：从零推 GitHub 到 SpeedLoop 联调

本文面向第一次做这件事的同学。你本地已经有两个**独立 Git 仓库**（还没有绑 GitHub）：

| 仓库 | 本机路径 | SpeedLoop 上对应 |
|------|----------|------------------|
| 后端 | `/Users/tang/AI/pkm-api` | **后端项目**（Lua Worker，Git 同步） |
| 前端 | `/Users/tang/AI/pkm-web` | **前端项目**（Vite 构建 `dist` 后上传） |

原来的「Product Knowledge Model」（FastAPI）**不要**再部署到云上，也不要和这两个仓混在一个仓库里。

请准备：GitHub 账号、能打开 SpeedLoop 控制台、公司 SSO 能登录。下面把菜单名按开发手册来写；若你司平台中文名略有差别，对一下同类入口即可。

---

## 第 0 步：先弄清会得到什么

联调成功后的形态：

1. 浏览器打开 **前端项目地址**，公司 SSO 登录后进入「产品知识模型」。
2. 页面请求发到 **`/{后端项目code}/api/...`**（平台会自动给后端路由加项目前缀）。
3. 数据存在平台 **SQLite**（不是你电脑上的文件）。
4. 没有本地 `admin / admin123`。第一个进来的人会成为管理员。

请准备一张纸记下这些值（后面会反复用到）：

- GitHub 用户名：________________
- 后端仓库地址：`https://github.com/____/pkm-api.git`
- 前端仓库地址：`https://github.com/____/pkm-web.git`
- SpeedLoop 控制台网址：________________
- **后端项目 code**（很短的英文/数字，决定 API 前缀）：________________
- 后端项目数字 ID（部署用）：________________
- 前端项目数字 ID：________________
- SQLite 配置 ID（`DB_CONFIG_ID`）：________________

---

## 第一部分：把代码推到 GitHub

### 1.1 确认本机仓库是干净的

打开「终端」（macOS 自带「终端」即可），**先提交后端尚未入库的 SQLite 改动**（若 `git status` 显示有修改）：

```bash
cd /Users/tang/AI/pkm-api
git status
git add sql/schema.sql modules workers README.md .env.example
git commit -m "改用平台 SQLite 建表与查询"
```

前端若显示干净，可跳过提交：

```bash
cd /Users/tang/AI/pkm-web
git status
```

### 1.2 在 GitHub 上建两个空仓库

1. 浏览器打开 [https://github.com/new](https://github.com/new)。
2. Repository name 填 `pkm-api`。
3. 选 **Private**（知识与配置不要公开）。
4. **不要**勾选 “Add a README”（本地已有提交，勾了会很难合）。
5. 点 Create repository。
6. 再同样建一个空仓库 `pkm-web`。

### 1.3 把本地后端推上去

把下面的 `你的用户名` 换成 GitHub 用户名。

```bash
cd /Users/tang/AI/pkm-api
git branch -m main
git remote add origin https://github.com/你的用户名/pkm-api.git
git push -u origin main
```

若提示登录：用浏览器登录，或使用 GitHub 的 **Personal Access Token** 当密码（Settings → Developer settings → Personal access tokens，勾 `repo` 权限）。

### 1.4 把本地前端推上去

```bash
cd /Users/tang/AI/pkm-web
git branch -m main
git remote add origin https://github.com/你的用户名/pkm-web.git
git push -u origin main
```

浏览器打开两个仓库主页，能看到 `workers/`、`modules/`（后端）和 `src/`（前端）即成功。

> 不要把 `.speedloop.json`、`.env`、部署令牌提交进 Git。仓库里只有 `.env.example` 和 `.speedloop.example.json`。

---

## 第二部分：SpeedLoop 建库（SQLite）

必须先有库，后端同步后才查得到表。

### 2.1 新建 SQLite 配置

1. 登录 SpeedLoop 控制台。
2. 打开 **Databases**。
3. 新建配置，**连接方式选 SQLite**（不要填 MySQL 主机、账号）。
4. 按表单填配额等必填项，保存。
5. **复制配置 ID**，这就是后面的 `DB_CONFIG_ID`。

刚建好的库可能短暂提示「尚未被任何节点接管」，等几十秒再操作。

### 2.2 建表（必须逐条 SQL）

平台对 SQLite **一次只允许一条语句**。不要把整个 `schema.sql` 一次贴进去。

1. 打开该 SQLite 配置的 **管控台 → SQL 控制台**。
2. 用编辑器打开本机文件：  
   `/Users/tang/AI/pkm-api/sql/schema.sql`
3. 按分号 `;` 切开，**每次只执行一条** `CREATE TABLE ...` 或 `CREATE INDEX ...`。
4. 全部成功后，执行下面这条检查（单独一条）：

```sql
SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;
```

应能看到 `users`、`products`、`knowledge_entities`、`app_settings` 等表。

---

## 第三部分：SpeedLoop 后端项目 + Git 同步

### 3.1 新建后端项目

1. 在 SpeedLoop 里 **新建后端项目**（接口 Worker / Lua 项目）。
2. 项目 **code** 用简短英文，例如 `pkm-api`。  
   **立刻记下来**：浏览器里的接口将是 `/{这个code}/api/...`。
3. 打开该项目的 **环境变量**，新增：

| 变量名 | 值 |
|--------|-----|
| `DB_CONFIG_ID` | 第 2.1 步复制的 SQLite 配置 ID |
| `ADMIN_USERNAMES` | 可选。填你的 SSO 登录名（多个用英文逗号）。不填则**第一个访问系统的人**成为 admin |

保存。不要把密钥写进 Git。

### 3.2 绑定 GitHub（让平台去拉 `pkm-api`）

在后端项目的 **Git 配置 / Git 同步**（名称以你司界面为准）中：

1. 仓库地址填：`https://github.com/你的用户名/pkm-api.git`
2. 分支填：`main`
3. 若要拉私有库，按表单填 GitHub Token（建议只读 `repo` 的 PAT）。
4. **Workers 路径**填：`workers`（不要填 `src`）。
5. **Modules 路径**填：`modules`。
6. 保存并执行一次 **同步**。

同步成功后，在 **Workers** 里应看到：

- `health` ← `workers/health.lua`
- `api` ← `workers/api.lua`
- `v1` ← `workers/v1.lua`

在 **Modules** 里应看到 `handlers`、`catalog`、`db` 等一长串。

在 **路由**（只读）里应看到类似：

- `GET /api/health`（无需 SSO）
- `ALL /api` 前缀（需要 SSO）
- `ALL /v1` 前缀（不走 SSO，用应用 Token）

平台会自动变成：`GET /{项目code}/api/health`。

若同步报错「缺少 require_sso_auth」：我们仓库里三个 Worker 已写全，把 Git 再同步一次。若仍失败，打开对应脚本确认头部三行鉴权都是 `true` 或 `false`。

### 3.3 先测健康检查（不登录）

在浏览器或终端访问（把 `平台域名` 和 `项目code` 换成你的）：

```text
https://平台域名/{后端项目code}/api/health
```

期望 JSON 类似：

```json
{ "ok": true, "name": "产品知识模型", "engine": "speedloop-lua", "db": "sqlite" }
```

若 404：Git 未同步成功，或 code 写错。  
若 500 且日志里有 `DB_CONFIG_ID`：环境变量没配或 ID 贴错。

`/api/auth/me` **现在测会失败或跳登录**，这是正常的，要等 SSO。

---

## 第四部分：SpeedLoop 前端项目 + 构建上传

前端**不是**把 `src` Git 同步成 Worker。它是静态站点：本地（或 CI）`npm run build`，把 `dist` 上传到**另一个**前端项目。

### 4.1 新建前端项目

1. SpeedLoop **新建前端项目**。
2. 记下该项目的 **数字 ID**（`speed init` / 自动部署会用到）。
3. 打开方式以平台为准：通常有独立访问域名或路径。

### 4.2 填构建时的 API 地址（最容易错）

前端在 **build 那一刻** 把接口前缀写进 JS。改环境变量后必须 **重新 build 再上传**。

在本机：

```bash
cd /Users/tang/AI/pkm-web
cp .env.example .env
```

用文本编辑打开 `.env`，**只改这一行**（斜杠 + 后端 code，不要多余空格）：

```bash
VITE_API_BASE=/你的后端项目code
```

例子：后端 code 是 `pkm-api`，就写：

```bash
VITE_API_BASE=/pkm-api
```

`VITE_PROXY_TARGET` 仅本地 `npm run dev` 用，**生产打包不要依赖它**。

同域网关下这样即可：页面在 `https://平台/...`，接口在 `https://平台/pkm-api/api/...`。

### 4.3 安装 Node 并构建

本机需已安装 Node.js（建议 18 或 20）。终端执行：

```bash
cd /Users/tang/AI/pkm-web
npm install
npm run build
```

成功后出现目录 `pkm-web/dist/`（里面有 `index.html` 和 `assets/`）。

### 4.4 上传到 SpeedLoop

**方法 A：控制台「自动部署」+ CLI（手册推荐）**

1. SpeedLoop 打开 **自动部署** → **创建令牌**，勾选刚建的**前端项目**（需要的话也勾后端）。
2. **令牌只显示一次**，复制到密码本。不要提交 Git。
3. 按你们内网要求安装 CLI（手册示例走京东 npm 源）：

```bash
npm config set registry=http://registry.m.jd.com
sudo npm install -g @jd/speedloop
```

4. 在 `pkm-web` 目录执行 `speed init`，按提示填：

- 服务器地址：SpeedLoop 控制台那个站点（不要抄手册里的 `localhost:9000`，除非你真在本机搭了平台）
- token：上一步的 `sl_deploy_...`
- frontend 的 `id`：前端项目数字 ID
- `buildDir`：`dist`
- `buildCommand`：`npm run build`

5. 生成的 `.speedloop.json` 已在 `.gitignore` 里，不要 `git add`。
6. 部署：

```bash
cd /Users/tang/AI/pkm-web
speed deploy frontend
```

**方法 B：控制台若提供「上传 dist.zip」**

```bash
cd /Users/tang/AI/pkm-web
# 先保证已 npm run build
cd dist && zip -r ../dist.zip . && cd ..
```

在自动部署/前端发布页上传 `dist.zip`，`project_id` 填前端项目 ID。

后端代码**以 Git 同步为准**。若令牌也授权了后端，可用 `speed deploy backend` 触发再同步一次，效果等同于在 Git 配置里点同步。

---

## 第五部分：SSO 联调（第一次打开页面）

### 5.1 用公司账号打开前端

1. 用 **SpeedLoop 能识别的 SSO 浏览器** 打开前端访问地址（不要用无痕且未登录的窗口）。
2. 应进入产品知识模型首页，而不是账号密码框。
3. 若停在「请通过公司平台 SSO 进入」转圈：

- 是否已登录平台；
- `VITE_API_BASE` 是否在 **build 前** 写成 `/{后端code}` 并重新上传了 dist；
- 浏览器开发者工具 Network 里 `/api/auth/me` 实际请求的 URL 是不是 `/{后端code}/api/auth/me`；
- 该请求若 401：SSO Cookie 没带到 API（前端、后端要在平台认为「已登录」的同一套域名下）。

### 5.2 确认你是管理员

打开 **系统设置 → 用户与模型权限**。应能看到自己的 SSO 用户名。第一个进来的人是 `admin`，或你在 `ADMIN_USERNAMES` 里写过的账号。

### 5.3 配大模型（抽取 / 问答才需要）

系统设置 → 大模型与文档连接：

- 提供方：OpenAI 兼容
- Base URL：必须带 `/v1`，例如 `https://api.deepseek.com/v1`
- 模型名、API Key
- 点「保存并验证大模型」，应提示可用

平台 Worker 单次大约 **30 秒**，超长正文会被截断。

### 5.4 业务冒烟（建议按顺序点）

1. **产品管理**：新建一个产品（不要选云端没有的「示例知识」）。
2. 进入该产品工作台 → **知识治理**：手工新建一条「产品定位」草稿，填必填项并发布。
3. **知识收集**：上传一个 `.txt` 或 `.md`（不要传 Word/PDF）。未配大模型时「抽取」会失败，属预期。
4. **技能配置**：能打开 78 类列表，下载 CSV。
5. **知识应用**：打一个知识版本；新建应用，**只显示一次**的 `pkm_...` Token 立刻复制保存。

开放接口（不走页面 SSO），把 Token 和 code 换掉：

```bash
curl -sS -H "Authorization: Bearer pkm_你的token" \
  "https://平台域名/{后端项目code}/v1/knowledge"
```

应返回 `ok: true` 和接口列表。

---

## 第六部分：以后改代码怎么更新

### 改后端 Lua

```bash
cd /Users/tang/AI/pkm-api
# 改 workers 或 modules
git add -A
git commit -m "说明为什么改"
git push origin main
```

到 SpeedLoop 后端项目再点一次 **Git 同步**（或 `speed deploy backend`）。

**改 `sql/schema.sql` 不会自动改已存在的库。** 已上线的表要自己在 SQL 控制台执行 `ALTER TABLE`（同样一次一条）。

### 改前端

```bash
cd /Users/tang/AI/pkm-web
# 改 src
git add -A && git commit -m "说明为什么改" && git push origin main
# 若改了 VITE_API_BASE，先改 .env 再构建
npm run build
speed deploy frontend
```

只 push GitHub **不会**自动更新线上前端，除非你们后来接了 GitHub Actions。

---

## 第七部分：本地对照前端（可选）

云上后端已经通、只想在本机改 UI 时：

`pkm-web/.env` 示例：

```bash
VITE_API_BASE=
VITE_PROXY_TARGET=https://你的SpeedLoop域名
VITE_API_PREFIX=/后端项目code
```

```bash
cd /Users/tang/AI/pkm-web
npm run dev
```

浏览器打开 `http://127.0.0.1:5173`。Cookie 能否带到公司域名上的 API，取决于登录态和跨域，**不通就改用已部署的前端做联调**。

---

## 出问题对照表

| 现象 | 先查什么 |
|------|----------|
| GitHub 推不上去 | 仓库是否空仓库、remote URL、是否要用 PAT |
| SpeedLoop 同步不到 Worker | Workers 路径是否为 `workers`，是否同步的是 **pkm-api** 而不是前端仓 |
| `/api/health` 404 | 项目 code、是否已同步、URL 是否带 `/{code}` |
| `/api/health` 500 | `DB_CONFIG_ID`、SQLite 是否已建表、库是否仍在接管中 |
| 页面一直 SSO 等待 | dist 是否用错误的 `VITE_API_BASE` 打的包；Network 里 me 的完整路径 |
| `/api/auth/me` 401 | 未走平台 SSO；或 API 与前端不在可共享登录态的域名 |
| 建表报错「一次多条」 | SQL 控制台一次只跑一条 `CREATE` |
| 抽取失败 | 未配 LLM；正文不是纯文本；超时 |
| 开放 `/v1` 401 | Token 复制漏了、应用已作废、没加 `Bearer ` |

---

## 不要做的事

- 不要把 FastAPI 那个旧仓 Git 同步进 SpeedLoop。
- 不要把 `workers` 配成 `src`。
- 不要把部署令牌、API Key 提交到 GitHub。
- 不要期望 Word/PDF 能解析（本期只支持 txt/md/html）。
- 不要改完前端只 push 代码却不重新 `build` + 上传 dist。

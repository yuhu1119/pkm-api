-- 与原 FastAPI 前端兼容的响应：错误体用 { detail }。

local M = {}

--- 返回 JSON。
function M.json(data)
  ctx.res.json(data)
end

--- 返回 HTTP 错误。
function M.fail(code, detail)
  ctx.res.status(code).json({ detail = detail or "请求失败" })
end

--- 下载文本附件。
function M.download(body, filename, mime)
  ctx.res.header("Content-Disposition", 'attachment; filename="' .. (filename or "download.txt") .. '"')
  ctx.res.send(body or "", mime or "text/plain; charset=utf-8")
end

return M

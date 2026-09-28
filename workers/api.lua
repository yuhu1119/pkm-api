--- @route ALL /api
--- @match_type prefix
--- @priority 100
--- @require_sso_auth true
--- @require_access_auth false
--- @require_data_auth false
-- 业务 API：SSO 登录后访问

local handlers = ctx.require("handlers")
handlers.handle()

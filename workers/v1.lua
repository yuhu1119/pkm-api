--- @route ALL /v1
--- @match_type prefix
--- @priority 100
--- @require_sso_auth false
--- @require_access_auth false
--- @require_data_auth false
-- 开放知识 API：应用 Token（pkm_）鉴权

local v1 = ctx.require("v1")
v1.handle()

--
-- identity-context —— 身份/角色头注入插件（本仓自定义插件）
--
-- 作用：从 openid-connect **验签后注入**的 X-Userinfo 中解析主体与角色，注入 X-User / X-Roles 头下发上游，
--       供应用侧 libs-java `starter-security`（GatewayPreAuthFilter）还原认证主体与方法级授权（@PreAuthorize）。
--
-- 与 tenant-context 的关系（职责分离 · 同链成对）：
--   · tenant-context  管「租户」头（X-Tenant-*），是数据/计算隔离的可信根；
--   · identity-context 管「身份/角色」头（X-User / X-Roles），是功能权限（模块 RBAC）的可信根。
--   二者都消费同一 X-Userinfo、都在 openid-connect 之后执行，但解决正交的两件事，故拆为两个插件。
--
-- 🔒 安全约束（与 tenant-context 一致）：
--   · 必须与 openid-connect 同路由且在其后执行；本插件不自行验签，只消费验签产物 X-Userinfo；
--   · 进入即清除客户端可能携带的 X-User / X-Roles，再写入网关可信值（防客户端伪造角色越权）；
--   · 未配 openid-connect 的路由上 X-Userinfo 不存在 → require_identity 时 fail-closed 401。
--
-- 角色来源：Keycloak realm 角色经协议映射器以 `roles` claim（多值字符串数组）注入 userinfo
--   （见 keycloak/realm-export.json 的 realm-roles mapper）。X-Roles = 逗号分隔角色名（去重、保序），
--   角色名**不含** ROLE_ 前缀——starter-security 据 rolePrefix 默认补 ROLE_。
--
local core = require("apisix.core")
local ngx  = ngx

local plugin_name = "identity-context"

local schema = {
    type = "object",
    properties = {
        userinfo_header  = { type = "string",  default = "X-Userinfo" },   -- 须与 openid-connect 的 set_userinfo_header 对齐
        user_header      = { type = "string",  default = "X-User" },        -- 主体标识头（对齐 starter-security userHeader）
        roles_header     = { type = "string",  default = "X-Roles" },       -- 角色头（逗号分隔；对齐 starter-security rolesHeader）
        subject_claim    = { type = "string",  default = "sub" },           -- OIDC 标准主体声明
        roles_claim      = { type = "string",  default = "roles" },         -- realm 角色映射器写入 userinfo 的 claim 名
        require_identity = { type = "boolean", default = true },            -- X-Userinfo 缺失时是否 fail-closed
        max_userinfo_len = { type = "integer", default = 16384 },           -- 防超长头 DoS 兜底
    },
}

local _M = {
    version  = 0.1,
    priority = 2597,   -- 紧随 openid-connect(2599) / tenant-context(2598) 之后执行
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- 解码 openid-connect 注入的 base64(JSON) userinfo（容错 base64 / base64url）。
local function decode_userinfo(b64, max_len)
    if #b64 > max_len then
        return nil, "userinfo header too large"
    end
    local raw = ngx.decode_base64(b64)
    if not raw then
        local s = b64:gsub("-", "+"):gsub("_", "/")
        local rem = #s % 4
        if rem > 0 then s = s .. string.rep("=", 4 - rem) end
        raw = ngx.decode_base64(s)
    end
    if not raw then
        return nil, "invalid base64 userinfo"
    end
    local info = core.json.decode(raw)
    if type(info) ~= "table" then
        return nil, "invalid JSON userinfo"
    end
    return info
end

-- 规范化角色 claim → 逗号分隔字符串：兼容数组 ["a","b"] / 单字符串 "a" / 逗号串 "a,b"。
-- 去空白、丢空项、去重保序；无有效角色返回 nil（不注入 X-Roles）。
local function normalize_roles(claim)
    local items
    local t = type(claim)
    if t == "table" then
        items = {}
        for _, v in ipairs(claim) do
            if type(v) == "string" then
                items[#items + 1] = v
            end
        end
    elseif t == "string" then
        items = {}
        for part in claim:gmatch("[^,]+") do
            items[#items + 1] = part
        end
    else
        return nil
    end

    local seen, out = {}, {}
    for _, v in ipairs(items) do
        local role = v:gsub("^%s*(.-)%s*$", "%1")   -- trim
        if role ~= "" and not seen[role] then
            seen[role] = true
            out[#out + 1] = role
        end
    end
    if #out == 0 then
        return nil
    end
    return table.concat(out, ",")
end

function _M.rewrite(conf, ctx)
    -- 1) 清除客户端伪造的身份/角色头（防越权）
    core.request.set_header(ctx, conf.user_header, nil)
    core.request.set_header(ctx, conf.roles_header, nil)

    -- 2) 读取 openid-connect 验签后注入的 userinfo；缺失 = 身份未由网关建立 → fail-closed
    local userinfo_b64 = core.request.header(ctx, conf.userinfo_header)
    if not userinfo_b64 then
        core.log.warn(plugin_name, ": missing ", conf.userinfo_header,
                      " — 该路由是否漏配 openid-connect？")
        if conf.require_identity then
            return 401, { message = "identity not established (openid-connect required)" }
        end
        return
    end

    local info, err = decode_userinfo(userinfo_b64, conf.max_userinfo_len)
    if not info then
        core.log.warn(plugin_name, ": ", err)
        if conf.require_identity then
            return 403, { message = "cannot resolve identity" }
        end
        return
    end

    -- 3) 注入主体头（sub 为 OIDC 标准主体声明）
    local subject = info[conf.subject_claim]
    if type(subject) == "string" and subject ~= "" then
        core.request.set_header(ctx, conf.user_header, subject)
    end

    -- 4) 注入角色头（无有效角色则不注入；应用侧据此判定无授权 → @PreAuthorize 拒绝 403）
    local roles = normalize_roles(info[conf.roles_claim])
    if roles then
        core.request.set_header(ctx, conf.roles_header, roles)
    end
end

return _M

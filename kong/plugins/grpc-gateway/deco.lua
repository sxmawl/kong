-- Copyright (c) Kong Inc. 2020

package.loaded.lua_pack = nil   -- BUG: why?
require "lua_pack"
local cjson = require "cjson"
local protoc = require "protoc"
local pb = require "pb"

local setmetatable = setmetatable

local bpack = string.pack         -- luacheck: ignore string
local bunpack = string.unpack     -- luacheck: ignore string

local ngx = ngx
local decode_base64 = ngx.decode_base64
local encode_base64 = ngx.encode_base64
local re_gsub = ngx.re.gsub
local re_match = ngx.re.match

local encode_json = cjson.encode
local decode_json = cjson.decode

local deco = {}
deco.__index = deco


local function safe_access(t, ...)
  for _, k in ipairs({...}) do
    if t[k] then
      t = t[k]
    else
      return
    end
  end
  return t
end

local valid_method = {
  get = true,
  post = true,
  put = true,
  patch = true,
  delete = true,
}

--[[
  // ### Path template syntax
  //
  //     Template = "/" Segments [ Verb ] ;
  //     Segments = Segment { "/" Segment } ;
  //     Segment  = "*" | "**" | LITERAL | Variable ;
  //     Variable = "{" FieldPath [ "=" Segments ] "}" ;
  //     FieldPath = IDENT { "." IDENT } ;
  //     Verb     = ":" LITERAL ;
]]
-- assume LITERAL = [-_.~0-9a-zA-Z], needs more
local options_path_regex = [=[{([-_.~0-9a-zA-Z]+)=?((?:(?:\*|\*\*|[-_.~0-9a-zA-Z])/?)+)?}]=]

local function parse_options_path(path)
  local match_groups = {}
  local match_group_idx = 1
  local path_regex, _, err = re_gsub("^" .. path .. "$", options_path_regex, function(m)
    local var = m[1]
    local paths = m[2]
    -- store lookup table to matched groups to variable name
    match_groups[match_group_idx] = var
    match_group_idx = match_group_idx + 1
    if not paths or paths == "*" then
      return "([^/]+)"
    else
      return ("(%s)"):format(
        paths:gsub("%*%*", ".+"):gsub("%*", "[^/]+")
      )
    end
  end, "jo")
  if err then
    return nil, nil, err
  end

  return path_regex, match_groups
end

-- TODO: Any fields in the request message which are not bound by the path template

-- parse, compile and load .proto file
-- returns a table mapping valid request URLs to input/output types
local _proto_info = {}
local function get_proto_info(fname)
  local info = _proto_info[fname]
  if info then
    return info
  end

  local p = protoc.new()
  local parsed = p:parsefile(fname)

  info = {}

  for _, srvc in ipairs(parsed.service) do
    for _, mthd in ipairs(srvc.method) do
      local options_bindings =  {
        safe_access(mthd, "options", "options", "google.api.http"),
        safe_access(mthd, "options", "options", "google.api.http", "additional_bindings")
      }
      for _, options in ipairs(options_bindings) do
        for http_method, http_path in pairs(options) do
          http_method = http_method:lower()
          if valid_method[http_method] then
            local preg, grp, err = parse_options_path(http_path)
            if err then
              ngx.log(ngx.ERR, "error parsing options path ", err)
            else
              if not info[http_method] then
                info[http_method] = {}
              end
              info[http_method][preg] = {
                mthd.input_type,
                mthd.output_type,
                ("/%s.%s/%s"):format(parsed.package, srvc.name, mthd.name), -- request path
                grp,
                options.body,
              }
            end
          end
        end
      end
    end
  end

  _proto_info[fname] = info

  p:loadfile(fname)
  return info
end

-- return input and output names of the method specified by the url path
-- TODO: memoize
local function rpc_transcode(method, path, protofile)
  if not protofile then
    return nil
  end

  local info = get_proto_info(protofile)
  info = info[method]
  if not info then
    return nil, ("Unkown method %q"):format(method)
  end
  for p, types in pairs(info) do
    local m, err = re_match(path, p, "jo")
    if err then
      return nil, ("Cannot match path %q"):format(err)
    end
    if m then
      local vars = {}
      for i, g in ipairs(types[4]) do
        vars[g] = m[i]
      end
      return types[1], types[2], types[3], vars, types[5]
    end
  end
  return nil, ("Unkown path %q"):format(path)
end


function deco.new(method, path, protofile)
  if not protofile then
    return nil, "transcoding requests require a .proto file defining the service"
  end

  local input_type, output_type, rewrite_path, template_payload, body_variable = rpc_transcode(method, path, protofile)

  if not input_type then
    return nil, output_type
  end

  return setmetatable({
    input_type = input_type,
    output_type = output_type,
    rewrite_path = rewrite_path,
    template_payload = template_payload,
    body_variable = body_variable,
  }, deco)
end


local function frame(ftype, msg)
  return bpack("C>I", ftype, #msg) .. msg
end

local function unframe(body)
  if not body or #body <= 5 then
    return nil, body
  end

  local pos, ftype, sz = bunpack(body, "C>I")       -- luacheck: ignore ftype
  local frame_end = pos + sz - 1
  if frame_end > #body then
    return nil, body
  end

  return body:sub(pos, frame_end), body:sub(frame_end + 1)
end


function deco:upstream(body)
  --[[
    // Note that when using `*` in the body mapping, it is not possible to
    // have HTTP parameters, as all fields not bound by the path end in
    // the body. This makes this option more rarely used in practice when
    // defining REST APIs. The common usage of `*` is in custom methods
    // which don't use the URL at all for transferring data.
  ]]
  -- TODO: do we allow http parameter when body is not *?
  local payload = self.template_payload
  if self.body_variable then
    if body then
      local body_decoded = cjson.decode(body)
      if self.body_variable ~= "*" then
        --[[
          // For HTTP methods that allow a request body, the `body` field
          // specifies the mapping. Consider a REST update method on the
          // message resource collection:
        ]] 
        payload[self.body_variable] = body_decoded
      else
        --[[
          // The special name `*` can be used in the body mapping to define that
          // every field not bound by the path template should be mapped to the
          // request body.  This enables the following alternative definition of
          // the update method:
        ]]
        for k, v in pairs(body_decoded) do
          payload[k] = v
        end
      end
    end
  else
    --[[
      // Any fields in the request message which are not bound by the path template
      // automatically become HTTP query parameters if there is no HTTP request body.
    ]]--
    -- TODO primitive type checking
    local args, err = ngx.req.get_uri_args()
    if err then
    else
      for k, v in pairs(args) do
        payload[k] = v
      end
    end
  end
  body = frame(0x0, pb.encode(self.input_type, payload))

  return body
end


function deco:downstream(chunk)
  local body = (self.downstream_body or "") .. chunk

  local out, n = {}, 1
  local msg, body = unframe(body)

  while msg do
    msg = encode_json(pb.decode(self.output_type, msg))

    out[n] = msg
    n = n + 1
    msg, body = unframe(body)
  end

  self.downstream_body = body
  chunk = table.concat(out)

  return chunk
end


function deco:frame(ftype, msg)
  local f = frame(ftype, msg)

  return f
end


return deco

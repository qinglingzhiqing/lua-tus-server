-- Tus server for OpenResty or NGINX with mod_lua
--
-- Copyright (C) by Martin Matuska (mmatuska)

local string = require "string"
local rstring = require "resty.string"
local random = require "resty.random"
local tus_version = "1.0.0"

local _M = {}
_M.config = {
  resource_url_prefix="",
  max_size=0,
  chunk_size=65536,
  socket_timeout=30000,
  expire_timeout=0,
  storage_backend="tus.storage_file",
  storage_backend_config={},
  hard_delete=false,
  extension = {
    checksum=true,
    creation=true,
    creation_defer_length=true,
    expiration=true,
    termination=true
  }
}
_M.resource = {
  name=nil,
  info=nil,
  state=nil
}
_M.sb = nil

local function split(s, delimiter)
    local result = {};
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
	table.insert(result, match);
    end
    return result;
end

local function decode_base64_pair(text)
    if not text then
	return nil
    end
    local p = split(text, " ")
    if p[1] == nil or p[2] == nil or p[3] ~= nil then
	return nil
    end
    local key = p[1]
    local val = ngx.decode_base64(p[2])
    if val == nil then
	return nil
    end
    return {key=key,val=val}
end

local function decode_metadata(metadata)
    if metadata == nil then
	return nil
    end
    local ret = {}
    local q = split(metadata, ",")
    if not q then
      q = {}
      table.insert(q, metadata)
    end
    for _, v in pairs(q) do
	local p = decode_base64_pair(v)
	if not p then
	    return nil
	end
	ret[p.key] = p.val
    end
    return ret
end

local function encode_metadata(mtable)
    local first = true
    local ret = ""
    for key, val in pairs(mtable) do
	if not first then
	     ret = ret .. ","
	else
	     first = false
	end
	ret = ret .. key .. " " .. ngx.encode_base64(val)
    end
    return ret
end

local function get_extensions_string(extensions)
    if not extensions then
	return false
    end

    local e = {}
    for k in pairs(extensions) do
	table.insert(e, k)
    end
    table.sort(e)
    local exstr = ""
    for _,key in ipairs(e) do
	if extensions[key] then
	    if exstr ~= "" then
		    exstr = exstr .. ","
	    end
	    exstr = exstr .. key
	end
    end
    if exstr == "" then
	return nil
    end
    return exstr:gsub("_", "-")
end

local function interr()
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    return false
end

local function exit_status(status)
   ngx.status = status
   ngx.header["Content-Length"] = 0
end

function _M.process_request(self)
    -- All responses include the Tus-Resumable header
    ngx.header["Tus-Resumable"] = tus_version

    if not self.config then
	return interr()
    end

    -- Store extension support
    local extensions = self.config.extension
    -- Autodisable creation-defer-length if creation is disabled
    if not extensions.creation then
	ngx.log(ngx.NOTICE, "Auto-disabling creation-defer-length extension")
	extensions.creation_defer_length = false
    end

    -- Read storage backend
    local sb = require(self.config.storage_backend)
    if not sb then
       ngx.log(ngx.ERR, "could not load storage backend")
       return interr()
    end
    sb.config = self.config.storage_backend_config
    self.sb = sb

    local headers = ngx.req.get_headers()
    local method

    if headers["x-http-method-override"] then
	method = headers["x-http-method-override"]
    else
	method = ngx.req.get_method()
    end

    self.method = method

    if method == "OPTIONS" then
	local extstr = get_extensions_string(extensions)
	ngx.header["Tus-Version"] = tus_version
	if extstr then
	    ngx.header["Tus-Extension"] = extstr
	end
	if extensions.checksum then
	    ngx.header["Tus-Checksum-Algorithm"] = "md5,sha1,sha256"
	end
	if self.config["max_size"] > 0 then
	    ngx.header["Tus-Max-Size"] = self.config["max_size"]
	end
	ngx.status = ngx.HTTP_NO_CONTENT
	return true
    end

    if (method ~= "HEAD" and method ~= "PATCH"
      and method ~= "POST" and method ~= "DELETE") or
      (method == "POST" and not extensions.creation) or
      (method == "DELETE" and not extensions.termination) then
	exit_status(ngx.HTTP_NOT_ALLOWED)
	return true
    end

    if not headers["tus-resumable"] or
      headers["tus-resumable"] ~= tus_version then
	exit_status(412) -- Precondition Failed
	return true
    end

    if method == "POST" then
	local ulen
	if headers["upload-length"] then
	    ulen = tonumber(headers["upload-length"])
	else
	    ulen = false
	end
	local udefer
	-- Ignore Upload-Defer-Length if not supported
	if extensions.creation_defer_length then
	    if headers["upload-defer-length"] then
		udefer = tonumber(headers["upload-defer-length"])
	    else
		udefer = false
	    end
	else
	    udefer = false
	end
	local umeta = headers["upload-metadata"]
	local metadata = nil
	local newresource
	local rnd
	local bad_request = false
	if udefer ~= false and udefer ~= 1 then
	    ngx.log(ngx.INFO, "Invalid Upload-Defer-Length")
	    bad_request = true
	elseif not ulen and not udefer then
	    ngx.log(ngx.INFO, "Received neither Upload-Length nor Upload-Defer-Length")
	    bad_request = true
	elseif ulen and udefer then
	    ngx.log(ngx.INFO, "Received both Upload-Length and Upload-Defer-Length")
	    bad_request = true
	elseif ulen and ulen < 0 then
	    ngx.log(ngx.INFO, "Received negative Upload-Length")
	    bad_request = true
	end
	if bad_request then
	    exit_status(ngx.HTTP_BAD_REQUEST)
	    return true
	end
	if self.config["max_size"] > 0 and ulen and
	  ulen > self.config["max_size"] then
	    ngx.log(ngx.INFO, "Upload-Length exceeds Tus-Max-Size")
	    exit_status(413) -- Request Entity Too Large
	    return true
	end
	if umeta and umeta ~= "" then
	    metadata = decode_metadata(umeta)
	    if not metadata then
		ngx.log(ngx.INFO, "Invalid Upload-Metadata")
		exit_status(ngx.HTTP_BAD_REQUEST)
		return true
	    end
	end
	while true do
	    rnd = random.bytes(16,true)
	    newresource = rstring.to_hex(rnd)
	    if not sb:get_info(newresource) then break end
	end
	local info = {}
	info.offset = 0
	if ulen ~= false then
	    info.size = ulen
	end
	if udefer ~= false then
	    info.defer = udefer
	end
	info.metadata = metadata
	if extensions.expiration and self.config.expire_timeout > 0 then
	    info.expires = ngx.time() + self.config.expire_timeout
	end
	local ret = sb:create(newresource, info)
	if not ret then
	    ngx.log(ngx.ERR, "Unable to create resource: " .. newresource)
	    return interr()
	else
	    ngx.header["Location"] = self.config.resource_url_prefix .. "/" .. newresource
	    if extensions.expiration and info.expires then
		ngx.header["Upload-Expires"] = ngx.http_time(info.expires)
	    end
	    if info.defer then
		ngx.header["Upload-Defer-Length"] = info.defer
	    end
	    self.resource.name = newresource
	    self.resource.state = "created"
	    exit_status(ngx.HTTP_CREATED)
	    return true
	end
    end

    -- At the moment we support only hex resources
    local resource = string.match(ngx.var.uri,"^.*/([0-9a-f]+)$")
    if not resource then
	ngx.log(ngx.INFO, "Invalid resource endpoint")
	exit_status(ngx.HTTP_NOT_FOUND)
	return true
    end
    self.resource.name = resource

    -- For all following requests the resource must exist
    self.resource.info = sb:get_info(resource)
    if not self.resource.info or not self.resource.info.offset then
       exit_status(ngx.HTTP_NOT_FOUND)
       return true
    end
    -- If the resource is marked as deleted, return 410
    if self.resource.info.deleted then
	self.resource.state = "deleted"
	exit_status(ngx.HTTP_GONE)
	return true
    end

    if self.resource.info.offset == 0 then
	self.resource.state = "empty"
    elseif self.resource.info.size == self.resource.info.offset then
	self.resource.state = "completed"
    else
	self.resource.state = "partial"
    end

    if method == "HEAD" then
	-- If creation-defer-length is disabled, ignore such resources
	if not extensions.creation_defer_length and
	  self.resource.info.defer then
	    ngx.log(ngx.INFO, "Ignoring resource due to disabled creation-defer-length")
	    exit_status(ngx.HTTP_FORBIDDEN)
	    return true
	end
	ngx.header["Cache-Control"] = "no_store"
	local expires = self.resource.info.expires
	if extensions.expiration and expires then
	    if ngx.now() > expires then
		self.resource.state = "expired"
		exit_status(ngx.HTTP_GONE)
		return true
	    end
	end
	ngx.header["Upload-Offset"] = self.resource.info.offset
	if self.resource.info.defer then
	    ngx.header["Upload-Defer-Length"] = 1
	end
	if self.resource.info.size then
	    ngx.header["Upload-Length"] = self.resource.info.size
	end
	if self.resource.info.metadata then
	    local metadata = encode_metadata(self.resource.info.metadata)
	    if metadata then
	      ngx.header["Upload-Metadata"] = metadata
	    end
	end
	if extensions.expiration and expires then
	    ngx.header["Upload-Expires"] = ngx.http_time(expires)
	end
	exit_status(ngx.HTTP_NO_CONTENT)
	return true
    end

    if method == "DELETE" then
	self.resource.info.deleted = true
	if not sb:update_info(resource, self.resource.info) then
	    ngx.log(ngx.ERR, "Error updating resource metadata: " .. resource)
	    return interr()
	end
	if self.config.hard_delete and not sb:delete(resource) then
	    ngx.log(ngx.ERR, "Error deleting resource: " .. resource)
	    return interr()
	end
	exit_status(ngx.HTTP_NO_CONTENT)
	self.resource.state = "deleted"
	return true
    end

    if method == "PATCH" then
	if headers["content-type"] ~= "application/offset+octet-stream" then
	    ngx.log(ngx.INFO, "Invalid or missing header: Content-Type")
	    exit_status(415) -- Unsupported Media Type
	    return true
	end
	local upload_offset = tonumber(headers["upload-offset"])
	if not upload_offset or upload_offset ~= self.resource.info.offset then
	    ngx.log(ngx.INFO, "Upload-Offset mismatch: " .. resource)
	    exit_status(ngx.HTTP_CONFLICT)
	    return true
	end
	local upload_length
	if self.resource.info.defer then
	    if not extensions.creation_defer_length then
		ngx.log(ngx.INFO, "Ignoring resource due to disabled creation-defer-length")
		exit_status(ngx.HTTP_FORBIDDEN)
		return true
	    end
	    upload_length = tonumber(headers["upload-length"])
	    if not upload_length then
		ngx.log(ngx.INFO, "Invalid header: Upload-Length")
		exit_status(ngx.HTTP_CONFLICT)
		return true
	    end
	    if self.config["max_size"] > 0 and
	      upload_length > self.config["max_size"] then
		ngx.log(ngx.INFO, "Upload-Length exceeds Tus-Max-Size")
		exit_status(413) -- Request Entity Too Large
		return true
	    end
	    self.resource.info.defer = nil
	    self.resource.info.size = upload_length
	    if not sb:update_info(resource, self.resource.info) then
		ngx.log(ngx.ERR, "Error updating resource metadata: " .. resource)
		return interr()
	    end
	else
	    upload_length = self.resource.info.size
	end
	local content_length = tonumber(headers["content-length"])
	if not content_length or content_length < 0 then
	    ngx.log(ngx.INFO, "Invalid header: Content-Length")
	    exit_status(ngx.HTTP_BAD_REQUEST)
	    return true
	end

	local resty_hash
	local c_hash -- Client-supplied hash
	local hash_ctx = nil

	if headers["upload-checksum"] then
	    if not extensions.checksum then
		ngx.log(ngx.INFO, "Upload-Checksum without checksum extension")
		exit_status(ngx.HTTP_BAD_REQUEST)
		return true
	    end
	    local p = decode_base64_pair(headers["upload-checksum"])
	    if not p then
		ngx.log(ngx.INFO, "Invalid header: Upload-Checksum")
		exit_status(ngx.HTTP_BAD_REQUEST)
		return true
	    end
	    local c_algo = p.key -- Client supplied algo
	    if c_algo ~= "md5" and c_algo ~= "sha1" and c_algo ~= "sha256" then
		ngx.log(ngx.INFO, "Unsupported checksum algorithm: " .. c_algo)
		exit_status(ngx.HTTP_BAD_REQUEST)
		return true
	    end
	    c_hash = p.val
	    -- In theory we support everything from lua-resty-string
	    resty_hash = require('resty/' .. c_algo)
	    if not resty_hash then
		ngx.log(ngx.WARN, "Error loading supported checksum algorithm: " .. c_algo)
		exit_status(ngx.HTTP_BAD_REQUEST)
		return true
	    end
	    hash_ctx = resty_hash:new()
	end

	if (upload_offset + content_length) > upload_length then
	    ngx.log(ngx.INFO, "Upload-Offset + Content-Length exceeds Upload-Length")
	    exit_status(ngx.HTTP_CONFLICT)
	    return true
	end
	if self.resource.info.expires then
	    local secs = self.resource.info.expires
	    if secs and ngx.now() > secs then
		self.resource.state = "expired"
		exit_status(ngx.HTTP_GONE)
		return true
	    end
	end
	if content_length == 0 then
	    exit_status(ngx.HTTP_NO_CONTENT)
	    return true
	end

	local socket, err = ngx.req.socket()
	if not socket then
	    ngx.log(ngx.ERR, "Socket error: "  .. err)
	    return interr()
	end
	socket:settimeout(self.config.socket_timeout)

	local to_receive = content_length
	local cur_offset = upload_offset
	local csize
	if not sb:open(resource, upload_offset) then
	    ngx.log(ngx.ERR, "Error opening resource for writing: " .. resource)
	    return interr()
	end
	while true do
	    if to_receive <= 0 then break end
	    if to_receive > self.config.chunk_size then
		csize = self.config.chunk_size
	    else
		csize = to_receive
	    end
	    local chunk, e = socket:receive(csize)
	    if e then
		sb:close(resource)
		ngx.log(ngx.ERR, "Socket receive error: " .. e)
		return interr()
	    end
	    if hash_ctx then
		hash_ctx:update(chunk)
	    end
	    if not sb:write(chunk) then
		sb:close(resource)
		ngx.log(ngx.ERR, "Error writing to resource: " .. resource)
		return interr()
	    end
	    cur_offset = cur_offset + csize
	    to_receive = to_receive - csize
	end
	sb:close(resource)
	if hash_ctx then
	    local digest = hash_ctx:final()
	    if digest then
		if c_hash ~= rstring.to_hex(digest) then
		    ngx.log(ngx.INFO, "Checksum mismatch")
		    exit_status(460)
		    return true
		end
	    else
		ngx.log("Error computing checksum: " .. resource)
		return interr()
	    end
	end
	self.resource.info.offset = cur_offset
	ngx.header["Upload-Offset"] = cur_offset
	if not sb:update_info(resource, self.resource.info) then
	    ngx.log(ngx.ERR, "Error updating resource metadata: " .. resource)
	    return interr()
	end
	exit_status(ngx.HTTP_NO_CONTENT)
	if cur_offset == self.resource.info.size then
	    self.resource.state = "completed"
	end
	return true
    end
end

return _M

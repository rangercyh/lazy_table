local wire_type = require "wire_type"

local reader_mt = {}
reader_mt.__index = reader_mt

local index_new = nil
------------------ reader ------------------
local function check_file_handle(file_handle)
    assert(file_handle, "need file handle")
    assert(file_handle.seek, "need seek function")
    assert(file_handle.read, "need read function")
end

local function reader_new(file_handle)
    local raw = {
        v_file_handle = false,
        v_cache = setmetatable({}, {__mode = "kv"})
    }
    if type(file_handle)=="string" then
        raw.v_file_handle = io.open(file_handle, "rb")
    else
        raw.v_file_handle = file_handle
    end
    check_file_handle(raw.v_file_handle)
    return setmetatable(raw, reader_mt)
end

local function read_type(self)
    local s = self.v_file_handle:read(1)
    local v = string.unpack("<I1", s)
    -- print("read_type size: 1 value:"..(v))
    return v
end

local function read_string(self)
    local sz_s = self.v_file_handle:read(2)
    local sz = string.unpack("<I2", sz_s)
    local s = self.v_file_handle:read(sz)
    -- print("read_string size: "..(sz+2).." value:"..s)
    return s
end

local function read_integer_number(self)
    local s = self.v_file_handle:read(8)
    local v = string.unpack("<I8", s)
    -- print("read_integer size: 8 value:"..(v))
    return v
end

local function read_real_number(self)
    local s = self.v_file_handle:read(8)
    local v = string.unpack("d", s)
    -- print("read_real size: 8 value:"..(v))
    return v
end

local function read_offset(self)
    local s = self.v_file_handle:read(4)
    local v = string.unpack("<I4", s)
    -- print("read_offset size: 4 value:"..(v))
    return v
end

local function read_offset_value(self, pos)
    local cur_pos = self.v_file_handle:seek("cur")
    self.v_file_handle:seek("set", pos)
    local type, v = self:read_value()
    assert(type~=wire_type.OFFSET_WIRE_TYPE)
    self.v_file_handle:seek("set", cur_pos)
    return type, v
end

local function set_value(type, v)
    if type == wire_type.OFFSET_WIRE_TYPE then
        return v
    else
        return {
            type = type,
            value = v,
        }
    end
end

local function set_key(self, type, v)
    if type == wire_type.OFFSET_WIRE_TYPE then
        type, v = read_offset_value(self, v)
        if  type == wire_type.NIL_WIRE_TYPE or 
            type == wire_type.MAP_WIRE_TYPE or
            type == wire_type.LIST_WIRE_TYPE then
            error("invalid key type:"..tostring(key))
        end
    end
    return v
end

local function read_list(self)
    local cur_pos = self.v_file_handle:seek("cur")
    local cache_value = self.v_cache[cur_pos]
    if cache_value then
        return cache_value
    end
    local list = {}
    local index_obj = index_new(list, self)
    self.v_cache[cur_pos] = index_obj
    local s = self.v_file_handle:read(4)
    local entry_len = string.unpack("<I4", s)
    -- print("read list entry_len:"..(entry_len))
    for i=1,entry_len do
        local type, v = self:read_value()
        list[i] = set_value(type, v)
    end
    return index_obj
end


local function read_map(self)
    local cur_pos = self.v_file_handle:seek("cur")
    local cache_value = self.v_cache[cur_pos]
    if cache_value then
        return cache_value
    end
    local map = {}
    local index_obj = index_new(map, self)
    self.v_cache[cur_pos] = index_obj
    local s = self.v_file_handle:read(4)
    local entry_len = string.unpack("<I4", s)
    -- print("read map entry_len:"..(entry_len))
    for i=1,entry_len do
        local tk, vk = self:read_value()
        local tv, vv = self:read_value()
        local key = set_key(self, tk, vk)
        local value = set_value(tv, vv)
        assert(map[key]==nil)
        map[key] = value
    end
    return index_obj
end


local type_drive_map = {
    [wire_type.NIL_WIRE_TYPE] = function (self)
        return nil
    end,

    [wire_type.MAP_WIRE_TYPE] = read_map,

    [wire_type.LIST_WIRE_TYPE] = read_list,

    [wire_type.STRING_WIRE_TYPE] = read_string,

    [wire_type.REAL_WIRE_TYPE] = read_real_number,

    [wire_type.INTEGET_WIRE_TYPE] = read_integer_number,

    [wire_type.TRUE_WIRE_TYPE] = function() 
        return true 
    end,

    [wire_type.FALSE_WIRE_TYPE] = function ()
        return false
    end,

    [wire_type.OFFSET_WIRE_TYPE] = read_offset,
}


function reader_mt:read_value()
    local type = read_type(self)
    local f = type_drive_map[type]
    if not f then
        error("invalid type:"..tostring(type))
    end
    local v = f(self)
    return type, v
end


------------------ index ------------------
local function index_get_value(meta_value, reader)
    local tv = type(meta_value)
    if tv == "number" then  -- offset 
        local type, v = read_offset_value(reader, meta_value)
        return v
    elseif tv == "table" then -- value
        return meta_value.value
    else
        return nil
    end
end

local function index_meta_index(raw, key)
    local mt = getmetatable(raw)
    local meta_info  = mt.__meta_info
    local meta_value = meta_info[key]
    local v = index_get_value(meta_value, mt.__reader)
    rawset(raw, key, v)
    return v
end

local function index_meta_len(raw)
    local mt = getmetatable(raw)
    local meta_info = mt.__meta_info
    return #meta_info
end

local function __meta_next(raw, key)
    local mt = getmetatable(raw)
    local meta_info = mt.__meta_info
    local k, v = next(meta_info, key)
    local raw_v = rawget(raw, k)
    if raw_v==nil and k then
        v = raw[k]
        rawset(raw, k, v)
    else
        v = raw_v
    end
    return k, v
end


local function index_meta_pairs(raw)
    return __meta_next, raw
end

index_new = function (meta_info, reader)
    local raw = {}
    local mt  = {
        __reader = reader,
        __meta_info = meta_info,
        __index = index_meta_index,
        __len = index_meta_len,
        __pairs = index_meta_pairs,
    }
    return setmetatable(raw, mt)
end


local function decode_binary_data(file_handle)
    local reader = reader_new(file_handle)
    local type, v = reader:read_value()
    if type ~= wire_type.MAP_WIRE_TYPE and type ~= wire_type.LIST_WIRE_TYPE then
        error("invalid binary data head, must map or list type")
    end
    return v
end

return decode_binary_data

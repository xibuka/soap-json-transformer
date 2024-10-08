---------------------------------------------------------------------
-- LuaSoap implementation for Lua.
--
-- See Copyright Notice in license.html
---------------------------------------------------------------------

local assert, error, pairs, tonumber, tostring, type = assert, error, pairs, tonumber, tostring, type
local table = require"table"
local tconcat, tinsert, tremove = table.concat, table.insert, table.remove
local string = require"string"
local gsub, strfind, strformat = string.gsub, string.find, string.format
local max = require"math".max
local lom = require"lxp.lom"
local parse = lom.parse


local tescape = {
	['&'] = '&amp;',
	['<'] = '&lt;',
	['>'] = '&gt;',
	['"'] = '&quot;',
	["'"] = '&apos;',
}
---------------------------------------------------------------------
-- Escape special characters.
---------------------------------------------------------------------
local function escape (text)
	return (gsub (text, "([&<>'\"])", tescape))
end

local tunescape = {
	['&amp;'] = '&',
	['&lt;'] = '<',
	['&gt;'] = '>',
	['&quot;'] = '"',
	['&apos;'] = "'",
}
---------------------------------------------------------------------
-- Unescape special characters.
---------------------------------------------------------------------
local function unescape (text)
	return (gsub (text, "(&%a+%;)", tunescape))
end

local serialize

---------------------------------------------------------------------
-- Serialize the table of attributes.
-- @param a Table with the attributes of an element.
-- @return String representation of the object.
---------------------------------------------------------------------
local function attrs (a)
	if not a then
		return "" -- no attributes
	else
		local c = {}
		if a[1] then
			for i = 1, #a do
				local v = a[i]
				c[i] = strformat ("%s=%q", v, tostring(a[v]))
			end
		else
			for i, v in pairs (a) do
				c[#c+1] = strformat ("%s=%q", i, tostring(v))
			end
		end
		if #c > 0 then
			return " "..tconcat (c, " ")
		else
			return ""
		end
	end
end

---------------------------------------------------------------------
-- Serialize the children of an object.
-- @param obj Table with the object to be serialized.
-- @return String representation of the children.
---------------------------------------------------------------------
local function contents (obj)
	if not obj[1] then
		return ""
	else
		local c = {}
		for i = 1, #obj do
			c[i] = serialize (obj[i])
		end
		return tconcat (c)
	end
end

---------------------------------------------------------------------
-- Serialize an object.
-- @param obj Table with the object to be serialized.
-- @return String with representation of the object.
---------------------------------------------------------------------
serialize = function (obj)
	local tt = type(obj)
	if tt == "string" then
		return escape(unescape(obj))
	elseif tt == "number" then
		return obj
	elseif tt == "table" then
		local t = obj.tag
		assert (t, "Invalid table format (no `tag' field)")
		return strformat ("<%s%s>%s</%s>", t, attrs(obj.attr), contents(obj), t)
	else
		return ""
	end
end

---------------------------------------------------------------------
-- @param attr Table of object's attributes.
-- @return String with the value of the namespace ("xmlns") field.
---------------------------------------------------------------------
local function find_xmlns (attr)
	for a, v in pairs (attr) do
		if strfind (a, "xmlns", 1, 1) then
			return v
		end
	end
end

---------------------------------------------------------------------
-- Add header element (if it exists) to object.
-- Cleans old header element anyway.
---------------------------------------------------------------------
local header_template = {
	-- SJM
	-- tag = "soap:Header",
	tag = "soapenv:Header"
}
local function insert_header (obj, header)
	-- removes old header
	if obj[2] then
		tremove (obj, 1)
	end


	-- SJM
	header = {
		tag = "ns:KwsSoapHeader",
		attr = {},
		{
			tag = "ns:SessionId",
			attr = {},
			"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
		}
	}

	if header then
		header_template[1] = header
		tinsert (obj, 1, header_template)
	end
end


local xmlns_soap = "http://schemas.xmlsoap.org/soap/envelope/"
local xmlns_soap12 = "http://www.w3.org/2003/05/soap-envelope"

---------------------------------------------------------------------
-- Converts a LuaExpat table into a SOAP message.
-- @param args Table with the arguments, which could be:
-- namespace: String with the namespace of the elements.
-- method: String with the method's name;
-- entries: Table of SOAP elements (LuaExpat's format);
-- header: Table describing the header of the SOAP envelope (optional);
-- internal_namespace: String with the optional namespace used
--	as a prefix for the method name (default = "");
-- soap_version: Number of SOAP version (default = 1.1);
-- @return String with SOAP envelope element.
---------------------------------------------------------------------
local function encode (args)
	local tae = type (args.entries)
    assert (tae == "table", "Invalid field entries: expected table but got "..tae)
    local soap_prefix = args.soap_prefix == nil and "soap" or args.soap_prefix

    local namespace = xmlns_soap
    if tonumber(args.soap_version) == 1.2 then
		namespace = xmlns_soap12
	end

    local envelope_template = {
        tag = soap_prefix .. ":Envelope",
        attr = { "xmlns:" .. soap_prefix, "xmlns:ns",
            ["xmlns:" .. soap_prefix] = namespace,
            ["xmlns:ns"] = "http://www.shijinet.com.cn/kunlun/kws/1.1/",
        },
        {
            tag = soap_prefix .. ":Body",
            [1] = {
                tag = nil, -- must be filled
                attr = {}, -- must be filled
            },
        }
    }

	local xmlns = "xmlns"
	local method = args.method
	if args.internal_namespace then
		xmlns = xmlns..":"..args.internal_namespace
		method = args.internal_namespace..":"..method
	end
	-- Cleans old header and insert a new one (if it exists).

	insert_header (envelope_template, args.header)
	-- Sets new body contents (and erase old content).
	local body = (envelope_template[2] and envelope_template[2][1]) or envelope_template[1][1]
	for i = 1, max (#body, #args.entries) do
		body[i] = { tag = "ns:" .. args.entries[i].tag, attr = args.entries[i].attr, unpack(args.entries[i]) }
	end
	-- Sets method (actually, the table's tag) and namespace.
	body.tag = method
	body.attr[xmlns] = args.namespace
	return serialize (envelope_template)
end

-- Iterates over the children of an object.
-- It will ignore any text, so if you want all of the elements, use ipairs(obj).
-- @param obj Table (LOM format) representing the XML object.
-- @param tag String with the matching tag of the children
--	or nil to match only structured children (single strings are skipped).
-- @return Function to iterate over the children of the object
--	which returns each matching child.

local function list_children (obj, tag)
	local i = 0
	return function ()
		i = i+1
		local v = obj[i]
		while v do
			if type(v) == "table" and (not tag or v.tag == tag) then
				return v
			end
			i = i+1
			v = obj[i]
		end
		return nil
	end
end

---------------------------------------------------------------------
-- Converts a SOAP message into Lua objects.
-- @param doc String with SOAP document.
-- @return String with namespace, String with method's name and
--	Table with SOAP elements (LuaExpat's format).
---------------------------------------------------------------------
local function decode (doc)
	local obj = assert (parse (doc))
	assert (obj.tag, "Not an SOAP document")
	local ns = assert (obj.tag:match ("^(.-):Envelope"), "Not a SOAP Envelope: "..obj.tag)
	local lc = list_children (obj)
	local o = lc ()
	local headers = {}
	-- Store SOAP:Headers separatelly
	while o and (o.tag == ns..":Header" or o.tag == "SOAP-ENV:Header") do
		headers[#headers+1] = list_children (o)()
		o = lc ()
	end
	if o and (o.tag == ns..":Body" or o.tag == "SOAP-ENV:Body") then
		obj = list_children (o)()
	else
		error ("Couldn't find SOAP Body!")
	end

	local namespace = find_xmlns (obj.attr)
	local method = obj.tag:match ("%:([^:]*)$") or obj.tag
	local entries = {}
	for i = 1, #obj do
		entries[i] = obj[i]
	end
	return namespace, method, entries, headers
end

------------------------------------------------------------------------------
-- @export
return {
	_COPYRIGHT = "Copyright (C) 2004-2020 Kepler Project",
	_DESCRIPTION = "LuaSOAP provides a very simple API that convert Lua tables to and from XML documents",
	_VERSION = "LuaSOAP 4.0.2",

	decode = decode,
	encode = encode,
	escape = escape,
	unescape = unescape,
	serialize = serialize,
	attrs = attrs,
}
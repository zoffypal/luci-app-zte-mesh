-- SPDX-License-Identifier: GPL-2.0-only
-- Lua controller for LuCI releases without the JavaScript view framework
-- (OpenWrt 19.07 and the firmware built on it, where the dispatcher only
-- scans Lua controllers and never reads menu.d). The page itself is the CBI
-- model luasrc/model/cbi/zte-mesh.lua; the two call() entries below are the
-- per-node actions and the restart the modern page does through ubus, here
-- as plain links that render a short result and link back to the page.
module("luci.controller.zte-mesh", package.seeall)

local translate = require "luci.i18n".translate

function index()
	-- LuCI 19.07 serialises index() into /tmp/luci-indexcache and re-runs it
	-- from the cached bytecode, where file-level locals (upvalues) come back
	-- nil: the outer `local translate` below broke the whole site with
	-- "attempt to call upvalue 'translate' (a nil value)" (HTTP 500) on the
	-- second request. Take the translator here, inside index(), so every run
	-- fetches it fresh; the outer one stays for the action handlers, which
	-- run from the freshly loaded module and keep their upvalues.
	local translate = require "luci.i18n".translate
	entry({"admin", "network", "zte-mesh"}, cbi("zte-mesh"), translate("ZTE Mesh"), 62)
	entry({"admin", "network", "zte-mesh", "node"}, call("action_node"))
	entry({"admin", "network", "zte-mesh", "restart"}, call("action_restart"))
end

local json = require "luci.jsonc"
local http = require "luci.http"

local RUNDIR = "/run/zte-mesh"
local STATE = RUNDIR .. "/state.json"
local ACTIONS = RUNDIR .. "/actions"

local function read_state()
	local f = io.open(STATE, "r")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return json.parse(data)
end

-- node_action VERB MAC [ARG]: the same file the rpcd plugin hands to the
-- running controller service, and the same wait for its answer in state.json.
-- Returns the status code, or nil when the controller never answered.
local function node_action(verb, mac, arg)
	local f = io.open(STATE, "r")
	if not f then
		return -5
	end
	f:close()
	if os.execute("test -d " .. ACTIONS) ~= 0 then
		return -5
	end
	math.randomseed(os.time())
	local id = tostring(os.time()) .. "-" .. tostring(math.random(99999))
	local req = verb .. " " .. mac
	if arg then
		req = req .. " " .. arg
	end
	local tmp = ACTIONS .. "/." .. id .. ".tmp"
	f = io.open(tmp, "w")
	if not f then
		return -5
	end
	f:write(req .. "\n")
	f:close()
	os.execute("chmod 600 " .. tmp .. " && mv " .. tmp .. " " .. ACTIONS .. "/" .. id .. ".act")
	for _ = 1, 8 do
		os.execute("sleep 1")
		local state = read_state()
		if state and state.actions then
			for _, a in ipairs(state.actions) do
				if a.id == id then
					return a.status
				end
			end
		end
	end
	return nil
end

local function result_page(message)
	http.prepare_content("text/html")
	http.write("<!DOCTYPE html><html><head><meta charset=\"utf-8\" />")
	http.write("<title>" .. translate("ZTE Mesh") .. "</title></head><body>")
	http.write("<p>" .. message .. "</p>")
	http.write("<p><a href=\"" .. luci.dispatcher.build_url("admin", "network", "zte-mesh") .. "\">" ..
		translate("Back to ZTE Mesh") .. "</a></p>")
	http.write("</body></html>")
end

local function action_problem(res)
	if res == 0 then
		return nil
	elseif res == nil then
		return translate("No answer from the controller yet.")
	elseif res == -2 then
		return translate("The request was malformed.")
	elseif res == -3 then
		return translate("That router is not online or is not a ZTE router.")
	elseif res == -4 then
		return translate("The controller is restarting; try again in a moment.")
	elseif res == -5 then
		return translate("The controller is not running.")
	else
		return translate("The controller could not send the request (%s)."):format(res)
	end
end

function action_node()
	local mac = (http.formvalue("mac") or ""):lower()
	local op = http.formvalue("op")
	local problem, ok
	if not mac:match("^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$") then
		problem = translate("The request was malformed.")
	elseif op == "reboot" then
		local res = node_action("reboot", mac)
		problem = action_problem(res)
		ok = translate("The restart request was sent.")
	elseif op == "light" then
		local on = http.formvalue("on")
		local res = node_action("light", mac, (on == "1") and "1" or "0")
		problem = action_problem(res)
		ok = (on == "1") and translate("Indicator light switched on.") or translate("Indicator light switched off.")
	else
		problem = translate("The request was malformed.")
	end
	result_page(problem or ok)
end

function action_restart()
	os.execute("( /etc/init.d/zte-mesh restart >/dev/null 2>&1 </dev/null & )")
	result_page(translate("The controller is restarting."))
end

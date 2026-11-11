-- SPDX-License-Identifier: GPL-2.0-only
-- CBI page for LuCI releases without the JavaScript view framework (OpenWrt
-- 19.07 and the firmware built on it). It mirrors the modern view
-- (htdocs/luci-static/resources/view/network/zte-mesh.js) option for option:
-- the same UCI names, the same tabs, the same role rule (a child takes its
-- Wi-Fi profile from the controller, so the Wi-Fi, roaming and extra-network
-- settings are not rendered there at all), and the same status, child-router
-- and device tables, which live in the view luasrc/view/zte-mesh/status.htm.
-- Strings reuse the message ids of po/zh_Hans/zte-mesh.po, so the existing
-- Chinese translation applies to this page as well.
local uci = require "luci.model.uci".cursor()

local role = uci:get("zte_mesh", "main", "mesh_role") or "master"
local child = (role == "slave")
local legacy = (role == "main" or role == "auto")
local apply = uci:get("zte_mesh", "main", "apply_local")
local is_local = not child and (apply == nil and legacy or apply == "1")

m = Map("zte_mesh", translate("ZTE Mesh"), child
	and translate("This router is a mesh child: the controller manages it and gives it the Wi-Fi name, password and security.")
	or is_local
	and translate("The main router: this router is the mesh controller and also broadcasts the Wi-Fi profile below, so it and its child routers put the same network on the air.")
	or translate("A controller without Wi-Fi of its own: it manages the child routers and gives them the Wi-Fi profile below. This router's own radios are left alone."))

-- Status, child routers and devices, read live from the rpcd status and the
-- host-side device list. No polling here: reload the page for fresh numbers.
local st = m:section(SimpleSection, translate("Status"))
st.template = "zte-mesh/status"

local s = m:section(NamedSection, "main", "zte_mesh")
s.addremove = false

s:tab("general", translate("General"))
if not child then
	s:tab("wifi", translate("Wi-Fi profile"))
	s:tab("policy", translate("Roaming and steering"))
end

local o

o = s:taboption("general", Flag, "enabled", translate("Enable"))
o.default = "1"
o.rmempty = false

o = s:taboption("general", Value, "bridge", translate("LAN bridge"))
o.default = "br-lan"
o.datatype = "maxlength(15)"
o.rmempty = false
o.description = translate("The bridge the child routers are cabled to (up to 15 characters, default br-lan).")

if not child then
	o = s:taboption("general", Value, "al_last", translate("Controller address, last byte"))
	o.datatype = "and(minlength(2),maxlength(2))"
	o.optional = true
	o.validate = function(self, value)
		if value == nil or value == "" then
			return value
		end
		if value:match("^[0-9a-fA-F][0-9a-fA-F]$") then
			return value
		end
		return nil, translate("Two hex digits, as in e3.")
	end
	o.description = translate("The address this router presents as a mesh controller is 02:00:00:00:19:<this byte>. Empty: the last byte of the LAN bridge MAC, which already differs between two boxes. Change it only when they still collide, for example because the same image was cloned onto both. Only this byte can be changed: the first five are the shape a ZTE child accepts. Currently %s."):format(
		(uci:get("zte_mesh", "main", "al_last") or ""))
end

o = s:taboption("general", ListValue, "mesh_role", translate("Device role"))
o:value("master", translate("Controller"))
o:value("slave", translate("Child router"))
o.default = "master"
o.optional = true
o.description = translate("Controller: this router runs the mesh -- it answers the child routers, hands out the Wi-Fi profile and decides about roaming and steering. Child router: this router is a mesh agent, it hands nothing out and the controller gives it the Wi-Fi name, key and security. A child starts from the wireless network this router already broadcasts until the controller sends its own, so nothing has to be filled in here: the Wi-Fi, roaming and extra-network settings are hidden while the child role is selected. Whether a controller also broadcasts this router's own Wi-Fi is the choice below. Changing the role restarts the service and reloads this page, and the child routers drop out of the topology for a short while.")

if not child then
	o = s:taboption("general", Flag, "apply_local", translate("Also broadcast here"))
	o.default = legacy and "1" or "0"
	o.rmempty = false
	o.description = translate("On: this controller puts the Wi-Fi profile below on its own radios as well as handing it to the child routers, so it and they broadcast the same network -- the main router of the factory page. Off: the profile goes to the child routers only and this router's own radios are left exactly as they are, which is the shape of most wired OpenWrt boxes at the head of a mesh, so it is the default. On a router that does apply a profile here, a radio device that was switched off is switched on when the band is enabled, because a disabled radio puts nothing on the air; a radio switched off afterwards stays off until a different profile arrives.")
end

if child or is_local then
	o = s:taboption("general", ListValue, "backhaul",
		child and translate("Backhaul to the controller") or translate("Backhaul BSS for the child routers"))
	o:value("off", translate("Off (main SSIDs only)"))
	o:value("multi_ap", translate("Multi-AP (4-address)"))
	o.default = "off"
	o.optional = true
	o.description = (child
		and translate("How this router reaches the controller over the radio. Off: only the main SSIDs are applied, as before. Multi-AP: the backhaul network the controller sends becomes a client interface (mode sta, marked as a Multi-AP backhaul station, with 4-address mode on and the bridge of that band), so the mesh control traffic crosses the radio instead of the cable. Requires a hostapd built with Multi-AP support (the full wpad, not wpad-basic); nothing is created until the controller has sent a backhaul network.")
		or translate("Whether this router puts the backhaul network of its profile on the air. Off: only the main SSIDs are applied, as before. Multi-AP: the hidden backhaul network becomes its own BSS (multi_ap=2) and the main SSIDs are marked as fronthaul, so a child that joins it reaches this router as 4-address Ethernet over the radio. Requires a hostapd built with Multi-AP support (the full wpad, not wpad-basic); nothing is created until the profile carries a backhaul network."))
		.. " " .. translate("Switching this restarts the mesh service (the child routers drop out of the topology for up to a minute).")

	o = s:taboption("general", ListValue, "extra_slots", translate("Extra SSIDs on this router"))
	o:value("0", translate("Off (main SSIDs only)"))
	o:value("1", translate("On (guest, spare and hidden backhaul too)"))
	o.default = "0"
	o.optional = true
	o.description = translate("Whether the extra SSID slots are applied to this router as well. Off: only the main SSIDs are applied, as before. On: every enabled slot becomes its own network on the band it belongs to, and a slot that stops arriving is removed again. An extra slot shares the bridge of its band's main network: this image has no VLAN separation yet, so a guest slot is not isolated from the main one.")

	local pin_desc = translate("Which wireless device carries this band. Leave it alone unless the service log says it cannot tell the two apart: a band with one device needs no answer, and a band with several uses the one that is not switched off. The value is a wireless device name of the Wi-Fi settings, such as radio1, and it has to be a device of this band -- a name that is not one is ignored, and the mesh is left off that radio.")
		.. " " .. translate("Switching this restarts the mesh service (the child routers drop out of the topology for up to a minute).")
	local pin_name = function(self, value)
		if value == nil or value == "" then
			return value
		end
		if value:match("^[A-Za-z0-9_]+$") then
			return value
		end
		return nil, translate("A wireless device name: letters, digits and underscores, like radio1.")
	end
	o = s:taboption("general", Value, "wifi_2g", translate("2.4 GHz wireless device"))
	o.optional = true
	o.placeholder = "radio0"
	o.validate = pin_name
	o.description = pin_desc
	o = s:taboption("general", Value, "wifi_5g", translate("5 GHz wireless device"))
	o.optional = true
	o.placeholder = "radio1"
	o.validate = pin_name
	o.description = pin_desc
end

if not child then
	o = s:taboption("general", Flag, "mesh_compatible", translate("MESH compatible"))
	o.default = "1"
	o.rmempty = false
	o.description = translate("The factory MESH switch. On (ZTE compatible, default): any child router is accepted. Off (ZTE enhanced): only ZTE child routers with the same market code are accepted. Switching restarts the mesh daemon (the child routers drop out of the topology for up to a minute).")

	o = s:taboption("general", Flag, "mlo_enable", translate("Wi-Fi 7 MLO"))
	o.optional = true
	o.default = "1"
	o.description = translate("Tell child routers whether multi-link operation is on (factory default: on). Only Wi-Fi 7 children act on it.")

	o = s:taboption("wifi", Flag, "wifi_dual_band_sync", translate("Same name and password on both bands"))
	o.default = "1"
	o.rmempty = false
	o.description = translate("On: the 5 GHz band uses the 2.4 GHz name, password, security, hidden setting and MAC filter policy. Off: the 5 GHz name is the 2.4 GHz name plus the suffix below unless a 5 GHz name is given.")

	local function profile(band, label)
		local id = "wifi_" .. band
		local five = band == "5g"

		o = s:taboption("wifi", Flag, id .. "_enabled", translate("%s enabled"):format(label))
		o.default = "1"
		o.rmempty = false
		o.description = is_local
			and translate("Off switches the main network of this band off here and on the child routers.")
			or translate("Off switches the main network of this band off on the child routers.")

		o = s:taboption("wifi", Value, id .. "_ssid", translate("%s network name (SSID)"):format(label))
		o.datatype = "and(minlength(1),maxlength(31))"
		if five then
			o.rmempty = true
			o:depends("wifi_dual_band_sync", "0")
			o.placeholder = translate("2.4 GHz name + suffix")
			o.description = translate("1 to 31 characters. Empty: the 2.4 GHz name plus the suffix below.")
		else
			o.rmempty = false
			o.default = "ImmortalWrt"
			o.description = translate("1 to 31 characters. Required.")
		end

		o = s:taboption("wifi", Value, id .. "_key", translate("%s password"):format(label))
		o.password = true
		o.datatype = "and(minlength(8),maxlength(63))"
		if five then
			o.rmempty = true
			o:depends("wifi_dual_band_sync", "0")
			o.placeholder = translate("Same as 2.4 GHz")
			o.description = translate("8 to 63 characters. Empty: the 2.4 GHz password.")
		else
			o.rmempty = false
			o.default = "Ztemesh2631!"
			o.placeholder = translate("8 to 63 characters")
			o.description = translate("8 to 63 characters, default Ztemesh2631!. Required: the controller does not start without one.")
		end

		if five then
			o = s:taboption("wifi", Value, "wifi_5g_suffix", translate("5 GHz name suffix"))
			o.datatype = "and(minlength(1),maxlength(8))"
			o.default = "-5G"
			o.optional = true
			o:depends("wifi_dual_band_sync", "0")
			o.description = translate("1 to 8 characters, appended to the 2.4 GHz name when no 5 GHz name is given (factory default -5G). The whole name must stay within 31 characters.")
		end

		o = s:taboption("wifi", Flag, id .. "_hidden", translate("%s hidden network name"):format(label))
		o.optional = true
		o.default = "0"
		if five then
			o:depends("wifi_dual_band_sync", "0")
		end

		o = s:taboption("wifi", ListValue, id .. "_security", translate("%s security"):format(label))
		o:value("psk2", "WPA2-PSK")
		o:value("psk-mixed", "WPA/WPA2-PSK")
		o:value("sae-mixed", "WPA2/WPA3")
		o:value("sae", "WPA3")
		o:value("none", translate("None (open network)"))
		o.default = five and "psk-mixed" or "sae-mixed"
		o.optional = true
		o.description = translate("Child routers without WPA3 treat WPA2/WPA3 as WPA2 and ignore WPA3-only. \"None\" makes the main network open.")
		if five then
			o:depends("wifi_dual_band_sync", "0")
		end

		o = s:taboption("wifi", Value, id .. "_beacon_interval", translate("%s beacon interval (ms)"):format(label))
		o.datatype = "range(20,1000)"
		o.default = "100"
		o.optional = true
		o.description = translate("20 to 1000 ms, factory default 100. Changing it restarts the radio of the child routers for a few seconds.")

		o = s:taboption("wifi", Value, id .. "_channel", translate("%s channel"):format(label))
		o.datatype = five and "or(range(0,0),range(36,165))" or "range(0,13)"
		o.default = "0"
		o.optional = true
		o.description = five
			and translate("0 = automatic (factory default). Fixed: 36, 40, 44, 48, 52 to 64, 100 to 144 and 149 to 165 in steps of 4. Empty: keep the child routers' setting.")
			or translate("0 = automatic (factory default). Fixed: 1 to 13. Empty: keep the child routers' setting.")

		o = s:taboption("wifi", Value, id .. "_tx_power", translate("%s transmit power (dBm, EIRP)"):format(label))
		o.datatype = "range(0,30)"
		o.default = five and "23" or "20"
		o.optional = true
		o.description = five
			and translate("0 to 30 dBm. The child routers round it to one of five levels: above 21 is full power (factory default), 20 to 21, 16 to 19, 10 to 15, below 10. Empty: keep the child routers' setting.")
			or translate("0 to 30 dBm. The child routers round it to one of five levels: above 19 is full power (factory default), 16 to 19, 12 to 15, 8 to 11, below 8. Empty: keep the child routers' setting.")

		o = s:taboption("wifi", ListValue, id .. "_acl_policy", translate("%s MAC filter policy"):format(label))
		o:value("", translate("Keep the child routers' setting"))
		o:value("disabled", translate("Off"))
		o:value("ban", translate("Block listed devices"))
		o:value("allow", translate("Allow only listed devices"))
		o.optional = true
		if five then
			o:depends("wifi_dual_band_sync", "0")
		end
	end
	profile("24g", translate("2.4 GHz"))
	profile("5g", translate("5 GHz"))

	o = s:taboption("policy", Flag, "band_steer", translate("Band steering"))
	o.optional = true
	o.default = "1"
	o.description = translate("Move capable devices to the better band (factory default: on while both bands share a name). The factory turns this off together with the dual-band switch; here it is a separate choice.")

	o = s:taboption("policy", Value, "band_steer_rssi_24g", translate("Band steering threshold, 2.4 GHz (dBm)"))
	o.datatype = "range(-110,-30)"
	o.default = "-60"
	o.optional = true
	o.description = translate("-110 to -30 dBm, factory default -60. The controller's own decision threshold; set both bands or neither.")
	o = s:taboption("policy", Value, "band_steer_rssi_5g", translate("Band steering threshold, 5 GHz (dBm)"))
	o.datatype = "range(-110,-30)"
	o.default = "-110"
	o.optional = true
	o.description = translate("-110 to -30 dBm, factory default -110. Set both bands or neither.")

	o = s:taboption("policy", Value, "roam_rssi_24g", translate("Roaming threshold, 2.4 GHz (dBm)"))
	o.datatype = "range(-110,-30)"
	o.default = "-60"
	o.optional = true
	o.description = translate("-110 to -30 dBm, factory default -60 (the factory page allows -110 to -40). A device weaker than this is moved to a better router. Sent to the child routers; some models, the Z506 among them, ignore it. Set both bands or neither.")
	o = s:taboption("policy", Value, "roam_rssi_5g", translate("Roaming threshold, 5 GHz (dBm)"))
	o.datatype = "range(-110,-30)"
	o.default = "-70"
	o.optional = true
	o.description = translate("-110 to -30 dBm, factory default -70. Set both bands or neither.")

	o = s:taboption("policy", Flag, "roam_force", translate("Force roaming on weak signal"))
	o.optional = true
	o.default = "0"
	o.description = translate("Kick devices that stay on a weak signal (factory default: off).")

	o = s:taboption("policy", Value, "ban_minutes", translate("Blocked devices stay off for (minutes)"))
	o.datatype = "range(0,1440)"
	o.optional = true
	o.description = translate("0 to 1440 minutes, 0 = until the entry is removed (the default). Applies to every entry of the list below, which is blocked for that long after the rule was first sent; the time is not extended by later saves.")

	local b = m:section(TypedSection, "zte_mesh_bss", translate("Extra Wi-Fi networks"),
		translate("Guest, spare and hidden backhaul networks of the child routers. The slots of one band must be 1, 2, 3 in order without a gap: removing slot 1 while slot 2 exists is refused. Adding or removing a slot makes the child routers drop out of the topology for up to a minute; switching one on or off does not."))
	b.addremove = true
	b.anonymous = true
	b.template = "cbi/tblsection"

	o = b:option(ListValue, "band", translate("Band"))
	o:value("24g", "2.4 GHz")
	o:value("5g", "5 GHz")
	o.default = "24g"
	o.rmempty = false

	o = b:option(ListValue, "slot", translate("Slot"))
	o:value("1", translate("1 (guest)"))
	o:value("2", translate("2 (spare)"))
	o:value("3", translate("3 (hidden backhaul)"))
	o.default = "1"
	o.rmempty = false

	o = b:option(Flag, "enabled", translate("Enabled"))
	o.default = "1"
	o.rmempty = false

	o = b:option(Value, "ssid", translate("Network name (SSID)"))
	o.datatype = "and(minlength(1),maxlength(31))"
	o.rmempty = false
	o.placeholder = translate("1 to 31 characters")
	o.description = translate("1 to 31 characters. Required.")

	o = b:option(Value, "key", translate("Password"))
	o.password = true
	o.datatype = "and(minlength(8),maxlength(63))"
	o.rmempty = false
	o.placeholder = translate("8 to 63 characters")
	o.description = translate("8 to 63 characters. Required, also for an open network (it is kept for when security is switched on).")

	o = b:option(Flag, "hidden", translate("Hidden network name"))
	o.optional = true

	o = b:option(ListValue, "security", translate("Security"))
	o:value("psk2", "WPA2-PSK")
	o:value("psk-mixed", "WPA/WPA2-PSK")
	o:value("sae-mixed", "WPA2/WPA3")
	o:value("sae", "WPA3")
	o:value("none", translate("None (open network)"))
	o.default = "psk2"
	o.optional = true

	o = b:option(Value, "access_minutes", translate("Switch off after (minutes)"))
	o.datatype = "range(1,10080)"
	o.optional = true
	o.placeholder = translate("Empty: no time limit")
	o.description = translate("1 to 10080 minutes (7 days); empty = no time limit. Guest time limit: the network is switched off this long after it came on. Switching it off and on again, or changing this value, restarts the countdown. Not kept across a controller restart.")

	o = b:option(Flag, "force_wifi5", translate("Wi-Fi 5 compatible network"))
	o.optional = true
	o.description = translate("Announces the network as Wi-Fi 5 only to child routers that understand it; many models ignore it.")

	o = b:option(ListValue, "acl_policy", translate("MAC filter policy"))
	o:value("", translate("Keep the child routers' setting"))
	o:value("disabled", translate("Off"))
	o:value("ban", translate("Block listed devices"))
	o:value("allow", translate("Allow only listed devices"))
	o.optional = true

	local nm = m:section(TypedSection, "zte_mesh_node", translate("Router names"),
		translate("Names for child routers, shown in the list above instead of the name the router reports. They are kept on this router only; the child routers keep their own names."))
	nm.addremove = true
	nm.anonymous = true
	nm.template = "cbi/tblsection"

	o = nm:option(Value, "mac", translate("MAC address"))
	o.datatype = "macaddr"
	o.rmempty = false
	o.placeholder = "aa:bb:cc:dd:ee:ff"
	o.description = translate("The MAC address shown for the router in the list above.")

	o = nm:option(Value, "name", translate("Name"))
	o.datatype = "and(minlength(1),maxlength(63))"
	o.rmempty = false
	o.description = translate("1 to 63 characters.")

	local t = m:section(TypedSection, "zte_mesh_timer", translate("Wi-Fi schedule"),
		translate("Switch Wi-Fi off during these windows on every child router. \"All Wi-Fi\" turns off the main networks and the guest and spare networks (the hidden backhaul network stays on); \"Guest network\" turns off guest network 1 only. A window that ends before it starts runs past midnight. Times are in the router's time zone (the zone in effect when the settings were saved)."))
	t.addremove = true
	t.anonymous = true
	t.template = "cbi/tblsection"

	local time_of_day = function(self, value)
		if value ~= nil and value:match("^([01][0-9]|2[0-3]):[0-5][0-9]$") then
			return value
		end
		return nil, translate("Use the form HH:MM, for example 23:00")
	end

	o = t:option(Value, "start", translate("Off from"))
	o.default = "23:00"
	o.rmempty = false
	o.validate = time_of_day
	o.description = translate("HH:MM, 00:00 to 23:59.")

	o = t:option(Value, "end", translate("Back on at"))
	o.default = "07:00"
	o.rmempty = false
	o.validate = time_of_day
	o.description = translate("HH:MM, 00:00 to 23:59. Earlier than the start: the window runs past midnight.")

	o = t:option(MultiValue, "days", translate("On the days that start on"))
	o:value("mon", translate("Mon"))
	o:value("tue", translate("Tue"))
	o:value("wed", translate("Wed"))
	o:value("thu", translate("Thu"))
	o:value("fri", translate("Fri"))
	o:value("sat", translate("Sat"))
	o:value("sun", translate("Sun"))
	o.default = "mon tue wed thu fri sat sun"
	o.rmempty = false

	o = t:option(ListValue, "scope", translate("Switch off"))
	o:value("all", translate("All Wi-Fi"))
	o:value("guest", translate("Guest network"))
	o.default = "all"

	local a = m:section(TypedSection, "zte_mesh_acl", translate("MAC filter list"),
		translate("Up to 16 devices. A rule applies to the main network of the chosen band or to one of its extra networks; the policy above decides whether listed devices are blocked or the only ones allowed."))
	a.addremove = true
	a.anonymous = true
	a.template = "cbi/tblsection"

	o = a:option(Value, "mac", translate("MAC address"))
	o.datatype = "macaddr"
	o.rmempty = false
	o.placeholder = "aa:bb:cc:dd:ee:ff"
	o.description = translate("The address the device uses now: phones often use a private MAC per network.")

	o = a:option(Value, "name", translate("Name"))
	o.datatype = "maxlength(20)"
	o.optional = true
	o.description = translate("Up to 20 characters: letters, digits and _ . -. Empty: acl1, acl2 and so on.")
	o.validate = function(self, value)
		if value == nil or value == "" or value:match("^[A-Za-z0-9_.-]+$") then
			return value
		end
		return nil, translate("Only letters, digits and _ . - are allowed")
	end

	o = a:option(ListValue, "band", translate("Band"))
	o:value("", translate("Both"))
	o:value("24g", "2.4 GHz")
	o:value("5g", "5 GHz")
	o.optional = true

	o = a:option(ListValue, "bss", translate("Network"))
	o:value("", translate("Main network"))
	o:value("1", translate("Extra network 1"))
	o:value("2", translate("Extra network 2"))
	o:value("3", translate("Extra network 3"))
	o.optional = true

	local c = m:section(TypedSection, "zte_mesh_client", translate("Blocked and kicked devices"),
		translate("Up to 8 devices. \"Block\" keeps a device off the Wi-Fi until the time below runs out or the entry is removed; the controller repeats the rule so a child router that reboots does not forget it. \"Kick once\" asks the device to move to the better access point and gives up after a few tries. Both need the child routers to support it; the factory default leaves it off, so a device that does not move is not necessarily an error."))
	c.addremove = true
	c.anonymous = true
	c.template = "cbi/tblsection"

	o = c:option(Value, "mac", translate("MAC address"))
	o.datatype = "macaddr"
	o.rmempty = false
	o.placeholder = "aa:bb:cc:dd:ee:ff"
	o.description = translate("The address the device uses now: phones often use a private MAC per network.")

	o = c:option(ListValue, "action", translate("Action"))
	o:value("ban", translate("Block"))
	o:value("kick", translate("Kick once"))
	o.default = "ban"
	o.rmempty = false
end

-- Restart is a form button, not a saved option: it submits the page (saving
-- any edits first) and restarts the service.
o = s:taboption("general", Button, "_restart", translate("Restart controller"))
o.inputstyle = "apply"
o.inputtitle = translate("Restart controller")
function o.write(self, section)
	os.execute("/etc/init.d/zte-mesh restart >/dev/null 2>&1")
end

return m

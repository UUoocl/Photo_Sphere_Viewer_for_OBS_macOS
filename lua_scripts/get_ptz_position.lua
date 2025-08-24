--[[
      OBS Studio Lua script : Get USB Camera PTZ values with hotkeys
      Author: Jonathan Wood
      Version: 0.1
      Released: 2024-03-23
      references: https://obsproject.com/forum/resources/hotkeyrotate.723/, https://obsproject.com/forum/threads/command-runner.127662/
      https://github.com/jtfrey/uvc-util
--]]

local obs = obslua

local debug
local source_name = ""
local uvcUtil_Location = ""

local output = ""
local previous_output = ""
local interval = 1000 -- default interval in milliseconds

local use_auto_follow_ptz = true
local is_following_ptz = false

local p = ""
local t = ""
local z = ""

local is_obs_loaded = false

--Run the command and return its output
function os.capture(cmd)
    local f = assert(io.popen(cmd, 'r'))
    local s = assert(f:read('*a'))
    f:close()
    return s
end

function run_command()
    --Get the Camera Pan and Tilt values with uvc-util command "{Path}/uvc-util -I 0 -o pan-tilt-abs"
    
    command = uvcUtil_Location .. "uvc-util -I 0 -o pan-tilt-abs"
    
    log("Executing command: " .. command)
    output = os.capture(command)
    log("Output: " .. output)
    
    --Tranform uvc-util results
    local pt = string.gsub(output,"{pan=", "")
    local pt = string.gsub(pt,"}", "")
    local pEnd = string.find(pt,",") 
    
    -- OBSBOT Tiny 2 min and max pan -468000 to +468000.  Scaled to 0-100
    -- Insta360 Link min and max pan -522000 to +522000.  Scaled to 0-100
    p = math.floor(((tonumber(string.sub(pt,0,pEnd-1))+468000)/936000)*100)
    
    -- Tiny2 min and max tilt -324000 to +324000.  Scaled to 0-100
    -- Link min and max tilt -324000 to +360000.  Scaled to 0-100
    t = math.floor(((tonumber(string.sub(pt,pEnd+6))+324000)/648000)*100)
    --output = p .." " .. t
    log(p .." " ..t)

    --Get Zoom Value
    -- Tiny2 min and max zoom 0 to 100.  
    -- Link min and max zoom 100 to 400.
    command = uvcUtil_Location .. "/uvc-util -I 0 -o zoom-abs"
    log("Executing command: " .. command)
    z = tonumber(os.capture(command))
    log("Zoom Output: " .. z)
 
    set_source_text()
end

function set_source_text()
    if output ~= previous_output then
        local source = obs.obs_get_source_by_name(source_name)
        if source ~= nil then
            local settings = obs.obs_data_create()
            obs.obs_data_set_string(settings, "text", '{"pan":' .. p .. ',"tilt":' .. t .. ',"zoom":' .. z .. "}")
            obs.obs_source_update(source, settings)
            obs.obs_data_release(settings)
            obs.obs_source_release(source)
        end
    end
    previous_output = output
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

function on_toggle_follow(pressed)
    if pressed then
        is_following_ptz = not is_following_ptz
        log("Tracking ptz is " .. (is_following_ptz and "on" or "off"))

        if is_following_ptz == true then
            obs.timer_add(run_command, interval)
        else
            obs.timer_remove(run_command)
        end
    end
end

----------------------------------------------------------
-- Script start up
----------------

-- return description shown to user
function script_description()
    return "Run the uvc-util command to send PTZ values to a Text Source with hotkeys \nThe uvc-util camera utility is required.\n. https://github.com/jtfrey/uvc-util\n. It is recommended to save uvc-util to the /Applications/Utilities folder."
end

-- define properties that user can change
function script_properties()
    local props = obs.obs_properties_create()
    --uvc-util location
    obs.obs_properties_add_text(props, "uvcUtil_Location", "Path to the uvc-util \n(example /Applications/Utilities/)", obs.OBS_TEXT_DEFAULT)
    
    --list of text sources
    local property_list = obs.obs_properties_add_list(props, "source_name", "Select a Text Source to store PTZ values", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            source_id = obs.obs_source_get_id(source)
            if source_id == "text_gdiplus" or source_id == "text_ft2_source" or source_id == "text_ft2_source_v2" then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(property_list, name, name)
            end
        end
    end
    obs.source_list_release(sources)

    --refresh interval
    obs.obs_properties_add_int(props, "interval", "Refresh Interval (ms)", 2, 60000, 1)

    local follow = obs.obs_properties_add_bool(props, "follow", "Start PTZ follow with OBS")
    obs.obs_property_set_long_description(follow,
        "When enabled ptz tracking will auto-start without waiting for tracking toggle hotkey")

    --debug option
    obs.obs_properties_add_bool(props, "debug", "Debug")
    
    return props
end

function script_load(settings)
    obs.script_log(obs.OBS_LOG_INFO, "Loading OBS PTZ script")
    -- Workaround for detecting if OBS is already loaded and we were reloaded using "Reload Scripts"
    local current_scene = obs.obs_frontend_get_current_scene()
    is_obs_loaded = current_scene ~= nil -- Current scene is nil on first OBS load
    obs.obs_source_release(current_scene)
   
    -- Add our hotkey
    hotkey_follow_id = obs.obs_hotkey_register_frontend("toggle_ptz_follow", "Toggle follow PTZ",
        on_toggle_follow)

    -- Attempt to reload existing hotkey bindings if we can find any
    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_ptz.hotkey.follow")
    obs.obs_hotkey_load(hotkey_follow_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    -- Load any other settings
    use_auto_follow_ptz = obs.obs_data_get_bool(settings, "follow")

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    is_script_loaded = true

    use_auto_follow_ptz = obs.obs_data_get_bool(settings, "follow")
    
    if use_auto_follow_ptz then
        on_toggle_follow(true)
    end

end

function script_unload()
    is_script_loaded = false
    
    obs.obs_hotkey_unregister(on_toggle_follow)
    obs.obs_frontend_remove_event_callback(on_frontend_event)
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "uvcUtil_Location", "/Applications/Utilities/")
    obs.obs_data_set_default_string(settings, "source", "")
    obs.obs_data_set_default_int(settings, "interval", 1000)
end

function script_save(settings)
    -- Save the custom hotkey information
    if hotkey_follow_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_follow_id)
        obs.obs_data_set_array(settings, "obs_ptz.hotkey.follow", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

-- called when settings changed
function script_update(settings)
    local old_follow = use_auto_follow_ptz

    uvcUtil_Location = obs.obs_data_get_string(settings, "uvcUtil_Location") 
    source_name = obs.obs_data_get_string(settings, "source_name")
	interval = obs.obs_data_get_int(settings, "interval")

    use_auto_follow_ptz = obs.obs_data_get_bool(settings, "follow")
    if old_follow ~= use_auto_follow_ptz then
       on_toggle_follow(true)
    end

end
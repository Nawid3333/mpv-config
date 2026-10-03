--- mpv player Lua scripting API definitions (subset, hand-written).
--- Source of truth: doc/manual.txt (LUA SCRIPTING section) of this mpv build
--- (v0.41.0-1023-g69e63f425). Loaded via .luarc.json -> workspace.library.
--- Extend as needed; full docs live in doc/manual.txt.

---@meta

--!nonstrict

-------------------------------------------------------------------------------
-- mp - core API (preloaded in every mpv script)
-------------------------------------------------------------------------------
---@class mp
---@field osc? any reserved: builtin osc state (user-data/osc)
mp = {}

---Run a command. Returns the result of the command, or error on failure.
---@param ... any command name and arguments (strings/numbers)
---@return any
---@overload fun(command: string[], flags?: table): any
function mp.command(...) end

---Run a command, aborting on error (raises a Lua error containing the
---error string on failure).
---@param ... any command name and arguments
---@return any
function mp.commandv(...) end

---Like mp.command(), but takes the command in array form.
---@param cmd any[] command as {name, arg1, arg2, ...}
---@param flags? table {async=function, on_error=function}
---@return any result
---@return string? error
function mp.command_native(cmd, flags) end

---Asynchronous version of mp.command_native(). Callback receives
---(success, result, error).
---@param cmd any[]
---@param callback? fun(success: boolean, result: any, err: string)
---@return table node: abort with node:abort()
function mp.command_native_async(cmd, callback) end

---Read a property, as string. Returns nil on error.
---Optional default is returned instead of nil on error.
---@param name string property name
---@param default? any fallback value
---@return string|any
---@overload fun(name: string): string?
function mp.get_property(name, default) end

---Read a property as boolean (nil on error / missing value).
---@param name string
---@param default? any fallback value
---@return boolean|any
---@overload fun(name: string): boolean?
function mp.get_property_bool(name, default) end

---Read a property as number (nil on error / missing value).
---@param name string
---@param default? any fallback value
---@return number|any
---@overload fun(name: string): number?
function mp.get_property_number(name, default) end

---Read a property natively (returns native object: tables, node trees...).
---Optional default is returned instead of nil on error (fallback for
---table/property reads, e.g. mp.get_property_native('track-list', {})).
---@param name string
---@param default? any fallback value
---@return any
function mp.get_property_native(name, default) end

---Read a property as string with fallback default.
---@param name string
---@param default any
---@return any
function mp.get_property_osd(name, default) end

---Write a property as string.
---@param name string
---@param value any
---@return boolean success
function mp.set_property(name, value) end

---Write a property as boolean.
---@param name string
---@param value boolean
---@return boolean success
function mp.set_property_bool(name, value) end

---Write a property as number.
---@param name string
---@param value number
---@return boolean success
function mp.set_property_number(name, value) end

---Write a property natively (tables map to node arrays/maps).
---@param name string
---@param value any
---@return boolean success
function mp.set_property_native(name, value) end

---Convenience: get property, if nil set it to default, return final value.
---@param name string
---@param v any
---@return any
function mp.get_property_native_default(name, v) end

---Format a time (in seconds) as a string.
---@param t number time in seconds
---@return string
function mp.format_time(t) end

---Return the current time in seconds (high precision, relative).
---@return number
function mp.get_time() end

---Abort a pending asynchronous command started by mp.command_native_async().
---@param async_cmd table the table returned by mp.command_native_async
function mp.abort_async_command(async_cmd) end

---Watch a property for changes. fn(name, value) is called on every change
---(and once initially). type: "none"|"native"|"bool"|"string"|"number".
---Returns a connection object with :unobserve().
---@param name string
---@param type string
---@param fn fun(name: string, value: any)
---@return table connection
function mp.observe_property(name, type, fn) end

---Stop watching a property. fn must match the callback passed to observe_property.
---@param fn fun(name: string, value: any)
function mp.unobserve_property(fn) end

---Register a callback on an event ("start-file", "end-file", "file-loaded",
---"seek", "shutdown", "log-message", "hook", "video-reconfig", ...).
---@param name string
---@param fn fun(event: table)
function mp.register_event(name, fn) end

---Unregister a previously registered event callback.
---@param fn fun(event: table)
function mp.unregister_event(fn) end

---Register a script message handler (events named "client-message" carry
---these). Convenience for inter-script communication.
---@param name string message string to match
---@param fn fun(...: any)
function mp.register_script_message(name, fn) end

---Unregister a script message.
---@param name string
function mp.unregister_script_message(name) end

---Bind a key. In a user's input.conf referenced as script-binding <script>/<name>.
---flags: {repeatable=true, scalable=true, complex=true}
---@param key string|nil key name, or nil to not pre-bind
---@param name string|nil binding name
---@param fn fun(...)|table command array (if fn is a table it's a command)
---@param flags? {repeatable?: boolean, scalable?: boolean, complex?: boolean}|string
function mp.add_key_binding(key, name, fn, flags) end

---Like add_key_binding, but overrides user input.conf bindings.
---@param key string|nil
---@param name string|nil
---@param fn fun(...)|table
---@param flags? table|string
function mp.add_forced_key_binding(key, name, fn, flags) end

---Remove a key binding by name.
---@param name string
function mp.remove_key_binding(name) end

---Call fn once after `time` seconds.
---@param time number seconds
---@param fn fun()
---@return table timer with :stop() :kill() :resume() :is_enabled()
function mp.add_timeout(time, fn) end

---Call fn every `time` seconds (until stopped).
---@param time number seconds
---@param fn fun()
---@return table timer
function mp.add_periodic_timer(time, fn) end

---Register a hook handler. type: "on_before_start_file", "on_load",
---"on_load_fail", "on_preloaded", "on_loaded", "on_unload",
---"on_after_end_file". priority: 50 = neutral.
---fn(hook): call hook:cont() to continue or hook:defer() to suspend.
---@param type string
---@param priority integer
---@param fn fun(hook: table)
function mp.add_hook(type, priority, fn) end

---Show OSD message (uses osd duration setting).
---@param text string supports property expansion
---@param duration? number seconds
function mp.osd_message(text, duration) end

---Get current OSD dimensions as {width, height}.
---@return integer width
---@return integer height
---@return number aspect
function mp.get_osd_size() end

---Create an OSD overlay for custom drawing (e.g. ass-events).
---Use :update() after setting data; :remove() to destroy.
---@param format string "ass-events"|"osi"|"native" etc.
---@return table overlay with fields data/res_x/res_y/... and update()/remove()
function mp.create_osd_overlay(format) end

---Create an empty custom property source node (advanced).
---@return table
function mp.create_source_node() end

---Return the name of the current script (from --script=...).
---@return string
function mp.get_script_name() end

---Return the directory the script file resides in.
---@return string
function mp.get_script_directory() end

---Return the value of key in --script-opts=key=value, or nil if it is not set.
---@param key string
---@return string|nil
function mp.get_opt(key) end

---Return the client id of the script (also client-message source).
---@return string
function mp.get_script_id() end

---Register an idle hook called when the event loop is idle.
---@param fn fun()
function mp.register_idle(fn) end

---Mark a hook requirement (advanced; see manual).
---@param token any
function mp.request_idle_events(token) end

---Keep running flag: setting to false quits the script's event loop
---(0.40+: prefer global exit()).
mp.keep_running = true

-------------------------------------------------------------------------------
-- mp.msg - logging
-------------------------------------------------------------------------------
---@class mpmsg
mp.msg = {}
---@param ... any
function mp.msg.fatal(...) end

---@param ... any
function mp.msg.error(...) end

---@param ... any
function mp.msg.warn(...) end

---@param ... any
function mp.msg.info(...) end

---@param ... any
function mp.msg.verbose(...) end

---@param ... any
function mp.msg.debug(...) end

---@param ... any
function mp.msg.trace(...) end

---@param level string one of "fatal","error","warn","info","v","debug","trace"
---@param ... any
function mp.msg.log(level, ...) end

-------------------------------------------------------------------------------
-- mp.utils - file system / subprocess / JSON
-------------------------------------------------------------------------------
---@class mputils
mp.utils = {}

---Returns an array of file/directory names in path.
---@param path string
---@return string[]|nil
function mp.utils.readdir(path) end

---Returns file info: stat {size, atime, mtime, ctime} or mode ("file"/"dir").
---@param path string
---@return table|nil stat
---@return string|nil mode
function mp.utils.file_info(path) end

---Split a path into (directory, filename); dir ends with separator.
---@param path string
---@return string dir
---@return string filename
function mp.utils.split_path(path) end

---Join two path components.
---@param p1 string
---@param p2 string
---@return string
function mp.utils.join_path(p1, p2) end

---Return current working directory.
---@return string
function mp.utils.getcwd() end

---Run a subprocess. opts: {args=..., cancellable=..., capture_stdout=...,
---capture_stderr=..., playback_only=..., detach=...}.
---Returns {status, stdout, stderr, killed?}.
---@param opts table
---@return table result
function mp.utils.subprocess(opts) end

---Detached version (no result; runs independently).
---Optionally accepts a callback function as the second argument.
---@param opts table
---@param callback? fun(result: any)
---@return integer|nil pid
function mp.utils.subprocess_detached(opts, callback) end

---Parse JSON string into Lua table.
---@param s string
---@return any value
---@return string|nil error
function mp.utils.parse_json(s) end

---Serialize a table to JSON.
---@param v any
---@param props? table
---@return string|nil json
---@return string|nil error
function mp.utils.format_json(v, props) end

---Return process environment variables as array of "KEY=VALUE".
---@return string[]
function mp.utils.get_env_list() end

---Return the PID of the player process.
---@return integer
function mp.utils.getpid() end

---Convert a value to string (JSON for tables).
---@param v any
---@return string
function mp.utils.to_string(v) end

-------------------------------------------------------------------------------
-- mp.options - per-script options (script-opts/<id>.conf)
-------------------------------------------------------------------------------
---@class mpoptions
mp.options = {}

---Read options into table. identifier = script name used in
---script-opts/<identifier>.conf; on_update called when --script-opts change.
---@param table table defaults map {key = default}
---@param identifier? string
---@param on_update? fun()
function mp.options.read_options(table, identifier, on_update) end

-------------------------------------------------------------------------------
-- mp.input - terminal/console input (mp.input.get/select/...)
-------------------------------------------------------------------------------
---@class mpinput
mp.input = {}
---@param opts table {prompt, default_text, cursor_position, submit, ...}
---@param callback? fun(text: string)
function mp.input.get(opts, callback) end

---@param items table|string[] items or {items=..., submit=...}
---@param callback? fun(index: integer, item: table)
function mp.input.select(items, callback) end

---Terminate the active get/select call.
---@param text? string
function mp.input.terminate(text) end

---@param level string
---@param msg string
function mp.input.log(level, msg) end

---@param f fun(level: string, msg: string)
function mp.input.set_log(f) end

-------------------------------------------------------------------------------
-- global helpers injected by mpv
-------------------------------------------------------------------------------
---Terminate the script's event loop (mpv 0.40+).
function exit() end

---Print with log (LuaJIT: goes to terminal/log).
print = print

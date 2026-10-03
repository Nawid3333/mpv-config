--- uosc global declarations for Lua Language Server.
--- This is a definition-only file (loaded via .luarc.json workspace.library).
--- It mirrors globals defined by uosc's lib/ and elements/ modules so that
--- cross-module references (e.g. lib/menus.lua using Menu/state/options)
--- resolve without undefined-global diagnostics.
--- Type aliases are intentionally NOT defined here because they already exist
--- in the source files; duplicating them triggers LuaLS "duplicate alias" warnings.
---@meta

--!nonstrict
---@diagnostic disable: duplicate-doc-alias

-------------------------------------------------------------------------------
-- Classes defined in lib/std.lua and elements/*.lua
-------------------------------------------------------------------------------

---@class Class
Class = {}

---@generic T: Class
---@param parent? T
---@return T
function class(parent) end

---@class CircularBuffer : Class
CircularBuffer = {}

---@class Element : Class
---@field id string
---@field enabled boolean
---@field render_order number
---@field ax number
---@field ay number
---@field bx number
---@field by number
---@field proximity number
---@field proximity_raw number
---@field min_visibility number
---@field forced_visibility number|nil
---@field ignores_curtain boolean
---@field anchor_id string|nil
Element = {}

---@class Elements : Class
---@field menu Menu
---@field [string] Element|table
Elements = {}

---@param element Element
function Elements:add(element) end

function Elements:remove(idOrElement) end

function Elements:update_proximities() end

---@param ids string[]
function Elements:toggle(ids) end

---@param visibility number
---@param ids string[]
function Elements:set_min_visibility(visibility, ids) end

---@param ids string[]
function Elements:flash(ids) end

---@param name string
function Elements:trigger(name, ...) end

---@param name string
function Elements:proximity_trigger(name, ...) end

---@param id string
---@param prop string
---@param fallback any
function Elements:v(id, prop, fallback) end

---@param id string
---@param method string
function Elements:maybe(id, method, ...) end

function Elements:has(id) end

function Elements:ipairs() end

---@class Menu : Element
Menu = {}

---@alias MenuAction {name: string; icon: string; label?: string; filter_hidden?: boolean;}
---@alias MenuData {id?: string; type?: string; title?: string; hint?: string; footnote: string; search_style?: 'on_demand' | 'palette' | 'disabled';  item_actions?: MenuAction[]; item_actions_place?: 'inside' | 'outside'; callback?: string[]; keep_open?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; items?: table[]; selected_index?: integer; on_search?: string|string[]; on_paste?: string|string[]; on_move?: string|string[]; on_close?: string|string[]; search_debounce?: number|string; search_submenus?: boolean; search_suggestion?: string; search_submit?: boolean; bind_keys?: string[]}
---@alias MenuDataItem {title?: string; hint?: string; icon?: string; value: any; actions?: MenuAction[]; actions_place?: 'inside' | 'outside'; active?: boolean; keep_open?: boolean; selectable?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'}
---@alias MenuDataChild MenuDataItem|table
---@alias MenuOptions {mouse_nav?: boolean;}
---@alias MenuStackItem {title?: string; hint?: string; icon?: string; value: any; actions?: MenuAction[]; actions_place?: 'inside' | 'outside'; active?: boolean; keep_open?: boolean; selectable?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; title_width: number; hint_width: number; ass_safe_hint?: string}
---@alias MenuStackChild MenuStackItem|table
---@alias MenuEventActivate {type: 'activate'; index: number; value: any; action?: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean; is_pointer: boolean; keep_open?: boolean; menu_id: string;}
---@alias MenuEventMove {type: 'move'; from_index: number; to_index: number; menu_id: string;}
---@alias MenuEventKey {type: 'key'; id: string; key: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean; menu_id: string; selected_item?: {index: number; value: any; action?: string;}}
---@alias MenuEventPaste {type: 'paste'; value: string; menu_id: string; selected_item?: {index: number; value: any; action?: string;}}

-------------------------------------------------------------------------------
-- Globals defined in main.lua and mpv stdlib modules
-------------------------------------------------------------------------------

-- mpv built-in modules loaded into globals by uosc main.lua
assdraw = {}
opt = {}
utils = {}
msg = {}
---@type table
osd = {}

QUARTER_PI_SIN = 0.7071067811865475

-- uosc runtime state tables
defaults = {}
options = {}
config = {}
state = {}
display = {}
external = {}
key_binding_overwrites = {}

---@type {width: number, height: number, disabled: boolean}
thumbnail = {}

---@type table
buttons = {}

-------------------------------------------------------------------------------
-- Globals defined in lib/std.lua
-------------------------------------------------------------------------------

---@param number number
---@return integer
function round(number) end

---@param min number
---@param value number
---@param max number
---@return number
function clamp(min, value, max) end

---@param rgba string
---@return {color: string, opacity: number, [any]: any}
function serialize_rgba(rgba) end

---@param str string
---@return string
function trim(str) end

---@param str string
---@param char string
---@return string
function trim_end(str, char) end

---@param str string
---@param pattern string
---@return string[]
function split(str, pattern) end

---@param input string|string[]|nil
---@return string[]
function comma_split(input) end

---@param str string
---@param sub string
---@return integer|nil
function string_last_index_of(str, sub) end

---@param str string
---@return string
function anycase(str) end

---@param value string
---@return string
function regexp_escape(value) end

---@param itable table
---@param value any
---@return integer|nil
function itable_index_of(itable, value) end

---@param itable table
---@param value any
---@return boolean
function itable_has(itable, value) end

---@param itable table
---@param compare fun(value: any, index: number): boolean|integer|string|nil
---@param from? number
---@param to? number
---@return number|nil
---@return any|nil
function itable_find(itable, compare, from, to) end

---@param itable table
---@param decider fun(value: any, index: number): boolean|integer|string|nil
---@return table
function itable_filter(itable, decider) end

---@param itable table
---@param value any
---@return table
function itable_delete_value(itable, value) end

---@param itable table
---@param transformer fun(value: any, index: number): any
---@return table
function itable_map(itable, transformer) end

---@param itable table
---@param start_pos? integer
---@param end_pos? integer
---@return table
function itable_slice(itable, start_pos, end_pos) end

---@generic T
---@param ... T[]|nil
---@return T[]
function itable_join(...) end

---@param target any[]
---@param source any[]
---@return any[]
function itable_append(target, source) end

---@param itable table
function itable_clear(itable) end

---@generic T
---@param input table<T, any>
---@return T[]
function table_keys(input) end

---@generic T
---@param input table<any, T>
---@return T[]
function table_values(input) end

---@generic T: table<any, any>
---@param target T
---@param ... T|nil
---@return T
function table_assign(target, ...) end

---@generic T: table<any, any>
---@param target T
---@param source T
---@param props string[]
---@return T
function table_assign_props(target, source, props) end

---@generic T: table<any, any>
---@param target T
---@param source T
---@param props table<string, boolean>
---@return T
function table_assign_exclude(target, source, props) end

---@generic T: table<any, any>
---@param input T
---@return T
function table_copy(input) end

---@param values any[]
---@return table<any, boolean>
function create_set(values) end

---@param input string
---@param value_sanitizer? fun(value: string, key: string): any
---@return table<string, any>
function serialize_key_value_list(input, value_sanitizer) end

---@param key string
---@param modifiers? string
---@return {id: string, key: string, modifiers?: string, alt: boolean, ctrl: boolean, shift: boolean}
function create_shortcut(key, modifiers) end

---@param x number
---@return number
function ease_out_quart(x) end

---@param x number
---@return number
function ease_out_sext(x) end

-------------------------------------------------------------------------------
-- Globals defined in lib/intl.lua
-------------------------------------------------------------------------------

---@param key string
---@param ... any
---@return string
function t(key, ...) end

---@return string[]
function get_languages() end

-------------------------------------------------------------------------------
-- Globals defined in lib/text.lua
-------------------------------------------------------------------------------

function timestamp_zero_rep_clear_cache() end

---@param text string|number
---@param opts {size: number; bold?: boolean; italic?: boolean}
---@return number
function text_width(text, opts) end

---@param text string
---@param opts {size: number; bold?: boolean; italic?: boolean}
---@param target_line_length number
---@return string
---@return integer
function wrap_text(text, opts, target_line_length) end

---@param text string
---@param index integer
---@param direction? -1|1
---@return integer|nil
function find_string_segment_bound(text, index, direction) end

---@param str string
---@param index integer
---@return integer|nil
function utf8_next(str, index) end

---@param str string
---@param index integer
---@return integer|nil
function utf8_prev(str, index) end

---@param name string
---@return string[]
function initials(name) end

---@param text string
---@param byte_positions number[]
---@param font_color string
---@param bold? boolean
---@return string
function highlight_match(text, byte_positions, font_color, bold) end

---@param title string
---@param query string
---@param mode string
---@param roman string[]
---@return integer[]|nil
function get_roman_match_positions(title, query, mode, roman) end

---@param str string
---@return string
function ass_escape(str) end

-------------------------------------------------------------------------------
-- Globals defined in lib/char_conv.lua
-------------------------------------------------------------------------------

---@param chars string
---@param use_ligature boolean
---@param has_separator? boolean
---@return string
---@return string[]
function char_conv(chars, use_ligature, has_separator) end

---@return boolean
function need_romanization() end

-------------------------------------------------------------------------------
-- Globals defined in lib/utils.lua
-------------------------------------------------------------------------------

---@param ... string
---@return string
function join_path(...) end

---@param path string
---@return {path: string, is_root: boolean, dirname?: string, basename: string, filename: string, extension?: string}|nil
function serialize_path(path) end

---@param delta integer
---@return boolean
function navigate_directory(delta) end

---@param delta integer
---@return boolean
function navigate_item(delta) end

---@param delta integer
function delete_file_navigate(delta) end

function request_render() end

---@param strings string[]
function sort_strings(strings) end

---@param seconds number
---@return string
function format_time(seconds) end

---@param from number
---@param to number|fun():number
---@param setter fun(value: number)
---@param duration_or_callback? number|fun()
---@param callback? fun()
---@return fun()
function tween(from, to, setter, duration_or_callback, callback) end

---@param point {x: number, y: number}
---@param rect {ax: number, ay: number, bx: number, by: number, window_drag?: boolean}
---@return number
function get_point_to_rectangle_proximity(point, rect) end

---@param point_a {x: number, y: number}
---@param point_b {x: number, y: number}
---@return number
function get_point_to_point_proximity(point_a, point_b) end

---@param point {x: number, y: number}
---@param hitbox {ax: number, ay: number, bx: number, by: number, window_drag?: boolean}|{point: {x: number, y: number}, r: number, window_drag?: boolean}
---@return boolean
function point_collides_with(point, hitbox) end

---@param path string
---@param opts? table
---@return string[] files
---@return string[] directories
---@return string|nil error
function read_directory(path, opts) end

---@param path string
---@return string
function normalize_path(path) end

---@param path string
---@return string
function path_separator(path) end

---@param path string
---@return boolean
function is_protocol(path) end

---@param path string
---@param extensions string[]
---@return boolean
function has_any_extension(path, extensions) end

---@param value string
function set_clipboard(value) end

---@return string|nil
function get_clipboard() end

---@param track_type string
---@param path string
function load_track(track_type, path) end

---@param args (string|number)[]
---@param callback fun(error: string|nil, data: table)
function call_ziggy_async(args, callback) end

-------------------------------------------------------------------------------
-- Globals defined in lib/menus.lua
-------------------------------------------------------------------------------

---@param data table
---@param opts? table
function open_command_menu(data, opts) end

---@param opts? table
function toggle_menu_with_items(opts) end

---@param opts table
---@return fun()
function create_self_updating_menu_opener(opts) end

---@param opts table
---@return fun()
function create_select_tracklist_type_menu_opener(opts) end

---@param opts table
---@return fun()
function create_track_loader_menu_opener(opts) end

function open_stream_quality_menu() end

function open_open_file_menu() end

---@param path string
---@param handle_activate fun(event: table)
---@param opts table
function open_file_navigation_menu(path, handle_activate, opts) end

function open_subtitle_downloader() end

---@return table[]
function get_keybinds_items() end

---@return table[]
function create_default_menu_items() end

---@return table[]
function get_menu_items() end

---@return {key: string, cmd: string, comment: string, is_menu_item: boolean}[]
function get_all_user_bindings() end

---@return {key: string, cmd: string, comment: string, is_menu_item: boolean}[]
function find_active_keybindings() end

---@param key string
---@return string
function keybind_to_human(key) end

-------------------------------------------------------------------------------
-- Globals from other uosc modules
-------------------------------------------------------------------------------

---@type table
cursor = {}

---@type table
Manager = {}

---@type table
ass = {}

fzy = {}

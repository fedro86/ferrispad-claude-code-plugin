-- Claude Code Plugin for FerrisPad v0.5.0
-- AI assistant powered by the Claude Code CLI.
--
-- Features:
-- - Opens an embedded terminal running `claude` in interactive mode
-- - Registers FerrisPad as an MCP server so Claude Code can query editor state
-- - Auto-approves MCP tools to skip permission prompts (configurable)
-- - Instructs Claude Code to refresh the file explorer after filesystem changes
--
-- Requires: claude CLI installed and authenticated (Pro/Max plan or API key)

local M = {
    name = "Claude Code",
    version = "0.5.0",
    description = "AI assistant powered by Claude Code CLI"
}

-- Track which project roots we've already handled in this session
local handled_roots = {}

--- Write tool permissions to <project>/.claude/settings.local.json
--- so Claude Code auto-approves our MCP tools without prompting.
local function write_tool_permissions(api, root)
    local dir_path = root .. "/.claude"
    local settings_path = dir_path .. "/settings.local.json"

    -- Read existing settings if present
    local existing = nil
    if api:file_exists(settings_path) then
        local data, _ = api:read_file(settings_path)
        if data then existing = data end
    end

    -- Check if our permission is already there
    if existing and existing:find("mcp__ferrispad__", 1, true) then
        return -- already configured
    end

    -- Create .claude dir if needed
    if not api:file_exists(dir_path) then
        api:create_dir(dir_path)
    end

    if existing then
        -- Check if there's already an "allow" array we can append to
        local allow_start = existing:find('"allow"')
        if allow_start then
            -- Find the opening bracket of the allow array
            local bracket_start = existing:find("%[", allow_start)
            if bracket_start then
                -- Insert our entry right after the opening bracket
                local after_bracket = existing:sub(bracket_start + 1)
                local is_empty = after_bracket:match("^%s*%]")
                local new
                if is_empty then
                    -- Empty allow array: ["mcp__ferrispad__*"]
                    local bracket_end = existing:find("%]", bracket_start)
                    new = existing:sub(1, bracket_start) ..
                        '"mcp__ferrispad__*"' ..
                        existing:sub(bracket_end)
                else
                    -- Non-empty: prepend with comma
                    new = existing:sub(1, bracket_start) ..
                        '\n      "mcp__ferrispad__*",' ..
                        existing:sub(bracket_start + 1)
                end
                api:write_file(settings_path, new)
                return
            end
        end

        -- No "allow" key — add permissions block before last }
        local last_pos = nil
        for i = #existing, 1, -1 do
            if existing:sub(i, i) == "}" then
                last_pos = i
                break
            end
        end

        if not last_pos then return end

        local before = existing:sub(1, last_pos - 1):gsub("%s+$", "")
        local new = before .. ',\n  "permissions": {\n    "allow": ["mcp__ferrispad__*"]\n  }\n}\n'
        api:write_file(settings_path, new)
    else
        -- No existing file, write fresh
        local content = '{\n  "permissions": {\n    "allow": ["mcp__ferrispad__*"]\n  }\n}\n'
        api:write_file(settings_path, content)
    end
end

--- Write .mcp.json in a project root and update .gitignore.
--- Binary path and MCP port are resolved internally by the Rust API.
local function ensure_mcp_json(api, root)
    local ok, err = api:setup_mcp_config(root)
    if not ok and err and err ~= "" then
        api:log("MCP: " .. err)
    end
end

-- The hook command that injects editor context and MCP instructions.
-- Uses single quotes in echo to avoid breaking JSON double-quote delimiters.
local hook_command = [[(cat ~/.config/ferrispad/editor-context.txt 2>/dev/null || true) && echo '[FerrisPad] After creating, renaming, moving, or deleting files, call the refresh_tree MCP tool to update the file explorer.']]

-- PreToolUse hook: show diff preview (non-blocking, exits immediately).
-- Saves stdin to a temp file so jq can extract multiple fields from it.
local preview_command = [[TMP=$(mktemp /tmp/fp-pre-XXXXXX); cat > "$TMP"; PORT=$(cat ~/.config/ferrispad/mcp-port 2>/dev/null); FILE=$(jq -r '.tool_input.file_path // empty' < "$TMP" 2>/dev/null); OLD=$(jq -r '.tool_input.old_string // empty' < "$TMP" 2>/dev/null); NEW=$(jq -r '.tool_input.new_string // empty' < "$TMP" 2>/dev/null); rm -f "$TMP"; [ -n "$PORT" ] && [ -n "$FILE" ] && printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"preview_edit","arguments":{"path":"%s","old_string":%s,"new_string":%s,"decision_fifo":""}}}\n' "$FILE" "$(echo "$OLD" | jq -Rs .)" "$(echo "$NEW" | jq -Rs .)" | nc -w1 127.0.0.1 "$PORT" > /dev/null 2>&1; exit 0]]

-- PostToolUse hook: reload the file buffer after Edit/Write.
local reload_command = [[FILE=$(jq -r '.tool_input.file_path // empty' 2>/dev/null); PORT=$(cat ~/.config/ferrispad/mcp-port 2>/dev/null); [ -n "$PORT" ] && [ -n "$FILE" ] && printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"reload_file","arguments":{"path":"%s"}}}\n' "$FILE" | nc -w1 127.0.0.1 "$PORT" > /dev/null 2>&1; true]]

--- Write hooks to <project>/.claude/settings.local.json:
--- - UserPromptSubmit: injects editor context
--- - PostToolUse: calls show_diff after Edit/Write
local function write_hooks(api, root)
    local settings_path = root .. "/.claude/settings.local.json"

    -- Must have existing settings (write_tool_permissions creates it first)
    local existing = nil
    if api:file_exists(settings_path) then
        local data, _ = api:read_file(settings_path)
        if data then existing = data end
    end
    if not existing then return end

    -- Check if hooks are fully configured (preview_edit = current version)
    if existing:find("preview_edit", 1, true) then
        return -- fully configured
    end

    -- Remove old hooks block to replace with new one
    -- Find the "hooks" key and remove everything up to its closing }
    local hooks_start = existing:find('"hooks"')
    if hooks_start then
        -- Find the matching closing brace for the hooks block
        local depth = 0
        local block_start = existing:find("{", hooks_start + 6)
        if block_start then
            local block_end = nil
            for i = block_start, #existing do
                local ch = existing:sub(i, i)
                if ch == "{" then depth = depth + 1
                elseif ch == "}" then
                    depth = depth - 1
                    if depth == 0 then block_end = i; break end
                end
            end
            if block_end then
                -- Remove the hooks entry (and preceding comma if any)
                local before_hooks = existing:sub(1, hooks_start - 1):gsub(",%s*$", "")
                local after_hooks = existing:sub(block_end + 1)
                existing = before_hooks .. after_hooks
            end
        end
    end

    -- Escape double quotes for JSON embedding
    local function json_escape(s)
        return s:gsub('\\', '\\\\'):gsub('"', '\\"')
    end

    -- Build the hooks block with both UserPromptSubmit and PostToolUse
    local hooks_block = string.format(
        [["hooks": {
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "%s"}]}],
    "PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "%s"}]}],
    "PostToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "%s"}]}]
  }]],
        json_escape(hook_command),
        json_escape(preview_command),
        json_escape(reload_command)
    )

    -- Find last } to insert before it
    local last_pos = nil
    for i = #existing, 1, -1 do
        if existing:sub(i, i) == "}" then
            last_pos = i
            break
        end
    end
    if not last_pos then return end

    local before = existing:sub(1, last_pos - 1):gsub("%s+$", "")
    local new = before .. ',\n  ' .. hooks_block .. '\n}\n'
    api:write_file(settings_path, new)
end

--- Set up MCP integration for a project root.
--- Writes .mcp.json for MCP discovery and settings.local.json for auto-approve.
local function setup_mcp(api)
    local root = api:get_project_root()
    if not root then return end

    -- Skip if we already handled this root in this session
    if handled_roots[root] then return end
    handled_roots[root] = true

    -- Write .mcp.json for MCP server discovery
    ensure_mcp_json(api, root)

    -- Write tool permissions for auto-approve (if enabled)
    if api:get_config_bool("auto_approve_mcp") then
        write_tool_permissions(api, root)
    end

    -- Write hooks (context injection + auto show_diff)
    write_hooks(api, root)
end

--- On startup: set up MCP for the CWD project (if any).
function M.init(api)
    setup_mcp(api)
end

--- On file open: set up MCP for the file's project root.
--- Covers switching between projects or opening files from different repos.
function M.on_document_open(api, path)
    setup_mcp(api)
end

--- Clean up .mcp.json for all roots we handled.
function M.shutdown(api)
    for root, _ in pairs(handled_roots) do
        local mcp_path = root .. "/.mcp.json"
        if api:file_exists(mcp_path) then
            api:remove(mcp_path)
        end
    end
end

--- Open Claude Code in an embedded terminal.
function M.on_menu_action(api, action, path, content)
    if action == "open_chat" then
        return {
            terminal_view = {
                title = "Claude Code",
                command = "claude",
                persistent = true,
            }
        }
    end
end

return M

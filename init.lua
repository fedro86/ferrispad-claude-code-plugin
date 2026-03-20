-- Claude Code Plugin for FerrisPad v0.4.0
-- AI assistant powered by the Claude Code CLI.
--
-- Features:
-- - Opens an embedded terminal running `claude` in interactive mode
-- - Registers FerrisPad as an MCP server so Claude Code can query editor state
-- - Auto-approves MCP tools to skip permission prompts (configurable)
--
-- Requires: claude CLI installed and authenticated (Pro/Max plan or API key)

local M = {
    name = "Claude Code",
    version = "0.4.0",
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
local function ensure_mcp_json(api, root)
    local port = api:get_mcp_port()
    if not port then return end

    local binary = api:get_binary_path()
    if not binary then return end

    local mcp_path = root .. "/.mcp.json"

    -- Don't overwrite existing .mcp.json (user may have customized it)
    if api:file_exists(mcp_path) then return end

    -- Escape backslashes and quotes for JSON string value
    local escaped = binary:gsub("\\", "\\\\"):gsub('"', '\\"')
    local config = string.format([[{
  "mcpServers": {
    "ferrispad": {
      "type": "stdio",
      "command": "%s",
      "args": ["--mcp-server"]
    }
  }
}]], escaped)

    local ok, err = api:write_file(mcp_path, config)
    if not ok then
        api:log("MCP: failed to write .mcp.json: " .. (err or "unknown error"))
        return
    end

    -- Ensure .mcp.json is in .gitignore
    local gitignore_path = root .. "/.gitignore"
    local content = ""
    if api:file_exists(gitignore_path) then
        local data, _ = api:read_file(gitignore_path)
        if data then content = data end
    end

    if not content:find(".mcp.json", 1, true) then
        local prefix = ""
        if content ~= "" and content:sub(-1) ~= "\n" then
            prefix = "\n"
        end
        api:write_file(gitignore_path, content .. prefix .. ".mcp.json\n")
    end
end

--- Write UserPromptSubmit hook to <project>/.claude/settings.local.json
--- so Claude Code attaches the current editor selection as context.
local function write_selection_hook(api, root)
    local settings_path = root .. "/.claude/settings.local.json"

    -- Must have existing settings (write_tool_permissions creates it first)
    local existing = nil
    if api:file_exists(settings_path) then
        local data, _ = api:read_file(settings_path)
        if data then existing = data end
    end
    if not existing then return end

    -- Check if hook is already configured
    if existing:find("editor%-context%.txt", 1, false) then
        return -- already configured
    end

    local hook_block = '"hooks": {\n    "UserPromptSubmit": [{\n      "matcher": "",\n      "hooks": [{\n        "type": "command",\n        "command": "cat ~/.config/ferrispad/editor-context.txt 2>/dev/null || true"\n      }]\n    }]\n  }'

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
    local new = before .. ',\n  ' .. hook_block .. '\n}\n'
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

    -- Write selection context hook
    write_selection_hook(api, root)
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

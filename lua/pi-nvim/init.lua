local M = {}

local defaults = {
    mapping = "<leader>ai",
    context_lines = 20,
    split = "botright split",
    pi_command = { "pi" },
    socket_timeout_ms = 1500,
}

M.config = vim.deepcopy(defaults)
local mapped_key
local notification_server
local notification_socket

local function runtime_dir()
    local xdg = vim.env.XDG_RUNTIME_DIR
    if xdg and xdg ~= "" then
        return xdg .. "/pi-nvim"
    end

    local passwd = vim.uv.os_get_passwd()
    return string.format("/tmp/pi-nvim-%s", passwd and passwd.uid or "unknown")
end

local function get_context(visual)
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_count = vim.api.nvim_buf_line_count(buf)
    local first_line
    local last_line
    local kind

    if visual then
        local anchor = vim.fn.getpos("v")[2]
        local current = cursor[1]
        first_line = math.min(anchor, current)
        last_line = math.max(anchor, current)
        kind = "selection"
    else
        first_line = math.max(1, cursor[1] - M.config.context_lines)
        last_line = math.min(line_count, cursor[1] + M.config.context_lines)
        kind = "excerpt"
    end

    local raw_lines = vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false)
    local lines = {}
    for index, text in ipairs(raw_lines) do
        lines[index] = string.format("%d | %s", first_line + index - 1, text)
    end

    local name = vim.api.nvim_buf_get_name(buf)
    return {
        cwd = vim.fn.getcwd(),
        file = name ~= "" and vim.fn.fnamemodify(name, ":p") or "[No Name]",
        filetype = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or "unknown",
        cursor_line = cursor[1],
        cursor_column = cursor[2] + 1,
        modified = vim.bo[buf].modified,
        first_line = first_line,
        last_line = last_line,
        kind = kind,
        lines = lines,
    }
end

local function format_message(prompt, context)
    return table.concat({
        "<neovim_context>",
        "cwd: " .. context.cwd,
        "file: " .. context.file,
        "filetype: " .. context.filetype,
        string.format("cursor: %d:%d", context.cursor_line, context.cursor_column),
        "buffer_modified: " .. tostring(context.modified),
        string.format("%s_lines: %d-%d", context.kind, context.first_line, context.last_line),
        "```" .. (context.filetype ~= "unknown" and context.filetype or ""),
        table.concat(context.lines, "\n"),
        "```",
        "</neovim_context>",
        "",
        "<neovim_prompt>",
        prompt,
        "</neovim_prompt>",
    }, "\n")
end

local function read_file(path)
    local fd = vim.uv.fs_open(path, "r", 384)
    if not fd then
        return nil
    end
    local stat = vim.uv.fs_fstat(fd)
    local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
    vim.uv.fs_close(fd)
    return data
end

local function discover_instances(cwd)
    local dir = runtime_dir()
    local scanner = vim.uv.fs_scandir(dir)
    if not scanner then
        return {}
    end

    local instances = {}
    while true do
        local name, entry_type = vim.uv.fs_scandir_next(scanner)
        if not name then
            break
        end
        if entry_type == "file" and name:match("%.json$") then
            local metadata_path = dir .. "/" .. name
            local ok, metadata = pcall(vim.json.decode, read_file(metadata_path) or "")
            if ok and type(metadata) == "table" and type(metadata.socket) == "string" then
                local stat = vim.uv.fs_stat(metadata.socket)
                if stat then
                    metadata.metadata_path = metadata_path
                    metadata.cwd_match = metadata.cwd == cwd
                    metadata.updated_at = tonumber(metadata.updatedAt) or 0
                    table.insert(instances, metadata)
                else
                    vim.uv.fs_unlink(metadata_path)
                end
            end
        end
    end

    table.sort(instances, function(a, b)
        if a.cwd_match ~= b.cwd_match then
            return a.cwd_match
        end
        return a.updated_at > b.updated_at
    end)
    return instances
end

local function refresh_buffer(path)
    local absolute_path = vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local buffer_path = vim.api.nvim_buf_get_name(buf)
        buffer_path = vim.uv.fs_realpath(buffer_path) or vim.fn.fnamemodify(buffer_path, ":p")
        if vim.api.nvim_buf_is_loaded(buf) and buffer_path == absolute_path then
            if vim.bo[buf].modified then
                vim.notify("pi-nvim: skipped reloading modified buffer " .. path, vim.log.levels.WARN)
                return false
            end
            vim.api.nvim_buf_call(buf, function()
                vim.cmd("silent edit!")
            end)
            return true
        end
    end
    return false
end

local function start_notification_server()
    if notification_server then
        return
    end

    local dir = runtime_dir()
    vim.fn.mkdir(dir, "p")
    vim.uv.fs_chmod(dir, 448)
    notification_socket = string.format("%s/nvim-%d.sock", dir, vim.fn.getpid())
    vim.uv.fs_unlink(notification_socket)

    local server = vim.uv.new_pipe(false)
    local ok, bind_error = pcall(server.bind, server, notification_socket)
    if not ok then
        server:close()
        notification_socket = nil
        vim.notify("pi-nvim: failed to create notification socket: " .. tostring(bind_error), vim.log.levels.ERROR)
        return
    end

    server:listen(16, function(err)
        if err then
            return
        end
        local client = vim.uv.new_pipe(false)
        server:accept(client)
        local input = ""
        client:read_start(function(read_err, chunk)
            if read_err or not chunk then
                client:read_stop()
                client:close()
                return
            end
            input = input .. chunk
            local newline = input:find("\n", 1, true)
            if newline then
                local decoded, event = pcall(vim.json.decode, input:sub(1, newline - 1))
                client:read_stop()
                client:close()
                if decoded and event.version == 1 and event.type == "file_changed" and type(event.path) == "string" then
                    vim.schedule(function()
                        refresh_buffer(event.path)
                    end)
                end
            end
        end)
    end)

    notification_server = server
    vim.uv.fs_chmod(notification_socket, 384)
    vim.api.nvim_create_autocmd("VimLeavePre", {
        once = true,
        callback = function()
            if notification_server and not notification_server:is_closing() then
                notification_server:close()
            end
            vim.uv.fs_unlink(notification_socket)
        end,
    })
end

local function open_pi(message, context)
    vim.cmd(M.config.split)
    local terminal_buffer = vim.api.nvim_create_buf(false, false)
    local terminal_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(terminal_window, terminal_buffer)

    local command = vim.list_extend(vim.deepcopy(M.config.pi_command), { message })
    local env = vim.tbl_extend("force", vim.fn.environ(), { PI_NVIM_SOCKET = notification_socket })
    local options = {
        cwd = context.cwd,
        env = env,
        on_exit = function()
            vim.schedule(function()
                if vim.api.nvim_win_is_valid(terminal_window)
                    and vim.api.nvim_win_get_buf(terminal_window) == terminal_buffer then
                    pcall(vim.api.nvim_win_close, terminal_window, true)
                end
            end)
        end,
    }
    local job
    if vim.fn.has("nvim-0.12") == 1 then
        options.term = true
        job = vim.fn.jobstart(command, options)
    else
        job = vim.fn.termopen(command, options)
    end
    if job <= 0 then
        pcall(vim.api.nvim_win_close, terminal_window, true)
        vim.notify("pi-nvim: failed to start Pi", vim.log.levels.ERROR)
        return
    end
    vim.cmd("startinsert")
    return job
end

local function send_to_instance(instance, message, on_unavailable)
    local pipe = vim.uv.new_pipe(false)
    local timer = vim.uv.new_timer()
    local connected = false
    local finished = false
    local buffer = ""

    local function close_handles()
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        if pipe and not pipe:is_closing() then
            pipe:read_stop()
            pipe:close()
        end
    end

    local function finish()
        if finished then
            return false
        end
        finished = true
        close_handles()
        return true
    end

    timer:start(M.config.socket_timeout_ms, 0, vim.schedule_wrap(function()
        if not finish() then
            return
        end
        if connected then
            vim.notify("pi-nvim: Pi accepted the connection but did not acknowledge the prompt", vim.log.levels.ERROR)
        else
            on_unavailable()
        end
    end))

    pipe:connect(instance.socket, function(err)
        if finished then
            return
        end
        if err then
            vim.schedule(function()
                if finish() then
                    on_unavailable()
                end
            end)
            return
        end

        connected = true
        pipe:read_start(function(read_err, chunk)
            if finished then
                return
            end
            if read_err then
                vim.schedule(function()
                    if finish() then
                        vim.notify("pi-nvim: failed reading Pi acknowledgement: " .. read_err, vim.log.levels.ERROR)
                    end
                end)
                return
            end
            if not chunk then
                return
            end

            buffer = buffer .. chunk
            local newline = buffer:find("\n", 1, true)
            if not newline then
                return
            end
            local ok, response = pcall(vim.json.decode, buffer:sub(1, newline - 1))
            vim.schedule(function()
                if not finish() then
                    return
                end
                if ok and response.ok then
                    vim.notify(response.queued and "pi-nvim: prompt queued in Pi" or "pi-nvim: prompt sent to Pi")
                else
                    local error_message = ok and response.error or "invalid response"
                    vim.notify("pi-nvim: Pi rejected the prompt: " .. tostring(error_message), vim.log.levels.ERROR)
                end
            end)
        end)

        pipe:write(vim.json.encode({
            version = 1,
            message = message,
            notificationSocket = notification_socket,
        }) .. "\n", function(write_err)
            if write_err then
                vim.schedule(function()
                    if finish() then
                        vim.notify("pi-nvim: failed sending prompt: " .. write_err, vim.log.levels.ERROR)
                    end
                end)
            end
        end)
    end)
end

local function instance_label(instance)
    local scope = instance.cwd_match and "current cwd" or instance.cwd
    return string.format("%s · pid %s", scope, tostring(instance.pid or "unknown"))
end

local function deliver_to_instances(instances, message, context)
    local index = 1

    local function try_next()
        local instance = instances[index]
        index = index + 1
        if not instance then
            open_pi(message, context)
            return
        end
        send_to_instance(instance, message, try_next)
    end

    try_next()
end

local function deliver(message, context)
    local instances = discover_instances(context.cwd)
    if #instances < 2 then
        deliver_to_instances(instances, message, context)
        return
    end

    vim.ui.select(instances, {
        prompt = "Pi instance> ",
        format_item = instance_label,
    }, function(selected)
        if not selected then
            return
        end

        local ordered = { selected }
        for _, instance in ipairs(instances) do
            if instance ~= selected then
                table.insert(ordered, instance)
            end
        end
        deliver_to_instances(ordered, message, context)
    end)
end

function M.ask(options)
    options = options or {}
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].modified then
        if vim.api.nvim_buf_get_name(buf) == "" or vim.bo[buf].buftype ~= "" then
            vim.notify("pi-nvim: cannot send a modified buffer that is not a writable file", vim.log.levels.ERROR)
            return
        end
        local written, error_message = pcall(vim.cmd, "silent write")
        if not written then
            vim.notify("pi-nvim: failed to save buffer: " .. tostring(error_message), vim.log.levels.ERROR)
            return
        end
    end

    local context = get_context(options.visual == true)
    vim.ui.input({ prompt = "Pi> " }, function(prompt)
        if not prompt or vim.trim(prompt) == "" then
            return
        end
        deliver(format_message(prompt, context), context)
    end)
end

function M.setup(options)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
    start_notification_server()
    if mapped_key then
        pcall(vim.keymap.del, "n", mapped_key)
        pcall(vim.keymap.del, "x", mapped_key)
    end
    mapped_key = M.config.mapping
    vim.keymap.set("n", M.config.mapping, function()
        M.ask()
    end, { desc = "Send prompt and Neovim context to Pi" })
    vim.keymap.set("x", M.config.mapping, function()
        M.ask({ visual = true })
    end, { desc = "Send prompt and selection to Pi" })
end

M._test = {
    runtime_dir = runtime_dir,
    format_message = format_message,
    discover_instances = discover_instances,
    instance_label = instance_label,
    refresh_buffer = refresh_buffer,
    open_pi = open_pi,
}

return M

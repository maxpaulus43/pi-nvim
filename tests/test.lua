local plugin = require("pi-nvim")

local context = {
    cwd = "/tmp/project",
    file = "/tmp/project/main.lua",
    filetype = "lua",
    cursor_line = 3,
    cursor_column = 5,
    modified = true,
    first_line = 2,
    last_line = 3,
    kind = "excerpt",
    lines = { "2 | local x = 1", "3 | print(x)" },
}

local message = plugin._test.format_message("Explain this", context)
assert(message:find("<neovim_context>\n", 1, true) == 1)
assert(message:sub(-#"<neovim_prompt>\nExplain this\n</neovim_prompt>") == "<neovim_prompt>\nExplain this\n</neovim_prompt>")
assert(message:find("file: /tmp/project/main.lua", 1, true))
assert(message:find("cursor: 3:5", 1, true))
assert(message:find("buffer_modified: true", 1, true))
assert(message:find("2 | local x = 1", 1, true))

local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. "/pi-nvim", "p")
vim.env.XDG_RUNTIME_DIR = temp
local dir = plugin._test.runtime_dir()
assert(dir == temp .. "/pi-nvim")

local function write(path, data)
    local fd = assert(vim.uv.fs_open(path, "w", 384))
    assert(vim.uv.fs_write(fd, data, 0))
    vim.uv.fs_close(fd)
end

write(dir .. "/same.sock", "")
write(dir .. "/newer.sock", "")
write(dir .. "/other.sock", "")
write(dir .. "/same.json", vim.json.encode({
    pid = 1,
    socket = dir .. "/same.sock",
    cwd = "/tmp/project",
    updatedAt = 1,
}))
write(dir .. "/newer.json", vim.json.encode({
    pid = 3,
    socket = dir .. "/newer.sock",
    cwd = "/tmp/project",
    updatedAt = 3,
}))
write(dir .. "/other.json", vim.json.encode({
    pid = 2,
    socket = dir .. "/other.sock",
    cwd = "/tmp/other",
    updatedAt = 2,
}))


local instances = plugin._test.discover_instances("/tmp/project")
assert(#instances == 3)
assert(instances[1].pid == 3)
assert(instances[2].pid == 1)
assert(instances[3].pid == 2)
assert(plugin._test.instance_label(instances[1]) == "current cwd · pid 3")
assert(plugin._test.instance_label(instances[3]) == "/tmp/other · pid 2")

local buffer_path = temp .. "/buffer.lua"
write(buffer_path, "local value = 1\n")
vim.cmd("edit " .. vim.fn.fnameescape(buffer_path))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 2" })
local original_input = vim.ui.input
vim.ui.input = function(_, callback)
    local fd = assert(vim.uv.fs_open(buffer_path, "r", 384))
    local saved = assert(vim.uv.fs_read(fd, 100, 0))
    vim.uv.fs_close(fd)
    assert(saved == "local value = 2\n")
    callback(nil)
end
plugin.ask()
vim.ui.input = original_input
assert(not vim.bo.modified)

write(buffer_path, "local value = 200\n")
assert(plugin._test.refresh_buffer(buffer_path))
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "local value = 200")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 3" })
write(buffer_path, "local value = 4000\n")
assert(not plugin._test.refresh_buffer(buffer_path))
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "local value = 3")
vim.bo.modified = false

plugin.config.split = "botright split"
plugin.config.pi_command = { "sh", "-c", "sleep 10" }
local source_buffer = vim.api.nvim_get_current_buf()
context.cwd = temp
local first_job = plugin._test.open_pi("first", context)
local first_terminal_buffer = vim.api.nvim_get_current_buf()
local first_terminal_window = vim.api.nvim_get_current_win()
assert(first_job > 0)
assert(first_terminal_buffer ~= source_buffer)
assert(vim.bo[first_terminal_buffer].buftype == "terminal")

local second_job = plugin._test.open_pi("second", context)
local second_terminal_buffer = vim.api.nvim_get_current_buf()
local second_terminal_window = vim.api.nvim_get_current_win()
assert(second_job > 0)
assert(second_terminal_buffer ~= first_terminal_buffer)
assert(vim.bo[second_terminal_buffer].buftype == "terminal")
vim.fn.jobstop(first_job)
vim.fn.jobstop(second_job)
assert(vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(first_terminal_window)
        and not vim.api.nvim_win_is_valid(second_terminal_window)
end))
assert(vim.api.nvim_get_current_buf() == source_buffer)

vim.fn.delete(temp, "rf")
print("pi-nvim Lua tests passed")

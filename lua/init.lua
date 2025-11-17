local M = {}

local api = vim.api
local fn = vim.fn
local cmd = api.nvim_create_user_command
local map = vim.keymap.set
local autocmd = api.nvim_create_autocmd

local function info(msg) vim.notify(msg, vim.log.levels.INFO, { title = "DiffSnap" }) end
local function warn(msg) vim.notify(msg, vim.log.levels.WARN, { title = "DiffSnap" }) end
local function err(msg) vim.notify(msg, vim.log.levels.ERROR, { title = "DiffSnap" }) end
local function debug(msg) vim.notify(msg, vim.log.levels.DEBUG, { title = "DiffSnap" }) end

-- Cache for buffer snapshots, keyed by buffer number.
local snapshots = {}
local sign_group = "DiffSnapGroup" -- A unique namespace for our signs.
local placed_signs = {}            -- Track placed signs per buffer for efficient clearing
local sign_positions = {}          -- Track sign positions per buffer for navigation

-- Defines the signs and highlight groups. This should be called only once.
local function define_resources()
	-- Define highlight groups for the signs.
	api.nvim_set_hl(0, "DiffSnapAdd", { link = "GitSignsAdd" })
	api.nvim_set_hl(0, "DiffSnapChange", { link = "GitSignsChange" })
	api.nvim_set_hl(0, "DiffSnapDelete", { link = "GitSignsDelete" })
	api.nvim_set_hl(0, "DiffSnapDeletedContent", { link = "DiffDelete" })

	-- Define the signs themselves. Use clear, distinct characters.
	fn.sign_define("DiffSnapAdd", { text = "+", texthl = "DiffSnapAdd" })
	fn.sign_define("DiffSnapChange", { text = "~", texthl = "DiffSnapChange" })
	fn.sign_define("DiffSnapDelete", { text = "-", texthl = "DiffSnapDelete" })
	fn.sign_define("DiffSnapDeleteMulti", { text = "━", texthl = "DiffSnapDelete" })
end

-- Helper function to safely call LSP format
local function safe_format()
	local success, result = pcall(function()
		-- Try vim.lsp.buf.format first (newer API)
		if vim.lsp.buf.format then
			vim.lsp.buf.format({ timeout_ms = 3000 })
			return true
			-- Fall back to vim.lsp.buf.formatting (older API)
		elseif vim.lsp.buf.formatting then
			vim.lsp.buf.formatting()
			return true
		else
			return false
		end
	end)
	if not success then
		debug("LSP formatting failed or not available")
		return false
	end
	return result
end

--- Takes a snapshot of the current buffer's content.
function M.snap()
	local bufnr = api.nvim_get_current_buf()
	snapshots[bufnr] = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	-- Clean up snapshots for deleted buffers
	for buf_id in pairs(snapshots) do
		if not api.nvim_buf_is_valid(buf_id) then
			snapshots[buf_id] = nil
			placed_signs[buf_id] = nil
			sign_positions[buf_id] = nil
		end
	end
	info("Buffer snapshot created.")
end

--- Replaces buffer content with clipboard and shows diff.
function M.replace_and_diff(register)
	local bufnr = api.nvim_get_current_buf()
	register = register or '*' -- Default to system clipboard
	if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
		return err("Buffer is not modifiable")
	end
	M.snap()
	local clipboard_content = fn.getreg(register)
	if clipboard_content == '' then
		return warn("Clipboard is empty")
	end
	local new_lines = vim.split(clipboard_content, '\n')
	api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	-- Format the code if LSP is available
	local formatted = safe_format()
	if formatted then
		-- Wait a bit for formatting to complete before showing diff
		vim.defer_fn(function() M.show() end, 100)
	else
		M.show() --show immediately 
	end
end

-- Track virtual text namespaces
local virtual_text_ns = nil
local virtual_text_timer = nil

-- Helper function to show original content as virtual text
local function show_original_content(bufnr, line_num)
	local original_lines = snapshots[bufnr]
	if not original_lines or line_num > #original_lines then
		return
	end
	if not virtual_text_ns then
		virtual_text_ns = api.nvim_create_namespace("DiffSnapVirtualText")
	end
	-- Clear any existing virtual text
	api.nvim_buf_clear_namespace(bufnr, virtual_text_ns, 0, -1)
	-- Cancel previous timer if it exists
	if virtual_text_timer then
		virtual_text_timer:stop()
		virtual_text_timer:close()
	end
	-- Get original line content
	local original_line = original_lines[line_num] or ""
	-- Show virtual text above the current line
	api.nvim_buf_set_extmark(bufnr, virtual_text_ns, line_num - 1, 0, {
		virt_lines = {
			{
				{ "  Original: ", "Comment" },
				{ original_line,  "DiffDelete" }
			}
		},
		virt_lines_above = true
	})
	-- Auto-clear after 4 seconds
	virtual_text_timer = vim.loop.new_timer()
	virtual_text_timer:start(4000, 0, vim.schedule_wrap(function()
		if api.nvim_buf_is_valid(bufnr) then
			api.nvim_buf_clear_namespace(bufnr, virtual_text_ns, 0, -1)
		end
		virtual_text_timer:stop()
		virtual_text_timer:close()
		virtual_text_timer = nil
	end))
end
--- Navigate to next diff change.
function M.next_change()
	local bufnr = api.nvim_get_current_buf()
	local positions = sign_positions[bufnr]
	if not positions or #positions == 0 then
		return warn("No diff changes to navigate to.")
	end
	local current_line = api.nvim_win_get_cursor(0)[1]
	local next_pos = nil
	-- Find the next position after current line
	for _, pos in ipairs(positions) do
		if pos > current_line then
			next_pos = pos
			break
		end
	end
	-- If no next position found, wrap to first
	if not next_pos then
		next_pos = positions[1]
	end
	api.nvim_win_set_cursor(0, { next_pos, 0 })
	show_original_content(bufnr, next_pos)
	info(string.format("Navigated to change at line %d", next_pos))
end

--- Navigate to previous diff change.
function M.prev_change()
	local bufnr = api.nvim_get_current_buf()
	local positions = sign_positions[bufnr]
	if not positions or #positions == 0 then
		return warn("No diff changes to navigate to.")
	end
	local current_line = api.nvim_win_get_cursor(0)[1]
	local prev_pos = nil
	-- Find the previous position before current line (search in reverse)
	for i = #positions, 1, -1 do
		if positions[i] < current_line then
			prev_pos = positions[i]
			break
		end
	end
	-- If no previous position found, wrap to last
	if not prev_pos then
		prev_pos = positions[#positions]
	end
	api.nvim_win_set_cursor(0, { prev_pos, 0 })
	show_original_content(bufnr, prev_pos)
	info(string.format("Navigated to change at line %d", prev_pos))
end

--- Remove snapshot for a specific buffer.
function M.remove_snapshot(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if snapshots[bufnr] then
		snapshots[bufnr] = nil
		placed_signs[bufnr] = nil
		sign_positions[bufnr] = nil
		info("Snapshot removed.")
	else
		warn("No snapshot found to remove.")
	end
end

--- Check if current buffer has a snapshot.
function M.has_snapshot(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	return snapshots[bufnr] ~= nil
end

--- Clear all virtual text created by DiffSnap
function M.clear_virtual_text(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	-- Clear the original content virtual text namespace
	if virtual_text_ns then
		api.nvim_buf_clear_namespace(bufnr, virtual_text_ns, 0, -1)
	end
	-- Clear the deleted content virtual text namespace
	local deleted_ns = api.nvim_create_namespace("DiffSnapDeleted")
	api.nvim_buf_clear_namespace(bufnr, deleted_ns, 0, -1)
	-- Cancel any active timer to prevent virtual text from reappearing
	if virtual_text_timer then
		virtual_text_timer:stop()
		virtual_text_timer:close()
		virtual_text_timer = nil
	end
end

-- Enhanced show function with better deletion handling
function M.show()
	local bufnr = api.nvim_get_current_buf()
	local original_lines = snapshots[bufnr]
	if not original_lines then
		return warn("No snapshot found. Use :DiffSnap first.")
	end
	local current_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	-- Clear previous signs before showing new ones.
	M.clear()
	-- Convert lines to strings for vim.diff
	local original_text = table.concat(original_lines, '\n')
	local current_text = table.concat(current_lines, '\n')
	-- Use 'indices' result_type to get structured diff information
	local diff_result = vim.diff(original_text, current_text, { result_type = 'indices' })
	-- Handle the case where vim.diff returns a string instead of table
	if type(diff_result) == 'string' then
		return info("No differences found.")
	end
	if not diff_result or #diff_result == 0 then
		return info("No differences found.")
	end
	local sign_id = 1000 -- Starting ID for signs to avoid collision.
	placed_signs[bufnr] = {}
	sign_positions[bufnr] = {}
	-- Create namespace for deleted content virtual text
	local deleted_ns = api.nvim_create_namespace("DiffSnapDeleted")
	api.nvim_buf_clear_namespace(bufnr, deleted_ns, 0, -1)
	-- Process the diff indices
	for _, hunk in ipairs(diff_result) do
		-- hunk format: [start_a, count_a, start_b, count_b]
		local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
		if count_a == 0 and count_b > 0 then -- Addition
			for i = 0, count_b - 1 do
				local lnum = start_b + i
				fn.sign_place(sign_id, sign_group, "DiffSnapAdd", bufnr, { lnum = lnum })
				table.insert(placed_signs[bufnr], sign_id)
				table.insert(sign_positions[bufnr], lnum)
				sign_id = sign_id + 1
			end
		elseif count_a > 0 and count_b == 0 then -- Deletion
			-- Place the sign on the line where the deletion occurred
			local lnum = math.max(1, start_b)
			-- Use different sign for multi-line deletions
			local sign_name = count_a > 1 and "DiffSnapDeleteMulti" or "DiffSnapDelete"
			fn.sign_place(sign_id, sign_group, sign_name, bufnr, { lnum = lnum })
			table.insert(placed_signs[bufnr], sign_id)
			table.insert(sign_positions[bufnr], lnum)
			-- Show deleted content as virtual text
			local deleted_lines = {}
			for i = 0, count_a - 1 do
				local deleted_line = original_lines[start_a + i]
				if deleted_line then
					table.insert(deleted_lines, {
						{ "  ─ ", "DiffSnapDelete" },
						{ deleted_line, "DiffSnapDeletedContent" }
					})
				end
			end
			-- Add virtual text showing deleted content
			if #deleted_lines > 0 then
				-- Add header for deleted content
				table.insert(deleted_lines, 1, {
					{ string.format("  %d line%s deleted:", count_a, count_a > 1 and "s" or ""), "Comment" }
				})
				api.nvim_buf_set_extmark(bufnr, deleted_ns, lnum - 1, 0, {
					virt_lines = deleted_lines,
					virt_lines_above = true
				})
			end
			sign_id = sign_id + 1
		elseif count_a > 0 and count_b > 0 then -- Change
			for i = 0, count_b - 1 do
				local lnum = start_b + i
				fn.sign_place(sign_id, sign_group, "DiffSnapChange", bufnr, { lnum = lnum })
				table.insert(placed_signs[bufnr], sign_id)
				table.insert(sign_positions[bufnr], lnum)
				sign_id = sign_id + 1
			end
		end
	end
	-- Sort positions for easier navigation
	table.sort(sign_positions[bufnr])
	local diff_count = #placed_signs[bufnr]
	info(string.format("Diff marks displayed (%d changes).", diff_count))
end

-- Enhanced clear function to also clear deleted content virtual text
function M.clear()
	local bufnr = api.nvim_get_current_buf()
	-- Only clear if we have placed signs
	if placed_signs[bufnr] and #placed_signs[bufnr] > 0 then
		fn.sign_unplace(sign_group, { buffer = bufnr })
		placed_signs[bufnr] = {}
		sign_positions[bufnr] = {}
		-- Clear deleted content virtual text
		local deleted_ns = api.nvim_create_namespace("DiffSnapDeleted")
		api.nvim_buf_clear_namespace(bufnr, deleted_ns, 0, -1)
		info("Diff marks cleared.")
	end
end

-- Optional: Add a command to toggle showing deleted content
function M.toggle_deleted_content()
	local bufnr = api.nvim_get_current_buf()
	local deleted_ns = api.nvim_create_namespace("DiffSnapDeleted")
	-- Check if we have any virtual text (simple check)
	local marks = api.nvim_buf_get_extmarks(bufnr, deleted_ns, 0, -1, {})
	if #marks > 0 then
		-- Clear virtual text
		api.nvim_buf_clear_namespace(bufnr, deleted_ns, 0, -1)
		info("Deleted content hidden.")
	else
		-- Re-show the diff (this will restore virtual text)
		M.show()
	end
end

function M.setup()
	define_resources()
	-- Commands
	cmd("DiffSnap", M.snap, {
		desc = "Create a snapshot of the current buffer for diffing."
	})
	cmd("DiffShow", M.show, {
		desc = "Show diff marks against the last snapshot."
	})
	cmd("DiffClear", M.clear, { desc = "Clear all diff marks." })
	cmd("DiffReplace", M.replace_and_diff, {
		desc = "Snap, replace buffer with clipboard, and show diff."
	})
	cmd("DiffRemove", M.remove_snapshot, {
		desc = "Remove the snapshot for the current buffer."
	})

	-- Keymaps
	map('n', 'gz', M.replace_and_diff, {
		silent = true, desc = "Snap, replace with clipboard, and diff"
	})
	map('n', ']c', function() M.next_change() end, {
		silent = true, desc = "Go to next diff change"
	})
	map('n', '[c', function() M.prev_change() end, {
		silent = true, desc = "Go to previous diff change"
	})
	-- Auto-clear snapshots when buffer is deleted
	autocmd("BufDelete", {
		group = api.nvim_create_augroup("DiffSnap", { clear = true }),
		callback = function(args)
			snapshots[args.buf] = nil
			placed_signs[args.buf] = nil
			sign_positions[args.buf] = nil
		end
	})
end

return M

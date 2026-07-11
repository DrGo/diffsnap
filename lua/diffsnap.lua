local M = {}
local api = vim.api
local fn = vim.fn
local cmd = api.nvim_create_user_command
local map = vim.keymap.set
local uv = vim.uv or vim.loop

-- Consolidated notification helper
local function notify(msg, level)
	if msg and msg ~= "" then
		vim.notify(msg, level, { title = "DiffSnap" })
	end
end

-- State
local snapshots = {}
local placed_signs = {}
local sign_positions = {}
local sign_group = "DiffSnapGroup"

-- Namespaces (Created ONCE)
local ns_virt = api.nvim_create_namespace("DiffSnapVirtualText")
local ns_deleted = api.nvim_create_namespace("DiffSnapDeleted")

-- Timers
local virt_timer = nil

local function define_resources()
	-- Highlights (No trailing spaces!)
	api.nvim_set_hl(0, "DiffSnapAdd", { link = "GitSignsAdd" })
	api.nvim_set_hl(0, "DiffSnapChange", { link = "GitSignsChange" })
	api.nvim_set_hl(0, "DiffSnapDelete", { link = "GitSignsDelete" })
	api.nvim_set_hl(0, "DiffSnapDeletedContent", { link = "DiffDelete" })

	-- Signs
	fn.sign_define("DiffSnapAdd", { text = "+", texthl = "DiffSnapAdd" })
	fn.sign_define("DiffSnapChange", { text = "~", texthl = "DiffSnapChange" })
	fn.sign_define("DiffSnapDelete", { text = "-", texthl = "DiffSnapDelete" })
	fn.sign_define("DiffSnapDeleteMulti", { text = "━", texthl = "DiffSnapDelete" })
end

local function safe_format()
	local ok, _ = pcall(function()
		if vim.lsp.buf.format then
			vim.lsp.buf.format({ timeout_ms = 3000, async = false })
		elseif vim.lsp.buf.formatting then
			vim.lsp.buf.formatting()
		end
	end)
	return ok
end

function M.snap()
	local bufnr = api.nvim_get_current_buf()
	snapshots[bufnr] = api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- Cleanup invalid buffers
	for buf_id in pairs(snapshots) do
		if not api.nvim_buf_is_valid(buf_id) then
			snapshots[buf_id] = nil
			placed_signs[buf_id] = nil
			sign_positions[buf_id] = nil
		end
	end
	notify("Snap saved", vim.log.levels.INFO)
end

function M.replace_and_diff(register)
	local bufnr = api.nvim_get_current_buf()
	register = register or "*"

	if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
		return notify("Not modifiable", vim.log.levels.ERROR)
	end

	M.snap()
	local clip = fn.getreg(register)
	if clip == "" then return notify("Empty clipboard", vim.log.levels.WARN) end

	local new_lines = vim.split(clip, "\n", { plain = true })
	-- Remove trailing empty line caused by newline at EOF
	if new_lines[#new_lines] == "" then table.remove(new_lines) end

	api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

	if safe_format() then
		vim.defer_fn(function() M.show() end, 150)
	else
		M.show()
	end
end

local function show_original_content(bufnr, line_num)
	local orig = snapshots[bufnr]
	if not orig or line_num > #orig then return end

	api.nvim_buf_clear_namespace(bufnr, ns_virt, 0, -1)
	if virt_timer then
		virt_timer:stop(); virt_timer:close()
	end

	local orig_line = orig[line_num] or " "
	api.nvim_buf_set_extmark(bufnr, ns_virt, line_num - 1, 0, {
		virt_lines = { { { "  Original: ", "Comment" }, { orig_line, "DiffDelete" } } },
		virt_lines_above = true,
	})

	virt_timer = uv.new_timer()
	virt_timer:start(4000, 0, vim.schedule_wrap(function()
		if api.nvim_buf_is_valid(bufnr) then
			api.nvim_buf_clear_namespace(bufnr, ns_virt, 0, -1)
		end
		virt_timer:stop(); virt_timer:close(); virt_timer = nil
	end))
end

local function navigate(direction)
	local bufnr = api.nvim_get_current_buf()
	local pos = sign_positions[bufnr]
	if not pos or #pos == 0 then return notify("No diffs", vim.log.levels.WARN) end

	local cur = api.nvim_win_get_cursor(0)[1]
	local target = nil

	if direction == "next" then
		for _, p in ipairs(pos) do
			if p > cur then
				target = p; break
			end
		end
		target = target or pos[1]
	else
		for i = #pos, 1, -1 do
			if pos[i] < cur then
				target = pos[i]; break
			end
		end
		target = target or pos[#pos]
	end

	api.nvim_win_set_cursor(0, { target, 0 })
	show_original_content(bufnr, target)
	-- Silent navigation is generally preferred for usability
end

function M.next_change() navigate("next") end

function M.prev_change() navigate("prev") end

function M.remove_snapshot(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if snapshots[bufnr] then
		snapshots[bufnr] = nil; placed_signs[bufnr] = nil; sign_positions[bufnr] = nil
		notify("Snap removed", vim.log.levels.INFO)
	else
		notify("No snap", vim.log.levels.WARN)
	end
end

function M.has_snapshot(bufnr)
	return snapshots[bufnr or api.nvim_get_current_buf()] ~= nil
end

function M.clear_virtual_text(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	api.nvim_buf_clear_namespace(bufnr, ns_virt, 0, -1)
	api.nvim_buf_clear_namespace(bufnr, ns_deleted, 0, -1)
	if virt_timer then
		virt_timer:stop(); virt_timer:close(); virt_timer = nil
	end
end

function M.show()
	local bufnr = api.nvim_get_current_buf()
	local orig = snapshots[bufnr]
	if not orig then return notify("No snap", vim.log.levels.WARN) end

	M.clear()
	local diff_res = vim.diff(table.concat(orig, "\n"), table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
		{ result_type = "indices" })

	if type(diff_res) ~= "table" or #diff_res == 0 then
		return notify("No diffs", vim.log.levels.INFO)
	end

	api.nvim_buf_clear_namespace(bufnr, ns_deleted, 0, -1)
	placed_signs[bufnr] = {}
	sign_positions[bufnr] = {}
	local sign_id = 1000

	for _, hunk in ipairs(diff_res) do
		local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

		if count_a == 0 and count_b > 0 then -- Add
			for i = 0, count_b - 1 do
				local lnum = start_b + i
				fn.sign_place(sign_id, sign_group, "DiffSnapAdd", bufnr, { lnum = lnum })
				table.insert(placed_signs[bufnr], sign_id)
				table.insert(sign_positions[bufnr], lnum)
				sign_id = sign_id + 1
			end
		elseif count_a > 0 and count_b == 0 then -- Delete
			local lnum = math.max(1, start_b)
			local sign_name = count_a > 1 and "DiffSnapDeleteMulti" or "DiffSnapDelete"
			fn.sign_place(sign_id, sign_group, sign_name, bufnr, { lnum = lnum })
			table.insert(placed_signs[bufnr], sign_id)
			table.insert(sign_positions[bufnr], lnum)
			local del_lines = { { { string.format("  %d line%s deleted: ", count_a, count_a > 1 and "s" or ""), "Comment" } } }
			for i = 0, count_a - 1 do
				local dl = orig[start_a + i]
				if dl then table.insert(del_lines, { { "  ─ ", "DiffSnapDelete" }, { dl, "DiffSnapDeletedContent" } }) end
			end

			if #del_lines > 1 then
				api.nvim_buf_set_extmark(bufnr, ns_deleted, lnum - 1, 0,
					{ virt_lines = del_lines, virt_lines_above = true })
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

	table.sort(sign_positions[bufnr])
	notify(string.format("%d changes", #placed_signs[bufnr]), vim.log.levels.INFO)
end

function M.clear()
	local bufnr = api.nvim_get_current_buf()
	if placed_signs[bufnr] and #placed_signs[bufnr] > 0 then
		fn.sign_unplace(sign_group, { buffer = bufnr })
		placed_signs[bufnr] = {}
		sign_positions[bufnr] = {}
		api.nvim_buf_clear_namespace(bufnr, ns_deleted, 0, -1)
		notify("Cleared", vim.log.levels.INFO)
	end
end

function M.toggle_deleted_content()
	local bufnr = api.nvim_get_current_buf()
	if #api.nvim_buf_get_extmarks(bufnr, ns_deleted, 0, -1, {}) > 0 then
		api.nvim_buf_clear_namespace(bufnr, ns_deleted, 0, -1)
		notify("Hidden", vim.log.levels.INFO)
	else
		M.show()
	end
end

function M.setup()
	define_resources()

	cmd("DiffSnap", M.snap, { desc = "Snapshot buffer" })
	cmd("DiffShow", M.show, { desc = "Show diff" })
	cmd("DiffClear", M.clear, { desc = "Clear diff" })
	cmd("DiffReplace", M.replace_and_diff, { desc = "Replace with clipboard & diff" })
	cmd("DiffRemove", M.remove_snapshot, { desc = "Remove snapshot" })

	map("n", "gz", M.replace_and_diff, { silent = true, desc = "Replace & diff" })
	map("n", "]c", M.next_change, { silent = true, desc = "Next diff" })
	map("n", "[c", M.prev_change, { silent = true, desc = "Prev diff" })

	api.nvim_create_autocmd("BufDelete", {
		group = api.nvim_create_augroup("DiffSnap", { clear = true }),
		callback = function(args)
			snapshots[args.buf] = nil
			placed_signs[args.buf] = nil
			sign_positions[args.buf] = nil
		end,
	})
end

return M

local M = {}
local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local qfs = require('bqf.qfsession')
local qfpos = require('bqf.qfpos')
local utils = require('bqf.utils')

-- Code in this file relates to source code
-- https://github.com/neovim/neovim/blob/master/src/nvim/window.c
-- bfraction: before scroll_to_fraction, afraction: after scroll_to_fraction
-- bfraction = bwrow / bheight and afraction = awrow / aheight
-- bfraction = afraction ==> bwrow / bheight = awrow / aheight

-- FRACTION_MULT = 16384L
-- wp->w_fraction = ((long)wp->w_wrow * FRACTION_MULT + FRACTION_MULT / 2) / (long)wp->w_height_inner;
local function cal_fraction(wrow, height)
    return math.floor((wrow * 16384 + 8192) / height)
end

-- wp->w_wrow = ((long)wp->w_fraction * (long)height - 1L) / FRACTION_MULT;
local function cal_wrow(fraction, height)
    return math.floor((fraction * height - 1) / 16384)
end

-- Check out 'void scroll_to_fraction(win_T *wp, int prev_height)' in winodw.c for more details.
local function evaluate_sline(fraction, height, lnum, lines_size)
    local sline = cal_wrow(fraction, height)
    local i = sline
    for j = lnum - 1, math.max(1, lnum - sline), -1 do
        i = i - lines_size[j]
        if i <= 0 then
            if i < 0 then
                sline = sline - lines_size[j] - i
            end
            break
        end
    end
    return sline
end

local function do_filter(tbl_info, height, lnum, lines_size)
    local t = {}
    for _, info in ipairs(tbl_info) do
        local sline = evaluate_sline(info, height, lnum, lines_size)
        if fn.winline() - 1 == sline then
            table.insert(t, info)
        end
    end
    return t
end

-- If the lnum hasn't been changed, even if the window is resized, the fraction is still a constant.
-- And we can use this feature to find out the possible fraction with changing window height.
-- Check out 'void scroll_to_fraction(win_T *wp, int prev_height)' in winodw.c for more details.
local function filter_fraction(tbl_info, lnum, lines_size, max_hei)
    local asc
    local height = api.nvim_win_get_height(0)
    local h = height
    local min_hei = math.max(vim.o.wmh, 1)
    if max_hei then
        asc = true
    else
        asc = false
        max_hei = vim.o.lines
    end

    while #tbl_info > 1 do
        if h <= min_hei or h > max_hei then
            break
        end
        h = asc and h + 1 or h - 1
        api.nvim_win_set_height(0, h)
        if asc and api.nvim_win_get_height(0) ~= h then
            break
        end
        tbl_info = do_filter(tbl_info, h, lnum, lines_size)
    end
    api.nvim_win_set_height(0, height)
    return tbl_info
end

local function evaluate_fraction(winid, awrow, aheight, bheight, lbwrow, lfraction)
    -- s_bwrow: the minimum bwrow value
    -- Below formula we can derive from the known conditions
    local s_bwrow = math.ceil(awrow * bheight / aheight - 0.5)
    if s_bwrow < 0 or bheight == aheight then
        return
    end
    -- e_bwrow: the maximum bwrow value
    -- There are not enough conditions to derive e_bwrow, so we have to figure it out by guessing,
    -- and confirm the range of bwrow.
    -- It seems that 10 as a minimum and 1.2 as a scale is good to balance performance and accuracy
    local e_bwrow = math.max(10, math.ceil(awrow * 1.2 * bheight / aheight - 0.25))

    local lnum = api.nvim_win_get_cursor(winid)[1]
    local per_l_wid = api.nvim_win_get_width(winid) - utils.gutter_size(winid, lnum)

    local e_fraction = cal_fraction(e_bwrow, bheight)
    local e_sline = cal_wrow(e_fraction, aheight)

    if lbwrow then
        e_sline = math.max(cal_wrow(lfraction, aheight), e_sline)
    end

    local lines_size = {}
    -- use 9 as additional compensation
    for i = math.max(1, lnum - e_sline - 9), lnum - 1 do
        lines_size[i] = math.ceil(math.max(fn.virtcol({i, '$'}) - 1, 1) / per_l_wid)
    end

    if lbwrow and awrow == evaluate_sline(lfraction, aheight, lnum, lines_size) then
        return lbwrow, lfraction
    end

    local t_frac = {}
    for bw = math.max(s_bwrow, 1), e_bwrow do
        table.insert(t_frac, cal_fraction(bw, bheight))
    end

    t_frac = filter_fraction(t_frac, lnum, lines_size)
    -- print('t_frac:', vim.inspect(t_frac))

    if #t_frac > 1 and s_bwrow == 0 then
        table.insert(t_frac, 1, cal_fraction(0, bheight))
    end

    t_frac = filter_fraction(t_frac, lnum, lines_size, aheight + 9)
    -- print('after t_frac', vim.inspect(t_frac))
    if #t_frac > 0 then
        return t_frac[1]
    end
end

local function resetview(topline)
    fn.winrestview({topline = topline})
    -- topline seemly can't be changed sometimes without winline()
    fn.winline()
end

local function tune_line(winid, topline, l_size)
    if not vim.wo[winid].wrap or l_size == 0 then
        return topline - l_size
    end
    -- print('l_size:', l_size)
    local iter_start, iter_end, iter_step, len
    if l_size > 0 then
        iter_start, iter_end, iter_step = math.max(1, topline - l_size), topline - 1, 1
        len = iter_end - iter_start
    else
        iter_start, iter_end, iter_step = topline - l_size - 1, topline, -1
        len = iter_start - iter_end
    end

    return utils.win_execute(winid, function()
        local per_l_wid = api.nvim_win_get_width(winid) - utils.gutter_size(winid)
        local off, l_size_sum = 0, 0
        for i = iter_start, iter_end, iter_step do
            local per_l_size = math.ceil(math.max(fn.virtcol({i, '$'}) - 1, 1) / per_l_wid)
            -- print('============================================')
            -- print('l_size_sum:', l_size_sum, 'per_l_size:', per_l_size, 'lnum:', i)
            -- print('============================================')
            l_size_sum = l_size_sum + per_l_size
            off = off + 1
            if l_size_sum > len then
                break
            end
        end
        -- print('line_offset:', l_size > 0 and off or -off)
        return l_size > 0 and off or -off
    end)
end

local function do_enter_revert(qf_winid, winid, qf_pos)
    -- TODO upstream bug
    -- local f_win_so = vim.wo[winid].scrolloff
    -- return a big number like '1.4014575443238e+14' if window option is absent
    -- Use getwinvar to workaround
    local f_win_so = fn.getwinvar(winid, '&scrolloff')
    if f_win_so ~= 0 then
        -- turn off scrolloff and then show us true wrow
        vim.wo[winid].scrolloff = 0
        cmd(('au Bqf WinLeave * ++once %s'):format(
            ([[lua vim.wo[%d].scrolloff = %d]]):format(winid, f_win_so)))
    end

    utils.win_execute(winid, function()
        local qf_hei, win_hei = api.nvim_win_get_height(qf_winid), api.nvim_win_get_height(winid)
        local topline = fn.line('w0')
        local line_count = api.nvim_buf_line_count(0)

        -- qf winodw height might be changed by user adds new qf items or navigates history
        -- we need a cache to store previous state
        qfs[qf_winid].magicwin = qfs[qf_winid].magicwin or {}
        local mgw = qfs[qf_winid].magicwin[winid] or {}
        local def_hei = qf_hei + win_hei + 1
        local bheight, aheight = mgw.aheight or def_hei, win_hei
        local lbwrow, lfraction = mgw.bwrow, mgw.fraction
        local bwrow, fraction, delta_lsize

        local awrow = fn.winline() - 1

        if topline == 1 and line_count <= win_hei then
            delta_lsize = 0
        else
            if f_win_so >= awrow and awrow > 0 and win_hei > 1 then
                -- get the true wrow
                cmd('resize -1 | resize +1')
                awrow = fn.winline() - 1
                topline = fn.line('w0')
            end

            -- print('awrow:', awrow, 'aheight:', aheight, 'bheight:', bheight)
            -- print('lbwrow:', lbwrow, 'lfraction:', lfraction)
            fraction = evaluate_fraction(winid, awrow, aheight, bheight, lbwrow, lfraction)
            if not fraction then
                return
            end
            bwrow = cal_wrow(fraction, bheight)
            delta_lsize = bwrow - awrow
        end

        if qf_pos[1] == 'above' or qf_pos[2] == 'top' then
            if lbwrow == bwrow and lfraction == fraction then
                bheight = mgw.bheight or def_hei
            end
            delta_lsize = delta_lsize - bheight + aheight
        end

        if delta_lsize == 0 then
            return
        end

        local line_offset = tune_line(winid, topline, delta_lsize)
        line_offset = line_offset > 0 and math.min(line_offset, aheight - awrow - 1) or
                          math.max(line_offset, -awrow)
        resetview(math.max(1, topline - line_offset))

        mgw.bwrow, mgw.fraction, mgw.bheight, mgw.aheight = bwrow, fraction, bheight, aheight
        qfs[qf_winid].magicwin[winid] = mgw
    end)
end

local function prefetch_close_revert_topline(qf_winid, winid, qf_pos)
    local topline
    local ok, msg = pcall(fn.getwininfo, winid)
    if ok then
        topline = msg[1].topline
        if qf_pos[1] == 'above' or qf_pos[2] == 'top' then
            topline = topline - tune_line(winid, topline, api.nvim_win_get_height(qf_winid) + 1)
        end
    end
    return topline
end

local function need_revert(qf_pos)
    local rel_pos, abs_pos = unpack(qf_pos)
    return rel_pos == 'above' or rel_pos == 'below' or abs_pos == 'top' or abs_pos == 'bottom'
end

function M.revert_enter_adjacent_wins(qf_winid, file_winid, qf_pos)
    if need_revert(qf_pos) then
        for _, winid in ipairs(qfpos.find_adjacent_wins(qf_winid, file_winid)) do
            if api.nvim_win_is_valid(winid) then
                do_enter_revert(qf_winid, winid, qf_pos)
            end
        end
    end
end

function M.revert_close_adjacent_wins(qf_winid, file_winid, qf_pos)
    local defer_data = {}
    if need_revert(qf_pos) then
        for _, winid in ipairs(qfpos.find_adjacent_wins(qf_winid, file_winid)) do
            local topline = prefetch_close_revert_topline(qf_winid, winid, qf_pos)
            if topline then
                table.insert(defer_data, {winid = winid, topline = topline})
            end
        end
    end

    return function()
        for _, info in pairs(defer_data) do
            local winid, topline = info.winid, info.topline
            utils.win_execute(winid, function()
                resetview(topline)
            end)
        end
    end
end

return M

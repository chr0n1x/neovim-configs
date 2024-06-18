local harpoon = require("harpoon")

-- REQUIRED
harpoon:setup()
-- REQUIRED

vim.keymap.set("n", "<leader>hh", function() harpoon:list():add() end, { desc = 'Add focused buffer to harpoon list.'})
vim.keymap.set("n", "<leader>H", function() harpoon:list():clear() end, { desc = 'Clear entire harpoon list.'})

-- show previous/next buffers stored within Harpoon list; wraps the list
harpoon_wrapped_display_prev = function() harpoon:list():prev({ ui_nav_wrap = true }) end
vim.keymap.set("n", "<leader>hk", harpoon_wrapped_display_prev, { desc = 'Show previous buffer in harpoon list.'})

harpoon_wrapped_display_next = function() harpoon:list():next({ ui_nav_wrap = true }) end
vim.keymap.set("n", "<leader>hj", harpoon_wrapped_display_next, { desc = 'Show next buffer in harpoon list.'})

-- basic telescope configuration
local conf = require("telescope.config").values
local function toggle_telescope(harpoon_files)
    local file_paths = {}
    for _, item in ipairs(harpoon_files.items) do
        table.insert(file_paths, item.value)
    end

    require("telescope.pickers").new({}, {
        prompt_title = "Harpoon",
        finder = require("telescope.finders").new_table({
            results = file_paths,
        }),
        previewer = conf.file_previewer({}),
        sorter = conf.generic_sorter({}),
    }):find()
end

vim.keymap.set("n", "<C-e>", function() toggle_telescope(harpoon:list()) end,
    { desc = "Open harpoon window" })

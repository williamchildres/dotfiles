return {
  "nvim-telescope/telescope.nvim",
  opts = {
    defaults = {
      hidden = true,
      no_ignore = true,
      no_ignore_parent = true,
      follow = true,
    },
    pickers = {
      find_files = {
        hidden = true,
        no_ignore = true,
        follow = true,
        find_command = { "rg", "--files", "--hidden", "--follow", "-g", "!.git" },
      },
    },
  },
}

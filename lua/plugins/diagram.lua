if IN_PERF_MODE then
  return {}
end

-- Renders mermaid/plantuml/d2/gnuplot code blocks in markdown as inline images.
-- Images go through the kitty graphics protocol (Ghostty), which needs
-- `allow-passthrough on` when running inside tmux.
return {
  "3rd/diagram.nvim",
  ft = { "markdown" },
  dependencies = {
    {
      "3rd/image.nvim",
      opts = {
        backend = "kitty",
        processor = "magick_cli",
      },
    },
  },
  opts = function()
    return {
      integrations = { require("diagram.integrations.markdown") },
      renderer_options = {
        mermaid = { theme = "dark", background = "transparent" },
      },
    }
  end,
  keys = {
    {
      "<leader>K",
      function()
        require("diagram").show_diagram_hover()
      end,
      mode = "n",
      ft = { "markdown" },
      desc = "Diagram: show diagram under cursor in a new tab.",
    },
  },
}

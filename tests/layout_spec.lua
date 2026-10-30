-- layout.lua's rect functions are pure over a screen table, so these pin the geometry with no
-- windows open. The screen is 200 columns by 50 lines throughout.
describe("layout rects", function()
  local layout = require("harness-decorators.layout")
  local saved_rows

  before_each(function()
    saved_rows = layout.shelf_rows
  end)

  after_each(function()
    layout.shelf_rows = saved_rows
  end)

  local function screen(extra)
    return vim.tbl_extend("force", { lines = 50, columns = 200, zen_open = false }, extra or {})
  end
  local zen = { col = 40, width = 100 }
  local zen_bordered = { col = 40, width = 100, border = { "x", "x", "x", "x", "x", "x", "x", "x" } }

  it("Given no zen, When the default float rect is asked for, Then it sits at the top, left of the dock", function()
    assert.are.same({ row = 0, col = 119, width = 58, height = 43 }, layout.default_float_rect(screen()))
  end)

  it("Given no zen window, When the zen span is asked for, Then it ends where the dock begins", function()
    assert.are.same({ col = 140, width = 38 }, layout.zen_float_span(screen()))
  end)

  it(
    "Given a zen window, When the zen span is asked for, Then it starts a quarter into zen and takes 90% of the gap",
    function()
      assert.are.same({ col = 65, width = 34 }, layout.zen_float_span(screen({ zen_open = true, zen = zen })))
    end
  )

  it(
    "Given a zen window, When the side span is asked for, Then it starts right of zen and takes 55% of the gap",
    function()
      assert.are.same({ col = 141, width = 20 }, layout.zen_side_span(screen({ zen_open = true, zen = zen })))
      assert.are.same({ col = 143, width = 20 }, layout.zen_side_span(screen({ zen_open = true, zen = zen_bordered })))
    end
  )

  it("Given no zen, When the fullscreen rect is asked for, Then it pads 5% rows and 10% columns", function()
    assert.are.same({ row = 2, col = 20, width = 160, height = 45 }, layout.fullscreen_rect(screen()))
  end)

  it(
    "Given zen is open, When the fullscreen rect is asked for, Then it keeps the zen float's width, centered",
    function()
      assert.are.same(
        { row = 2, col = 82, width = 34, height = 45 },
        layout.fullscreen_rect(screen({ zen_open = true, zen = zen }))
      )
    end
  )

  it(
    "Given no zen, When the shelf rect is asked for, Then it is shelf_rows tall at the bottom of fullscreen, centered",
    function()
      layout.shelf_rows = 10
      assert.are.same({ row = 37, col = 70, width = 58, height = 10 }, layout.shelf_rect(screen()))
    end
  )

  it(
    "Given shelf_rows taller than fullscreen, When the shelf rect is asked for, Then it is capped at the fullscreen height",
    function()
      layout.shelf_rows = 100
      assert.are.same({ row = 2, col = 70, width = 58, height = 45 }, layout.shelf_rect(screen()))
    end
  )

  it(
    "Given zen is open, When the auto rect is asked for focused and aside, Then it takes the zen span or the side span",
    function()
      local s = screen({ zen_open = true, zen = zen })
      assert.are.same({ row = 0, col = 65, width = 34, height = 33 }, layout.auto_float_rect(nil, s, false))
      assert.are.same({ row = 0, col = 141, width = 20, height = 33 }, layout.auto_float_rect(nil, s, true))
    end
  )

  it("Given saved ratios, When the retract rect is asked for, Then it scales them to the screen", function()
    local inst = { _saved_config = { row_ratio = 0.1, col_ratio = 0.25, width_ratio = 0.5, height_ratio = 0.4 } }
    assert.are.same({ row = 5, col = 50, width = 100, height = 20 }, layout.retract_rect(inst, screen()))
  end)

  it(
    "Given a baseline taken at the auto spot or none, When the retract rect is asked for, Then it is the auto rect",
    function()
      local want = layout.default_float_rect(screen())
      assert.are.same(want, layout.retract_rect({ _saved_config = { auto = true, row_ratio = 0.5 } }, screen()))
      assert.are.same(want, layout.retract_rect({}, screen()))
    end
  )

  describe("stack_rects", function()
    it("Given 1 to 3 floats, Then they stack one per row", function()
      assert.are.same({ { row = 0, col = 10, width = 58, height = 43 } }, layout.stack_rects(1, 10, 60, screen()))
      assert.are.same({
        { row = 0, col = 10, width = 58, height = 19 },
        { row = 22, col = 10, width = 58, height = 21 },
      }, layout.stack_rects(2, 10, 60, screen()))
      assert.are.same({
        { row = 0, col = 10, width = 58, height = 12 },
        { row = 15, col = 10, width = 58, height = 12 },
        { row = 30, col = 10, width = 58, height = 13 },
      }, layout.stack_rects(3, 10, 60, screen()))
    end)

    it("Given 4 floats, Then they fill two rows of two with a one-cell gap", function()
      assert.are.same({
        { row = 0, col = 10, width = 27, height = 19 },
        { row = 0, col = 40, width = 28, height = 19 },
        { row = 22, col = 10, width = 27, height = 21 },
        { row = 22, col = 40, width = 28, height = 21 },
      }, layout.stack_rects(4, 10, 60, screen()))
    end)

    it("Given 4 to 7 floats, Then there are never more than 3 rows", function()
      local want_per_row = { [4] = 2, [5] = 2, [6] = 2, [7] = 3 }
      for n = 4, 7 do
        local rects = layout.stack_rects(n, 0, 90, screen())
        assert.are.equal(n, #rects)
        local rows = {}
        for _, r in ipairs(rects) do
          rows[r.row] = (rows[r.row] or 0) + 1
        end
        local nrows = vim.tbl_count(rows)
        assert.is_true(nrows <= 3, n .. " floats used " .. nrows .. " rows")
        assert.are.equal(want_per_row[n], rows[0])
      end
    end)
  end)
end)

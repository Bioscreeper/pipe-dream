local PrimeUI = require "primeui"

local thready = require "thready"
local file_helper = require "file_helper"
local logging = require "logging"

local data_dir = file_helper:instanced("data")
local log = logging.create_context("pipe_dream")


if ... == "debug" then
  logging.set_level(logging.LOG_LEVEL.DEBUG)
end

local main_win = window.create(term.current(), 1, 1, term.getSize())
local width, height = term.getSize()
local logging_display_win = window.create(term.current(), 3, 8, width - 4, height - 8)
local logging_win = window.create(logging_display_win, 1, 1, width - 4, height - 7)
logging_display_win.setVisible(false)
main_win.setVisible(false)
logging.set_window(logging_win)


local NICKNAMES_FILE = "nicknames.txt"
local FLUID_MOVED_FILE = "fluid_moved.txt"
local ITEMS_MOVED_FILE = "items_moved.txt"
local CONNECTIONS_FILE = "connections.txt"
local MOVING_ITEMS_FILE = "moving_items.txt"
local UPDATE_TICKRATE_FILE = "update_tickrate.txt"

local nicknames = data_dir:unserialize(NICKNAMES_FILE, {}) ---@type table<string, string>
local fluid_moved = data_dir:unserialize(FLUID_MOVED_FILE, 0) ---@type integer
local items_moved = data_dir:unserialize(ITEMS_MOVED_FILE, 0) ---@type integer
local connections = data_dir:unserialize(CONNECTIONS_FILE, {}) ---@type Connection[]
local moving_items = data_dir:unserialize(MOVING_ITEMS_FILE, true) ---@type boolean
local update_tickrate = data_dir:unserialize(UPDATE_TICKRATE_FILE, 10) ---@type integer
log.info("Loaded data (or created defaults).")

local function save()
  data_dir:serialize(NICKNAMES_FILE, nicknames)
  data_dir:serialize(FLUID_MOVED_FILE, fluid_moved)
  data_dir:serialize(ITEMS_MOVED_FILE, items_moved)
  data_dir:serialize(CONNECTIONS_FILE, connections)
  data_dir:serialize(MOVING_ITEMS_FILE, moving_items)
  data_dir:serialize(UPDATE_TICKRATE_FILE, update_tickrate)
  log.info("Saved data.")
end

-- We are fine if this value fails to load, as it will not break the program.
if type(items_moved) ~= "number" then
  items_moved = 0
  log.warn("Items moved file is corrupted, resetting to 0.")
end
---@cast items_moved number

-- We are also fine if this value fails to load, as it will not break the program.
if type(fluid_moved) ~= "number" then
  fluid_moved = 0
  log.warn("Fluid moved file is corrupted, resetting to 0.")
end

-- We are also fine if this value fails to load, as it will not break the program.
if type(update_tickrate) ~= "number" then
  update_tickrate = 10
  log.warn("Update tickrate file is corrupted, resetting to 10.")
end
---@cast update_tickrate number

-- We are also also fine if this value fails to load, as it will not break the program.
if type(nicknames) ~= "table" then
  nicknames = {}
  log.warn("Nicknames file is corrupted, resetting to empty table.")
end

-- We are not fine if this value fails to load, as it will break the program.
if type(connections) ~= "table" then
  error("Connections file might be corrupted, please check it for errors. Cannot read it currently.", 0)
end
---@cast connections Connection[]

---@class Connection
---@field name string The name of the connection.
---@field from string The peripheral the connection is from.
---@field to string[] The peripherals the connection is to.
---@field filter_list string[] The blacklist or whitelist of items.
---@field filter_mode "whitelist"|"blacklist" The item filter mode of the connection.
---@field mode "1234"|"split" The mode of the connection. 1234 means "push and fill 1, then 2, then 3, then 4". Split means "split input evenly between all outputs".
---@field moving boolean Whether the connection is active (moving items).
---@field id integer The unique ID of the connection.

--- Create an information box.
---@param win Window The window to draw the box on.
---@param title string The title of the box.
---@param desc string The description of the box.
---@param height integer The height of the box.
---@param override_title_color integer? The color of the title text.
local function info_box(win, title, desc, height, override_title_color)
  local width = win.getSize()
  width = width - 4

  -- Info box with border
  PrimeUI.borderBox(win, 3, 3, width, height)
  PrimeUI.textBox(win, 3, 2, #title + 2, 1, ' ' .. title .. ' ', override_title_color or colors.purple)
  PrimeUI.textBox(win, 3, 3, width, height, desc, colors.lightGray)
end

--- Create a selection box, with a list of items.
---@param win Window The window to draw the box on.
---@param x integer The x position of the box.
---@param y integer The y position of the box.
---@param width integer The width of the box.
---@param height integer The height of the box.
---@param items string[] The items to display in the box.
---@param action string|fun(index: integer, scroll_index: integer) The action to perform when an item is selected.
---@param select_change_action nil|string|fun(index: integer, scroll_index: integer) The action to perform when the selection changes.
---@param fg_color integer The color of the text.
---@param bg_color integer The color of the background.
---@param initial_index integer The index of the item to select initially.
---@param initial_scroll integer The index of the item to scroll to initially.
---@param disabled boolean? Whether the box is disabled (displayed, but not interactable).
local function outlined_selection_box(win, x, y, width, height, items, action, select_change_action, fg_color, bg_color,
                                      initial_index, initial_scroll, disabled)
  -- Selection box with border
  PrimeUI.borderBox(win, x, y, width, height, fg_color, bg_color)

  -- Draw the items
  return PrimeUI.selectionBox(win, x, y, width + 1, height, items, action, select_change_action, fg_color, bg_color,
    initial_index, initial_scroll, disabled)
end

--- Create an outlined input box.
---@param win Window The window to draw the box on.
---@param x integer The x position of the box.
---@param y integer The y position of the box.
---@param width integer The width of the box.
---@param action string|fun(text: string) The action to perform when the input is submitted.
---@param fg_color integer The color of the text.
---@param bg_color integer The color of the background.
---@param replacement string? The replacement character for the input.
---@param history string[]? The history of inputs.
---@param completion_func nil|fun(text: string): string[] The function to call for completion.
---@param default string? The default text to display in the input box.
---@param disabled boolean? Whether the box is disabled (displayed, but not interactable).
---@return string[] buffer The input buffer.
local function outlined_input_box(win, x, y, width, action, fg_color, bg_color, replacement, history, completion_func,
                                  default, disabled)
  -- Input box with border
  PrimeUI.borderBox(win, x, y, width, 1, fg_color, bg_color)

  return PrimeUI.inputBox(win, x, y, width, action, fg_color, bg_color, replacement, history, completion_func, default,
    disabled)
end

--- Get all peripherals by their name
---@return string[] peripherals The list of peripheral names.
local function get_peripherals()
  local peripherals = peripheral.getNames()

  -- Replace names with nicknames
  for i, v in ipairs(peripherals) do
    peripherals[i] = v
  end

  --[[@fixme this code needs to be re-added
  local periph_lookup = {}
  for i, v in ipairs(peripherals) do
    periph_lookup[v] = true
  end

  -- Iterate through connections and add any peripherals from that list that
  -- have been disconnected.
  for name in pairs(connections) do
    if not periph_lookup[name] then
      table.insert(peripherals, "dc:" .. (nicknames[name] or name))
    end
  end
  ]]

  return peripherals
end

--- Clear the screen buffer and ready it for drawing.
local function clear()
  main_win.setVisible(false)
  main_win.setBackgroundColor(colors.black)
  main_win.clear()
  PrimeUI.clear()
end

--- Display the unacceptable input screen.
---@param _type "error"|"input"|string The type of error.
---@param reason string The reason for the error.
local function unacceptable(_type, reason)
  log.warn("Unacceptable :", _type, ":", reason)

  clear()

  -- Draw info box.
  if _type == "error" then
    info_box(
      main_win,
      "Error",
      ("An error occurred.\n%s\n\nPress enter to continue."):format(reason),
      15,
      colors.red
    )
  elseif _type == "input" then
    info_box(
      main_win,
      "Input Error",
      ("The last user input was unacceptable.\n%s\n\nPress enter to continue."):format(reason),
      15,
      colors.red
    )
  else
    info_box(
      main_win,
      "Unknown Error",
      ("An unknown error occurred.\n%s\n\nPress enter to continue."):format(reason),
      15,
      colors.red
    )
  end

  PrimeUI.keyAction(keys.enter, "exit")
  PrimeUI.keyAction(keys.tab, "exit")

  main_win.setVisible(true)
  PrimeUI.run()
end

---@type table<integer, true> A lookup table of keys that are currently held.
local keys_held = {}

--- Key listener thread. Waits for `key` or `key_up` events and updates the `keys_held` table.
local function key_listener()
  keys_held = {} -- Reset the keys held when this method is called.
  while true do
    local event, key = os.pullEvent()
    if event == "key" then
      keys_held[key] = true
    elseif event == "key_up" then
      keys_held[key] = nil
    end
  end
end

local function shift_held()
  return keys_held[keys.leftShift] or keys_held[keys.rightShift]
end

--- Verify a connection.
---@param connection_data Connection The connection data to verify.
---@return boolean valid Whether the connection is valid.
---@return string? error_message The error message if the connection is invalid.
local function verify_connection(connection_data)
  if not connection_data then
    return false, "Connection data is nil. This should not happen, and is a bug."
  end

  if not connection_data.name or connection_data.name == "" then
    return false, "Connection has no name."
  end

  if not connection_data.from or connection_data.from == "" then
    return false, "Origin not set."
  end

  if not connection_data.to or #connection_data.to == 0 then
    return false, "No destinations selected."
  end

  if not connection_data.filter_mode or (connection_data.filter_mode ~= "whitelist" and connection_data.filter_mode ~= "blacklist") then
    return false, "Filter mode is not set or is invalid."
  end

  if not connection_data.filter_list then
    return false, "Filter list is not set."
  end

  if not connection_data.mode or (connection_data.mode ~= "1234" and connection_data.mode ~= "split") then
    return false, "Mode is not set or is invalid."
  end

  return true, "Connection is valid, so you should not see this message. This is a bug if you do."
end

--- Confirmation menu with custom title and body.
---@param title string The title of the menu.
---@param body string The body of the menu.
---@param select_yes_default boolean? Whether the default selection is "Yes".
---@return boolean sure Whether the user is sure they want to exit without saving.
local function confirmation_menu(title, body, select_yes_default)
  while true do
    clear()

    -- Draw info box.
    info_box(main_win, title, body, 2)

    outlined_selection_box(
      main_win, 3, 7, width - 4, 2,
      {
        "Yes",
        "No"
      }, "selection", nil,
      colors.white, colors.black,
      select_yes_default and 1 or 2, 1
    )

    PrimeUI.keyAction(keys.tab, "exit")

    main_win.setVisible(true)
    local object, event, result = PrimeUI.run()

    if object == "selectionBox" then
      if event == "selection" then
        return result == "Yes"
      end
    elseif object == "keyAction" and event == "exit" and shift_held() then
      return false
    end
  end
end

--- Ask the user if they're sure they want to exit without saving.
---@return boolean sure Whether the user is sure they want to exit without saving.
local function confirm_exit_no_save()
  return confirmation_menu(
    "Exit Without Saving",
    "Are you sure you want to exit without saving?",
    false
  )
end

--- Implement the connection filter editing menu.
---@param connection_data Connection The connection data to edit.
local function _connections_filter_edit_impl(connection_data)
  --[[
    # Filter connectionname ##############################
    # > Add item                                         # -- this box will turn into an info box if add/view/remove is selected
    #   View items                                       #
    #   Remove item                                      #
    #   Toggle blacklist/whitelist                       #
    ######################################################
    # Filter blacklist ################################### -- or whitelist...
    # minecraft:item_1                                   # -- If possible, the filter preview should scroll up and down if overfull
    # minecraft:item_2                                   # -- I believe we can use PrimeUI.addTask to do this, just have something
    # ...                                                # -- resolve PrimeUI after half a second or so?
    ######################################################
  ]]

  log.debug("Editing filter for connection", connection_data.name)

  local items = connection_data.filter_list
  local item_count = #items

  table.sort(items)

  ---@type "add"|"view"|"remove"|nil The selected action.
  local selected

  ---@type integer, integer The selected item in the preview box. Will be set to -1 unless it is active.
  local item_selected, item_scroll = -1, 1

  local items_y, items_height = 9, 10

  ---@type integer, integer For the main selection box.
  local main_selected, main_scroll = 1, 1

  ---@type integer When at either "edge" of the list, pause for this many iterations before reversing direction.
  local scroll_edge_pause = 5

  ---@type 1|0|-1 The direction to scroll in.
  local scroll_direction = 0
  ---@type 1|-1 The direction to swap to scrolling after the edge pause.
  local next_scroll_direction = 1

  local add_item, view_items, remove_item, toggle_mode = "Add item",
    "View items",
    "Remove item",
    "Toggle blacklist/whitelist"

  local no_items_toggle = true

  local timer_timeout = 0.5
  local timer

  --- Start a new timer.
  local function new_timer()
    timer = os.startTimer(timer_timeout)
  end

  --- Insert an item into the filter list.
  ---@param item string The item name to insert.
  local function insert_item(item)
    if not item or item == "" then
      log.debug("Add empty item, ignored.")
      return
    end

    table.insert(items, item)
    item_count = item_count + 1

    log.debug("Added item", item, "to filter list for connection", connection_data.name)

    table.sort(items)
  end

  --- Ask the user if they really want to remove the given item, and then remove it if they do.
  ---@param selection integer The index of the item to remove.
  local function really_remove(selection)
    -- Code cleanup: Declare the title and body outside of the if statement to reduce its size.
    local title = "Remove item"
    local body = "Are you sure you want to remove item " .. tostring(items[selection]) .. " from the filter list?"

    if items[selection] and confirmation_menu(title, body) then
      log.debug("Remove item", items[selection], "from filter list for connection", connection_data.name)

      table.remove(items, selection)
      item_count = item_count - 1

      -- Offset the selected item, since we just removed one.
      item_selected = item_selected - 1
      if item_selected < 1 then
        item_selected = 1
      end
      if item_selected < item_scroll then
        item_scroll = item_selected
      end
    end
  end

  new_timer()
  while true do
    clear()

    ---@type string[] The buffer for the input box.
    local buffer = {}

    -- If we've selected something, we can draw the info box for it.
    if selected == "add" then
      info_box(
        main_win,
        "Add item",
        "Enter the name of the item to add to the filter list, then press enter to confirm.",
        2
      )
      buffer = outlined_input_box(
        main_win, 3, 7, width - 4,
        "add-item",
        colors.white, colors.black
      )
      PrimeUI.textBox(
        main_win, 3, 6, 11, 1,
        " Item Name ",
        colors.purple
      )

      items_y = 10
      items_height = 9
    elseif selected == "view" then
      info_box(
        main_win,
        "View items",
        "Press shift+tab to go back.",
        1
      )
      items_y = 6
      items_height = 13
    elseif selected == "remove" then
      info_box(
        main_win,
        "Remove item",
        "Select the item to remove from the filter list.",
        1
      )
      items_y = 6
      items_height = 13
    else
      items_y = 13
      items_height = 6

      info_box(
        main_win,
        "Filter - " .. connection_data.name,
        "Select an action to perform on the filter list.\nPress shift+tab to save and exit.",
        2
      )

      -- No info box, just put the selection box in.
      outlined_selection_box(
        main_win, 3, 7, width - 4, 4,
          {
          add_item,
          view_items,
          remove_item,
          toggle_mode
        },
        "select", "select-change",
        colors.white, colors.black,
        main_selected, main_scroll
      )
    end

    local enable_selector = selected == "view" or selected == "remove"
    -- Draw the preview selection box
    outlined_selection_box(
      main_win,
      3, items_y,
      width - 4, items_height,
      #items == 0 and { no_items_toggle and "No items" or "" } or items,
      "select-item", "select-item-change",
      enable_selector and colors.white or colors.gray, colors.black,
      item_selected, item_scroll,
      not enable_selector
    )
    PrimeUI.textBox(
      main_win,
      3, items_y - 1,
      2 + #connection_data.filter_mode, 1,
      ' ' .. connection_data.filter_mode .. ' ',
      enable_selector and colors.purple or colors.gray
    )

    if selected ~= "add" then -- Add stops working due to read implementation
      PrimeUI.addTask(function()
        repeat
          local _, timer_id = os.pullEvent("timer")
        until timer_id == timer

        no_items_toggle = not no_items_toggle
        PrimeUI.resolve("scroller")
      end)
    end

    PrimeUI.keyAction(keys.tab, "exit")

    main_win.setVisible(true)
    local object, event, result, selection, scroll_result = PrimeUI.run()

    local function reset_scroller()
      scroll_direction = 0
      next_scroll_direction = 1
      scroll_edge_pause = 5
      item_scroll = 1
      item_selected = -1
    end

    if object == "selectionBox" then
      if event == "select-change" then
        main_selected = selection
        main_scroll = scroll_result
      elseif event == "select-item-change" then
        item_selected = selection
        item_scroll = scroll_result
      elseif event == "select" then
        if result == add_item then
          selected = "add"
          log.debug("Selected add item")
        elseif result == view_items then
          selected = "view"
          item_selected = 1
          item_scroll = 1
          log.debug("Selected view items")
        elseif result == remove_item then
          selected = "remove"
          item_selected = 1
          item_scroll = 1
          log.debug("Selected remove item")
        elseif result == toggle_mode then
          connection_data.filter_mode = connection_data.filter_mode == "whitelist" and "blacklist" or "whitelist"
          log.debug("Toggled filter mode to", connection_data.filter_mode)
        end
      elseif event == "select-item" then
        if selected == "remove" then
          really_remove(selection)

          -- Exit the selection mode
          selected = nil
          reset_scroller()

          -- Restart the timer, since we did something that may take longer than 0.5 secs
          new_timer()
        end
      end
    elseif object == "scroller" then
      -- scroll the preview box
      new_timer()

      if not enable_selector and item_count > items_height then

        item_scroll = item_scroll + scroll_direction

        if item_scroll < 1 then
          item_scroll = 1
          scroll_direction = 0
          next_scroll_direction = 1
          scroll_edge_pause = 5
        elseif item_scroll > item_count - items_height + 1 then
          item_scroll = item_count - items_height + 1
          scroll_direction = 0
          next_scroll_direction = -1
          scroll_edge_pause = 5
        end

        if scroll_edge_pause > 0 then
          scroll_edge_pause = scroll_edge_pause - 1
        else
          scroll_direction = next_scroll_direction
        end
      end
    elseif object == "keyAction" and event == "exit" then
      if shift_held() then
        if selected then
          -- Something was selected, so go back to the "main" section, reverting
          -- data to defaults.
          selected = nil
          reset_scroller()
        else
          save()
          return
        end
      else
        if selected then
          if selected == "add" then
            insert_item(table.concat(buffer))
          elseif selected == "remove" then
            really_remove(item_selected)

            -- Exit the selection mode
            selected = nil
            reset_scroller()
          end -- "view" doesn't need anything done here.

          -- Restart the timer, since we did something that may take longer than 0.5 secs
          new_timer()
        else
          ---@fixme
          -- I don't like this. If we change the order of these selections in
          -- the future, we have to change this code too.
          -- Can we un-hardcode the 1/2/3/4 here?

          -- Select the item
          if main_selected == 1 then
            selected = "add"
            log.debug("Selected add item")
          elseif main_selected == 2 then
            selected = "view"
            item_selected = 1
            item_scroll = 1
            log.debug("Selected view items")
          elseif main_selected == 3 then
            selected = "remove"
            item_selected = 1
            item_scroll = 1
            log.debug("Selected remove item")
          elseif main_selected == 4 then
            connection_data.filter_mode = connection_data.filter_mode == "whitelist" and "blacklist" or "whitelist"
            log.debug("Toggled filter mode to", connection_data.filter_mode)
          end
        end
      end
    elseif object == "inputBox" then
      if event == "add-item" then
        insert_item(result)

        selected = nil
        reset_scroller()

        -- Restart the timer, since we did something that may take longer than 0.5 secs
        new_timer()
      end
    end
  end
end

--- Implement the connection editing menu.
---@param connection_data Connection? The connection data to edit.
local function _connections_edit_impl(connection_data)
  --[[
    # Add Connection ##################################### -- Sections will expand/contract as needed.
    # Enter the name of this connection                  # -- Info box will change depending on expanded section.
    # Press enter when done.                             #
    ######################################################
    # Name ###############################################
    # blablabla                                          #
    ######################################################
    # Origin #############################################
    # peripheral_1                                       #
    ######################################################
    # Destinations #######################################
    # peripheral_2                                       #
    # peripheral_3                                       #
    # ...                                                #
    ######################################################
    # Filter Mode ########################################
    # Whitelist                                          #
    # Blacklist                                          #
    ######################################################
    # Filters ############################################
    # item_1                                             #
    # item_2                                             #
    # ...                                                #
    ######################################################
    # Mode ###############################################
    # Fill 1, then 2, then 3, then 4                     #
    # Split evenly                                       #
    ######################################################
  ]]
  local _connection_data = {
    name = "",
    from = "",
    to = {},
    filter_list = {},
    filter_mode = "blacklist",
    mode = "1234",
    moving = true, -- New connections are enabled by default.
    id = os.epoch("utc")
  }
  local editing_con = false
  if connection_data then
    _connection_data.name = connection_data.name or _connection_data.name
    _connection_data.from = connection_data.from or _connection_data.from
    _connection_data.to = connection_data.to or _connection_data.to
    _connection_data.filter_list = connection_data.filter_list or _connection_data.filter_list
    _connection_data.filter_mode = connection_data.filter_mode or _connection_data.filter_mode
    _connection_data.mode = connection_data.mode or _connection_data.mode
    _connection_data.moving = connection_data.moving or _connection_data.moving
    _connection_data.id = connection_data.id or _connection_data.id

    log.debug("Editing connection", _connection_data.name)
    editing_con = true
  else
    log.debug("Creating new connection")
  end

  --- If the connection is from a non-inventory type peripheral, it is
  --- connection limited, and can only move items to one destination. This means
  --- the filter and mode options should be disabled.
  local connection_limited = false

  local cached_peripheral_list = get_peripherals()
  local expanded_section = 1

  ---@type table<integer, {name: string, display: string}> The list of peripherals with their nicknames.
  local periphs_with_nicknames = {}
  ---@type table<integer, {name: string, display: string}> The list of peripherals with their nicknames.
  local destination_periphs_with_nicknames = {}

  local sorted_periphs = {}
  local sorted_destinations = {}


  local section_infos = {
    {
      name = (
        (_connection_data.name == "") and "Name" or
        "Name - " .. _connection_data.name
      ),
      info =
      "Enter the name of this connection\nPress enter to save section data, tab to go to the next step, and shift+tab to go back.",
      size = 1,
      object = "input_box",
      args = {
        default = _connection_data.name,
        action = "set-name",
      },
      increment_on_enter = true,
      disable_when_limited = false,
      save_buffer = "name",
    },
    {
      name = (
        (_connection_data.from == "") and "Origin" or
        "Origin - " .. (nicknames[_connection_data.from] or _connection_data.from)
      ),
      info = "Select the peripheral this connection is from.",
      size = 7,
      object = "selection_box",
      args = {
        action = "select-origin",
        items = sorted_periphs,
      },
      increment_on_enter = true,
      disable_when_limited = false,
      save_buffer = false,
    },
    {
      name = (
        (#_connection_data.to == 0) and "Destinations" or
        "Destinations - " .. (#_connection_data.to) .. " selected"
      ),
      info = "Select the peripherals this connection is to.",
      connection_limited_info = "This connection is limited, and can only set a single destination.",
      size = 7,
      object = "selection_box",
      args = {
        action = "select-destination",
        items = sorted_destinations,
      },
      increment_on_enter = false,
      disable_when_limited = false,
      save_buffer = false,
    },
    {
      name = (
        (_connection_data.filter_mode == "") and "Filter Mode" or
        "Filter Mode - " .. _connection_data.filter_mode
      ),
      info = "Select the filter mode of the connection. The list starts empty, and you can edit it in another menu.",
      connection_limited_info = "This connection is limited, filters cannot apply to it.",
      size = 2,
      object = "selection_box",
      args = {
        action = "select-filter_mode",
        items = { "Blacklist", "Whitelist" },
      },
      increment_on_enter = true,
      disable_when_limited = true,
      save_buffer = false,
    },
    {
      name = (
        (_connection_data.mode == "") and "Mode" or
        "Mode - " .. _connection_data.mode
      ),
      info = "Select the mode of the connection.",
      connection_limited_info = "This connection is limited, and can only be to one destination.",
      size = 2,
      object = "selection_box",
      args = {
        action = "select-mode",
        items = { "Fill 1, then 2, then 3, then 4", "Split evenly" },
      },
      increment_on_enter = true,
      disable_when_limited = true,
      save_buffer = false,
    }
  }

  local function save_connection()
    local ok, err = verify_connection(_connection_data)
    if ok then
      -- Search the connections list for a connection with this ID.
      for i, v in ipairs(connections) do
        if v.id == _connection_data.id then
          connections[i] = _connection_data
          save()
          return true
        end
      end

      -- If we made it here, we didn't find the connection in the list.
      -- Thus, this must be a new connection.
      -- We can just insert it into the list.
      table.insert(connections, _connection_data)

      return true
    else
      unacceptable("input", "Connection data is malformed or incorrect: " .. tostring(err))
      return false
    end
  end

  while true do
    if expanded_section > #section_infos then
      if save_connection() then
        return
      end
      expanded_section = #section_infos
    end

    local section_info = section_infos[expanded_section]

    -- Update peripheral list
    -- Clear the list
    while periphs_with_nicknames[1] do
      table.remove(periphs_with_nicknames)
    end
    while destination_periphs_with_nicknames[1] do
      table.remove(destination_periphs_with_nicknames)
    end

    -- Add the peripherals to the list
    -- Step 1: Add the peripherals to the list
    for i, v in ipairs(cached_peripheral_list) do
      -- we can just outright add the nicknames here for this table.
      periphs_with_nicknames[i] = {
        name = v,
        display = nicknames[v] or v
      }
      local found = false

      for j = 1, #_connection_data.to do
        if _connection_data.to[j] == v then
          destination_periphs_with_nicknames[i] = {
            name = v,
            display = j .. ". " .. periphs_with_nicknames[i].display
          }
          found = true
          break
        end
      end

      if not found then
        destination_periphs_with_nicknames[i] = {
          name = periphs_with_nicknames[i].name,
          display = "   " .. periphs_with_nicknames[i].display
        }
      end
    end

    -- Step 2: Sort the peripheral lists.
    table.sort(periphs_with_nicknames, function(a, b)
      return a.display < b.display
    end)
    table.sort(destination_periphs_with_nicknames, function(a, b)
      return a.display < b.display
    end)

    -- Step 3: Create the list of sorted peripherals.
    -- 3.a) Clear the list
    while sorted_periphs[1] do
      table.remove(sorted_periphs)
    end
    while sorted_destinations[1] do
      table.remove(sorted_destinations)
    end

    -- 3.b) Add the peripherals to the list
    for i, v in ipairs(periphs_with_nicknames) do
      sorted_periphs[i] = v.display
    end
    for i, v in ipairs(destination_periphs_with_nicknames) do
      sorted_destinations[i] = v.display
    end

    -- ALL OF THIS WAS NEEDED JUST TO SORT THE PERIPHERALS WITH NICKNAMES
    -- SO THAT I COULD STILL REFERENCE THEM BY THEIR ORIGINAL NAME LATER
    -- AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHHHHHH

    -- Begin drawing
    clear()

    -- Draw info box.
    info_box(
      main_win,
      editing_con and "Edit Connection" or "Add Connection",
      connection_limited and section_info.connection_limited_info or section_info.info,
      3
    )

    local y = 8

    local input_box_buffer

    -- Draw the sections
    for i = 1, #section_infos do
      local section = section_infos[i]
      local expanded = i == expanded_section
      local color = expanded and colors.purple or colors.gray

      local text = ' ' .. section.name .. ' '
      if section.disable_when_limited and connection_limited then
        text = ' ' .. section.name:gsub(" ?%-.+", "") .. ' ' .. "- Connection Limited "
      end

      if expanded then
        -- Draw the stuffs
        local object = section.object
        local args = section.args

        if object == "input_box" then
          -- Input box
          input_box_buffer = outlined_input_box(
            main_win, 3, y, width - 4,
            args.action,
            colors.white, colors.black,
            nil, nil, nil,
            args.default
          )
        elseif object == "selection_box" then
          -- Selection box

          if #args.items == 0 then
            args.items = { "No peripherals" }
          end

          outlined_selection_box(
            main_win,
            3,
            y,
            width - 4,
            section.size,
            args.items,
            args.action,
            nil,
            section.disable_when_limited and connection_limited and colors.red or colors.white,
            colors.black,
            args.selection or 1,
            args.scroll or 1,
            section.disable_when_limited and connection_limited
          )
        else
          error("Invalid object type '" .. tostring(object) .. "' at index " .. i)
        end

        -- Draw the text box
        PrimeUI.textBox(
          main_win,
          3,
          y - 1,
          #text,
          1,
          text,
          section.disable_when_limited and connection_limited and colors.orange or color,
          colors.black
        )
      else
        -- Draw the border box and text box
        PrimeUI.borderBox(
          main_win, 3, y, width - 4, -1,
          color, colors.black
        )
        PrimeUI.textBox(
          main_win, 3, y - 1, #text, 1,
          text,
          color, colors.black
        )
      end

      y = y + (expanded and section.size + 2 or 1)
    end

    -- Tab: advance the expanded section, saving any relevant data.
    -- shift+tab: go back a section, saving any relevant data.
    PrimeUI.keyAction(keys.tab, "section_switch")

    main_win.setVisible(true)
    local object, event, result, selection, scroll_result = PrimeUI.run()

    if object == "keyAction" then
      if event == "section_switch" then
        if keys_held[keys.leftShift] then
          log.debug("Go back a section.")
          expanded_section = expanded_section - 1
          if expanded_section < 1 then
            if confirm_exit_no_save() then
              log.debug("User confirmed exit without save.")
              return
            end
            expanded_section = 1
          end
        else
          log.debug("Advance a section.")

          if section_info.save_buffer then
            _connection_data[section_info.save_buffer] = table.concat(input_box_buffer)

            if type(section_info[section_info.save_buffer]) ~= "string" then
              error(
                "Tried to set a non-string value to a string buffer: "
                .. tostring(section_info.save_buffer)
                .. " - "
                .. type(section_info[section_info.save_buffer])
              )
            end

            ---@diagnostic disable-next-line: param-type-mismatch we check this case directly above.
            section_info[section_info.save_buffer] = section_info[section_info.save_buffer]:gsub(" ?%-.+", "")
              .. " - "
              .. _connection_data[section_info.save_buffer]
          end

          expanded_section = expanded_section + 1
          if expanded_section > #section_infos then
            if save_connection() then
              log.debug("Connection updated and saved, exiting this menu.")
              return
            end

            expanded_section = #section_infos
          end
        end
      end
    elseif object == "selectionBox" then
      if event == "select-origin" then
        local becomes_limited = not peripheral.hasType(periphs_with_nicknames[selection].name, "inventory")
          and not peripheral.hasType(periphs_with_nicknames[selection].name, "fluid_storage")

        if becomes_limited and #_connection_data.to > 1 then
          unacceptable(
            "input",
            "The last request would make this connection limited, and would only be able to have one destination.\nRemove all but one destination and try again."
          )
        else
          connection_limited = becomes_limited
          _connection_data.from = periphs_with_nicknames[selection].name
          section_info.name = "Origin - " .. result
          log.debug("Selected origin", sorted_periphs[selection], "-", _connection_data.from)
        end
      elseif event == "select-destination" then
        -- Insert the peripheral into the list of destinations.
        -- Unless it is already in the list, in which case remove it.
        local found = false

        for i = 1, #_connection_data.to do
          if _connection_data.to[i] == destination_periphs_with_nicknames[selection].name then
            table.remove(_connection_data.to, i)
            found = true
            log.debug("Removed destination", sorted_destinations[selection], "-", destination_periphs_with_nicknames[selection].name)
            break
          end
        end

        section_info.args.selection = selection
        section_info.args.scroll = scroll_result

        if connection_limited and #_connection_data.to >= 1 then
          unacceptable(
            "input",
            "This connection is connection limited, and can only have one destination.\nIf you need more destinations, create a buffer chest connection."
          )
        else
          if not found then
            table.insert(_connection_data.to, destination_periphs_with_nicknames[selection].name)
            log.debug("Added destination", sorted_destinations[selection], "-", destination_periphs_with_nicknames[selection].name)
          end

          if #_connection_data.to == 0 then
            section_info.name = "Destinations"
          else
            section_info.name = "Destinations - " .. (#_connection_data.to) .. " selected"
          end
        end
      elseif event == "select-filter_mode" then
        _connection_data.filter_mode = selection == 1 and "blacklist" or "whitelist"

        section_info.name = "Filter Mode - " .. _connection_data.filter_mode

        log.debug("Selected filter mode", _connection_data.filter_mode)
      elseif event == "select-mode" then
        _connection_data.mode = selection == 1 and "1234" or "split"

        section_info.name = "Mode - " .. _connection_data.mode

        log.debug("Selected mode", _connection_data.mode)
      end

      if section_info.increment_on_enter then
        expanded_section = expanded_section + 1
      end
    elseif object == "inputBox" then
      if event == "set-name" then
        _connection_data.name = result
        section_info.args.default = result
        section_info.name = "Name - " .. result

        log.debug("Set name to", result)
      end

      if section_info.increment_on_enter then
        expanded_section = expanded_section + 1
      end
    end
  end
end

--- Menu to add a new connection.
local function connections_add_menu()
  log.debug("Add connection")
  _connections_edit_impl()
end

--- A quick menu to select a connection, with a custom header.
---@param title string The title of the menu.
---@param body string The body of the menu.
---@param filter_func nil|fun(connection: Connection): boolean A function to filter connections.
---@param override_no_connections string? The message to display if there are no connections.
---@return Connection? connection The connection selected, or nil if none was selected.
local function select_connection(title, body, filter_func, override_no_connections)
  filter_func = filter_func or function() return true end

  local connection_list = {}
  for i, v in ipairs(connections) do
    if filter_func(v) then
      connection_list[#connection_list+1] = v.name
    end
  end

  if #connection_list == 0 then
    connection_list = { override_no_connections or "No connections" }
  end

  table.sort(connection_list)

  log.debug("Select a connection")

  while true do
    clear()

    -- Draw info box.
    info_box(main_win, title, body, 2)

    outlined_selection_box(
      main_win, 3, 7, width - 4, 12,
      connection_list, "edit", nil,
      colors.white, colors.black,
      1, 1
    )
    PrimeUI.textBox(
      main_win, 3, 6, 13, 1,
      " Connections ",
      colors.purple
    )

    PrimeUI.keyAction(keys.tab, "exit")

    main_win.setVisible(true)
    local object, event, selected, selection = PrimeUI.run()

    if object == "selectionBox" then
      if event == "edit" then
        log.debug("Selected connection", selection, "(", selected, ")")
        for _, v in ipairs(connections) do
          if v.name == selected then
            return v
          end
        end

        error("Selected connection not found in connections list.")
      end
    elseif object == "keyAction" and event == "exit" and shift_held() then
      log.debug("Exit connection selection.")
      return
    end
  end
end

--- Edit a connection
local function connections_edit_menu()
  log.debug("Edit connection")
  local connection = select_connection(
    "Edit Connection",
    "Press enter to edit a connection.\nPress shift+tab to exit."
  )

  if connection then
    _connections_edit_impl(connection)
  end
end

--- Edit whitelist/blacklist of a connection
local function connections_filter_menu()
  log.debug("Edit connection filter")
  local connection = select_connection(
    "Edit Connection Filter",
    "Press enter to edit a connection's filter.\nPress shift+tab to exit.",
    function(connection)
      -- Filter out any connections that would be 'connection limited', or are not present.
      local has_inv, has_fluid = peripheral.hasType(connection.from, "inventory"),
        peripheral.hasType(connection.from, "fluid_storage")

      -- If the peripheral is not present, both `has_inv` and `has_fluid` will be false.
      -- Thus, we do not need another check for that.
      -- added 'or false' to get warnings to go away.
      return has_inv or has_fluid or false
    end,
    "No editable connections"
  )

  if connection then
    _connections_filter_edit_impl(connection)
  end
end

local function connections_remove_menu()
  log.debug("Remove connection")
  local connection = select_connection(
    "Remove Connection",
    "Press enter to remove a connection.\nPress shift+tab to exit."
  )

  -- Code cleanup: Declare these as variables to reduce line length of the if statement.
  local title = "Remove Connection"
  local body = "Are you sure you want to remove connection " .. tostring(connection and connection.name) .. "?"

  if connection and confirmation_menu(title, body) then
    for i, v in ipairs(connections) do
      if v == connection then
        table.remove(connections, i)
        return
      end
    end
  end
end

local function toggle_connections_menu()
  log.debug("Toggle connections")

  local connection_names = {}
  local connection_list = {}

  for i, v in ipairs(connections) do
    connection_list[i] = v.name
  end

  table.sort(connection_list)

  local function get_connection(name)
    for _, v in ipairs(connections) do
      if v.name == name then
        return v
      end
    end
  end

  local function update_connection_list()
    for i, name in ipairs(connection_list) do
      local connection = get_connection(name)
      connection_names[i] = (connection.moving and " on - " or "off - ") .. connection.name
    end
  end

  local selection, scroll = 1, 1

  while true do
    update_connection_list()

    clear()

    -- Draw info box.
    info_box(
      main_win,
      "Toggle Connections",
      "Press enter to toggle the moving state of all connections.\nPress shift+tab to exit.",
      3
    )

    local toggle_on = "Turn on all connections"
    local toggle_off = "Turn off all connections"

    -- Draw the selection box.
    outlined_selection_box(
      main_win, 3, 8, width - 4, 11,
      {
        toggle_on,
        toggle_off,
        table.unpack(connection_names)
      },
      "selection", nil,
      colors.white, colors.black,
      selection, scroll
    )

    PrimeUI.keyAction(keys.tab, "exit")

    main_win.setVisible(true)
    local object, event, selected, _selection, _scroll = PrimeUI.run()

    if object == "selectionBox" then
      if selected == toggle_on or selected == toggle_off then
        for _, v in ipairs(connections) do
          v.moving = selected == toggle_on
        end
        log.debug("Turned all connections", selected == toggle_on and "on." or "off.")
      else
        local actual_selection = _selection - 2
        local connection = get_connection(connection_list[actual_selection])

        if connection then
          connection.moving = not connection.moving
          log.debug("Toggled connection", connection.name, "to", connection.moving and "on." or "off.")
        end
      end

      selection = _selection
      scroll = _scroll
      save()
    elseif object == "keyAction" and event == "exit" and shift_held() then
      save()
      log.debug("Exiting toggle connections menu.")
      return
    end
  end
end

--- Connections menu
local function connections_main_menu()
  --[[
    ######################################################
    # Connections                                        #
    #                                                    #
    # Total Connections: x                               #
    ######################################################
    ######################################################
    # > Add Connection                                   #
    #   Edit Connection                                  #
    #   Remove Connection                                #
    #   Go Back                                          # -- shift+tab will also work
    ######################################################
  ]]
  log.debug("Connections menu")

  while true do
    clear()

    -- Draw info box.
    info_box(
      main_win,
      "Connections",
      ("Total Connections: %d"):format(#connections),
      1
    )

    local add_connection = "Add Connection"
    local edit_connection = "Edit Connection"
    local filter_connection = "Edit Connection Filter"
    local toggle_connections = "Toggle Connections"
    local remove_connection = "Remove Connection"
    local go_back = "Go Back"

    -- Draw the selection box.
    outlined_selection_box(
      main_win, 3, 6, width - 4, 6,
      {
        add_connection,
        edit_connection,
        filter_connection,
        toggle_connections,
        remove_connection,
        go_back
      }, "selection", nil,
      colors.white, colors.black,
      1, 1
    )

    PrimeUI.keyAction(keys.tab, "exit")

    main_win.setVisible(true)
    local object, event, selected = PrimeUI.run()

    if object == "selectionBox" then
      if selected == add_connection then
        connections_add_menu()
      elseif selected == edit_connection then
        connections_edit_menu()
      elseif selected == filter_connection then
        connections_filter_menu()
      elseif selected == toggle_connections then
        toggle_connections_menu()
      elseif selected == remove_connection then
        connections_remove_menu()
      elseif selected == go_back then
        save()
        log.debug("Exiting connections menu.")
        return
      end

      save()
    elseif object == "keyAction" and event == "exit" and shift_held() then
      save()
      log.debug("Exiting connections menu.")
      return
    end
  end
end

local function tickrate_menu()
  --[[
    ######################################################
    # Update Rate                                        #
    # Press enter to accept the update rate and exit.    #
    ######################################################
    ######################################################
    # Updates every [  10] ticks                         #
    ######################################################
  ]]
  log.debug("Update tickrate menu")

  clear()

  -- Draw info box.
  info_box(
    main_win,
    "Update Rate",
    "Press enter to accept the new update rate and exit.\nPress shift+tab to exit without saving.",
    3
  )

  -- Draw the input box.
  -- First the text around the input box.
  PrimeUI.textBox(
    main_win, 3, 8, width - 4, 1,
    "Updates every [        ] ticks.",
    colors.white
  )

  -- And the outline
  PrimeUI.borderBox(
    main_win, 3, 8, width - 4, 1,
    colors.white, colors.black
  )

  -- Then the input box itself.
  local tickrate = tostring(update_tickrate)
  PrimeUI.inputBox(
    main_win, 18, 8, 8,
    "tickrate",
    colors.white, colors.black,
    nil, nil, nil,
    tickrate
  )

  PrimeUI.keyAction(keys.tab, "exit")

  main_win.setVisible(true)
  local object, event, output = PrimeUI.run()

  if object == "inputBox" then
    if event == "tickrate" then
      local value = tonumber(output)
      if not value then
        unacceptable("input", "The input must be a number.")
      elseif value < 1 then
        unacceptable("input", "The input must be 1 or greater.")
      else
        update_tickrate = math.ceil(value) -- disallow decimals
        log.debug("Set update tickrate to", update_tickrate)
      end
    end
  elseif object == "keyAction" and event == "exit" and shift_held() then
    log.debug("Exiting tickrate menu (discard).")
    return
  end
end

--- The nickname menu
local function nickname_menu()
  --[[
    ######################################################
    # Nicknames                                          #
    # Press enter to edit a nickname.                    #
    # Press shift+tab to exit.                           #
    ######################################################
    ######################################################
    # > peripheral_1                                     #
    #   peripheral_2                                     #
    #   peripheral_3                                     #
    #   ...                                              #
    #   ...                                              #
    ######################################################
    # nickname nickname nickname nickname nickname       #
    ######################################################
  ]]
  log.debug("Nickname menu")

  local run = true
  local index = 1
  local scroll = 1
  local editing = false

  local cached_peripheral_list = get_peripherals()

  while run do
    clear()

    -- Draw info box.
    local info = "Press enter to edit a nickname.\nPress shift+tab to exit."
    info_box(main_win, "Nicknames", info, 2)

    cached_peripheral_list = editing and cached_peripheral_list or get_peripherals()
    if #cached_peripheral_list == 0 then
      cached_peripheral_list = { "No peripherals" }
    end
    table.sort(cached_peripheral_list)

    outlined_selection_box(
      main_win,
      3, 7,
      width - 4, 9,
      cached_peripheral_list,
      "edit", "change",
      editing and colors.gray or colors.white, colors.black,
      index, scroll,
      editing
    )
    PrimeUI.textBox(
      main_win, 3, 6, 13, 1,
      " Peripherals ",
      editing and colors.gray or colors.purple
    )

    outlined_input_box(
      main_win,
      3, height - 1,
      width - 4,
      "text_box",
      editing and colors.white or colors.gray, colors.black,
      nil, nil, nil,
      nicknames[cached_peripheral_list[index]] or cached_peripheral_list[index],
      not editing
    )
    local x, y = term.getCursorPos()
    PrimeUI.textBox(
      main_win, 3, height - 2, 10, 1,
      " Nickname ",
      editing and colors.purple or colors.gray
    )

    PrimeUI.keyAction(keys.tab, "exit")

    -- Reset the cursor position to be in the input box, and ensure it is visible if it needs to be.
    term.setCursorPos(x, y)
    term.setTextColor(colors.white)
    term.setCursorBlink(editing)

    -- Run the UI
    main_win.setVisible(true)
    local object, event, selected, _selection, _scroll = PrimeUI.run()

    if object == "keyAction" then
      if event == "exit" and shift_held() then
        if editing then
          log.debug("Exiting nickname edit (discard).")
          editing = false
        else
          log.debug("Exiting nickname menu.")
          run = false
        end
      end
    elseif object == "selectionBox" then
      if event == "edit" then
        -- Edit the nickname of the selected peripheral.
        editing = true
        log.debug("Editing nickname for", selected)
      elseif event == "change" then
        index = _selection
        scroll = _scroll
      end
    elseif object == "inputBox" then
      if event == "text_box" then
        if selected == cached_peripheral_list[index] or selected == "" then
          -- Remove the nickname
          nicknames[cached_peripheral_list[index]] = nil

          log.debug("Removed nickname for", cached_peripheral_list[index])
        else
          -- Set the nickname
          nicknames[cached_peripheral_list[index]] = selected

          log.debug("Set nickname for", cached_peripheral_list[index], "to", selected)
        end
        editing = false
      end
    end
  end
end

--- Log menu
local function log_menu()
  log.info("Hello there!")

  local function draw_main()
    -- Draw the info box.
    info_box(
      main_win,
      "Log",
      "Press enter to dump log to a file.\nPress c to clear warns/errors.\nPress shift+tab to exit.",
      3
    )

    -- Draw a box around where the log will be displayed.
    PrimeUI.borderBox(
      main_win,
      3,
      8,
      width - 4,
      height - 8,
      logging.has_errored() and colors.red or logging.has_warned() and colors.orange or colors.white,
      colors.black
    )
  end

  local function draw_log()
    -- Draw the log window
    logging_display_win.setVisible(true)
    logging_display_win.redraw() -- ensure it actually redraws.
  end

  while true do
    clear()
    draw_main()

    PrimeUI.keyAction(keys.tab, "exit")
    PrimeUI.keyAction(keys.enter, "dump")
    PrimeUI.keyAction(keys.c, "clear")

    main_win.setVisible(true)
    draw_log()
    local object, event = PrimeUI.run()

    if object == "keyAction" then
      if event == "exit" and shift_held() then
        log.info("Exiting log menu.")
        break
      elseif event == "dump" then
        log.info("Getting output file...")

        clear()

        draw_main()

        outlined_input_box(
          main_win, 4, 4, width - 6,
          "output",
          colors.white, colors.black,
          nil, nil, nil,
          "latest.log"
        )
        PrimeUI.textBox(
          main_win, 4, 3, 10, 1,
          " Filename ",
          colors.purple
        )

        main_win.setVisible(true)
        draw_log()
        local object, event, output = PrimeUI.run()

        if object == "inputBox" and event == "output" then
          log.info("Dumping log to", output)

          logging.dump_log(output)
        end
      elseif event == "clear" then
        logging.clear_error()
        logging.clear_warn()
        log.info("Cleared errors and warnings.")
      end
    end
  end

  -- Hide the log window
  logging_display_win.setVisible(false)
end

--- Main menu
local function main_menu()
  local update_connections = "Update Connections"
  local update_rate = "Change Update Rate"
  local nickname = "Change Peripheral Nicknames"
  local toggle = "Toggle Running"
  local view_log = "View Log"
  local exit = "Exit"

  log.info("Start main menu")

  local menu_timer_timeout = 1
  local menu_timer = os.startTimer(menu_timer_timeout)

  local selection, scroll = 1, 1

  local blinky = false

  while true do
    local description = ("Select an option from the list below.\n\nTotal items moved: %d\nTotal fluid moved: %d mB\nTotal connections: %d\n\nUpdate rate: Every %d tick%s\nRunning: %s")
        :format(
          items_moved,
          fluid_moved,
          #connections,
          update_tickrate,
          update_tickrate == 1 and "" or "s",
          moving_items and "Yes" or "No"
        )
    clear()

    -- Create the information box.
    info_box(main_win, "Pipe : Dream", description, 8)

    -- Create the selection box.
    outlined_selection_box(
      main_win, 4, 13, width - 6, height - 13,
      {
        update_connections,
        update_rate,
        nickname,
        toggle,
        view_log,
        exit
      }, "selection", "selection-change",
      colors.white, colors.black,
      selection, scroll
    )

    PrimeUI.addTask(function()
      repeat
        local _, timer_id = os.pullEvent("timer")
      until timer_id == menu_timer

      PrimeUI.resolve("timeout")
    end)

    if logging.has_errored() or logging.has_warned() then
      if blinky then
        local color = logging.has_errored() and colors.red or colors.orange
        main_win.setBackgroundColor(color)

        main_win.setCursorPos(4, height - 2)
        main_win.write(' ')

        main_win.setCursorPos(width - 3, height - 2)
        main_win.write(' ')
      end
    end

    main_win.setVisible(true)
    local object, event, selected, _selection, _scroll = PrimeUI.run()
    log.debug("Selected", selected)

    if object == "selectionBox" then
      if event == "selection" then
        if selected == update_connections then
          connections_main_menu()
        elseif selected == update_rate then
          tickrate_menu()
        elseif selected == nickname then
          nickname_menu()
        elseif selected == toggle then
          moving_items = not moving_items
          log.debug("Toggled running to", moving_items)
        elseif selected == view_log then
          log_menu()
        elseif selected == exit then
          log.info("Exiting program")
          save()
          return true
        end
        save()
        menu_timer = os.startTimer(menu_timer_timeout)
      elseif event == "selection-change" then
        selection = _selection
        scroll = _scroll
      end
    elseif object == "timeout" then
      save()
      menu_timer = os.startTimer(menu_timer_timeout)
      blinky = not blinky
    end
  end
end

------------------------
-- Inventory Section
------------------------

---@class inventory_request
---@field funcs function[] The inventory requests to call, wrapped with arguments (i.e: {function() return inventory.getItemDetail(i) end, ...}). The returned value will be stored in the results field.
---@field id integer The ID of the request, used to identify it in the queue.
---@field results table[] The results of the inventory requests, in the same order as funcs.

local backend_log = logging.create_context("backend")

---@type integer The ID of the last inventory request.
local last_inventory_request_id = 0

---@type inventory_request[] A queue of inventory requests to process.
local inventory_request_queue = {}

---@type integer A soft maximum number of inventory requests to process at once.
local max_inventory_requests = 175

---@type integer If inserting the current job will overflow the max_inventory_requests, this is how much we are allowed to go over before the job is rejected. Thus, a hard limit of max_inventory_requests + max_inventory_requests_overflow is enforced.
local max_inventory_requests_overflow = 25

---@type boolean If we are actually processing something at this very moment. Used so that we can determine whether or not queueing a `inventory_request:new` event is necessary.
local processing_inventory_requests = false


--- Process inventory requests. We can run up to 256 of these at once (event queue length)
--- However, we will likely use a smaller value to allow for space for other events to not
--- overflow the queue.
local function process_inventory_requests()
  local current = {}
  local result_ts = {}
  local result_events = {}
  local current_n = 0

  --- Process the current request queue, or do nothing if there are no requests.
  local function process_queue()
    if current_n == 0 then return end

    backend_log.debug("Processing", current_n, "inventory requests.")

    local funcs = {}

    for i = 1, current_n do
      local func = current[i]
      local result = result_ts[i]

      funcs[i] = function()
        result.out[result.index] = func()
      end
    end

    parallel.waitForAll(table.unpack(funcs, 1, current_n))

    for _, event in ipairs(result_events) do
      os.queueEvent("inventory_request:" .. event)
    end

    current = {}
    result_ts = {}
    result_events = {}
    current_n = 0
  end

  while true do
    processing_inventory_requests = true

    while inventory_request_queue[1] do
      local request = table.remove(inventory_request_queue, 1)
      local count = #request.funcs

      if current_n + count > max_inventory_requests + max_inventory_requests_overflow then
        process_queue()
      end

      for i = 1, count do
        current[current_n + i] = request.funcs[i]
        result_ts[current_n + i] = {out = request.results, index = i}
      end
      result_events[#result_events + 1] = request.id

      current_n = current_n + count
    end

    -- We still technically need to do some processing after this, but at this
    -- point, we need the event to resume the queueing process.
    processing_inventory_requests = false

    -- Process the final request and wait for a new one.
    parallel.waitForAll(
      process_queue,
      function() os.pullEvent("inventory_request:new") end
    )
  end
end

--- Make an inventory request, then wait until it completes.
---@param funcs function[] The inventory requests to call, wrapped with arguments (i.e: {function() return inventory.getItemDetail(i) end, ...}).
---@return table[] The results of the inventory requests, in the same order as funcs.
local function make_inventory_request(funcs)
  last_inventory_request_id = last_inventory_request_id + 1
  local id = last_inventory_request_id
  local results = {}

  backend_log.debug("New inventory request:", id)

  -- insert request data into the queue
  table.insert(inventory_request_queue, {funcs = funcs, id = id, results = results})

  -- If we are not currently processing inventory requests, queue a new event to start the process.
  if not processing_inventory_requests then
    backend_log.debug("Queueing new inventory request event")
    os.queueEvent("inventory_request:new")
  end

  backend_log.debug("Waiting for inventory request", id, "to complete.")
  -- Wait for the results to be filled in.
  os.pullEvent("inventory_request:" .. id)

  backend_log.debug("Inventory request", id, "completed.")

  return results
end

--- Determines if the item can be moved from one inventory to another, given the filter mode and filter.
---@param item string The item to check.
---@param list string[] The list of items to check against.
---@param mode "whitelist"|"blacklist" The mode to use.
local function can_move(item, list, mode)
  if mode ~= "whitelist" and mode ~= "blacklist" then
    error("Invalid mode '" .. tostring(mode) .. "'")
  end

  -- Whitelist
  if mode == "whitelist" then
    for _, v in ipairs(list) do
      if v == item then
        return true
      end
    end

    return false
  end

  -- Blacklist
  for _, v in ipairs(list) do
    if v == item then
      return false
    end
  end

  return true
end

--- Run a connection from the "origin" node.
--- We do this without context of the endpoint nodes, as we can't guarantee that they are inventories.
---@param connection Connection The connection to run.
local function _run_connection_from_origin(connection)
  local filter = connection.filter_list
  local filter_mode = connection.filter_mode
  local mode = connection.mode
  local from = connection.from
  local to = connection.to

  local inv = peripheral.wrap(from) --[[@as Inventory|FluidStorage?]]

  if not inv then
    backend_log.warn("Connection", connection.name, "failed to run: origin peripheral is missing.")
    return
  end
  --Also try .items() for compatibility with certain custom inventories (e.g, the Create basin)
  local inv_contents = (inv.list and inv.list()) or
                       (peripheral.hasType(inv, "item_storage") and inv.items and inv.items())
  local inv_tanks = inv.tanks and inv.tanks()

  -- If the inventory is empty, we can't do anything.
  if inv_contents and not next(inv_contents)
    and inv_tanks and not next(inv_tanks) then
    backend_log.debug("Connection", connection.name, "is empty, skipping.")
    return
  end

  local funcs = {}
  if mode == "1234" then
    -- Iterate through each inventory, and push whatever remains in the input inventory to the selected output.
    for _, output_inventory in ipairs(to) do
      -- Queue up the items to move (if the origin is an item inventory)
      if inv_contents then
        for slot, item in pairs(inv_contents) do
          -- if items are left in this slot, and the item matches the filter, queue the move.
          if item.count > 0 and can_move(item.name, filter, filter_mode) then
            funcs[#funcs + 1] = function()
              local moved = inv.pushItems(output_inventory, slot)

              items_moved = items_moved + moved  -- track the number of items moved.

              if moved then
                item.count = item.count - moved
              end
            end
          end
        end
      end

      -- Similarly, queue up fluids to move (if the origin is a fluid inventory)
      if inv_tanks then
        for _, fluid in pairs(inv_tanks) do
          if fluid.amount > 0 and can_move(fluid.name, filter, filter_mode) then
            funcs[#funcs + 1] = function()
              local moved = inv.pushFluid(output_inventory)

              fluid_moved = fluid_moved + moved  -- track the amount of fluid moved.

              if moved then
                fluid.amount = fluid.amount - moved
              end
            end
          end
        end
      end

      if #funcs == 0 then
        break -- we are done moving items.
      end

      -- Actually run the request.
      make_inventory_request(funcs)

      -- Clear the funcs table for the next iteration.
      funcs = {}
    end
  else -- mode == "split"
    -- First, we need to calculate how much of each item (that we can move) in the inventory
    -- we have, then split it evenly between the output inventories.
    local item_counts = {}

    if inv_contents then
      for _, item in pairs(inv_contents) do
        if can_move(item.name, filter, filter_mode) then
          if not item_counts[item.name] then
            item_counts[item.name] = 0
          end

          item_counts[item.name] = item_counts[item.name] + item.count
        end
      end
    end

    if inv_tanks then
      for _, fluid in pairs(inv_tanks) do
        if can_move(fluid.name, filter, filter_mode) then
          if not item_counts[fluid.name] then
            item_counts[fluid.name] = 0
          end

          item_counts[fluid.name] = item_counts[fluid.name] + fluid.amount
        end
      end
    end

    -- Next, we need to calculate how many items to move to each inventory.
    -- We can do this by simply dividing each item count by the number of inventories.
    local inv_count = #to

    for name, count in pairs(item_counts) do
      local split = math.floor(count / inv_count)

      item_counts[name] = split
    end

    local moved_inventories = {}
    for _, output_inventory in ipairs(to) do
      for name in pairs(item_counts) do
        if not moved_inventories[output_inventory] then
          moved_inventories[output_inventory] = {}
        end

        moved_inventories[output_inventory][name] = 0
      end
    end

    -- Finally, we can start pushing items to the inventories.
    -- We will repeat the process until we have moved all of the (current) items in the inventory.
    -- In theory this shouldn't be an infinite loop?
    while true do
      if inv_contents then
        for _, output_inventory in ipairs(to) do
          for slot, item in pairs(inv_contents) do
            if item.count > 0 and item_counts[item.name] then
              if item_counts[item.name] > moved_inventories[output_inventory][item.name] and item.count > 0 then
                local to_move = math.min(item_counts[item.name] - moved_inventories[output_inventory][item.name], item.count)
                backend_log.debug("Splitting", to_move, "of", item.name, "to", output_inventory)

                funcs[#funcs + 1] = function()
                  local moved = inv.pushItems(
                    output_inventory,
                    slot,
                    to_move
                  )

                  items_moved = items_moved + moved  -- track the number of items moved.
                end -- end func

                item.count = item.count - to_move

                -- Update the amount of items moved to this inventory.
                -- We will either be moving the remaining amount of items in the stack,
                -- or we will be moving the amount of items we calculated to move.
                -- Whatever is smaller.
                moved_inventories[output_inventory][item.name] = moved_inventories[output_inventory][item.name]
                  + to_move
                backend_log.debug(
                  "Remains:", item_counts[item.name] - moved_inventories[output_inventory][item.name],
                  "Moved:", moved_inventories[output_inventory][item.name]
                )
              end -- end if item_counts
            end -- end if item.count...
          end -- end for pairs
        end -- end for ipairs
      end -- end if

      if inv_tanks then
        for _, output_inventory in ipairs(to) do
          for _, fluid in pairs(inv_tanks) do
            if fluid.amount > 0 and item_counts[fluid.name] then
              if item_counts[fluid.name] > moved_inventories[output_inventory][fluid.name] then
                local to_move = math.min(item_counts[fluid.name] - moved_inventories[output_inventory][fluid.name], fluid.amount)
                backend_log.debug("Splitting", to_move, "mB of", fluid.name, "to", output_inventory)

                funcs[#funcs + 1] = function()
                  local moved = inv.pushFluid(
                    output_inventory,
                    to_move,
                    fluid.name
                  )

                  fluid_moved = fluid_moved + moved  -- track the amount of fluid moved.
                end -- end func

                fluid.amount = fluid.amount - to_move

                -- Update the amount of fluid moved to this inventory.
                -- Same reasoning as above.
                moved_inventories[output_inventory][fluid.name] = moved_inventories[output_inventory][fluid.name]
                  + to_move
                backend_log.debug(
                  "Remains:", item_counts[fluid.name] - moved_inventories[output_inventory][fluid.name],
                  "mB. Moved:", moved_inventories[output_inventory][fluid.name]
                )
              end -- end if item_counts...
            end -- end if fluid.amount...
          end -- end for pairs
        end -- end for ipairs
      end -- end if

      if #funcs == 0 then
        break -- we are done moving items.
      end

      -- Actually run the request.
      make_inventory_request(funcs)

      -- Clear the funcs table for the next iteration.
      funcs = {}
    end
  end
end

--- Run a connection to a single 'to' node.
---@param connection Connection The connection to run.
local function _run_connection_to_inventory(connection)
  local from = connection.from
  local to = connection.to[1]

  -- We cannot see what is in the `from` node, since we cannot `.list()` or even
  -- `.size()` it.
  -- This means we cannot apply the filter or anything. Instead, the user should
  -- create another connection from the `to` node with the filters applied.
  --
  -- As well, since we don't know the items inside or even the size, we will
  -- call `pullItems`/`pullFluid` as many times as we have slots in `to`.

  local inv = peripheral.wrap(to) --[[@as Inventory|FluidStorage?]]

  if not inv then
    backend_log.warn("Connection", connection.name, "failed to run: destination peripheral is missing.")
    return
  end

  local size, tanks = 0, 0

  if inv.list then
    size = inv.size()
  end

  if inv.tanks then
    tanks = #inv.tanks()
  end

  local funcs = {}

  for i = 1, size do
    funcs[#funcs + 1] = function()
      local ok, moved = pcall(inv.pullItems, from, i)

      if ok then
        items_moved = items_moved + moved  -- track the number of items moved.
      end
    end
  end

  for _ = 1, tanks do
    funcs[#funcs + 1] = function()
      local ok, moved = pcall(inv.pullFluid, from)

      if ok then
        fluid_moved = fluid_moved + moved  -- track the amount of fluid moved.
      end
    end
  end

  make_inventory_request(funcs)
end

--- Implementation of the connection runner.
---@param connection Connection The connection to run.
local function _run_connection_impl(connection)
  local from = connection.from
  local to = connection.to

  -- First, we need to check if our from node is an inventory.
  if peripheral.hasType(from, "inventory") then
    _run_connection_from_origin(connection)
    return
  end

  -- Next check is if the first output node is any inventory.
  if peripheral.hasType(to[1], "inventory") then
    _run_connection_to_inventory(connection)
    return
  end

  -- Alternatively, fluid:
  if peripheral.hasType(from, "fluid_storage") then
    _run_connection_from_origin(connection)
    return
  end

  if peripheral.hasType(to[1], "fluid_storage") then
    _run_connection_to_inventory(connection)
    return
  end

  -- If we made it here, neither the origin or all destinations are inventories.
  -- Thus, fail.

  if not peripheral.isPresent(to[1]) then
    backend_log.error("Connection", connection.name, "could not be run: destination peripheral is missing.")
    return
  end

  if not peripheral.isPresent(from) and not peripheral.hasType(to[1], "inventory")
    and not peripheral.hasType(to[1], "fluid_storage") then
    backend_log.error("Connection", connection.name, "could not be run: origin peripheral is missing.")
  end

  backend_log.error("Connection", connection.name, "could not be run: could not select a valid path. Consider using a buffer inventory.")
end

--- Run the rules of a connection.
---@param connection Connection The connection to run the rules of.
local function run_connection(connection)
  if moving_items and connection.moving then
    backend_log.debug("Running connection", connection.name)
    _run_connection_impl(connection)
    backend_log.debug("Connection", connection.name, "completed.")
  end
end

local function backend()
  local known_ids = {}
  while true do
    for _, connection in ipairs(connections) do
      local id = connection.id

      -- Only spawn a new thread if the connection has finished running.
      if known_ids[id] then
        if not thready.is_alive(known_ids[id]) then
          backend_log.debug("Restarting connection", connection.name)
          known_ids[id] = thready.spawn("connection_runners", function() run_connection(connection) end)
          backend_log.debug("Connection", connection.name, "was restarted.")
        else
          backend_log.warn("Connection", connection.name, "took too long, and was skipped on this cycle.")
        end
      else
        -- ... Or never ran yet.
        known_ids[id] = thready.spawn("connection_runners", function() run_connection(connection) end)
        backend_log.debug("Connection", connection.name, "was started.")
      end
    end

    sleep(0.05 * update_tickrate)
  end
end

local function frontend()
  -- Repeat until main menu exited
  repeat until main_menu()
end

local ok, err = xpcall(function()
  thready.parallelAny(frontend, backend, process_inventory_requests, key_listener)
end, debug.traceback)
print() -- put the cursor back on the screen

if not ok then
  log.fatal(err)
  ---@diagnostic disable-next-line ITS A HEKKIN STRING
  unacceptable("error", err)

  logging.dump_log("crash.log")

  ---@fixme add test mode if error was "Terminated" and user terminates the unacceptable prompt again.
end

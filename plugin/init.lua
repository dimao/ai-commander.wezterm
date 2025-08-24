local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

-- Default configuration
local default_config = {
  provider = 'anthropic',  -- 'anthropic' or 'openai'
  api_key = {
    anthropic = nil,  -- Anthropic API key
    openai = nil,     -- OpenAI API key
  },
  api_url = {
    anthropic = 'https://api.anthropic.com/v1/messages',
    openai = 'https://api.openai.com/v1/chat/completions',
  },
  model = {
    anthropic = 'claude-3-5-sonnet-20241022',
    openai = 'gpt-4',
  },
  max_tokens = 4000,
  temperature = 0.1,
  history_file = wezterm.home_dir .. '/.wezterm_ai_prompt_history.txt',
  max_history = 100,
}

-- Active configuration (will be merged with user config)
local config = default_config

-- Function to load prompt history from file
local function load_prompt_history()
  local history = {}
  local file = io.open(config.history_file, 'r')
  if file then
    for line in file:lines() do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed and trimmed ~= "" then
        table.insert(history, trimmed)
      end
    end
    file:close()
  end
  return history
end

-- Function to save prompt to history file
local function save_prompt_to_history(prompt)
  local history = load_prompt_history()
  
  -- Remove if already exists (move to front)
  for i, item in ipairs(history) do
    if item == prompt then
      table.remove(history, i)
      break
    end
  end
  
  -- Add to front
  table.insert(history, 1, prompt)
  
  -- Keep only max_history items
  while #history > config.max_history do
    table.remove(history)
  end
  
  -- Save to file
  local file = io.open(config.history_file, 'w')
  if file then
    for _, item in ipairs(history) do
      file:write(item .. '\n')
    end
    file:close()
  end
end

-- Function to call AI API (supports both Anthropic and OpenAI)
local function call_ai_api(user_message, callback)
  local provider = config.provider or 'anthropic'
  local api_key = config.api_key[provider]
  
  if not api_key or api_key == "" then
    callback("Error: " .. provider .. " API key not configured. Please set api_key." .. provider .. " in your .wezterm.lua config.")
    return
  end

  local request_body, curl_args
  
  if provider == 'anthropic' then
    -- Create JSON request body for Anthropic API
    request_body = {
      model = config.model.anthropic,
      max_tokens = config.max_tokens,
      temperature = config.temperature,
      messages = {
        {
          role = "user",
          content = user_message
        }
      }
    }
    
    local json_body = wezterm.json_encode(request_body)
    
    -- Build curl arguments for Anthropic API
    curl_args = {
      "curl",
      "-s",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", "x-api-key: " .. api_key,
      "-H", "anthropic-version: 2023-06-01",
      config.api_url.anthropic,
      "-d", json_body
    }
  elseif provider == 'openai' then
    -- Create JSON request body for OpenAI API
    request_body = {
      model = config.model.openai,
      max_tokens = config.max_tokens,
      temperature = config.temperature,
      messages = {
        {
          role = "user",
          content = user_message
        }
      }
    }
    
    local json_body = wezterm.json_encode(request_body)
    
    -- Build curl arguments for OpenAI API
    curl_args = {
      "curl",
      "-s",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer " .. api_key,
      config.api_url.openai,
      "-d", json_body
    }
  else
    callback("Error: Unsupported provider: " .. provider)
    return
  end

  -- Make the HTTP request using wezterm.run_child_process
  local success, stdout, stderr = wezterm.run_child_process(curl_args)

  if not success then
    wezterm.log_error("HTTP request failed: " .. (stderr or "Unknown error"))
    callback("Error: HTTP request failed. " .. (stderr or "Unknown error"))
    return
  end

  -- Parse JSON response
  local ok, response = pcall(wezterm.json_parse, stdout)
  if not ok then
    callback("Error: Failed to parse API response: " .. stdout:sub(1, 1500))
    return
  end

  -- Handle API errors
  if response.error then
    local error_msg = "API error: " .. (response.error.message or "Unknown error")
    callback(error_msg)
    return
  end

  -- Extract content based on provider
  if provider == 'anthropic' then
    -- Anthropic API response format
    if response.content and #response.content > 0 and response.content[1].text then
      callback(response.content[1].text)
    else
      callback("Error: No content found in Anthropic API response")
    end
  elseif provider == 'openai' then
    -- OpenAI API response format
    if response.choices and #response.choices > 0 and response.choices[1].message and response.choices[1].message.content then
      callback(response.choices[1].message.content)
    else
      callback("Error: No content found in OpenAI API response")
    end
  end
end

-- Function to process a prompt with optional context
local function process_prompt_with_context(prompt, context, window, pane)
  save_prompt_to_history(prompt)
  
  local api_prompt = "Generate 3-5 different bash command options to: " .. prompt
  
  -- Add context if available
  if context and context ~= "" then
    api_prompt = api_prompt .. "\n\nContext (selected text):\n" .. context
  end
  
  api_prompt = api_prompt .. "\n\nReturn each command on a separate line, no explanations, no numbering, just the commands."
  
  call_ai_api(api_prompt, function(response)
    -- Parse multiple commands from response
    local commands = {}
    for command in response:gmatch("[^\r\n]+") do
      local trimmed = command:match("^%s*(.-)%s*$")
      if trimmed and trimmed ~= "" then
        table.insert(commands, trimmed)
      end
    end
    
    if #commands == 0 then
      pane:send_text("# Error: No commands generated")
      return
    elseif #commands == 1 then
      -- If only one command, print it without executing
      pane:send_text(commands[1])
      return
    end
    
    -- Show selection menu for multiple commands
    local choices = {}
    for i, cmd in ipairs(commands) do
      table.insert(choices, {
        id = tostring(i),
        label = cmd
      })
    end
    
    window:perform_action(
      act.InputSelector {
        action = wezterm.action_callback(function(window, pane, id, label)
          if id then
            local selected_command = commands[tonumber(id)]
            if selected_command then
              pane:send_text(selected_command)
            end
          end
        end),
        title = 'Select Command',
        choices = choices,
        description = 'Choose a command to execute:',
      },
      pane
    )
  end)
end

-- Function to process a prompt (backward compatibility)
local function process_prompt(prompt, window, pane)
  process_prompt_with_context(prompt, nil, window, pane)
end

function M.apply_to_config(wezterm_config, plugin_config)
  -- Merge user configuration with defaults
  if plugin_config then
    for key, value in pairs(plugin_config) do
      config[key] = value
    end
  end
end

-- Expose function for showing prompt history
function M.show_history(window, pane)
  local history = load_prompt_history()
  
  if #history == 0 then
    pane:send_text("# No prompt history available")
    return
  end
  
  -- Create choices for history selection
  local choices = {}
  for i, prompt in ipairs(history) do
    table.insert(choices, {
      id = tostring(i),
      label = prompt
    })
  end
  
  window:perform_action(
    act.InputSelector {
      action = wezterm.action_callback(function(window, pane, id, label)
        if id then
          local selected_prompt = history[tonumber(id)]
          if selected_prompt then
            -- Get selected text as context, just like in show_prompt
            local selection = window:get_selection_text_for_pane(pane)
            process_prompt_with_context(selected_prompt, selection, window, pane)
          end
        end
      end),
      title = 'Select Previous Prompt',
      choices = choices,
      description = 'Choose a prompt from history:',
    },
    pane
  )
end

-- Expose function for showing prompt input
function M.show_prompt(window, pane)
  -- Get selected text as context
  local selection = window:get_selection_text_for_pane(pane)
  local context_description = ""
  
  if selection and selection ~= "" then
    context_description = "Enter prompt for command to generate (selected text will be used as context):"
  else
    context_description = "Enter prompt for command to generate:"
  end
  
  window:perform_action(
    act.PromptInputLine {
      description = context_description,
      action = wezterm.action_callback(function(window, pane, line)
        if not line then 
          return 
        end
        
        process_prompt_with_context(line, selection, window, pane)
      end),
    },
    pane
  )
end

return M

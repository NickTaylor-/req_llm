defmodule ReqLLM.Providers.Cerebras do
  @moduledoc """
  Cerebras provider – OpenAI-compatible Chat Completions API with ultra-fast inference.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults with Cerebras-specific adjustments.

  ## Cerebras-Specific Notes

  - System messages have stronger influence compared to OpenAI's implementation
  - Streaming not supported with reasoning models in JSON mode or tool calling
  - Requires `strict: true` in tool schemas for structured output (automatically added)
  - Qwen models do NOT support `strict: true` (automatically excluded)
  - Only supports `tool_choice: "auto"` or `"none"`, not function-specific choices

  ## Unsupported OpenAI Features

  The following fields will result in a 400 error if supplied:
  - `frequency_penalty`
  - `logit_bias`
  - `presence_penalty`
  - `parallel_tool_calls`
  - `service_tier`

  ## Configuration

      # Add to .env file (automatically loaded)
      CEREBRAS_API_KEY=csk_...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :cerebras,
    base_url: "https://api.cerebras.ai/v1",
    metadata: "priv/models_dev/cerebras.json",
    default_env_key: "CEREBRAS_API_KEY",
    provider_schema: []

  use ReqLLM.Provider.Defaults

  @impl ReqLLM.Provider
  def encode_body(request) do
    request = ReqLLM.Provider.Defaults.default_encode_body(request)
    body = Jason.decode!(request.body)

    enhanced_body =
      body
      |> translate_tool_choice_format()
      |> add_strict_to_tools()
      |> normalize_tool_choice()
      |> normalize_assistant_content()

    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end

  defp translate_tool_choice_format(body) do
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    type = tool_choice && (Map.get(tool_choice, :type) || Map.get(tool_choice, "type"))
    name = tool_choice && (Map.get(tool_choice, :name) || Map.get(tool_choice, "name"))

    if type == "tool" && name do
      replacement =
        if is_map_key(tool_choice, :type) do
          %{type: "function", function: %{name: name}}
        else
          %{"type" => "function", "function" => %{"name" => name}}
        end

      Map.put(body, body_key, replacement)
    else
      body
    end
  end

  defp add_strict_to_tools(%{"tools" => tools, "model" => model} = body) when is_list(tools) do
    tools =
      if is_qwen_model?(model) do
        Enum.map(tools, &strip_unsupported_schema_constraints/1)
      else
        Enum.map(tools, fn tool ->
          put_in(tool, ["function", "strict"], true)
        end)
      end

    Map.put(body, "tools", tools)
  end

  defp add_strict_to_tools(body), do: body

  defp is_qwen_model?(model) do
    String.contains?(model, "qwen")
  end

  defp strip_unsupported_schema_constraints(tool) do
    update_in(tool, ["function", "parameters"], fn params ->
      if is_map(params) do
        strip_constraints_recursive(params)
      else
        params
      end
    end)
  end

  defp strip_constraints_recursive(schema) when is_map(schema) do
    schema
    |> Map.drop(["minimum", "maximum", "minLength", "maxLength"])
    |> Map.new(fn
      {"properties", props} when is_map(props) ->
        {"properties", Map.new(props, fn {k, v} -> {k, strip_constraints_recursive(v)} end)}

      {k, v} when is_map(v) ->
        {k, strip_constraints_recursive(v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp strip_constraints_recursive(value), do: value

  defp normalize_tool_choice(%{"tool_choice" => %{"type" => "function"}} = body) do
    Map.put(body, "tool_choice", "auto")
  end

  defp normalize_tool_choice(body), do: body

  defp normalize_assistant_content(%{"messages" => messages} = body) do
    normalized_messages =
      Enum.map(messages, fn message ->
        case message do
          %{"role" => "assistant", "content" => []} ->
            Map.put(message, "content", "")

          _ ->
            message
        end
      end)

    Map.put(body, "messages", normalized_messages)
  end

  defp normalize_assistant_content(body), do: body
end

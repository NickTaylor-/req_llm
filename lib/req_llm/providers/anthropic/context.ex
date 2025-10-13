defmodule ReqLLM.Providers.Anthropic.Context do
  @moduledoc """
  Anthropic-specific context encoding for the Messages API format.

  Handles encoding ReqLLM contexts to Anthropic's Messages API format.

  ## Key Differences from OpenAI

  - Uses content blocks instead of simple strings
  - System messages are extracted to top-level `system` parameter
  - Tool calls are represented as content blocks with type "tool_use"
  - Tool results must be in "user" role messages (Anthropic only accepts "user" or "assistant" roles)
  - Different parameter names (stop_sequences vs stop)

  ## Message Format

      %{
        model: "claude-3-5-sonnet-20241022",
        system: "You are a helpful assistant",
        messages: [
          %{role: "user", content: "What's the weather?"},
          %{role: "assistant", content: [
            %{type: "text", text: "I'll check that for you."},
            %{type: "tool_use", id: "toolu_123", name: "get_weather", input: %{location: "SF"}}
          ]},
          %{role: "user", content: [
            %{type: "tool_result", tool_use_id: "toolu_123", content: "72°F and sunny"}
          ]}
        ],
        max_tokens: 1000,
        temperature: 0.7
      }
  """

  @doc """
  Encode context and model to Anthropic Messages API format.
  """
  @spec encode_request(ReqLLM.Context.t(), ReqLLM.Model.t() | map()) :: map()
  def encode_request(context, model) do
    %{
      model: extract_model_name(model)
    }
    |> add_messages(context.messages)
    |> add_tools(Map.get(context, :tools, []))
    |> filter_nil_values()
  end

  defp extract_model_name(%{model: model_name}), do: model_name
  defp extract_model_name(model) when is_binary(model), do: model
  defp extract_model_name(_), do: "unknown"

  defp add_messages(request, messages) do
    {system_messages, non_system_messages} =
      Enum.split_with(messages, fn %ReqLLM.Message{role: role} -> role == :system end)

    request =
      case system_messages do
        [] ->
          request

        [%ReqLLM.Message{content: content} | _] ->
          # Anthropic only accepts one system message at top level
          Map.put(request, :system, encode_content(content))
      end

    encoded_messages = Enum.map(non_system_messages, &encode_message/1)
    Map.put(request, :messages, encoded_messages)
  end

  defp encode_message(%ReqLLM.Message{role: role, content: content}) do
    # Anthropic API only accepts "user" or "assistant" roles
    # Tool results must be wrapped in a "user" message
    # See: https://docs.anthropic.com/en/docs/build-with-claude/tool-use
    normalized_role = if role == :tool, do: :user, else: role

    %{
      role: to_string(normalized_role),
      content: encode_content(content)
    }
  end

  # Simple text content
  defp encode_content(content) when is_binary(content), do: content

  # Multi-part content
  defp encode_content(content) when is_list(content) do
    content_blocks =
      content
      |> Enum.map(&encode_content_part/1)
      |> Enum.reject(&is_nil/1)

    case content_blocks do
      [] -> ""
      # Simplify single text blocks
      [%{type: "text", text: text}] -> text
      blocks -> blocks
    end
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{type: :text, text: text}) do
    %{type: "text", text: text}
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{
         type: :tool_call,
         tool_name: name,
         input: input,
         tool_call_id: id
       }) do
    %{
      type: "tool_use",
      id: id,
      name: name,
      input: input
    }
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{
         type: :tool_result,
         tool_call_id: id,
         output: output
       }) do
    # Anthropic tool_result format requires string content
    # See: https://docs.anthropic.com/en/docs/build-with-claude/tool-use
    %{
      type: "tool_result",
      tool_use_id: id,
      content: serialize_tool_output(output)
    }
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{
         type: :image,
         data: data,
         media_type: media_type
       }) do
    base64 = Base.encode64(data)

    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: media_type,
        data: base64
      }
    }
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{type: :image_url, url: url}) do
    %{
      type: "image",
      source: %{
        type: "url",
        url: url
      }
    }
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{
         type: :file,
         data: data,
         media_type: media_type,
         filename: _filename
       }) do
    base64 = Base.encode64(data)

    %{
      type: "document",
      source: %{
        type: "base64",
        media_type: media_type,
        data: base64
      }
    }
  end

  defp encode_content_part(_), do: nil

  # Serialize tool output to string format required by Anthropic
  defp serialize_tool_output(output) when is_binary(output), do: output
  defp serialize_tool_output(output), do: Jason.encode!(output)

  defp add_tools(request, []), do: request

  defp add_tools(request, tools) when is_list(tools) do
    Map.put(request, :tools, encode_tools(tools))
  end

  defp encode_tools(tools) do
    Enum.map(tools, &encode_tool/1)
  end

  defp encode_tool(tool) do
    # Convert from ReqLLM tool to Anthropic format
    openai_schema = ReqLLM.Schema.to_openai_format(tool)

    %{
      name: openai_schema["function"]["name"],
      description: openai_schema["function"]["description"],
      input_schema: openai_schema["function"]["parameters"]
    }
  end

  defp filter_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

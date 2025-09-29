defmodule ReqLLM.Providers.OpenRouterTest do
  @moduledoc """
  Provider-level tests for OpenRouter implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.OpenRouter

  import ReqLLM.ProviderTestHelpers

  alias ReqLLM.Context
  alias ReqLLM.Providers.OpenRouter

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(OpenRouter.provider_id())
      assert is_binary(OpenRouter.default_base_url())
      assert String.starts_with?(OpenRouter.default_base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = OpenRouter.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      # Provider-specific keys should not overlap with core generation keys
      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "supported options include core generation keys" do
      supported = OpenRouter.supported_provider_options()
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      # All core keys should be supported (except meta-keys like :provider_options)
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- supported
      assert missing == [], "Missing core generation keys: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = OpenRouter.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      # Should include all core generation keys
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      # Should include provider-specific keys
      provider_keys = OpenRouter.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = OpenRouter.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> OpenRouter.attach(model, opts)

      # Verify core options
      assert request.options[:model] == model.model
      assert request.options[:temperature] == 0.5
      assert request.options[:max_tokens] == 50
      assert {:bearer, _key} = request.options[:auth]

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = OpenRouter.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      wrong_model = ReqLLM.Model.from!("xai:grok-3")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> OpenRouter.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body without tools" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      # Create a mock request with the expected structure
      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      # Test the encode_body function directly
      updated_request = OpenRouter.encode_body(mock_request)

      assert is_binary(updated_request.body)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "openai/gpt-4"
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 2
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")

      [system_msg, user_msg] = decoded["messages"]
      assert system_msg["role"] == "system"
      assert user_msg["role"] == "user"
    end

    test "encode_body with tools but no tool_choice" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool]
        ]
      }

      updated_request = OpenRouter.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
      refute Map.has_key?(decoded, "tool_choice")

      [encoded_tool] = decoded["tools"]
      assert encoded_tool["function"]["name"] == "test_tool"
    end

    test "encode_body with tools and tool_choice" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      tool_choice = %{type: "function", function: %{name: "specific_tool"}}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: tool_choice
        ]
      }

      updated_request = OpenRouter.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])

      assert decoded["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "specific_tool"}
             }
    end

    test "encode_body with response_format" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      response_format = %{type: "json_object"}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          response_format: response_format
        ]
      }

      updated_request = OpenRouter.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["response_format"] == %{"type" => "json_object"}
    end

    test "encode_body OpenRouter-specific options" do
      model = ReqLLM.Model.from!("openrouter:anthropic/claude-3-haiku")
      context = context_fixture()

      test_cases = [
        # OpenRouter routing options
        {[openrouter_models: ["anthropic/claude-3-haiku", "openai/gpt-4"]],
         fn json -> assert json["models"] == ["anthropic/claude-3-haiku", "openai/gpt-4"] end},
        {[openrouter_route: "fallback"], fn json -> assert json["route"] == "fallback" end},
        {[openrouter_provider: %{require_parameters: true}],
         fn json -> assert json["provider"] == %{"require_parameters" => true} end},
        {[openrouter_transforms: ["middle-out"]],
         fn json -> assert json["transforms"] == ["middle-out"] end},
        # Sampling parameters
        {[openrouter_top_k: 40], fn json -> assert json["top_k"] == 40 end},
        {[openrouter_repetition_penalty: 1.1],
         fn json -> assert json["repetition_penalty"] == 1.1 end},
        {[openrouter_min_p: 0.05], fn json -> assert json["min_p"] == 0.05 end},
        {[openrouter_top_a: 0.2], fn json -> assert json["top_a"] == 0.2 end},
        {[openrouter_top_logprobs: 5], fn json -> assert json["top_logprobs"] == 5 end}
      ]

      for {opts, assertion} <- test_cases do
        mock_request = %Req.Request{
          options: [context: context, model: model.model, stream: false] ++ opts
        }

        updated_request = OpenRouter.encode_body(mock_request)
        decoded = Jason.decode!(updated_request.body)
        assertion.(decoded)
      end
    end
  end

  describe "response decoding" do
    test "decode_response handles non-streaming responses" do
      # Create a mock OpenAI-style response body
      response_body = %{
        "id" => "chatcmpl-test123",
        "object" => "chat.completion",
        "created" => System.os_time(:second),
        "model" => "openai/gpt-4",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! How can I help you today?"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 12,
          "completion_tokens" => 8,
          "total_tokens" => 20
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: response_body
      }

      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false],
        private: %{req_llm_model: model}
      }

      # Test decode_response directly
      {req, resp} = OpenRouter.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert is_binary(response.id)
      assert response.model == model.model
      assert response.stream? == false

      # Verify message normalization
      assert response.message.role == :assistant
      text = ReqLLM.Response.text(response)
      assert is_binary(text)
      assert String.length(text) > 0
      assert response.finish_reason in [:stop, :length, "stop", "length"]

      # Verify usage normalization
      assert is_integer(response.usage.input_tokens)
      assert is_integer(response.usage.output_tokens)
      assert is_integer(response.usage.total_tokens)

      # Verify context advancement (original + assistant)
      assert length(response.context.messages) == 3
      assert List.last(response.context.messages).role == :assistant
    end

    test "decode_response handles streaming responses" do
      # Create mock streaming chunks
      stream_chunks = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}}]},
        %{"choices" => [%{"finish_reason" => "stop"}]}
      ]

      # Create a mock stream
      mock_stream = Stream.map(stream_chunks, & &1)

      # Create a mock Req response with streaming body
      mock_resp = %Req.Response{
        status: 200,
        body: mock_stream
      }

      # Create a mock request with context and model
      context = context_fixture()
      model = "openai/gpt-4"

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model]
      }

      # Test decode_response directly
      {req, resp} = OpenRouter.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert is_struct(response.stream, Stream)
      assert response.model == model

      # Verify context is preserved (original messages only in streaming)
      assert length(response.context.messages) == 2

      # Verify stream structure and processing
      assert response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      assert response.finish_reason == nil
      assert response.provider_meta == %{}
    end

    test "decode_response handles API errors with non-200 status" do
      # Create error response
      error_body = %{
        "error" => %{
          "message" => "Invalid API key",
          "type" => "authentication_error",
          "code" => "invalid_api_key"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")

      mock_req = %Req.Request{
        options: [context: context, model: "openai/gpt-4"],
        private: %{req_llm_model: model}
      }

      # Test decode_response error handling
      {req, error} = OpenRouter.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
      assert error.reason == "Openrouter API error"
      assert error.response_body == error_body
    end
  end

  describe "option translation" do
    test "provider implements translate_options/3" do
      # OpenRouter implements translate_options/3 for various alias handling
      assert function_exported?(OpenRouter, :translate_options, 3)
    end

    test "translate_options validates openrouter_top_k with OpenAI models" do
      openai_model = ReqLLM.Model.from!("openrouter:openai/gpt-4")

      opts = [temperature: 0.7, openrouter_top_k: 40]
      {translated_opts, warnings} = OpenRouter.translate_options(:chat, openai_model, opts)

      refute Keyword.has_key?(translated_opts, :openrouter_top_k)
      assert length(warnings) == 1
      assert hd(warnings) =~ "openrouter_top_k is not available for OpenAI models"
    end

    test "translate_options allows openrouter_top_k for non-OpenAI models" do
      anthropic_model = ReqLLM.Model.from!("openrouter:anthropic/claude-3-haiku")

      opts = [temperature: 0.7, openrouter_top_k: 40]
      {translated_opts, warnings} = OpenRouter.translate_options(:chat, anthropic_model, opts)

      assert Keyword.get(translated_opts, :openrouter_top_k) == 40
      assert warnings == []
    end

    test "translate_options handles legacy parameter names with warnings" do
      model = ReqLLM.Model.from!("openrouter:anthropic/claude-3-haiku")

      opts = [
        temperature: 0.7,
        models: ["anthropic/claude-3-haiku", "openai/gpt-4"],
        route: "fallback",
        top_k: 40
      ]

      {translated_opts, warnings} = OpenRouter.translate_options(:chat, model, opts)

      # Legacy parameters should be converted
      assert Keyword.get(translated_opts, :openrouter_models) == [
               "anthropic/claude-3-haiku",
               "openai/gpt-4"
             ]

      assert Keyword.get(translated_opts, :openrouter_route) == "fallback"
      assert Keyword.get(translated_opts, :openrouter_top_k) == 40

      # Original parameters should be removed
      refute Keyword.has_key?(translated_opts, :models)
      refute Keyword.has_key?(translated_opts, :route)
      refute Keyword.has_key?(translated_opts, :top_k)

      # Should generate warnings
      assert length(warnings) == 3
      warning_text = Enum.join(warnings, " ")
      assert warning_text =~ "models is deprecated"
      assert warning_text =~ "route is deprecated"
      assert warning_text =~ "top_k is deprecated"
    end

    test "provider-specific option handling" do
      # Test that provider-specific options are present in the provider schema
      schema_keys = OpenRouter.provider_schema().schema |> Keyword.keys()

      # Test that these options are supported
      supported_opts = OpenRouter.supported_provider_options()

      for provider_option <- schema_keys do
        assert provider_option in supported_opts,
               "Expected #{provider_option} to be in supported options"
      end
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = OpenRouter.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 10
      assert usage["completion_tokens"] == 20
      assert usage["total_tokens"] == 30
    end

    test "extract_usage with missing usage data" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = OpenRouter.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")

      {:error, :invalid_body} = OpenRouter.extract_usage("invalid", model)
      {:error, :invalid_body} = OpenRouter.extract_usage(nil, model)
      {:error, :invalid_body} = OpenRouter.extract_usage(123, model)
    end
  end

  describe "object generation edge cases" do
    test "prepare_request for :object with low max_tokens gets adjusted" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      # Test with max_tokens < 200
      opts = [max_tokens: 50, compiled_schema: schema]
      {:ok, request} = OpenRouter.prepare_request(:object, model, context, opts)

      # Should be adjusted to 200
      assert request.options[:max_tokens] == 200
    end

    test "prepare_request for :object with nil max_tokens gets default" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile([])

      # No max_tokens specified
      opts = [compiled_schema: schema]
      {:ok, request} = OpenRouter.prepare_request(:object, model, context, opts)

      # Should get default of 4096
      assert request.options[:max_tokens] == 4096
    end

    test "prepare_request for :object with sufficient max_tokens unchanged" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(value: [type: :integer])

      opts = [max_tokens: 1000, compiled_schema: schema]
      {:ok, request} = OpenRouter.prepare_request(:object, model, context, opts)

      # Should remain unchanged
      assert request.options[:max_tokens] == 1000
    end

    test "prepare_request rejects unsupported operations" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      # Test unsupported operation for 3-arg version
      {:error, error} = OpenRouter.prepare_request(:embedding, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :embedding not supported"

      # Test unsupported operation for object with schema
      {:ok, schema} = ReqLLM.Schema.compile([])

      {:error, error} =
        OpenRouter.prepare_request(:embedding, model, context, compiled_schema: schema)

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :embedding not supported"
    end
  end

  describe "error handling & robustness" do
    test "context validation" do
      # Multiple system messages should fail
      invalid_context =
        Context.new([
          Context.system("System 1"),
          Context.system("System 2"),
          Context.user("Hello")
        ])

      assert_raise ReqLLM.Error.Validation.Error,
                   ~r/should have at most one system message/,
                   fn ->
                     Context.validate!(invalid_context)
                   end
    end
  end

  describe "OpenRouter-specific features" do
    test "model routing parameters are encoded correctly" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")
      context = context_fixture()

      routing_opts = %{
        openrouter_models: ["openai/gpt-4", "anthropic/claude-3-haiku"],
        openrouter_route: "fallback",
        openrouter_provider: %{require_parameters: true}
      }

      mock_request = %Req.Request{
        options:
          [
            context: context,
            model: model.model
          ] ++ Map.to_list(routing_opts)
      }

      updated_request = OpenRouter.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["models"] == ["openai/gpt-4", "anthropic/claude-3-haiku"]
      assert decoded["route"] == "fallback"
      assert decoded["provider"] == %{"require_parameters" => true}
    end

    test "transform parameters are encoded correctly" do
      model = ReqLLM.Model.from!("openrouter:anthropic/claude-3-haiku")
      context = context_fixture()

      transforms = ["middle-out", "prompt-simplify"]

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          openrouter_transforms: transforms
        ]
      }

      updated_request = OpenRouter.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["transforms"] == transforms
    end

    test "sampling parameters are encoded correctly" do
      model = ReqLLM.Model.from!("openrouter:anthropic/claude-3-haiku")
      context = context_fixture()

      sampling_opts = [
        openrouter_top_k: 40,
        openrouter_repetition_penalty: 1.05,
        openrouter_min_p: 0.05,
        openrouter_top_a: 0.2,
        openrouter_top_logprobs: 3
      ]

      mock_request = %Req.Request{
        options:
          [
            context: context,
            model: model.model
          ] ++ sampling_opts
      }

      updated_request = OpenRouter.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["top_k"] == 40
      assert decoded["repetition_penalty"] == 1.05
      assert decoded["min_p"] == 0.05
      assert decoded["top_a"] == 0.2
      assert decoded["top_logprobs"] == 3
    end

    test "app attribution headers are added correctly" do
      model = ReqLLM.Model.from!("openrouter:openai/gpt-4")

      opts = [
        temperature: 0.7,
        app_referer: "https://myapp.com",
        app_title: "My Cool App"
      ]

      request = Req.new() |> OpenRouter.attach(model, opts)

      # Check that headers were added
      headers = Map.new(request.headers)
      assert headers["http-referer"] == ["https://myapp.com"]
      assert headers["x-title"] == ["My Cool App"]
    end
  end
end

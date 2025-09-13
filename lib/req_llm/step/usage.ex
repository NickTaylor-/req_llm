defmodule ReqLLM.Step.Usage do
  @moduledoc """
  Centralized Req step that extracts token usage from provider responses,
  normalizes usage values across providers, computes costs, and emits telemetry.

  This step:
  * Extracts token usage numbers from provider responses
  * Normalizes usage data across different provider formats
  * Calculates costs using ReqLLM.Model cost metadata
  * Stores usage data in `response.private[:req_llm][:usage]`
  * Emits telemetry events for monitoring

  ## Usage

      request
      |> ReqLLM.Step.Usage.attach(model)

  ## Telemetry Events

  Emits `[:req_llm, :token_usage]` events with:
  * Measurements: `%{tokens: %{input: 123, output: 456, reasoning: 64}, cost: 0.0123}`
  * Metadata: `%{model: %ReqLLM.Model{}}`
  """

  @event [:req_llm, :token_usage]

  @doc """
  Attaches the Usage step to a Req request.

  ## Parameters

  - `req` - The Req.Request struct
  - `model` - Optional ReqLLM.Model struct for cost calculation

  ## Examples

      request
      |> ReqLLM.Step.Usage.attach(model)

  """
  @spec attach(Req.Request.t(), ReqLLM.Model.t() | nil) :: Req.Request.t()
  def attach(%Req.Request{} = req, model \\ nil) do
    req
    |> Req.Request.append_response_steps(llm_usage: &__MODULE__.handle/1)
    |> then(fn r ->
      if model, do: Req.Request.put_private(r, :req_llm_model, model), else: r
    end)
  end

  @doc false
  @spec handle({Req.Request.t(), Req.Response.t()}) :: {Req.Request.t(), Req.Response.t()}
  def handle({req, resp}) do
    provider_module = get_provider_module(req)

    with {:ok, usage} <- extract_usage(resp.body, provider_module),
         {:ok, model} <- fetch_model(req),
         {:ok, cost} <- compute_cost(usage, model) do
      meta = %{tokens: usage, cost: cost}

      # Emit telemetry event for monitoring
      :telemetry.execute(@event, meta, %{model: model})

      # Store usage data in response private for access by callers
      req_llm_data = Map.get(resp.private, :req_llm, %{})
      updated_req_llm_data = Map.put(req_llm_data, :usage, meta)
      updated_resp = %{resp | private: Map.put(resp.private, :req_llm, updated_req_llm_data)}
      {req, updated_resp}
    else
      _ -> {req, resp}
    end
  end

  # Gets the provider module from the request options
  @spec get_provider_module(Req.Request.t()) :: module() | nil
  defp get_provider_module(%Req.Request{options: options}) do
    case options[:model] do
      %ReqLLM.Model{provider: provider_id} ->
        case ReqLLM.Provider.Registry.get_provider(provider_id) do
          {:ok, module} -> module
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Extracts token usage from provider responses with normalization
  @spec extract_usage(any, module() | nil) :: {:ok, map()} | :error
  defp extract_usage(body, provider_module) do
    # Try provider-specific extraction first if provider implements it
    case provider_module do
      nil ->
        fallback_extract_usage(body)

      module when is_atom(module) ->
        if function_exported?(module, :extract_usage, 2) do
          case module.extract_usage(body, nil) do
            {:ok, usage} -> {:ok, normalize_usage(usage)}
            _ -> fallback_extract_usage(body)
          end
        else
          fallback_extract_usage(body)
        end
    end
  end

  # Fallback usage extraction for standard formats
  @spec fallback_extract_usage(any) :: {:ok, map()} | :error
  defp fallback_extract_usage(%{"usage" => usage}) when is_map(usage) do
    base_usage = %{
      input: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      output: usage["completion_tokens"] || usage["output_tokens"] || 0
    }

    # Check for detailed token breakdown (e.g., OpenAI o1 models with reasoning)
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"])

    usage_with_reasoning =
      if is_integer(reasoning_tokens) and reasoning_tokens > 0 do
        Map.put(base_usage, :reasoning, reasoning_tokens)
      else
        Map.put(base_usage, :reasoning, 0)
      end

    {:ok, usage_with_reasoning}
  end

  # Handle top-level token fields (some smaller APIs)
  defp fallback_extract_usage(%{"prompt_tokens" => input, "completion_tokens" => output}) do
    {:ok, %{input: input, output: output, reasoning: 0}}
  end

  defp fallback_extract_usage(%{"input_tokens" => input, "output_tokens" => output}) do
    {:ok, %{input: input, output: output, reasoning: 0}}
  end

  defp fallback_extract_usage(_), do: :error

  # Normalizes usage data to standard format
  @spec normalize_usage(map()) :: map()
  defp normalize_usage(usage) when is_map(usage) do
    %{
      input: usage[:input] || usage["input"] || 0,
      output: usage[:output] || usage["output"] || 0,
      reasoning: usage[:reasoning] || usage["reasoning"] || 0
    }
  end

  # Finds the model from request private data or options
  @spec fetch_model(Req.Request.t()) :: {:ok, ReqLLM.Model.t()} | :error
  defp fetch_model(%Req.Request{private: private, options: options}) do
    case private[:req_llm_model] || options[:model] do
      %ReqLLM.Model{} = model -> {:ok, model}
      _ -> :error
    end
  end

  # Calculates cost based on token usage and model pricing
  @spec compute_cost(%{input: any(), output: any(), reasoning: any()}, ReqLLM.Model.t()) ::
          {:ok, float() | nil}
  defp compute_cost(%{input: _input_tokens, output: _output_tokens}, %ReqLLM.Model{cost: nil}) do
    {:ok, nil}
  end

  defp compute_cost(%{input: input_tokens, output: output_tokens}, %ReqLLM.Model{cost: cost_map})
       when is_map(cost_map) do
    # Handle both atom and string keys from model metadata
    input_cost = cost_map[:input] || cost_map["input"]
    output_cost = cost_map[:output] || cost_map["output"]

    if input_cost && output_cost do
      calculated_cost =
        Float.round(input_tokens / 1000 * input_cost + output_tokens / 1000 * output_cost, 6)

      {:ok, calculated_cost}
    else
      {:ok, nil}
    end
  end
end

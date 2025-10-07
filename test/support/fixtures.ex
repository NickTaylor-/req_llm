defmodule ReqLLM.Test.Fixtures do
  @moduledoc """
  Thin facade for fixture recording and replay.

  Provides unified interface for both streaming and non-streaming fixtures,
  delegating path construction to ReqLLM.Test.FixturePath.
  """

  @doc "Current fixture mode (:record or :replay)"
  @spec mode() :: :record | :replay
  def mode do
    if Code.ensure_loaded?(ReqLLM.Test.Env) do
      ReqLLM.Test.Env.fixtures_mode()
    else
      :replay
    end
  rescue
    _ -> :replay
  end

  @doc """
  Determine replay fixture path from model and options.

  Returns `{:fixture, path}` when:
  - Mode is `:replay`
  - `:fixture` option is provided (as test_name)
  - Fixture file exists

  Otherwise returns `:no_fixture`.

  Raises if replay mode and fixture specified but file doesn't exist.

  ## Options

  - `:fixture` - Test name only (e.g., "basic", "streaming", "usage")
  """
  @spec replay_path(ReqLLM.Model.t() | String.t(), keyword()) ::
          {:fixture, String.t()} | :no_fixture
  def replay_path(model_or_spec, opts) do
    result =
      case {mode(), Keyword.get(opts, :fixture)} do
        {:replay, nil} ->
          :no_fixture

        {:replay, test_name} when is_binary(test_name) ->
          path = ReqLLM.Test.FixturePath.file(model_or_spec, test_name)

          if File.exists?(path) do
            {:fixture, path}
          else
            raise """
            Fixture not found: #{path}
            Run the test with REQ_LLM_FIXTURES_MODE=record to capture it.
            """
          end

        _ ->
          :no_fixture
      end

    if match?({:fixture, _}, result) && System.get_env("REQ_LLM_DEBUG") == "1" do
      require Logger

      {:fixture, path} = result

      model =
        case model_or_spec do
          %ReqLLM.Model{} = m -> m
          spec when is_binary(spec) -> ReqLLM.Model.from!(spec)
        end

      test_name = Keyword.get(opts, :fixture, Path.basename(path, ".json"))

      Logger.debug("[Fixture] step: model=#{model.provider}:#{model.model}, name=#{test_name}")
    end

    result
  end

  @doc """
  Determine capture fixture path from model and options.

  Returns path string when:
  - `:fixture_path` explicitly provided, OR
  - Mode is `:record` and `:fixture` option provided

  Otherwise returns `nil`.

  ## Options

  - `:fixture` - Test name only (e.g., "basic", "streaming", "usage")
  - `:fixture_path` - Explicit override path
  """
  @spec capture_path(ReqLLM.Model.t() | String.t(), keyword()) :: String.t() | nil
  def capture_path(model_or_spec, opts) do
    result =
      case Keyword.get(opts, :fixture_path) do
        nil ->
          if mode() == :record do
            case Keyword.get(opts, :fixture) do
              test_name when is_binary(test_name) ->
                ReqLLM.Test.FixturePath.file(model_or_spec, test_name)

              _ ->
                nil
            end
          end

        explicit_path ->
          Path.expand(explicit_path)
      end

    if result && System.get_env("REQ_LLM_DEBUG") == "1" do
      require Logger

      model =
        case model_or_spec do
          %ReqLLM.Model{} = m -> m
          spec when is_binary(spec) -> ReqLLM.Model.from!(spec)
        end

      test_name = Keyword.get(opts, :fixture, Path.basename(result, ".json"))

      Logger.debug("[Fixture] step: model=#{model.provider}:#{model.model}, name=#{test_name}")
    end

    result
  end
end

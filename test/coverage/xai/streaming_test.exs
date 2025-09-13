defmodule ReqLLM.Coverage.XAI.StreamingTest do
  @moduledoc """
  xAI streaming API feature coverage tests.

  Uses shared provider test macros to eliminate duplication while maintaining
  clear per-provider test organization and failure reporting.

  Run with LIVE=true to test against live API and capture fixtures.
  Otherwise uses cached fixtures for fast, reliable testing.
  """

  use ReqLLM.ProviderTest.Streaming,
    provider: :xai,
    model: "xai:grok-3-mini"
end

# Ensure providers are loaded for testing
Application.ensure_all_started(:req_llm)

ExUnit.start()

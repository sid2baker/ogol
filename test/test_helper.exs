ExUnit.start()

ExUnit.configure(
  exclude: [session_integration: true, web_integration: true, browser_integration: true]
)

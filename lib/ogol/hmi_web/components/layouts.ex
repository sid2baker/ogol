defmodule Ogol.HMIWeb.Layouts do
  use Ogol.HMIWeb, :html

  attr(:inner_content, :any, required: true)

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full bg-slate-950">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Ogol HMI</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body class="h-full bg-slate-950 text-slate-100 antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[radial-gradient(circle_at_top,_rgba(56,189,248,0.18),_transparent_28%),linear-gradient(180deg,_#020617_0%,_#0f172a_100%)]">
      <header class="border-b border-white/10 bg-slate-950/80 backdrop-blur">
        <div class="mx-auto flex max-w-7xl items-center justify-between px-6 py-4 lg:px-8">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.22em] text-cyan-300">Ogol</p>
            <h1 class="text-xl font-semibold text-white">Runtime HMI</h1>
          </div>
          <div class="rounded-full border border-cyan-400/20 bg-cyan-400/10 px-3 py-1 text-xs font-medium text-cyan-100">
            LiveView
          </div>
        </div>
      </header>

      <main class="mx-auto max-w-7xl px-6 py-8 lg:px-8">
        {@inner_content}
      </main>
    </div>
    """
  end
end

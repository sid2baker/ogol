defmodule Ogol.HMIWeb.Layouts do
  use Ogol.HMIWeb, :html

  attr(:inner_content, :any, required: true)

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full bg-[#05090d]">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Ogol HMI</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body class="h-full bg-[#05090d] text-slate-100 antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[linear-gradient(180deg,rgba(15,23,42,0.22)_0%,rgba(2,6,23,0.06)_100%)]">
      <header class="border-b border-white/10 bg-[#04070bcc]/95 backdrop-blur-xl">
        <div class="mx-auto max-w-[1700px] px-4 py-4 lg:px-6">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_auto] xl:items-center">
            <div class="min-w-0">
              <div class="flex items-center gap-3">
                <span class="h-2.5 w-2.5 bg-amber-300 shadow-[0_0_20px_rgba(252,211,77,0.7)]"></span>
                <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                  Ogol Industrial Runtime
                </p>
              </div>
              <h1 class="mt-2 text-2xl font-semibold tracking-[0.05em] text-white">
                Supervisory Operations HMI
              </h1>
              <p class="mt-1 max-w-3xl text-sm text-slate-400">
                Dense line-side visibility for machine state, signal flow, and incident posture.
              </p>
            </div>

            <div class="grid gap-2 sm:grid-cols-3">
              <div class="border border-white/10 bg-slate-950/70 px-3 py-2">
                <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Runtime</p>
                <p class="mt-1 text-sm font-semibold text-slate-100">LiveView / Phoenix</p>
              </div>
              <div class="border border-white/10 bg-slate-950/70 px-3 py-2">
                <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Data Plane</p>
                <p class="mt-1 text-sm font-semibold text-slate-100">ETS Snapshots</p>
              </div>
              <div class="border border-white/10 bg-slate-950/70 px-3 py-2">
                <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Mode</p>
                <p class="mt-1 text-sm font-semibold text-amber-100">Realtime Monitoring</p>
              </div>
            </div>

            <div class="justify-self-start border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 xl:justify-self-end">
              <p class="font-mono text-[10px] uppercase tracking-[0.3em] text-emerald-100/75">Channel</p>
              <p class="mt-1 text-sm font-semibold text-emerald-50">Live Telemetry</p>
            </div>
          </div>

          <nav class="mt-4 flex flex-wrap gap-2 border-t border-white/8 pt-4">
            <.link
              navigate={~p"/"}
              class="border border-white/10 bg-slate-950/70 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-slate-200 transition hover:border-cyan-400/20 hover:text-cyan-100"
            >
              Overview
            </.link>
            <.link
              navigate={~p"/hardware"}
              class="border border-white/10 bg-slate-950/70 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-slate-200 transition hover:border-amber-400/20 hover:text-amber-100"
            >
              Hardware
            </.link>
          </nav>
        </div>
      </header>

      <main class="mx-auto max-w-[1700px] px-4 py-4 lg:px-6 lg:py-5">
        {@inner_content}
      </main>
    </div>
    """
  end
end

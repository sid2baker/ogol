defmodule OgolWeb.Live.SessionAction do
  @moduledoc false

  alias Ogol.Session
  alias Ogol.Session.Data
  alias Ogol.Studio.Cell.Control

  @type reduce_opt ::
          {:guard,
           (Phoenix.LiveView.Socket.t() ->
              :ok
              | :error
              | {:ok, Phoenix.LiveView.Socket.t()}
              | {:error, Phoenix.LiveView.Socket.t()})}
          | {:before, (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())}
          | {:after, (Phoenix.LiveView.Socket.t(), term() -> Phoenix.LiveView.Socket.t())}

  @spec reduce(Phoenix.LiveView.Socket.t(), Data.action(), [reduce_opt()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def reduce(socket, action, opts \\ []) do
    case run_guard(socket, Keyword.get(opts, :guard)) do
      {:halt, next_socket} ->
        {:noreply, next_socket}

      {:cont, next_socket} ->
        next_socket = apply_before(next_socket, Keyword.get(opts, :before))
        reply = Session.perform_action(action)
        {:noreply, apply_after(next_socket, reply, Keyword.get(opts, :after))}
    end
  end

  @spec reduce_control(Phoenix.LiveView.Socket.t(), Control.t(), [reduce_opt()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def reduce_control(socket, %Control{action: nil}, _opts), do: {:noreply, socket}

  def reduce_control(socket, %Control{action: action}, opts) do
    reduce(socket, action, opts)
  end

  defp run_guard(socket, nil), do: {:cont, socket}

  defp run_guard(socket, guard) when is_function(guard, 1) do
    case guard.(socket) do
      :ok -> {:cont, socket}
      :error -> {:halt, socket}
      {:ok, next_socket} -> {:cont, next_socket}
      {:error, next_socket} -> {:halt, next_socket}
    end
  end

  defp apply_before(socket, before) when is_function(before, 1), do: before.(socket)
  defp apply_before(socket, _before), do: socket

  defp apply_after(socket, reply, after_fun) when is_function(after_fun, 2) do
    after_fun.(socket, reply)
  end

  defp apply_after(socket, _reply, _after_fun), do: socket
end

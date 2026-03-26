defmodule Ogol.HMIWeb.ErrorHTML do
  use Ogol.HMIWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

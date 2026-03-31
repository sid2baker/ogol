defmodule Ogol.HMI.Bus do
  @moduledoc false

  @pubsub Ogol.HMI.PubSub

  def overview_topic, do: "overview"
  def machine_topic(machine_id), do: "machine:#{machine_id}"
  def topology_topic(topology_id), do: "topology:#{topology_id}"
  def hardware_topic(bus, endpoint_id), do: "hardware:#{bus}:#{endpoint_id}"
  def events_topic, do: "events"
  def workspace_topic, do: "studio:workspace"

  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)
  def broadcast(topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)
end

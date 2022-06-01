with {:module, _} <- Code.ensure_compiled(Broadway) do
  defmodule OffBroadway.Jetstream.Acknowledger do
    @moduledoc false
    alias Broadway.Acknowledger
    alias Broadway.Message

    @behaviour Acknowledger

    @typedoc """
    Acknowledgement data to be placed in `Broadway.Message`.
    """
    @type ack_data :: %{
            :reply_to => String.t(),
            optional(:on_failure) => ack_option,
            optional(:on_success) => ack_option
          }

    @typedoc """
    An acknowledgement action.

    ## Options

    * `ack` - acknowledges a message was completely handled.

    * `nack` - signals that the message will not be processed now and will be redelivered.

    * `term` - tells the server to stop redelivery of a message without acknowledging it.
    """
    @type ack_option :: :ack | :nack | :term

    @type ack_ref :: reference()

    @type t :: %__MODULE__{
            connection_name: String.t(),
            on_failure: ack_option,
            on_success: ack_option
          }

    @enforce_keys [:connection_name]
    defstruct [:connection_name, on_failure: :nack, on_success: :ack]

    @doc """
    Initializes the acknowledger.

    ## Options

    * `connection_name` - The name of Gnat process or Gnat connection supervisor.

    * `on_success` - The action to perform on successful messages. Defaults to `:ack`.

    * `on_failure` - The action to perform on unsuccessful messages. Defaults to `:nack`.
    """
    @spec init(opts :: keyword()) :: {:ok, ack_ref()} | {:error, message :: binary()}
    def init(opts) do
      with {:ok, on_success} <- validate(opts, :on_success, :ack),
           {:ok, on_failure} <- validate(opts, :on_failure, :nack) do
        state = %__MODULE__{
          connection_name: opts[:connection_name],
          on_success: on_success,
          on_failure: on_failure
        }

        ack_ref = make_ref()
        put_config(ack_ref, state)

        {:ok, ack_ref}
      end
    end

    defp put_config(reference, state) do
      :persistent_term.put({__MODULE__, reference}, state)
    end

    @doc """
    Returns an `acknowledger` to be put in `Broadway.Message`.
    """
    @spec builder(ack_ref()) :: (String.t() -> {__MODULE__, ack_ref(), ack_data()})
    def builder(ack_ref) do
      &{__MODULE__, ack_ref, %{reply_to: &1}}
    end

    @impl Acknowledger
    def ack(ack_ref, successful, failed) do
      config = get_config(ack_ref)

      apply_ack_func(config.on_success, successful, config.connection_name)
      apply_ack_func(config.on_failure, failed, config.connection_name)

      :ok
    end

    def get_config(reference) do
      :persistent_term.get({__MODULE__, reference})
    end

    defp apply_ack_func(action, messages, connection_name) when is_list(messages) do
      for message <- messages, do: apply_ack_func(action, message, connection_name)
    end

    defp apply_ack_func(
           :ack,
           %Message{acknowledger: {_, _, %{reply_to: reply_to}}},
           connection_name
         ) do
      Jetstream.ack(%{gnat: connection_name, reply_to: reply_to})
    end

    defp apply_ack_func(
           :nack,
           %Message{acknowledger: {_, _, %{reply_to: reply_to}}},
           connection_name
         ) do
      Jetstream.nack(%{gnat: connection_name, reply_to: reply_to})
    end

    defp apply_ack_func(
           :term,
           %Message{acknowledger: {_, _, %{reply_to: reply_to}}},
           connection_name
         ) do
      Jetstream.ack_term(%{gnat: connection_name, reply_to: reply_to})
    end

    @impl Acknowledger
    def configure(_ack_ref, ack_data, options) do
      options = assert_valid_config!(options)
      ack_data = Map.merge(ack_data, Map.new(options))
      {:ok, ack_data}
    end

    defp assert_valid_config!(options) do
      Enum.map(options, fn
        {:on_success, value} -> {:on_success, validate_option!(:on_success, value)}
        {:on_failure, value} -> {:on_failure, validate_option!(:on_failure, value)}
        {other, _value} -> raise ArgumentError, "unsupported configure option #{inspect(other)}"
      end)
    end

    defp validate(opts, key, default) when is_list(opts) do
      validate_option(key, opts[key] || default)
    end

    defp validate_option(action, value) when action in [:on_success, :on_failure] do
      case validate_action(value) do
        {:ok, result} ->
          {:ok, result}

        :error ->
          {:error,
           "expected #{inspect(action)} to be a valid acknowledgement option, got: #{inspect(value)}"}
      end
    end

    defp validate_option(_, value), do: {:ok, value}

    defp validate_option!(key, value) do
      case validate_option(key, value) do
        {:ok, value} -> value
        {:error, message} -> raise ArgumentError, message
      end
    end

    defp validate_action(action) when action in [:ack, :nack, :term], do: {:ok, action}
    defp validate_action(_), do: :error
  end
end
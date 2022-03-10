defmodule Jetstream.PullConsumer do
  @moduledoc """
  A behaviour which provides the NATS JetStream Pull Consumer functionalities.

  When a Consumer is pull-based, it means that the messages will be delivered when the server
  is asked for them.

  ## Example

  Declare a module which uses `Jetstream.PullConsumer` and implements `c:init/1` and
  `c:handle_message/2` callbacks.

      defmodule MyApp.PullConsumer do
        use Jetstream.PullConsumer,
          connection_name: :gnat,
          stream_name: "TEST_STREAM",
          consumer_name: "TEST_CONSUMER"

        def start_link(arg) do
          Jetstream.PullConsumer.start_link(__MODULE__, arg)
        end

        @impl true
        def init(_arg) do
          {:ok, nil}
        end

        @impl true
        def handle_message(message, state) do
          # Do some processing with the message.
          {:ack, state}
        end
      end

  You can then place your Pull Consumer in a supervision tree. Remember that you need to have the
  `Gnat.ConnectionSupervisor` set up.

      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            # Create NATS connection
            {Gnat.ConnectionSupervisor, ...},
            # Start NATS Jetstream Pull Consumer
            MyApp.PullConsumer,
          ]
          opts = [strategy: :one_for_one]
          Supervisor.start_link(children, opts)
        end
      end

  ## Options

  On top of standard `GenServer` options passed to `start*` functions, this module adds several
  new options which you have to consider.

  Following options **must** be provided. Omitting this options will cause the process to raise
  errors upon initialization:

  * `:connection_name` - Gnat connection or `Gnat.ConnectionSupervisor` name/PID.
  * `:stream_name` - name of an existing string the consumer will consume messages from.
  * `:consumer_name` - name of an existing consumer pointing at the stream.

  You can also pass the optional ones:

  * `:connection_retry_timeout` - a duration in milliseconds after which the PullConsumer which
    failed to establish NATS connection retries, defaults to `1000`
  * `:connection_retries` - a number of attempts the PullConsumer will make to establish the NATS
    connection. When this value is exceeded, the pull consumer stops with the `:timeout` reason,
    defaults to `10`

  ## Dynamic Options

  It is possible that business case requires determining some of the options dynamically depending
  on pull consumer's init argument. To do so, one could pass dynamic options as third argument
  to the `start_link/3` function:

      defmodule MyApp.PullConsumer do
        use Jetstream.PullConsumer, connection_name: :gnat

        def start_link(%{counter: counter}) do
          Jetstream.PullConsumer.start_link(__MODULE__, arg,
            stream_name: "TEST_STREAM_#\{counter}",
            consumer_name: "TEST_CONSUMER_#\{counter}"
          )
        end

        ...
      end

  ## How to supervise

  A `PullConsumer` is most commonly started under a supervision tree. When we invoke
  `use Jetstream.PullConsumer`, it automatically defines a `child_spec/1` function that allows us
  to start the pull consumer directly under a supervisor. To start a pull consumer under
  a supervisor with an initial argument of :example, one may do:

      children = [
        {MyPullConsumer, :example}
      ]
      Supervisor.start_link(children, strategy: :one_for_all)

  While one could also simply pass the `MyPullConsumer` as a child to the supervisor, such as:

      children = [
        MyPullConsumer # Same as {MyPullConsumer, []}
      ]
      Supervisor.start_link(children, strategy: :one_for_all)

  A common approach is to use a keyword list, which allows setting init argument and server options,
  for example:

      def start_link(opts) do
        {initial_state, opts} = Keyword.pop(opts, :initial_state, nil)
        Jetstream.PullConsumer.start_link(__MODULE__, initial_state, opts)
      end

  and then you can use `MyPullConsumer`, `{MyPullConsumer, name: :my_consumer}` or even
  `{MyPullConsumer, initial_state: :example, name: :my_consumer}` as a child specification.

  `use Jetstream.PullConsumer` also accepts a list of options which configures the child
  specification and therefore how it runs under a supervisor. The generated `child_spec/1` can be
  customized with the following options:

    * `:id` - the child specification identifier, defaults to the current module
    * `:restart` - when the child should be restarted, defaults to `:permanent`
    * `:shutdown` - how to shut down the child, either immediately or by giving it time to shut down

  For example:

      use Jetstream.PullConsumer, restart: :transient, shutdown: 10_000

  See the "Child specification" section in the `Supervisor` module for more detailed information.
  The `@doc` annotation immediately preceding `use Jetstream.PullConsumer` will be attached to
  the generated `child_spec/1` function.

  ## Name registration

  A pull consumer is bound to the same name registration rules as GenServers.
  Read more about it in the `GenServer` documentation.
  """

  @doc """
  Invoked when the server is started. `start_link/3` or `start/3` will block until it returns.

  `init_arg` is the argument term (second argument) passed to `start_link/3`.

  See `c:Connection.init/1` for more details.
  """
  @callback init(init_arg :: term) ::
              {:ok, state :: term()}
              | :ignore
              | {:stop, reason :: any}

  @doc """
  Invoked to synchronously process a message pulled by the consumer.
  Depending on the value it returns, the acknowledgement is or is not sent.

  ## ACK actions

  Possible ACK actions values explained:

  * `:ack` - acknowledges the message was handled and requests delivery of the next message to
    the reply subject.
  * `:nack` - signals that the message will not be processed now and processing can move onto
    the next message, NAK'd message will be retried.
  * `:noreply` - nothing is sent. You may send later asynchronously an ACK or NACK message using
    the `Jetstream.ack/1` or `Jetstream.nack/1` functions.

  ## Example

      def handle_message(message, state) do
        IO.inspect(message)
        {:ack, state}
      end

  """
  @callback handle_message(message :: Jetstream.message(), state :: term()) ::
              {ack_action, new_state}
            when ack_action: :ack | :nack | :noreply, new_state: term()

  @typedoc """
  The pull consumer reference.
  """
  @type consumer :: GenServer.server()

  @typedoc """
  Option values used by the `start*` functions.
  """
  @type option ::
          {:connection_name, GenServer.server()}
          | {:stream_name, String.t()}
          | {:consumer_name, String.t()}
          | {:connection_retry_timeout, non_neg_integer()}
          | {:connection_retries, non_neg_integer()}
          | GenServer.option()

  @typedoc """
  Options used by the `start*` functions.
  """
  @type options :: [option()]

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour Jetstream.PullConsumer

      unless Module.has_attribute?(__MODULE__, :doc) do
        @doc """
        Returns a specification to start this module under a supervisor.

        See the "Child specification" section in the `Supervisor` module for more detailed
        information.
        """
      end

      @spec child_spec(arg :: Jetstream.PullConsumer.options()) :: Supervisor.child_spec()
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      defoverridable child_spec: 1
    end
  end

  @doc """
  Starts a pull consumer linked to the current process with the given function.

  This is often used to start the pull consumer as part of a supervision tree.

  Once the server is started, the `c:init/1` function of the given `module` is called with
  `init_arg` as its argument to initialize the server. To ensure a synchronized start-up procedure,
  this function does not return until `c:init/1` has returned.

  See `GenServer.start_link/3` for more details.
  """
  @spec start_link(module(), init_arg :: term(), options()) :: GenServer.on_start()
  def start_link(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    do_start(:link, module, init_arg, options)
  end

  @doc """
  Starts a `Jetstream.PullConsumer` process without links (outside of a supervision tree).

  See `start_link/3` for more information.
  """
  @spec start(module(), init_arg :: term(), options()) :: GenServer.on_start()
  def start(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    do_start(:nolink, module, init_arg, options)
  end

  defp do_start(link, module, init_arg, gen_options) do
    {options, gen_options} = pop_options!(gen_options)

    init_arg = %{module: module, init_arg: init_arg, options: options}

    case link do
      :nolink -> Connection.start(Jetstream.PullConsumer.Server, init_arg, gen_options)
      :link -> Connection.start_link(Jetstream.PullConsumer.Server, init_arg, gen_options)
    end
  end

  defmacrop require_option!(name, value) do
    quote location: :keep, bind_quoted: [name: name, value: value] do
      case value do
        nil -> raise "Required Jetstream PullConsumer option #{inspect(name)} is missing."
        value -> value
      end
    end
  end

  defp pop_options!(gen_options) do
    {connection_name, gen_options} = Keyword.pop(gen_options, :connection_name, nil)
    require_option!(:connection_name, connection_name)

    {stream_name, gen_options} = Keyword.pop(gen_options, :stream_name, nil)
    require_option!(:stream_name, stream_name)

    {consumer_name, gen_options} = Keyword.pop(gen_options, :consumer_name, nil)
    require_option!(:consumer_name, consumer_name)

    {connection_retry_timeout, gen_options} =
      Keyword.pop(gen_options, :connection_retry_timeout, 1000)

    {connection_retries, gen_options} = Keyword.pop(gen_options, :connection_retries, 10)

    options = %{
      connection_name: connection_name,
      stream_name: stream_name,
      consumer_name: consumer_name,
      connection_retry_timeout: connection_retry_timeout,
      connection_retries: connection_retries
    }

    {options, gen_options}
  end

  @doc """
  Closes the pull consumer and stops underlying process.

  ## Example

      {:ok, consumer} =
        PullConsumer.start_link(ExamplePullConsumer,
          connection_name: :gnat,
          stream_name: "TEST_STREAM",
          consumer_name: "TEST_CONSUMER"
        )

      :ok = PullConsumer.close(consumer)

  """
  @spec close(consumer :: consumer()) :: :ok
  def close(consumer) do
    Connection.call(consumer, :close)
  end
end

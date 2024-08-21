defmodule Anoma.Node.Transport.TCPConnection do
  @moduledoc """
  I am TCPConnection Engine.

  I manage an individual TCP connection and stream.

  I can run in two modes: either I can act as a client, initiating a connection
  to a server, or as a listener, waiting to accept and then accepting a
  connection on a server.
  In the latter case, since accepting the connection marks me as its owner and
  handoff is complicated, I start up a new listener once I accept a connection.


  ### How I work

  A good general overview of how I work at a high level with my
  environment can be seen in `Anoma.Node.Transport.TCPServer`.

  The diagrams I'll include in my documentation are more focused on my D2D inner workings

  ```mermaid
  graph LR;

  %% Role Setup
  TCPConnection:::TCPConnection
  Child_Process(Child Connection):::Listener
  Listener1(A TCP Listener Node):::Listener
  Transport(Our Transport):::Transport


  %% Note Relationship between TCPConnection and the outside
  :accept_connection -- start_listener --- Child_Process
  Transport -- handshake ---Listener1


  subgraph TCPConnection
    direction TB
    :accept_connection:::Listener
    :init_connection:::Client

    init -- is a Listener -->:accept_connection
    init -- is a Client -->:init_connection

    :accept_connection -- ":gen_tcp.accept" --- :accept_connection


    :accept_connection & :init_connection -- failure --> sd(Shut down)
    :accept_connection & :init_connection -- successful --> Standby

  end


  %% Note Relationship between TCPConnection and the outside
  :init_connection -- ":gen_tcp.connect" --- Listener1
  :init_connection -- begin handshake ---Transport



  %% Styling
  classDef Listener      fill:#add8e6
  classDef TCPConnection fill:#fff9ca
  classDef Client        fill:#e6add8
  classDef Transport     fill:#d8e6ad


  %% Linking

  click Transport "https://anoma.github.io/anoma/Anoma.Node.Transport.html"
  click init "https://anoma.github.io/anoma/Anoma.Node.Transport.TCPConnection.html#init/1"
  click Child_Process "https://anoma.github.io/anoma/Anoma.Node.Transport.TCPConnection.html"
  click :init_connection "https://anoma.github.io/anoma/Anoma.Node.Transport.TCPConnection.html"
  click :accept_connection "https://anoma.github.io/anoma/Anoma.Node.Transport.TCPConnection.html"
  click Listener1 "https://anoma.github.io/anoma/Anoma.Node.Transport.TCPConnection.html"
  ```

  This diagram uses the following Color Codes:
  1. Blue Nodes represent TCP Connections running in the listening mode.
  2. Purple Node represents TCP Connection running in the client mode.
  3. Green Nodes is the Transport Server.

  We can see that my behavior differs drastically if I'm in the client
  mode or a listening mode.

  If I'm listening then I'll block calling `:gen_tcp.accept/1`, if
  that works, then we create another
  `Anoma.Node.Transport.TCPConnection`. If not we shutdown

  Likewise for the client behavior, we try using
  `:gen_tcp.connect/3`. If this fails then we shutdown.

  If we do successfully connect, then we begin the handshake process,
  which is best explained in a diagram in `Anoma.Node.Transport`.

  """

  alias Anoma.Node.Router
  alias Anoma.Node.Transport
  alias __MODULE__

  require Logger
  use Transport.Connection
  use TypedStruct

  typedstruct do
    @typedoc """
    I am the type of the TCPConnection Engine.

    ### Fields
    - `:router` - The address of the Router Engine that the Transport Engine
      instance serves to.
    - `:transport` - The address of the Transport server managing the
      connection.
    - `:connection_pool` - The supervisor which manages the connection pool that
      the TCPConnection Engine instance belongs to.
    - `:mode` - The mode of the connection: client or listener.
    - `:listener` - The listening socket that accepts incoming connection
      requests.  Must be provided in the listener mode. Default: nil
    - `:conn` - Socket of the established connection for the listener mode.
      Initially, nil. Filled in as soon as a connection is established.
    """
    field(:router, Router.addr())
    field(:transport, Router.addr())
    field(:connection_pool, Supervisor.supervisor())
    field(:mode, :client | :listener)
    field(:listener, reference() | nil)
    field(:conn, reference() | nil)
  end

  # TODO: annoyingly, we can't initiate tcp connections asynchronously, so it's
  # not clear how to cleanly abort the connection attempt
  # still, we can initiate the connection in a continue, so we don't block
  # whoever started us

  @doc """
  I am the initialization function for TCPConnection Engine.

  ### Pattern-Matching Variations

  - `init({:client, router, transport, address, connection_pool})` -
    create a TCP connection as a client.

  - `init({:listener, router, transport, listener, connection_pool})` -
    create a TCP connection as a listener.
  """
  @spec init(
          {:client, Router.addr(), Router.addr(), Transport.transport_addr(),
           Supervisor.supervisor()}
        ) :: {:ok, t(), {:continue, {:init_connection, any()}}}
  def init({:client, router, transport, address, connection_pool}) do
    {:ok,
     %TCPConnection{
       router: router,
       transport: transport,
       connection_pool: connection_pool,
       mode: :client
     }, {:continue, {:init_connection, address}}}
  end

  @spec init(
          {:listener, Router.addr(), Router.addr(), reference(),
           Supervisor.supervisor()}
        ) :: {:ok, t(), {:continue, :accept_connection}}
  def init({:listener, router, transport, listener, connection_pool}) do
    {:ok,
     %TCPConnection{
       router: router,
       transport: transport,
       connection_pool: connection_pool,
       mode: :listener,
       listener: listener
     }, {:continue, :accept_connection}}
  end

  ############################################################
  #                    Genserver Behavior                    #
  ############################################################

  def handle_continue({:init_connection, address}, s) do
    res =
      case address do
        {:unix, path} ->
          :gen_tcp.connect({:local, path}, 0, mode: :binary)

        {:tcp, host, port} ->
          :gen_tcp.connect(to_charlist(host), port, mode: :binary)
      end

    case res do
      {:ok, conn} ->
        Transport.new_connection(
          s.transport,
          Transport.transport_type(address)
        )

        {:noreply, %{s | conn: conn}}

      err ->
        die(s, inspect(err))
    end
  end

  def handle_continue(:accept_connection, s) do
    res = :gen_tcp.accept(s.listener)
    start_listener(s)

    case res do
      {:ok, conn} ->
        # need to figure out if unix or tcp
        Transport.new_connection(s.transport, :unix)
        {:noreply, %{s | conn: conn}}

      err ->
        die(s, inspect(err))
    end
  end

  def handle_cast({:send, msg}, _, s) do
    case :gen_tcp.send(s.conn, msg) do
      {:error, error} -> die(s, inspect(error))
      _ -> {:noreply, s}
    end
  end

  def handle_cast(:shutdown, _, s) do
    :gen_tcp.shutdown(s.conn, :read_write)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, _}, s) do
    die(s, "connection shutdown")
  end

  def handle_info({:tcp, _, data}, s) do
    Transport.receive_chunk(s.transport, data)
    {:noreply, s}
  end

  ############################################################
  #                  Genserver Implementation                #
  ############################################################

  defp die(s, reason) do
    Transport.disconnected(s.transport, reason)
    {:stop, :normal, s}
  end

  defp start_listener(s) do
    Router.start_engine(
      s.router,
      __MODULE__,
      {:listener, s.router, s.transport, s.listener, s.connection_pool},
      supervisor: s.connection_pool
    )
  end
end

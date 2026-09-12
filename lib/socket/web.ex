#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                    Version 2, December 2004
#
#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
#  0. You just DO WHAT THE FUCK YOU WANT TO.

defmodule Socket.Web do
  @moduledoc ~S"""
  This module implements RFC 6455 WebSockets.

  ## Client example

      socket = Socket.Web.connect! "echo.websocket.org"
      socket |> Socket.Web.send! { :text, "test" }
      socket |> Socket.Web.recv! # => {:text, "test"}

  ## Server example

      server = Socket.Web.listen! 80
      client = server |> Socket.Web.accept!

      # here you can verify if you want to accept the request or not, call
      # `Socket.Web.close!` if you don't want to accept it, or else call
      # `Socket.Web.accept!`
      client |> Socket.Web.accept!

      # echo the first message
      client |> Socket.Web.send!(client |> Socket.Web.recv!)

  """

  import Kernel, except: [length: 1, send: 2]
  alias __MODULE__, as: W

  @type error :: Socket.TCP.error() | Socket.SSL.error()

  @type packet ::
          {:text, String.t()}
          | {:binary, binary}
          | {:fragmented, :text | :binary | :continuation | :end, binary}
          | :close
          | {:close, atom, binary}
          | {:ping, binary}
          | {:pong, binary}

  @compile {:inline, opcode: 1, close_code: 1, key: 1, length: 1, forge: 2}

  Enum.each([text: 0x1, binary: 0x2, close: 0x8, ping: 0x9, pong: 0xA], fn {name, code} ->
    defp opcode(unquote(name)), do: unquote(code)
    defp opcode(unquote(code)), do: unquote(name)
  end)

  Enum.each(
    [
      normal: 1000,
      going_away: 1001,
      protocol_error: 1002,
      unsupported_data: 1003,
      reserved: 1004,
      no_status_received: 1005,
      abnormal: 1006,
      invalid_payload: 1007,
      policy_violation: 1008,
      message_too_big: 1009,
      mandatory_extension: 1010,
      internal_error: 1011,
      handshake: 1015
    ],
    fn {name, code} ->
      defp close_code(unquote(name)), do: unquote(code)
      defp close_code(unquote(code)), do: unquote(name)
    end
  )

  # Decoding must accept a code outside the registered set: RFC 6455 §7.4.2
  # leaves 3000-4999 to applications and libraries, and raising on one turns a
  # peer's clean close into a crash of the reader process.
  defp close_code(code) when is_integer(code), do: code

  defmacrop known?(n) do
    quote do
      unquote(n) in [0x1, 0x2, 0x8, 0x9, 0xA]
    end
  end

  defmacrop data?(n) do
    quote do
      unquote(n) in 0x1..0x7 or unquote(n) in [:text, :binary]
    end
  end

  defmacrop control?(n) do
    quote do
      unquote(n) in 0x8..0xF or unquote(n) in [:close, :ping, :pong]
    end
  end

  defstruct socket: nil,
            version: 13,
            path: nil,
            origin: nil,
            protocols: [],
            extensions: nil,
            key: nil,
            mask: false,
            active_pid: nil,
            target_pid: nil,
            headers: %{},
            max_size: :infinity

  @type max_size :: non_neg_integer | :infinity

  @type t :: %Socket.Web{
          socket: term,
          version: 13,
          path: String.t(),
          origin: String.t(),
          protocols: [String.t()],
          extensions: [String.t()],
          key: String.t(),
          mask: boolean,
          active_pid: pid(),
          target_pid: pid(),
          max_size: max_size
        }

  @spec max_size(Keyword.t(), max_size) :: max_size
  defp max_size(options, default) do
    case Keyword.get(options, :max_size, default) do
      :infinity ->
        :infinity

      size when is_integer(size) and size >= 0 ->
        size

      other ->
        raise ArgumentError,
              "max_size must be a non-negative integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp within?(_size, :infinity), do: true
  defp within?(size, max_size), do: size <= max_size

  # What a handshake may carry: header lines up to 8 KiB, the bound nginx and
  # Apache apply, and at most 100 of them. Without an explicit line size inet
  # refuses any line longer than its receive buffer, about 1.4 KiB, which a
  # cookie or a bearer token exceeds.
  @max_line 8192
  @max_headers 100

  @spec headers(%{String.t() => String.t()}, Socket.t(), Keyword.t(), non_neg_integer) ::
          {:ok, %{String.t() => String.t()}} | {:error, term}
  defp headers(acc, socket, options, count \\ 0)

  defp headers(_acc, _socket, _options, count) when count >= @max_headers do
    {:error, :too_many_headers}
  end

  defp headers(acc, socket, options, count) do
    case socket |> Socket.Stream.recv(options) do
      {:ok, {:http_header, _, name, _, value}} ->
        name = if is_atom(name), do: Atom.to_string(name), else: name
        acc |> Map.put(String.downcase(name), value) |> headers(socket, options, count + 1)

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, _} ->
        {:error, :malformed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp headers!(socket, options) do
    case headers(%{}, socket, options) do
      {:ok, headers} -> headers
      {:error, :too_many_headers} -> raise RuntimeError, message: "too many headers"
      {:error, :malformed} -> raise RuntimeError, message: "malformed handshake"
      {:error, reason} -> raise Socket.Error, reason: reason
    end
  end

  # RFC 6455 §4.2.1: 16 random bytes, in base64.
  defp key?(key) do
    match?({:ok, <<_::128>>}, Base.decode64(key))
  end

  defp http_mode!(socket), do: Socket.TCP.options!(socket, packet: :http_bin, size: @max_line)
  defp raw_mode!(socket), do: Socket.TCP.options!(socket, packet: :raw, size: 0)

  # RFC 7230 §6.7: `Connection` lists tokens, and `Upgrade` is one of them.
  defp upgrade?(headers) do
    String.downcase(headers["upgrade"] || "") == "websocket" and
      "upgrade" in tokens(headers["connection"])
  end

  defp tokens(nil), do: []

  defp tokens(value),
    do: value |> String.downcase() |> String.split(",") |> Enum.map(&String.trim/1)

  # A CR or LF inside a value written on the request line or in a header would
  # end that line and start another: header injection.
  defp clean!(nil), do: nil

  defp clean!(value) do
    if value |> to_string() |> String.contains?(["\r", "\n"]) do
      raise ArgumentError, "a handshake value cannot contain CR or LF: #{inspect(value)}"
    end

    value
  end

  # RFC 6455 §4.2.2: a request the server turns down gets an HTTP status.
  defp reject!(socket, status, message, headers \\ []) do
    socket
    |> Socket.Stream.send([
      "HTTP/1.1 #{status}\r\n",
      headers,
      "Connection: close\r\nContent-Length: 0\r\n\r\n"
    ])

    raise RuntimeError, message: message
  end

  # A handshake that fails half-way must not leave its socket behind: the
  # process that accepts or connects usually lives on.
  defp closing_on_error(socket, fun) do
    fun.()
  rescue
    e ->
      Socket.close(socket)
      reraise e, __STACKTRACE__
  end

  @spec key(String.t()) :: String.t()
  defp key(value) do
    :crypto.hash(:sha, value <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> :base64.encode()
  end

  # Active Web socket process function.
  #
  # This loop is the only reader of the socket and it runs under a bare spawn/1,
  # so every shape recv/2 can return has to be matched here: an unmatched one
  # raises CaseClauseError, kills this process and takes a perfectly healthy
  # connection down with it. The clauses below cover the whole of `packet()` —
  # binary frames, the fragmented sequence of §5.4, pongs, and every close code,
  # not only the abnormal one.
  #
  # `fragments` accumulates the payload of a fragmented message, in reverse, and
  # `size` is its byte count so far: the limit binds the message, not the frame.
  defp active_websocket_process(self, fragments \\ [], size \\ 0) do
    case recv(self) do
      # ---- unfragmented data ------------------------------------------------
      {:ok, {:text, data}} ->
        notify(self, {:web, self, data})
        active_websocket_process(self)

      {:ok, {:binary, data}} ->
        notify(self, {:web, self, data})
        active_websocket_process(self)

      # ---- fragmented data (RFC 6455 §5.4) ----------------------------------
      # The final frame is delivered as one message: the owner of a %Socket.Web{}
      # is handed messages, not frames.
      {:ok, {:fragmented, :end, data}} ->
        gather(self, [data | fragments], size + byte_size(data), true)

      {:ok, {:fragmented, :continuation, data}} ->
        gather(self, [data | fragments], size + byte_size(data), false)

      # First frame of a fragmented message (opcode :text or :binary).
      {:ok, {:fragmented, _opcode, data}} ->
        gather(self, [data], byte_size(data), false)

      # ---- control frames ---------------------------------------------------
      # §5.5.3: the pong MUST carry the application data of the ping it answers.
      # Answering with an empty payload makes a peer that matches its own cookie
      # (Kamailio's websocket keep-alive does) conclude the connection is dead.
      {:ok, {:ping, cookie}} ->
        case send(self, {:pong, cookie}) do
          :ok -> active_websocket_process(self, fragments, size)
          {:error, reason} -> closed(self, reason)
        end

      {:ok, {:pong, cookie}} ->
        notify(self, {:web_pong, self, cookie})
        active_websocket_process(self, fragments, size)

      # §5.5.1: a close frame is answered with one, then the transport goes.
      # 1006 is not a frame the peer sent: the transport is already gone.
      {:ok, :close} ->
        drop(self, :normal)
        closed(self, :normal)

      {:ok, {:close, :abnormal, nil}} ->
        closed(self, :abnormal)

      {:ok, {:close, reason, _data}} ->
        drop(self, reason)
        closed(self, reason)

      # ---- transport error, or a peer failure recv/2 already answered --------
      {:error, reason} ->
        closed(self, reason)
    end
  end

  defp gather(self, fragments, size, final?) do
    cond do
      not within?(size, self.max_size) ->
        drop(self, :message_too_big)
        closed(self, :message_too_big)

      final? ->
        notify(self, {:web, self, IO.iodata_to_binary(Enum.reverse(fragments))})
        active_websocket_process(self)

      true ->
        active_websocket_process(self, fragments, size)
    end
  end

  defp notify(%W{target_pid: nil}, _message), do: :ok
  defp notify(%W{target_pid: pid}, message), do: Kernel.send(pid, message)

  # The reason is carried to the owner: a connection that goes away is a
  # diagnostic, and `{:web_closed, socket}` alone said only "gone".
  defp closed(self, reason) do
    notify(self, {:web_closed, self, reason})
    nil
  end

  # RFC 6455 §7.1.7: tell the peer why, then drop the transport. The read side
  # may be out of step with the frame boundaries, so nothing more can be read.
  @peer_failures [:protocol_error, :invalid_payload, :message_too_big]

  defp fail(self, reason) do
    drop(self, reason)
    {:error, reason}
  end

  defp drop(self, reason) do
    close(self, reason, wait: false)
    abort(self)
  end

  @doc """
  Connects to the given address or { address, port } tuple.
  """
  @spec connect({Socket.Address.t(), :inet.port_number()}) :: {:ok, t} | {:error, error}
  def connect({address, port}) do
    connect(address, port, [])
  end

  def connect(address) do
    connect(address, [])
  end

  @doc """
  Connect to the given address or { address, port } tuple with the given
  options or address and port.
  """
  @spec connect(
          {Socket.Address.t(), :inet.port_number()} | Socket.Address.t(),
          Keyword.t() | :inet.port_number()
        ) :: {:ok, t} | {:error, error}
  def connect({address, port}, options) do
    connect(address, port, options)
  end

  def connect(address, options) when options |> is_list do
    connect(address, if(options[:secure], do: 443, else: 80), options)
  end

  def connect(address, port) when port |> is_integer do
    connect(address, port, [])
  end

  @doc """
  Connect to the given address, port and options.

  ## Options

  `:path` sets the path to give the server, `/` by default
  `:origin` sets the Origin header, this is optional
  `:handshake` is the key used for the handshake, this is optional

  You can also pass TCP or SSL options, depending if you're using secure
  websockets or not.
  """
  @spec connect(Socket.Address.t(), :inet.port_number(), Keyword.t()) ::
          {:ok, t} | {:error, error}
  def connect(address, port, options) do
    try do
      {:ok, connect!(address, port, options)}
    rescue
      e in [MatchError] ->
        case e.term do
          {:http_response, _, http_code, http_message} -> {:error, {http_code, http_message}}
          _ -> {:error, "malformed handshake"}
        end

      e in [RuntimeError] ->
        {:error, e.message}

      e in [Socket.Error] ->
        {:error, e.message}
    end
  end

  @doc """
  Connects to the given address or { address, port } tuple, raising if an error
  occurs.
  """
  @spec connect!({Socket.Address.t(), :inet.port_number()}) :: t | no_return
  def connect!({address, port}) do
    connect!(address, port, [])
  end

  def connect!(address) do
    connect!(address, [])
  end

  @doc """
  Connect to the given address or { address, port } tuple with the given
  options or address and port, raising if an error occurs.
  """
  @spec connect!(
          {Socket.Address.t(), :inet.port_number()} | Socket.Address.t(),
          Keyword.t() | :inet.port_number()
        ) :: t | no_return
  def connect!({address, port}, options) do
    connect!(address, port, options)
  end

  def connect!(address, options) when options |> is_list do
    connect!(address, if(options[:secure], do: 443, else: 80), options)
  end

  def connect!(address, port) when port |> is_integer do
    connect!(address, port, [])
  end

  @doc """
  Connect to the given address, port and options, raising if an error occurs.

  ## Options

  `:path` sets the path to give the server, `/` by default
  `:origin` sets the Origin header, this is optional
  `:handshake` is the key used for the handshake, this is optional
  `:headers` are additional headers that will be sent
  `:max_size` bounds the payload accepted from the peer, in bytes, see `recv/2`
  `:timeout` bounds the connection and each step of the handshake, in
  milliseconds

  A value that carries a CR or LF is refused with `ArgumentError`. The
  server's answer may carry at most 100 header lines of 8 KiB each.

  You can also pass TCP or SSL options, depending if you're using secure
  websockets or not.
  """
  @spec connect!(Socket.Address.t(), :inet.port_number(), Keyword.t()) :: t | no_return
  def connect!(address, port, options) do
    {local, global} = arguments(options)

    mod =
      if local[:secure] do
        Socket.SSL
      else
        Socket.TCP
      end

    path = clean!(local[:path] || "/")
    origin = clean!(local[:origin])
    protocols = clean!(local[:protocol])
    extensions = clean!(local[:extensions])
    handshake = :base64.encode(local[:handshake] || "fork the dongles")
    headers = Enum.map(local[:headers] || %{}, fn {k, v} -> [clean!("#{k}: #{v}"), "\r\n"] end)
    max_size = max_size(local, :infinity)

    client = mod.connect!(address, port, global)

    self =
      closing_on_error(client, fn ->
        client |> raw_mode!()

        client
        |> Socket.Stream.send!([
          "GET #{path} HTTP/1.1",
          "\r\n",
          headers,
          "Host: #{Socket.Address.to_uri_host(address)}:#{port}",
          "\r\n",
          if(origin, do: ["Origin: #{origin}", "\r\n"], else: []),
          "Upgrade: websocket",
          "\r\n",
          "Connection: Upgrade",
          "\r\n",
          "Sec-WebSocket-Key: #{handshake}",
          "\r\n",
          if(protocols,
            do: ["Sec-WebSocket-Protocol: #{Enum.join(protocols, ", ")}", "\r\n"],
            else: []
          ),
          if(extensions,
            do: ["Sec-WebSocket-Extensions: #{Enum.join(extensions, ", ")}", "\r\n"],
            else: []
          ),
          "Sec-WebSocket-Version: 13",
          "\r\n",
          "\r\n"
        ])

        client |> http_mode!()
        {:http_response, _, 101, _} = client |> Socket.Stream.recv!(global)
        headers = headers!(client, global)

        unless upgrade?(headers) do
          raise RuntimeError, message: "malformed upgrade response"
        end

        if headers["sec-websocket-version"] && headers["sec-websocket-version"] != "13" do
          raise RuntimeError, message: "unsupported version"
        end

        if headers["sec-websocket-accept"] != key(handshake) do
          raise RuntimeError, message: "wrong key response"
        end

        client |> raw_mode!()

        %Socket.Web{
          socket: client,
          version: 13,
          path: path,
          origin: origin,
          key: handshake,
          mask: true,
          max_size: max_size
        }
      end)

    if local[:mode] == :active do
      target_pid =
        if is_nil(local[:process]) do
          self()
        else
          local[:process]
        end

      process(self, target_pid) |> active(true)
    else
      self
    end
  end

  @doc """
  Listens on the default port (80).
  """
  @spec listen :: {:ok, t} | {:error, error}
  def listen do
    listen([])
  end

  @doc """
  Listens on the given port or with the given options.
  """
  @spec listen(:inet.port_number() | Keyword.t()) :: {:ok, t} | {:error, error}
  def listen(port) when port |> is_integer do
    listen(port, [])
  end

  def listen(options) do
    if options[:secure] do
      listen(443, options)
    else
      listen(80, options)
    end
  end

  @doc """
  Listens on the given port with the given options.

  ## Options

  `:secure` when true it will use SSL sockets
  `:max_size` bounds the payload accepted from every client this listener
  accepts, in bytes, see `recv/2`

  You can also pass TCP or SSL options, depending if you're using secure
  websockets or not.
  """
  @spec listen(:inet.port_number(), Keyword.t()) :: {:ok, t} | {:error, error}
  def listen(port, options) do
    {local, global} = arguments(options)

    mod =
      if local[:secure] do
        Socket.SSL
      else
        Socket.TCP
      end

    case mod.listen(port, global) do
      {:ok, socket} ->
        {:ok, %W{socket: socket, max_size: max_size(local, :infinity)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Listens on the default port (80), raising if an error occurs.
  """
  @spec listen! :: t | no_return
  def listen! do
    listen!([])
  end

  @doc """
  Listens on the given port or with the given options, raising if an error
  occurs.
  """
  @spec listen!(:inet.port_number() | Keyword.t()) :: t | no_return
  def listen!(port) when port |> is_integer do
    listen!(port, [])
  end

  def listen!(options) do
    if options[:secure] do
      listen!(443, options)
    else
      listen!(80, options)
    end
  end

  @doc """
  Listens on the given port with the given options, raising if an error occurs.

  ## Options

  `:secure` when true it will use SSL sockets
  `:max_size` bounds the payload accepted from every client this listener
  accepts, in bytes, see `recv/2`

  You can also pass TCP or SSL options, depending if you're using secure
  websockets or not.
  """
  @spec listen!(:inet.port_number(), Keyword.t()) :: t | no_return
  def listen!(port, options) do
    {local, global} = arguments(options)

    mod =
      if local[:secure] do
        Socket.SSL
      else
        Socket.TCP
      end

    %W{socket: mod.listen!(port, global), max_size: max_size(local, :infinity)}
  end

  @doc """
  If you're calling this on a listening socket, it accepts a new client
  connection.

  If you're calling this on a client socket, it finalizes the acception
  handshake, this separation is done because then you can verify the client can
  connect based on Origin header, path and other things.
  """
  @spec accept(t, Keyword.t()) :: {:ok, t} | {:error, error}
  def accept(self, options \\ []) do
    try do
      {:ok, accept!(self, options)}
    rescue
      MatchError ->
        {:error, "malformed handshake"}

      e in [RuntimeError] ->
        {:error, e.message}

      e in [Socket.Error] ->
        {:error, e.message}
    end
  end

  @doc """
  If you're calling this on a listening socket, it accepts a new client
  connection.

  If you're calling this on a client socket, it finalizes the acception
  handshake, this separation is done because then you can verify the client can
  connect based on Origin header, path and other things.

  `:max_size` bounds the payload accepted from this client, in bytes, see
  `recv/2`. Without it the client inherits the listener's.
  `:timeout` bounds each step of the handshake, in milliseconds

  A request that is not a websocket upgrade is answered with a 400, one that
  asks for another protocol version with a 426, one with more than 100 header
  lines with a 431, and its socket is closed. A line over 8 KiB closes the
  socket without a status: the transport refuses it before anything can be
  sent back.

  In case of error, it raises.
  """
  @spec accept!(t, Keyword.t()) :: t | no_return
  def accept!(socket, options \\ [])

  def accept!(%W{socket: socket, key: nil, max_size: inherited}, options) do
    {local, global} = arguments(options)

    max_size = max_size(local, inherited)
    client = socket |> Socket.accept!(global)

    closing_on_error(client, fn ->
      client |> http_mode!()

      # RFC 6455 §4.2.1: a GET, over HTTP/1.1 or higher.
      path =
        case client |> Socket.Stream.recv(global) do
          {:ok, {:http_request, :GET, {:abs_path, path}, {1, minor}}} when minor >= 1 ->
            path

          {:ok, _} ->
            reject!(client, "400 Bad Request", "malformed upgrade request")

          # On a line over @max_line, inet has dropped the connection already:
          # no status can follow.
          {:error, :emsgsize} ->
            raise RuntimeError, message: "request line too long"

          {:error, reason} ->
            raise Socket.Error, reason: reason
        end

      headers =
        case headers(%{}, client, global) do
          {:ok, headers} ->
            headers

          {:error, :too_many_headers} ->
            reject!(client, "431 Request Header Fields Too Large", "too many headers")

          {:error, :emsgsize} ->
            raise RuntimeError, message: "header line too long"

          {:error, :malformed} ->
            reject!(client, "400 Bad Request", "malformed handshake")

          {:error, reason} ->
            raise Socket.Error, reason: reason
        end

      unless upgrade?(headers) do
        reject!(client, "400 Bad Request", "malformed upgrade request")
      end

      unless headers["sec-websocket-key"] do
        reject!(client, "400 Bad Request", "missing key")
      end

      unless key?(headers["sec-websocket-key"]) do
        reject!(client, "400 Bad Request", "invalid key")
      end

      unless headers["sec-websocket-version"] == "13" do
        reject!(
          client,
          "426 Upgrade Required",
          "unsupported version",
          "Sec-WebSocket-Version: 13\r\n"
        )
      end

      protocols =
        if p = headers["sec-websocket-protocol"] do
          String.split(p, ~r/\s*,\s*/)
        end

      extensions =
        if e = headers["sec-websocket-extensions"] do
          String.split(e, ~r/\s*,\s*/)
        end

      client |> raw_mode!()

      %Socket.Web{
        socket: client,
        origin: headers["origin"],
        path: path,
        version: 13,
        key: headers["sec-websocket-key"],
        protocols: protocols,
        extensions: extensions,
        headers: headers,
        max_size: max_size
      }
    end)
  end

  def accept!(%W{socket: socket, key: key} = self, options) do
    {local, _} = arguments(options)

    extensions = clean!(local[:extensions])
    protocol = clean!(local[:protocol])

    socket |> Socket.packet!(:raw)

    socket
    |> Socket.Stream.send!([
      "HTTP/1.1 101 Switching Protocols",
      "\r\n",
      "Upgrade: websocket",
      "\r\n",
      "Connection: Upgrade",
      "\r\n",
      "Sec-WebSocket-Accept: #{key(key)}",
      "\r\n",
      "Sec-WebSocket-Version: 13",
      "\r\n",
      if(extensions,
        do: ["Sec-WebSocket-Extensions: ", Enum.join(extensions, ", "), "\r\n"],
        else: []
      ),
      if(protocol, do: ["Sec-WebSocket-Protocol: ", protocol, "\r\n"], else: []),
      "\r\n"
    ])

    %W{self | max_size: max_size(local, self.max_size)}
  end

  @doc """
  Extract websocket specific options from the rest.
  """
  @spec arguments(Keyword.t()) :: {Keyword.t(), Keyword.t()}
  def arguments(options) do
    options =
      Enum.group_by(options, fn
        {:secure, _} -> true
        {:path, _} -> true
        {:origin, _} -> true
        {:protocol, _} -> true
        {:extensions, _} -> true
        {:handshake, _} -> true
        {:headers, _} -> true
        {:process, _} -> true
        {:max_size, _} -> true
        # active websocket will be reimplemented
        {:mode, _} -> true
        _ -> false
      end)

    {Map.get(options, true, []), Map.get(options, false, [])}
  end

  @doc """
  Return the local address and port.
  """
  @spec local(t) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, error}
  def local(%W{socket: socket}) do
    socket |> Socket.local()
  end

  @doc """
  Return the local address and port, raising if an error occurs.
  """
  @spec local!(t) :: {:inet.ip_address(), :inet.port_number()} | no_return
  def local!(%W{socket: socket}) do
    socket |> Socket.local!()
  end

  @doc """
  Return the remote address and port.
  """
  @spec remote(t) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, error}
  def remote(%W{socket: socket}) do
    socket |> Socket.remote()
  end

  @doc """
  Return the remote address and port, raising if an error occurs.
  """
  @spec remote!(t) :: {:inet.ip_address(), :inet.port_number()} | no_return
  def remote!(%W{socket: socket}) do
    socket |> Socket.remote!()
  end

  @spec mask(binary) :: {integer, binary}
  defp mask(data) do
    case :crypto.strong_rand_bytes(4) do
      <<key::32>> ->
        {key, unmask(key, data)}
    end
  end

  @spec mask(integer, binary) :: {integer, binary}
  defp mask(key, data) do
    {key, unmask(key, data)}
  end

  @spec unmask(integer, binary) :: binary
  defp unmask(key, data) do
    unmask(key, data, <<>>)
  end

  # we have to XOR the key with the data iterating over the key when there's
  # more data, this means we can optimize and do it 4 bytes at a time and then
  # fallback to the smaller sizes
  defp unmask(key, <<data::32, rest::binary>>, acc) do
    unmask(key, rest, <<acc::binary, Bitwise.bxor(data, key)::32>>)
  end

  defp unmask(key, <<data::24>>, acc) do
    <<key::24, _::8>> = <<key::32>>

    unmask(key, <<>>, <<acc::binary, Bitwise.bxor(data, key)::24>>)
  end

  defp unmask(key, <<data::16>>, acc) do
    <<key::16, _::16>> = <<key::32>>

    unmask(key, <<>>, <<acc::binary, Bitwise.bxor(data, key)::16>>)
  end

  defp unmask(key, <<data::8>>, acc) do
    <<key::8, _::24>> = <<key::32>>

    unmask(key, <<>>, <<acc::binary, Bitwise.bxor(data, key)::8>>)
  end

  defp unmask(_, <<>>, acc) do
    acc
  end

  # The payload of a frame whose first two bytes have been read. The announced
  # length is checked against `max_size` before a single byte of payload is
  # asked for, so an oversized announcement costs nothing.
  @spec payload(t, boolean, 0..127, max_size, Keyword.t()) :: {:ok, binary} | {:error, error}
  defp payload(%W{socket: socket, version: 13}, masked?, length, max_size, options) do
    with {:ok, length} <- payload_length(socket, length, options),
         {:ok, length} <- bounded(length, max_size) do
      unmasked(socket, masked?, length, options)
    end
  end

  # RFC 6455 §5.2: the most significant bit of a 64-bit length MUST be 0.
  defp payload_length(socket, 127, options) do
    case read(socket, 8, options) do
      {:ok, <<0::1, length::63>>} -> {:ok, length}
      {:ok, _} -> {:error, :protocol_error}
      error -> error
    end
  end

  defp payload_length(socket, 126, options) do
    case read(socket, 2, options) do
      {:ok, <<length::16>>} -> {:ok, length}
      error -> error
    end
  end

  defp payload_length(_socket, length, _options), do: {:ok, length}

  defp bounded(length, max_size) do
    if within?(length, max_size), do: {:ok, length}, else: {:error, :message_too_big}
  end

  defp unmasked(socket, false, length, options), do: read(socket, length, options)

  defp unmasked(socket, true, length, options) do
    with {:ok, <<key::32>>} <- read(socket, 4, options),
         {:ok, data} <- read(socket, length, options) do
      {:ok, unmask(key, data)}
    end
  end

  # Exactly `n` bytes, or an error. `Socket.Stream.recv/3` turns a peer that
  # went away into `{:ok, nil}`; inside a frame that is a truncated frame.
  defp read(_socket, 0, _options), do: {:ok, <<>>}

  defp read(socket, n, options) do
    case Socket.Stream.recv(socket, n, options) do
      {:ok, nil} -> {:error, :closed}
      other -> other
    end
  end

  defmacrop on_success(result, max_size, options) do
    quote do
      case payload(var!(self), var!(mask) == 1, var!(length), unquote(max_size), unquote(options)) do
        {:ok, var!(data)} ->
          {:ok, unquote(result)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # RFC 6455 §5.5.1: a close payload is empty or starts with a 2-byte code.
  defp control(:ping, data), do: {:ok, {:ping, data}}
  defp control(:pong, data), do: {:ok, {:pong, data}}
  defp control(:close, <<>>), do: {:ok, :close}
  defp control(:close, <<code::16, rest::binary>>), do: {:ok, {:close, close_code(code), rest}}
  defp control(:close, _), do: {:error, :protocol_error}

  @doc """
  Receive a packet from the websocket.

  ## Options

  `:timeout` bounds the wait, in milliseconds, `:infinity` by default
  `:max_size` bounds the payload of the frame, in bytes; it overrides the
  `:max_size` the socket was opened with, `:infinity` by default

  The limit is checked against the length the peer announces, before any of
  the payload is read.

  A frame over the limit, a malformed one, or text that is not UTF-8 fails
  the connection (RFC 6455 §7.1.7): the peer is sent a close frame with the
  matching status code, 1009, 1002 or 1007, the transport is closed, and the
  call returns `{:error, :message_too_big}`, `{:error, :protocol_error}` or
  `{:error, :invalid_payload}`.

  In passive mode the limit binds each frame. A caller that reassembles a
  fragmented message has to bound the sum. In active mode the reader does,
  and a message over the limit fails the connection the same way.
  """
  @spec recv(t, Keyword.t()) :: {:ok, packet} | {:error, error}
  def recv(self, options \\ [])

  def recv(%W{version: 13} = self, options) do
    case frame(self, options) do
      {:error, reason} when reason in @peer_failures -> fail(self, reason)
      other -> other
    end
  end

  defp frame(%W{socket: socket} = self, options) do
    max_size = max_size(options, self.max_size)
    # §5.1: a client masks every frame, a server none.
    masked = if self.mask, do: 0, else: 1

    case socket |> Socket.Stream.recv(2, options) do
      {:ok, <<_::8, mask::1, _::7>>} when mask != masked ->
        {:error, :protocol_error}

      # a non fragmented message packet
      {:ok, <<1::1, 0::3, opcode::4, mask::1, length::7>>} when known?(opcode) and data?(opcode) ->
        case on_success({opcode(opcode), data}, max_size, options) do
          {:ok, {:text, data}} = result ->
            if String.valid?(data) do
              result
            else
              {:error, :invalid_payload}
            end

          {:ok, {:binary, _}} = result ->
            result

          {:error, reason} ->
            {:error, reason}
        end

      # beginning of a fragmented packet
      {:ok, <<0::1, 0::3, opcode::4, mask::1, length::7>>}
      when known?(opcode) and not control?(opcode) ->
        {:fragmented, opcode(opcode), data} |> on_success(max_size, options)

      # a fragmented continuation
      {:ok, <<0::1, 0::3, 0::4, mask::1, length::7>>} ->
        {:fragmented, :continuation, data} |> on_success(max_size, options)

      # final fragmented packet
      {:ok, <<1::1, 0::3, 0::4, mask::1, length::7>>} ->
        {:fragmented, :end, data} |> on_success(max_size, options)

      # control packet, RFC 6455 §5.5: at most 125 bytes, never fragmented
      {:ok, <<1::1, 0::3, opcode::4, mask::1, length::7>>}
      when known?(opcode) and control?(opcode) and length <= 125 ->
        case payload(self, mask == 1, length, :infinity, options) do
          {:ok, data} -> control(opcode(opcode), data)
          error -> error
        end

      {:ok, nil} ->
        # 1006 is reserved for connection closed with no close frame
        # https://tools.ietf.org/html/rfc6455#section-7.4.1
        {:ok, {:close, close_code(1006), nil}}

      {:ok, _} ->
        {:error, :protocol_error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Receive a packet from the websocket, raising if an error occurs.
  """
  @spec recv!(t, Keyword.t()) :: packet | no_return
  def recv!(self, options \\ []) do
    case recv(self, options) do
      {:ok, packet} ->
        packet

      {:error, :protocol_error} ->
        raise RuntimeError, message: "protocol error"

      {:error, code} ->
        raise Socket.Error, reason: code
    end
  end

  @spec length(binary) :: binary
  defp length(data) when byte_size(data) <= 125 do
    <<byte_size(data)::7>>
  end

  defp length(data) when byte_size(data) <= 65_535 do
    <<126::7, byte_size(data)::16>>
  end

  defp length(data) when byte_size(data) <= 18_446_744_073_709_551_616 do
    <<127::7, byte_size(data)::64>>
  end

  @spec forge(nil | boolean | integer, binary) :: binary
  defp forge(mask, data) when mask in [nil, false] do
    <<0::1, length(data)::bitstring, data::bitstring>>
  end

  defp forge(true, data) do
    {key, data} = mask(data)

    <<1::1, length(data)::bitstring, key::32, data::bitstring>>
  end

  defp forge(key, data) do
    {key, data} = mask(key, data)

    <<1::1, length(data)::bitstring, key::32, data::bitstring>>
  end

  @doc """
  Send a packet to the websocket.
  """
  @spec send(t, packet) :: :ok | {:error, error}
  @spec send(t, packet, Keyword.t()) :: :ok | {:error, error}
  def send(self, packet, options \\ [])

  def send(%W{socket: socket, version: 13, mask: mask}, {opcode, data}, options)
      when opcode != :close do
    mask = if Keyword.has_key?(options, :mask), do: options[:mask], else: mask

    socket |> Socket.Stream.send(<<1::1, 0::3, opcode(opcode)::4, forge(mask, data)::binary>>)
  end

  def send(%W{socket: socket, version: 13, mask: mask}, {:fragmented, :end, data}, options) do
    mask = if Keyword.has_key?(options, :mask), do: options[:mask], else: mask

    socket |> Socket.Stream.send(<<1::1, 0::3, 0::4, forge(mask, data)::binary>>)
  end

  def send(
        %W{socket: socket, version: 13, mask: mask},
        {:fragmented, :continuation, data},
        options
      ) do
    mask = if Keyword.has_key?(options, :mask), do: options[:mask], else: mask

    socket |> Socket.Stream.send(<<0::1, 0::3, 0::4, forge(mask, data)::binary>>)
  end

  def send(%W{socket: socket, version: 13, mask: mask}, {:fragmented, opcode, data}, options) do
    mask = if Keyword.has_key?(options, :mask), do: options[:mask], else: mask

    socket |> Socket.Stream.send(<<0::1, 0::3, opcode(opcode)::4, forge(mask, data)::binary>>)
  end

  @doc """
  Send a packet to the websocket, raising if an error occurs.
  """
  @spec send!(t, packet) :: :ok | no_return
  @spec send!(t, packet, Keyword.t()) :: :ok | no_return
  def send!(self, packet, options \\ []) do
    case send(self, packet, options) do
      :ok ->
        :ok

      {:error, code} ->
        raise Socket.Error, reason: code
    end
  end

  @doc """
  Send a ping request with the optional cookie.
  """
  @spec ping(t) :: :ok | {:error, error}
  @spec ping(t, binary) :: :ok | {:error, error}
  def ping(self, cookie \\ :crypto.strong_rand_bytes(32)) do
    case send(self, {:ping, cookie}) do
      :ok ->
        cookie

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send a ping request with the optional cookie, raising if an error occurs.
  """
  @spec ping!(t) :: :ok | no_return
  @spec ping!(t, binary) :: :ok | no_return
  def ping!(self, cookie \\ :crypto.strong_rand_bytes(32)) do
    send!(self, {:ping, cookie})

    cookie
  end

  @doc """
  Send a pong with the given (and received) ping cookie.
  """
  @spec pong(t, binary) :: :ok | {:error, error}
  def pong(self, cookie) do
    send(self, {:pong, cookie})
  end

  @doc """
  Send a pong with the given (and received) ping cookie, raising if an error
  occurs.
  """
  @spec pong!(t, binary) :: :ok | no_return
  def pong!(self, cookie) do
    send!(self, {:pong, cookie})
  end

  @doc """
  Close the socket when a close request has been received.
  """
  @spec close(t) :: :ok | {:error, error}
  def close(%W{socket: socket, version: 13}) do
    socket |> Socket.Stream.send(<<1::1, 0::3, opcode(:close)::4, forge(nil, <<>>)::binary>>)
  end

  @doc """
  Close the socket sending a close request, unless `:wait` is set to `false` it
  blocks until the close response has been received, and then closes the
  underlying socket.
  If :reason? is set to true and the response contains a closing reason
  and custom data the function returns it as a tuple.
  """
  @spec close(t, atom, Keyword.t()) :: :ok | {:ok, atom, binary} | {:error, error}
  def close(%W{socket: socket, version: 13, mask: mask} = self, reason, options \\ []) do
    {reason, data} = if is_tuple(reason), do: reason, else: {reason, <<>>}
    mask = if Keyword.has_key?(options, :mask), do: options[:mask], else: mask

    socket
    |> Socket.Stream.send(
      <<1::1, 0::3, opcode(:close)::4,
        forge(
          mask,
          <<close_code(reason)::16, data::binary>>
        )::binary>>
    )

    unless options[:wait] == false do
      do_close(self, recv(self, options), Keyword.get(options, :reason?, false), options)
    end
  end

  defp do_close(self, {:ok, :close}, _, _) do
    abort(self)
  end

  defp do_close(self, {:ok, {:close, _, _}}, false, _) do
    abort(self)
  end

  defp do_close(self, {:ok, {:close, reason, data}}, true, _) do
    abort(self)
    {:ok, reason, data}
  end

  defp do_close(self, {:error, reason}, _, _) do
    abort(self)
    {:error, reason}
  end

  defp do_close(self, _, reason?, options) do
    do_close(self, recv(self, options), reason?, options)
  end

  @doc """
  Close the underlying socket, only use when you mean it, normal closure
  procedure should be preferred.
  """
  @spec abort(t) :: :ok | {:error, error}
  def abort(%W{socket: socket}) do
    Socket.Stream.close(socket)
  end

  def process(self, pid) when is_map(self) and is_pid(pid) do
    # TODO if pid is changed kill the old process and restart a new active process
    Map.put(self, :target_pid, pid)
  end

  @doc """
  Start or stop the reader process that turns incoming frames into messages.

  Stopping it kills that process. It is blocked in `recv/2` most of its life
  and never reaches its mailbox, so nothing else stops it on the spot. Close
  the socket or arm it again rather than reading it passively afterwards: a
  frame may have been half read when the reader went away.
  """
  @spec active(t, boolean) :: t
  def active(self, true) when is_map(self) do
    if self.active_pid != nil and Process.alive?(self.active_pid) do
      self
    else
      # The reader puts its own socket in every message it sends, so it has to
      # hold the struct that already knows its pid. It waits for that struct
      # instead of being handed a copy taken before the spawn.
      active_pid =
        spawn(fn ->
          receive do
            {:socket, socket} -> active_websocket_process(socket)
          end
        end)

      self = Map.put(self, :active_pid, active_pid)
      Kernel.send(active_pid, {:socket, self})

      self
    end
  end

  def active(self, false) when is_map(self) do
    if self.active_pid != nil and Process.alive?(self.active_pid) do
      Process.exit(self.active_pid, :kill)
    end

    Map.put(self, :active_pid, nil)
  end

  # ------------------ Socket protocol implementation for WebSocket ----
  defimpl Socket.Protocol do
    require Record

    def equal?(self = %Socket.Web{}, other) when is_tuple(other) do
      self.socket == other
    end

    def equal?(self = %Socket.Web{}, other) do
      self == other
    end

    def equal?(_, _) do
      false
    end

    def accept(self = %Socket.Web{}, options \\ []) do
      Socket.Web.accept(self, options)
    end

    def options(self = %Socket.Web{}, opts) do
      Socket.options(self.socket, opts)
    end

    def packet(self = %Socket.Web{}, _type) do
      self
    end

    def process(self = %Socket.Web{}, pid) do
      Socket.Web.process(self, pid)
    end

    def active(self = %Socket.Web{}) do
      Socket.Web.active(self, true)
    end

    def active(self = %Socket.Web{}, :once) do
      self
    end

    def passive(self = %Socket.Web{}) do
      Socket.Web.active(self, false)
    end

    def local(self = %Socket.Web{}) do
      Socket.local(self.socket)
    end

    def remote(self = %Socket.Web{}) do
      Socket.remote(self.socket)
    end

    def close(self = %Socket.Web{}) do
      Socket.Web.close(self)
    end
  end
end

defmodule Phoenix.LiveDashboard.SystemInfo do
  # Helpers for fetching and formatting system info.
  @moduledoc false

  ## Fetchers

  def fetch_processes(node, search, sort_by, sort_dir, limit) do
    search = search && String.downcase(search)
    :rpc.call(node, __MODULE__, :processes_callback, [search, sort_by, sort_dir, limit])
  end

  def fetch_ets(node, search, sort_by, sort_dir, limit) do
    search = search && String.downcase(search)
    :rpc.call(node, __MODULE__, :ets_callback, [search, sort_by, sort_dir, limit])
  end

  def fetch_sockets(node, search, sort_by, sort_dir, limit) do
    search = search && String.downcase(search)
    :rpc.call(node, __MODULE__, :sockets_callback, [search, sort_by, sort_dir, limit])
  end

  def fetch_socket_info(port, keys) do
    :rpc.call(node(port), __MODULE__, :socket_info_callback, [port, keys])
  end

  def fetch_process_info(pid, keys) do
    :rpc.call(node(pid), __MODULE__, :process_info_callback, [pid, keys])
  end

  def fetch_ports(node, search, sort_by, sort_dir, limit) do
    search = search && String.downcase(search)
    :rpc.call(node, __MODULE__, :ports_callback, [search, sort_by, sort_dir, limit])
  end

  def fetch_port_info(port, keys) do
    :rpc.call(node(port), __MODULE__, :port_info_callback, [port, keys])
  end

  def fetch_ets_info(node, ref) do
    :rpc.call(node, __MODULE__, :ets_info_callback, [ref])
  end

  def fetch_system_info(node) do
    :rpc.call(node, __MODULE__, :info_callback, [])
  end

  def fetch_system_usage(node) do
    :rpc.call(node, __MODULE__, :usage_callback, [])
  end

  ## System callbacks

  @doc false
  def info_callback do
    %{
      system_info: %{
        banner: :erlang.system_info(:system_version),
        elixir_version: System.version(),
        phoenix_version: Application.spec(:phoenix, :vsn) || "None",
        dashboard_version: Application.spec(:phoenix_live_dashboard, :vsn) || "None",
        system_architecture: :erlang.system_info(:system_architecture)
      },
      system_limits: %{
        atoms: :erlang.system_info(:atom_limit),
        ports: :erlang.system_info(:port_limit),
        processes: :erlang.system_info(:process_limit)
      },
      system_usage: usage_callback()
    }
  end

  @doc false
  def usage_callback do
    %{
      atoms: :erlang.system_info(:atom_count),
      ports: :erlang.system_info(:port_count),
      processes: :erlang.system_info(:process_count),
      io: io(),
      uptime: :erlang.statistics(:wall_clock) |> elem(0),
      memory: memory(),
      total_run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      cpu_run_queue: :erlang.statistics(:total_run_queue_lengths)
    }
  end

  defp io() do
    {{:input, input}, {:output, output}} = :erlang.statistics(:io)
    {input, output}
  end

  defp memory() do
    memory = :erlang.memory()
    total = memory[:total]
    process = memory[:processes]
    atom = memory[:atom]
    binary = memory[:binary]
    code = memory[:code]
    ets = memory[:ets]

    %{
      total: total,
      process: process,
      atom: atom,
      binary: binary,
      code: code,
      ets: ets,
      other: total - process - atom - binary - code - ets
    }
  end

  ## Process Callbacks

  @process_info [
    :registered_name,
    :initial_call,
    :memory,
    :reductions,
    :message_queue_len,
    :current_function
  ]

  @doc false
  def processes_callback(search, sort_by, sort_dir, limit) do
    multiplier = sort_dir_multipler(sort_dir)

    processes =
      for pid <- Process.list(), info = process_info(pid), show_process?(info, search) do
        sorter = info[sort_by] * multiplier
        {sorter, info}
      end

    count = if search, do: length(processes), else: :erlang.system_info(:process_count)
    processes = processes |> Enum.sort() |> Enum.take(limit) |> Enum.map(&elem(&1, 1))
    {processes, count}
  end

  defp process_info(pid) do
    if info = Process.info(pid, @process_info) do
      [{:registered_name, name}, {:initial_call, initial_call} | rest] = info
      name_or_initial_call = if is_atom(name), do: inspect(name), else: format_call(initial_call)
      [pid: pid, name_or_initial_call: name_or_initial_call] ++ rest
    end
  end

  defp show_process?(_, nil) do
    true
  end

  defp show_process?(info, search) do
    pid = info[:pid] |> :erlang.pid_to_list() |> List.to_string()
    name_or_call = info[:name_or_initial_call]
    pid =~ search or String.downcase(name_or_call) =~ search
  end

  def process_info_callback(pid, keys) do
    case Process.info(pid, keys) do
      [_ | _] = info -> {:ok, info}
      nil -> :error
    end
  end

  ## Ports callbacks

  @inet_ports ['tcp_inet', 'udp_inet', 'sctp_inet']

  @doc false
  def ports_callback(search, sort_by, sort_dir, limit) do
    multiplier = sort_dir_multipler(sort_dir)

    ports =
      for port <- Port.list(), port_info = port_info(port), show_port?(port_info, search) do
        sorter = port_info[sort_by]
        sorter = if is_integer(sorter), do: sorter * multiplier, else: 0
        {sorter, port_info}
      end

    count = length(ports)
    ports = ports |> Enum.sort() |> Enum.take(limit) |> Enum.map(&elem(&1, 1))
    {ports, count}
  end

  @doc false
  def port_info_callback(port, _keys) do
    case Port.info(port) do
      [_ | _] = info -> {:ok, info}
      nil -> :error
    end
  end

  defp port_info(port) do
    info = Port.info(port)

    if info && info[:name] not in @inet_ports do
      [port: port] ++ info
    end
  end

  defp show_port?(_, nil) do
    true
  end

  defp show_port?(info, search) do
    port = info[:port] |> :erlang.port_to_list() |> List.to_string()
    port =~ search or String.downcase(List.to_string(info[:name])) =~ search
  end

  ## ETS callbacks

  def ets_callback(search, sort_by, sort_dir, limit) do
    multiplier = sort_dir_multipler(sort_dir)

    tables =
      for ref <- :ets.all(), info = ets_info(ref), show_ets?(info, search) do
        sorter = info[sort_by] * multiplier
        {sorter, info}
      end

    count = length(tables)
    tables = tables |> Enum.sort() |> Enum.take(limit) |> Enum.map(&elem(&1, 1))
    {tables, count}
  end

  defp ets_info(ref) do
    case :ets.info(ref) do
      :undefined -> nil
      info -> [name: inspect(info[:name])] ++ Keyword.delete(info, :name)
    end
  end

  defp show_ets?(_, nil) do
    true
  end

  defp show_ets?(info, search) do
    String.downcase(info[:name]) =~ search
  end

  def ets_info_callback(ref) do
    case :ets.info(ref) do
      :undefined -> :error
      info -> {:ok, info}
    end
  end

  ## Socket callbacks

  def sockets_callback(search, sort_by, sort_dir, limit) do
    sorter = if sort_dir == :asc, do: &<=/2, else: &>=/2

    sockets =
      for port <- Port.list(), info = socket_info(port), show_socket?(info, search), do: info

    count = length(sockets)

    sockets =
      sockets
      |> Enum.sort_by(&Keyword.fetch!(&1, sort_by), sorter)
      |> Enum.take(limit)

    {sockets, count}
  end

  def socket_info_callback(port, keys) do
    case socket_info(port) do
      nil -> :error
      info -> {:ok, Keyword.take(info, keys)}
    end
  end

  defp socket_info(port) do
    with info when not is_nil(info) <- Port.info(port),
         true <- info[:name] in @inet_ports,
         {:ok, stat} <- :inet.getstat(port, [:send_oct, :recv_oct]),
         {:ok, state} <- :prim_inet.getstatus(port),
         {:ok, {_, type}} <- :prim_inet.gettype(port),
         module <- inet_module_lookup(port) do
      [
        port: port,
        module: module,
        local_address: format_address(:inet.sockname(port)),
        foreign_address: format_address(:inet.peername(port)),
        state: format_socket_state(state),
        type: type
      ] ++ info ++ stat
    else
      _ -> nil
    end
  end

  defp show_socket?(_info, nil), do: true

  defp show_socket?(info, search) do
    info[:local_address] =~ search || info[:foreign_address] =~ search
  end

  defp inet_module_lookup(port) do
    case :inet_db.lookup_socket(port) do
      {:ok, module} -> module
      _ -> "prim_inet"
    end
  end

  ## Helpers

  defp format_call({m, f, a}), do: Exception.format_mfa(m, f, a)

  # The address is formatted based on the implementation of `:inet.fmt_addr/2`
  defp format_address({:error, :enotconn}), do: "*:*"
  defp format_address({:error, _}), do: " "

  defp format_address({:ok, address}) do
    case address do
      {{0, 0, 0, 0}, port} -> "*:#{port}"
      {{0, 0, 0, 0, 0, 0, 0, 0}, port} -> "*:#{port}"
      {{127, 0, 0, 1}, port} -> "localhost:#{port}"
      {{0, 0, 0, 0, 0, 0, 0, 1}, port} -> "localhost:#{port}"
      {:local, path} -> "local:#{path}"
      {ip, port} -> "#{:inet.ntoa(ip)}:#{port}"
    end
  end

  # See `:inet.fmt_status`
  defp format_socket_state(flags) do
    case Enum.sort(flags) do
      [:accepting | _] -> "ACCEPTING"
      [:bound, :busy, :connected | _] -> "BUSY"
      [:bound, :connected | _] -> "CONNECTED"
      [:bound, :listen, :listening | _] -> "LISTENING"
      [:bound, :listen | _] -> "LISTEN"
      [:bound, :connecting | _] -> "CONNECTING"
      [:bound, :open] -> "BOUND"
      [:connected, :open] -> "CONNECTED"
      [:open] -> "IDLE"
      [] -> "CLOSED"
      sorted -> inspect(sorted)
    end
  end

  defp sort_dir_multipler(:asc), do: 1
  defp sort_dir_multipler(:desc), do: -1
end

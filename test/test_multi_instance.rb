# test/test_multi_instance.rb
#
# Several SketchUp processes, one server each (docs/multi-instance.md): a
# server whose port is taken moves on to the next free one, the application
# reports the port it really bound, and get_instance_info says which
# SketchUp a server is.
require "minitest/autorun"
require "json"
require "socket"

module Sketchup; def self.status_text=(_); end; end unless defined?(Sketchup)
module UI;       def self.messagebox(*); end;    end unless defined?(UI)
SKETCHUP_CONSOLE = nil unless defined?(SKETCHUP_CONSOLE)

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/framing"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/client_state"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/server"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/application"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/system"
require_relative "support/config_reset"

class TestMultiInstance < Minitest::Test
  Server      = MCPforSketchUp::Core::Server
  Config      = MCPforSketchUp::Core::Config
  Application = MCPforSketchUp::Core::Application
  System      = MCPforSketchUp::Handlers::System

  def setup
    ConfigReset.reset_all!
  end

  # Minitest 6 has no Object#stub: put +replacement+ in for +name+ on
  # +target+ for the block, and take it out again.
  def swap(target, name, replacement)
    meta = target.singleton_class
    own = meta.instance_methods(false).include?(name)
    saved = meta.instance_method(name) if own
    meta.send(:define_method, name, replacement)
    yield
  ensure
    meta.send(:remove_method, name) if meta.instance_methods(false).include?(name)
    meta.send(:define_method, name, saved) if saved
  end

  def teardown
    ConfigReset.reset_all!
  end

  # A port free right now, with the next one free too.
  def free_pair
    loop do
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close
      next if port >= 65_535
      begin
        TCPServer.new("127.0.0.1", port + 1).close
        return port
      rescue Errno::EADDRINUSE, Errno::EACCES
        next
      end
    end
  end

  def test_a_taken_port_moves_on_to_the_next
    first = free_pair
    holder = TCPServer.new("127.0.0.1", first)
    server, port = Server.new.send(:bind_first_free, "127.0.0.1", first)
    assert_equal first + 1, port
    assert_equal port, server.addr[1]
  ensure
    server&.close
    holder&.close
  end

  def test_a_free_port_is_kept
    first = free_pair
    server, port = Server.new.send(:bind_first_free, "127.0.0.1", first)
    assert_equal first, port
  ensure
    server&.close
  end

  def test_every_port_taken_raises
    taken = ->(*) { raise Errno::EADDRINUSE, "taken" }
    swap(TCPServer, :new, taken) do
      assert_raises(Errno::EADDRINUSE) do
        Server.new.send(:bind_first_free, "127.0.0.1", 9876)
      end
    end
  end

  def test_tries_no_more_than_the_span
    tried = []
    taken = ->(_host, port) { tried << port; raise Errno::EADDRINUSE, "taken" }
    swap(TCPServer, :new, taken) do
      assert_raises(Errno::EADDRINUSE) { Server.new.send(:bind_first_free, "127.0.0.1", 9876) }
    end
    assert_equal (9876...9876 + Config::PORT_SPAN).to_a, tried
  end

  def test_other_bind_errors_are_not_skipped
    unresolvable = ->(*) { raise SocketError, "getaddrinfo failed" }
    swap(TCPServer, :new, unresolvable) do
      assert_raises(SocketError) { Server.new.send(:bind_first_free, "nowhere.invalid", 9876) }
    end
  end

  class PortedServer
    attr_reader :port
    def initialize; @port = 9878; end
    def start; end
    def stop; end
  end

  def test_the_application_reports_the_port_bound
    Application.server_class = PortedServer
    Application.start
    assert_equal 9878, Application.running_config[:port]
  ensure
    Application.stop
    Application.server_class = nil
  end

  # get_instance_info reads Sketchup.active_model and Sketchup.version; the
  # stub module has neither unless another test gave it them.
  def with_sketchup(model, version, &block)
    swap(Sketchup, :active_model, -> { model }) do
      swap(Sketchup, :version, -> { version }, &block)
    end
  end

  def test_instance_info_names_the_process_its_port_and_model
    model = Struct.new(:title, :path).new("Level 2", "C:/m/level2.skp")
    Application.instance_variable_set(:@running_config, { host: "127.0.0.1", port: 9877 })
    info = with_sketchup(model, "26.1.0") { System.get_instance_info({}) }
    assert_equal Process.pid, info[:pid]
    assert_equal 9877, info[:port]
    assert_equal "Level 2", info[:model_title]
    assert_equal "C:/m/level2.skp", info[:model_path]
    assert_equal "26.1.0", info[:sketchup_version]
    assert_equal MCPforSketchUp::Core::Compat::SERVER_VERSION, info[:server_version]
  ensure
    Application.instance_variable_set(:@running_config, nil)
  end

  def test_dispatch_routes_get_instance_info
    request = {
      "jsonrpc" => "2.0",
      "method"  => "tools/call",
      "params"  => { "name" => "get_instance_info", "arguments" => {} },
      "id"      => 5,
    }
    response = with_sketchup(nil, "26.1.0") { MCPforSketchUp::Handlers::Dispatch.handle(request) }
    payload = JSON.parse(response["result"]["content"][0]["text"])
    assert_equal Process.pid, payload["pid"]
    assert_nil payload["model_title"]
  end
end

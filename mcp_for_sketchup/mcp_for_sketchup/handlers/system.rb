# mcp_for_sketchup/mcp_for_sketchup/handlers/system.rb
module MCPforSketchUp
  module Handlers
    module System
      # Returns the Ruby-side compat metadata. Used by the MCP tool
      # `get_version` (Python wrapper computes the `compatible` flag).
      # Only the floor: there is no upper bound on the client version.
      def self.get_version(_params)
        {
          ruby_version:           MCPforSketchUp::Core::Compat::SERVER_VERSION,
          min_compatible_python:  MCPforSketchUp::Core::Compat::MIN_PYTHON,
        }
      end

      # Which SketchUp this server is - for the Python side's
      # list_sketchup_instances / select_sketchup_instance, which tell the
      # processes apart by these. Read-only.
      def self.get_instance_info(_params)
        running = (defined?(Core::Application) && Core::Application.running_config) || {}
        model = active_model
        {
          pid:              Process.pid,
          host:             running[:host],
          port:             running[:port],
          model_title:      model && model.title,
          model_path:       model && model.path,
          sketchup_version: sketchup_version,
          server_version:   MCPforSketchUp::Core::Compat::SERVER_VERSION,
        }
      end

      def self.active_model
        defined?(::Sketchup) && ::Sketchup.respond_to?(:active_model) ? ::Sketchup.active_model : nil
      end

      def self.sketchup_version
        defined?(::Sketchup) && ::Sketchup.respond_to?(:version) ? ::Sketchup.version.to_s : nil
      end
      private_class_method :active_model, :sketchup_version
    end
  end
end

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
    end
  end
end

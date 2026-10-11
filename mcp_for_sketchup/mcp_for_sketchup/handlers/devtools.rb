# mcp_for_sketchup/mcp_for_sketchup/handlers/devtools.rb
#
# Plugin-development tools. Both run Ruby code — the first evaluates it,
# the second loads it from disk — so both sit behind the same gate as
# eval_ruby (Plugins → MCP Server → Settings → Enable Ruby evaluation) and
# answer -32010 with the same message when it is closed.
module MCPforSketchUp
  module Handlers
    module DevTools
      V = MCPforSketchUp::Helpers::Validation
      E = MCPforSketchUp::Core::StructuredError

      MAX_RESULT = 20_000
      MAX_FILES  = 300

      def self.require_eval_enabled!
        return if MCPforSketchUp::Core::Config.eval_enabled?
        raise E.new(Eval::EVAL_DISABLED_CODE, Eval::EVAL_DISABLED_MESSAGE)
      end

      # Counts the operations committed while the code runs. Duck-typed: the
      # API takes any object answering the callbacks, so this needs no
      # Sketchup::ModelObserver at load time.
      class CommitSpy
        attr_reader :commits

        def initialize
          @commits = 0
        end

        def onTransactionCommit(_model)
          @commits += 1
        end
      end

      # ===== eval_ruby_dry_run ===============================================
      #
      # Evaluate code inside an operation that is always aborted, so whatever
      # it does to the model is rolled back — a "what would this build?" that
      # leaves no geometry and no Undo entry behind. Operations can't nest in
      # SketchUp: code that starts its own commits this one, and code that
      # commits makes its changes permanent. The spy notices either, and the
      # result then says rolled_back: false instead of claiming a clean
      # model.
      def self.eval_ruby_dry_run(params)
        require_eval_enabled!
        code = V.require_string(params, "code")
        model = MCPforSketchUp::Helpers::Entities.active_model!
        spy = CommitSpy.new
        model.add_observer(spy)
        outcome = { "ok" => true }
        begin
          model.start_operation("MCP Dry Run", true)
          begin
            value = eval(code, TOPLEVEL_BINDING.dup)  # rubocop:disable Security/Eval
            text = value.inspect
            outcome["result"] = text.length > MAX_RESULT ? "#{text[0, MAX_RESULT]}…" : text
          rescue NoMemoryError, SignalException
            raise
          rescue Exception => e  # rubocop:disable Lint/RescueException
            # Broad on purpose, as in eval.rb: SyntaxError and friends are not
            # StandardErrors, and the abort below must still run.
            outcome["ok"] = false
            outcome["error"] = "#{e.class}: #{e.message}"
          ensure
            model.abort_operation
          end
        ensure
          model.remove_observer(spy)
        end
        outcome["rolled_back"] = spy.commits.zero?
        if spy.commits > 0
          outcome["warning"] = "the code committed #{spy.commits} operation(s) of its own " \
                               "(start_operation commits an open one), so those changes are " \
                               "in the model and on the Undo stack"
        end
        outcome
      end

      # ===== reload_ruby =====================================================
      #
      # `load` Ruby files into the running SketchUp, the way a plugin author
      # reloads code without restarting. Paths may be globs. Redefinition
      # warnings ("already initialized constant") are silenced while loading;
      # real errors come back per file with the line they point at.
      def self.reload_ruby(params)
        require_eval_enabled!
        raw = params["paths"]
        unless raw.is_a?(Array) && raw.length.between?(1, 100) &&
               raw.all? { |p| p.is_a?(String) && !p.empty? }
          raise E.new(-32602, "field paths must be an array of 1..100 non-empty strings")
        end
        stop_on_error = V.optional_bool(params, "stop_on_error", true)
        files = []
        raw.each do |path|
          path = path.tr("\\", "/")
          if path.match?(/[*?\[{]/)
            matches = Dir.glob(path).select { |f| f.end_with?(".rb") && File.file?(f) }.sort
            raise E.new(-32602, "pattern #{path.inspect} matched no .rb files") if matches.empty?
            files.concat(matches)
          else
            raise E.new(-32602, "no such file: #{path}") unless File.file?(path)
            raise E.new(-32602, "not a .rb file: #{path}") unless path.end_with?(".rb")
            files << path
          end
        end
        files = files.map { |f| File.expand_path(f) }.uniq
        if files.length > MAX_FILES
          raise E.new(-32602, "#{files.length} files matched; at most #{MAX_FILES} per call")
        end

        loaded = []
        failed = []
        verbose = $VERBOSE
        begin
          $VERBOSE = nil
          files.each do |file|
            t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              load(file)
              loaded << { "path" => file,
                          "ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1) }
            rescue NoMemoryError, SignalException
              raise
            rescue Exception => e  # rubocop:disable Lint/RescueException
              at = (e.backtrace || []).find { |line| line.include?(File.basename(file)) }
              failed << { "path" => file, "error" => "#{e.class}: #{e.message}"[0, 2000],
                          "at" => at }
              break if stop_on_error
            end
          end
        ensure
          $VERBOSE = verbose
        end
        { "loaded" => loaded, "failed" => failed,
          "skipped" => files.length - loaded.length - failed.length }
      end
    end
  end
end

module Sinatra
  module DebugTime
    class ProcessTime
      attr_reader :process, :start_time
      attr_reader :db,   :db_stock
      attr_reader :view, :view_stock

      def initialize
        @start_time = Time.now
        @db = @view = 0
        @db_stack   = []
        @view_stack = []
      end

      def start(type)
        case type
        when :db
          @db_stack << Time.now
        when :view
          @view_stack << Time.now
        else
          raise ArgumentError, "unknown type: #{type}"
        end
      end

      def finish(type)
        case type
        when :db
          start_time = @db_stack.pop
          time = diff(start_time)
          @db += time
        when :view
          start_time = @view_stack.pop
          time = diff(start_time)
          @view += time
        else
          raise ArgumentError, "unknown type: #{type}"
        end
      end

      def as_ms(type)
        case type
        when :process
          time_diff = @process
        when :db
          time_diff = @db
        when :view
          time_diff = @view
        else
          raise ArgumentError, "unknown type: #{type}"
        end

        (time_diff * 10000).to_i / 10.0
      end

      def finish_process
        @process = diff(@start_time)
      end

      def diff(start_time)
        finish_time = Time.now
        finish_time - start_time
      end
    end

    module DebugTimeHelper
      def process_route_with_logging(pattern, keys, conditions, _block = nil, values = [], &block)
        path_info = @request.path_info
        path_info = path_info.empty? ? "/" : path_info
        logger.info "Started #{@request.request_method} \"#{path_info}\", Params: #{@request.params.inspect}"
        @process_time = ProcessTime.new
        process_route_without_logging(pattern, keys, conditions, _block, values, &block)
      ensure
        @process_time.finish_process
        logger.info "Completed #{@response.status} in #{@process_time.as_ms(:process)} ms (DB: #{@process_time.as_ms(:db)} ms, View: #{@process_time.as_ms(:view)} ms)"
      end

      def render_with_calc_time(engine, data, options = {}, locals = {}, &block)
        @process_time.start(:view)
        render_without_calc_time(engine, data, options, locals, &block)
      ensure
        @process_time.finish(:view)
      end

      def xquery_with_calc_time(*args)
        @process_time.start(:db)
        db.xquery(*args)
      ensure
        @process_time.finish(:db)
      end
    end

    def self.registered(app)
      app.helpers DebugTime::DebugTimeHelper

      app.instance_eval do
        alias_method :process_route_without_logging, :process_route
        alias_method :process_route, :process_route_with_logging

        alias_method :render_without_calc_time, :render
        alias_method :render, :render_with_calc_time

        alias_method :xquery, :xquery_with_calc_time
      end
    end
  end

  register DebugTime
end

module Timescaledb
  module ContinuousAggregatesHelper
    extend ActiveSupport::Concern

    included do
      class_attribute :rollup_rules, default: {
        /count\(\*\)\s+as\s+(\w+)/ => 'sum(\1) as \1',
        /sum\((\w+)\)\s+as\s+(\w+)/ => 'sum(\2) as \2',
        /min\((\w+)\)\s+as\s+(\w+)/ => 'min(\2) as \2',
        /max\((\w+)\)\s+as\s+(\w+)/ => 'max(\2) as \2',
        /first\((\w+),\s*(\w+)\)\s+as\s+(\w+)/ => 'first(\3, \2) as \3',
        /high\((\w+),\s*(\w+)\)\s+as\s+(\w+)/ => 'max(\1) as \1',
        /low\((\w+),\s*(\w+)\)\s+as\s+(\w+)/ => 'min(\1) as \1',
        /last\((\w+),\s*(\w+)\)\s+as\s+(\w+)/ => 'last(\3, \2) as \3',
        /candlestick_agg\((\w+)\)\s+as\s+(\w+)/ => 'rollup(\2) as \2',
        /stats_agg\((\w+),\s*(\w+)\)\s+as\s+(\w+)/ => 'rollup(\3) as \3',
        /stats_agg\((\w+)\)\s+as\s+(\w+)/ => 'rollup(\2) as \2',
        /state_agg\((\w+)\)\s+as\s+(\w+)/ => 'rollup(\2) as \2',
        /percentile_agg\((\w+),\s*(\w+)\)\s+as\s+(\w+)/ => 'rollup(\3) as \3',
        /heartbeat_agg\((\w+)\)\s+as\s+(\w+)/ => 'rollup(\2) as \2',
      }

      scope :rollup, ->(interval) do
        select_values = self.select_values.join(', ')
        if select_values.include?('time_bucket(')
          select_values = apply_rollup_rules(select_values)
          select_values.gsub!(/time_bucket\((.+), (.+)\)/, "time_bucket(#{interval}, \2)")
        end
        group_values = self.group_values
        where_values = self.where_values_hash
        self.unscoped.select("time_bucket(#{interval}, #{time_column}) as #{time_column}, #{select_values}")
          .where(where_values)
          .group(1, *group_values)
      end
    end

    class_methods do
      def continuous_aggregates(options = {})
        @time_column = options[:time_column] || self.time_column
        @timeframes = options[:timeframes] || [:minute, :hour, :day, :week, :month, :year]
        
        scopes = options[:scopes] || []
        @aggregates = {}

        scopes.each do |scope_name|
          @aggregates[scope_name] = {
            scope_name: scope_name,
            select: nil,
            group_by: nil,
            refresh_policy: options[:refresh_policy] || {}
          }
        end

        # Allow for custom aggregate definitions to override or add to scope-based ones
        @aggregates.merge!(options[:aggregates] || {})

        # Add custom rollup rules if provided
        self.rollup_rules.merge!(options[:custom_rollup_rules] || {})

        define_continuous_aggregate_classes unless options[:skip_definition]
      end

      def refresh_aggregates(timeframes = nil)
        timeframes ||= @timeframes
        @aggregates.each do |aggregate_name, _|
          timeframes.each do |timeframe|
            klass = const_get("#{aggregate_name}_per_#{timeframe}".classify)
            klass.refresh!
          end
        end
      end

      def create_continuous_aggregates(with_data: false)
        @aggregates.each do |aggregate_name, config|
          @timeframes.each do |timeframe|
            klass = const_get("#{aggregate_name}_per_#{timeframe}".classify)
            connection.execute <<~SQL
              CREATE MATERIALIZED VIEW IF NOT EXISTS #{klass.table_name}
              WITH (timescaledb.continuous) AS
              #{klass.base_query}
              #{with_data ? 'WITH DATA' : 'WITH NO DATA'};
            SQL

            if (policy = klass.refresh_policy)
              connection.execute <<~SQL
                SELECT add_continuous_aggregate_policy('#{klass.table_name}',
                  start_offset => INTERVAL '#{policy[:start_offset]}',
                  end_offset =>  INTERVAL '#{policy[:end_offset]}',
                  schedule_interval => INTERVAL '#{policy[:schedule_interval]}');
              SQL
            end
          end
        end
      end

      def apply_rollup_rules(select_values)
        rollup_rules.reduce(select_values) do |result, (pattern, replacement)|
          result.gsub(pattern, replacement)
        end
      end

      def drop_continuous_aggregates
        @aggregates.each do |aggregate_name, _|
          @timeframes.reverse_each do |timeframe|
            view_name = "#{aggregate_name}_per_#{timeframe}"
            connection.execute("DROP MATERIALIZED VIEW IF EXISTS #{view_name} CASCADE")
          end
        end
      end

      private

      def define_continuous_aggregate_classes
        base_model = self
        @aggregates.each do |aggregate_name, config|
          previous_timeframe = nil
          @timeframes.each do |timeframe|
            _table_name = "#{aggregate_name}_per_#{timeframe}"
            class_name = "#{aggregate_name}_per_#{timeframe}".classify
            const_set(class_name, Class.new(base_model) do
              class << self
                attr_accessor :config, :timeframe, :base_query, :base_model
              end

              self.table_name = _table_name
              self.config = config
              self.timeframe = timeframe

              interval = "'1 #{timeframe.to_s}'"
              self.base_model = base_model
              if previous_timeframe
                prev_klass = base_model.const_get("#{aggregate_name}_per_#{previous_timeframe}".classify)
                select_clause = base_model.apply_rollup_rules("#{config[:select]}")
                self.base_query = "SELECT time_bucket(#{interval}, #{time_column}) as #{time_column}, #{select_clause} FROM \"#{prev_klass.table_name}\" GROUP BY #{[1, *config[:group_by]].join(', ')}"
              else
                scope = base_model.public_send(config[:scope_name])
                config[:select] = scope.select_values.join(', ')
                config[:group_by] = scope.group_values
                self.base_query = "SELECT time_bucket(#{interval}, #{time_column}) as #{time_column}, #{config[:select]} FROM \"#{scope.table_name}\" GROUP BY #{[1, *config[:group_by]].join(', ')}"
              end

              def self.refresh!(start_time = nil, end_time = nil)
                if start_time && end_time
                  connection.execute("CALL refresh_continuous_aggregate('#{table_name}', '#{start_time}', '#{end_time}')")
                else
                  connection.execute("CALL refresh_continuous_aggregate('#{table_name}', null, null)")
                end
              end

              def readonly?
                true
              end

              def self.refresh_policy
                config[:refresh_policy]&.dig(timeframe)
              end
            end)
            previous_timeframe = timeframe
          end
        end
      end
    end
  end
end

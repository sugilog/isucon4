require 'sinatra/base'
require 'digest/sha2'
require 'mysql2-cs-bind'
require 'rack-flash'
require 'json'

module Isucon4
  class App < Sinatra::Base
    use Rack::Session::Cookie, secret: ENV['ISU4_SESSION_SECRET'] || 'shirokane'
    use Rack::Flash
    set :public_folder, File.expand_path('../../public', __FILE__)
    set :logging, true

    helpers do
      def config
        @config ||= {
          user_lock_threshold: (ENV['ISU4_USER_LOCK_THRESHOLD'] || 3).to_i,
          ip_ban_threshold: (ENV['ISU4_IP_BAN_THRESHOLD'] || 10).to_i,
        }
      end

      def db
        Thread.current[:isu4_db] ||= Mysql2::Client.new(
          host: ENV['ISU4_DB_HOST'] || 'localhost',
          port: ENV['ISU4_DB_PORT'] ? ENV['ISU4_DB_PORT'].to_i : nil,
          username: ENV['ISU4_DB_USER'] || 'root',
          password: ENV['ISU4_DB_PASSWORD'],
          database: ENV['ISU4_DB_NAME'] || 'isu4_qualifier',
          reconnect: true,
        )
      end

      def calculate_password_hash(password, salt)
        Digest::SHA256.hexdigest "#{password}:#{salt}"
      end

      def login_log(succeeded, login, user_id = nil)
        xquery("INSERT INTO login_log" \
                  " (`created_at`, `user_id`, `login`, `ip`, `succeeded`)" \
                  " VALUES (?,?,?,?,?)",
                 Time.now, user_id, login, request.ip, succeeded ? 1 : 0)
      end

      def user_locked?(user)
        return nil unless user
        log = xquery("SELECT COUNT(1) AS failures FROM login_log WHERE user_id = ? AND id > IFNULL((select id from login_log where user_id = ? AND succeeded = 1 ORDER BY id DESC LIMIT 1), 0);", user['id'], user['id']).first

        config[:user_lock_threshold] <= log['failures']
      end

      def ip_banned?
        log = xquery("SELECT COUNT(1) AS failures FROM login_log WHERE ip = ? AND id > IFNULL((select id from login_log where ip = ? AND succeeded = 1 ORDER BY id DESC LIMIT 1), 0);", request.ip, request.ip).first

        config[:ip_ban_threshold] <= log['failures']
      end

      def attempt_login(login, password)
        user = xquery('SELECT * FROM users WHERE login = ?', login).first

        if ip_banned?
          login_log(false, login, user ? user['id'] : nil)
          return [nil, :banned]
        end

        if user_locked?(user)
          login_log(false, login, user['id'])
          return [nil, :locked]
        end

        if user && calculate_password_hash(password, user['salt']) == user['password_hash']
          login_log(true, login, user['id'])
          [user, nil]
        elsif user
          login_log(false, login, user['id'])
          [nil, :wrong_password]
        else
          login_log(false, login)
          [nil, :wrong_login]
        end
      end

      def current_user
        return @current_user if @current_user
        return nil unless session[:user_id]

        @current_user = xquery('SELECT * FROM users WHERE id = ?', session[:user_id].to_i).first
        unless @current_user
          session[:user_id] = nil
          return nil
        end

        @current_user
      end

      def last_login
        return nil unless current_user

        xquery('SELECT * FROM login_log WHERE succeeded = 1 AND user_id = ? ORDER BY id DESC LIMIT 2', current_user['id']).each.last
      end

      def banned_ips
        ips = []
        threshold = config[:ip_ban_threshold]

        not_succeeded = xquery('SELECT ip FROM (SELECT ip, MAX(succeeded) as max_succeeded, COUNT(1) as cnt FROM login_log GROUP BY ip) AS t0 WHERE t0.max_succeeded = 0 AND t0.cnt >= ?', threshold)

        ips.concat not_succeeded.each.map { |r| r['ip'] }

        last_succeeds = xquery('SELECT ip, MAX(id) AS last_login_id FROM login_log WHERE succeeded = 1 GROUP by ip')

        last_succeeds.each do |row|
          count = xquery('SELECT COUNT(1) AS cnt FROM login_log WHERE ip = ? AND ? < id', row['ip'], row['last_login_id']).first['cnt']
          if threshold <= count
            ips << row['ip']
          end
        end

        ips
      end

      def locked_users
        user_ids = []
        threshold = config[:user_lock_threshold]

        not_succeeded = xquery('SELECT user_id, login FROM (SELECT user_id, login, MAX(succeeded) as max_succeeded, COUNT(1) as cnt FROM login_log GROUP BY user_id) AS t0 WHERE t0.user_id IS NOT NULL AND t0.max_succeeded = 0 AND t0.cnt >= ?', threshold)

        user_ids.concat not_succeeded.each.map { |r| r['login'] }

        last_succeeds = xquery('SELECT user_id, login, MAX(id) AS last_login_id FROM login_log WHERE user_id IS NOT NULL AND succeeded = 1 GROUP BY user_id')

        last_succeeds.each do |row|
          count = xquery('SELECT COUNT(1) AS cnt FROM login_log WHERE user_id = ? AND ? < id', row['user_id'], row['last_login_id']).first['cnt']
          if threshold <= count
            user_ids << row['login']
          end
        end

        user_ids
      end
    end

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
    alias_method :process_route_without_logging, :process_route
    alias_method :process_route, :process_route_with_logging

    def render_with_calc_time(engine, data, options = {}, locals = {}, &block)
      @process_time.start(:view)
      render_without_calc_time(engine, data, options, locals, &block)
    ensure
      @process_time.finish(:view)
    end
    alias_method :render_without_calc_time, :render
    alias_method :render, :render_with_calc_time

    def xquery_with_calc_time(*args)
      @process_time.start(:db)
      db.xquery(*args)
    ensure
      @process_time.finish(:db)
    end
    alias_method :xquery, :xquery_with_calc_time

    get '/' do
      erb :index, layout: :base
    end

    post '/login' do
      user, err = attempt_login(params[:login], params[:password])
      if user
        session[:user_id] = user['id']
        redirect '/mypage'
      else
        case err
        when :locked
          flash[:notice] = "This account is locked."
        when :banned
          flash[:notice] = "You're banned."
        else
          flash[:notice] = "Wrong username or password"
        end
        redirect '/'
      end
    end

    get '/mypage' do
      unless current_user
        flash[:notice] = "You must be logged in"
        redirect '/'
      end
      erb :mypage, layout: :base
    end

    get '/report' do
      content_type :json
      {
        banned_ips: banned_ips,
        locked_users: locked_users,
      }.to_json
    end
  end
end

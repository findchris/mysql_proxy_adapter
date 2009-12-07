require 'active_record/connection_adapters/mysql_adapter'

module ActiveRecord
  
  class Base    
    class << self
      
      VALID_FIND_OPTIONS << :use_db
      
      # Establishes a connection to the database that's used by all Active Record objects.
      def mysql_proxy_connection(config) # :nodoc:
        config = config.symbolize_keys
        host     = config[:host]
        port     = config[:port]
        socket   = config[:socket]
        username = config[:username] ? config[:username].to_s : 'root'
        password = config[:password].to_s

        if config.has_key?(:database)
          database = config[:database]
        else
          raise ArgumentError, "No database specified. Missing argument: database."
        end

        # Require the MySQL driver and define Mysql::Result.all_hashes
        unless defined? Mysql
          begin
            require_library_or_gem('mysql')
          rescue LoadError
            $stderr.puts '!!! The bundled mysql.rb driver has been removed from Rails 2.2. Please install the mysql gem and try again: gem install mysql.'
            raise
          end
        end
        MysqlCompat.define_all_hashes_method!

        mysql = Mysql.init
        mysql.ssl_set(config[:sslkey], config[:sslcert], config[:sslca], config[:sslcapath], config[:sslcipher]) if config[:sslca] || config[:sslkey]

        ConnectionAdapters::MysqlProxyAdapter.new(mysql, logger, [host, username, password, database, port, socket], config)
      end
      
      def use_named(options)
        if connection.is_a?(ConnectionAdapters::MysqlProxyAdapter)
          connection.use_named(connection.named_connection_option(options)) do
            yield
          end
        else
          yield
        end
      end
      
      ###
      # Chain ActiveRecord::Base methods to optionally use a named connection.
      def find_every_with_named_connection(options)
        use_named(options) do
          find_every_without_named_connection(options)
        end
      end
      alias_method_chain :find_every, :named_connection

      def find_by_sql_with_named_connection(sql, *args)
        use_named(args.extract_options!) do
          find_by_sql_without_named_connection(sql)
        end
      end
      alias_method_chain :find_by_sql, :named_connection

      def count_by_sql_with_named_connection(sql, *args)
        use_named(args.extract_options!) do
          count_by_sql_without_named_connection(sql)
        end
      end
      alias_method_chain :count_by_sql, :named_connection

      def calculate_with_named_connection(operation, column_name, options ={})
        use_named(options.delete(:use_db)) do
          calculate_without_named_connection(operation, column_name, options)
        end
      end
      alias_method_chain :calculate, :named_connection
      
    end
  end
  
  module ConnectionAdapters
    
    # The MySQL adapter will work with both Ruby/MySQL, which is a Ruby-based MySQL adapter that comes bundled with Active Record, and with
    # the faster C-based MySQL/Ruby adapter (available both as a gem and from http://www.tmtm.org/en/mysql/ruby/).
    #
    # Options:
    #
    # * <tt>:host</tt> -- Defaults to localhost
    # * <tt>:port</tt> -- Defaults to 3306
    # * <tt>:socket</tt> -- Defaults to /tmp/mysql.sock
    # * <tt>:username</tt> -- Defaults to root
    # * <tt>:password</tt> -- Defaults to nothing
    # * <tt>:database</tt> -- The name of the database. No default, must be provided.
    # * <tt>:sslkey</tt> -- Necessary to use MySQL with an SSL connection
    # * <tt>:sslcert</tt> -- Necessary to use MySQL with an SSL connection
    # * <tt>:sslcapath</tt> -- Necessary to use MySQL with an SSL connection
    # * <tt>:sslcipher</tt> -- Necessary to use MySQL with an SSL connection
    #
    # By default, the MysqlAdapter will consider all columns of type tinyint(1)
    # as boolean. If you wish to disable this emulation (which was the default
    # behavior in versions 0.13.1 and earlier) you can add the following line
    # to your environment.rb file:
    #
    #   ActiveRecord::ConnectionAdapters::MysqlAdapter.emulate_booleans = false
    class MysqlProxyAdapter < MysqlAdapter      
      
      ADAPTER_NAME = 'MySQLProxy'.freeze     
      
      def initialize(connection, logger, connection_options, config)
        @named_connections = nil
        @retries = config[:retries]
        super(connection, logger, connection_options, config)
      end

      def adapter_name #:nodoc:
        ADAPTER_NAME
      end
      
      def use_named(connection)
        old_connection = @connection
        @connection = connection
        yield
      ensure
        @connection = old_connection
      end

      def named_connection_option(option = nil)
        # pull the :use_db option if a Hash, else option is assumed to be the connection name
        option = option.is_a?(Hash) ? option[:use_db] : option

        named_connection =  @named_connections[option.to_sym] unless option.blank?
        named_connection || @connection
      end

      def disconnect!
        @connection.close rescue nil
        @named_connections.each { |conn| conn.close rescue nil } if @named_connections
      end


      # DATABASE STATEMENTS ======================================

      def execute(sql, name = nil) #:nodoc:
        retries = 0
        log(sql, "#{name} against #{@connection.host_info}") do
          @connection.query(sql) 
        end
      rescue Mysql::Error => ex
        if ex.message =~ /MySQL server has gone away/
          if @retries && retries < @retries
            retries += 1
            disconnect!
            connect
            retry
          else
            raise
          end
        else
          raise
        end
      rescue ActiveRecord::StatementInvalid => exception
        if exception.message.split(":").first =~ /Packets out of order/
          raise ActiveRecord::StatementInvalid, "'Packets out of order' error was received from the database. Please update your mysql bindings (gem install mysql) and read http://dev.mysql.com/doc/mysql/en/password-hashing.html for more information.  If you're on Windows, use the Instant Rails installer to get the updated mysql bindings."
        else
          raise
        end
      end
      
    
      def connect
        # set up the primary connection
        setup_connection(@connection, @connection_options)            
        setup_named_connections
      end

      private
        
        def setup_named_connections
          named_connections_config = @config[:named_connections].symbolize_keys! rescue return

          # create the named connections if they don't already exist
          initialize_named_connections unless @named_connections
            
          @named_connections.each do |name, conn|
            config = named_connections_config[name]
            setup_connection(conn, [config["host"], config["username"], config["password"], config["database"], config["port"], config["socket"]])
          end     
        end
        
        # call #real_connect on the given connection with the passed in options. 
        def setup_connection(conn, conn_opts)
          encoding = @config[:encoding]
          if encoding
            conn.options(Mysql::SET_CHARSET_NAME, encoding) rescue nil
          end

          if @config[:sslca] || @config[:sslkey]
            conn.ssl_set(@config[:sslkey], @config[:sslcert], @config[:sslca], @config[:sslcapath], @config[:sslcipher])
          end
          
          conn.real_connect(*conn_opts)
          
          # reconnect must be set after real_connect is called, because real_connect sets it to false internally
          conn.reconnect = !!@config[:reconnect] if conn.respond_to?(:reconnect=)

          old_conn, @connection = @connection, conn
          execute("SET NAMES '#{encoding}'") if encoding
          # By default, MySQL 'where id is null' selects the last inserted id.
          # Turn this off. http://dev.rubyonrails.org/ticket/6778
          execute("SET SQL_AUTO_IS_NULL=0")
          @connection = old_conn
        end
        
        def initialize_named_connections
          @config[:named_connections].each_key {|name| @named_connections ||= {}; @named_connections[name] = Mysql.init}
        end
      
    end
  end
end


module ActiveRecord
  
  class Base    
    class << self
      
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

        ConnectionAdapters::MysqlReplicationAdapter.new(mysql, logger, [host, username, password, database, port, socket], config)
      end
      
      ###
      # Override ActiveRecord::Base methods to optionally use a named connection.
      def find_every(options)
        connection.use_named(named_connection_option(options)) do
          super(options)
        end
      end

      def find_by_sql(sql, *args)
        connection.use_named(named_connection_option(args.extract_options!)) do
          super(sql)
        end
      end

      def count_by_sql(sql, *args)
        connection.use_named(named_connection_option(args.extract_options!)) do
          super(sql)
        end
      end

      def calculate(operation, column_name, options ={})
        connection.use_named(named_connection_option(options.delete(:use_db))) do
          super(operation, column_name, options)
        end
      end
      
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

      def adapter_name #:nodoc:
        ADAPTER_NAME
      end

      # the magic load_balance method
      def load_balance_query
        old_connection = @connection
        @connection = select_clone
        yield
      ensure
        @connection = old_connection
      end

      # choose a random clone to use for the moment
      def select_clone
        # if we happen not to be connected to any clones, just use the master
        return @master if @clones.nil? || @clones.empty? 
        # return a random clone
        return @clones[rand(@clones.size)]
      end

      def disconnect!
        @master.close rescue nil
        if @clones
          @clones.each do |clone|
            clone.close rescue nil
          end
        end
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


      private
      # Create the array of clone Mysql instances. Note that the instances
      # actually don't correspond to the clone specs at this point. We're 
      # just getting Mysql object instances we can connect with later.
      def init_clones
        @clones = (@config[:clones] || @config[:slaves]).map{Mysql.init}
      end
    
      # Given a Mysql object and connection options, call #real_connect
      # on the connection. 
      def setup_connection(conn, conn_opts)
        # figure out if we're going to be doing any different
        # encoding. if so, set it.
        encoding = @config[:encoding]
        if encoding
          conn.options(Mysql::SET_CHARSET_NAME, encoding) rescue nil
        end
        
        # set the ssl options
        conn.ssl_set(@config[:sslkey], @config[:sslcert], @config[:sslca], @config[:sslcapath], @config[:sslcipher]) if @config[:sslkey]
        
        # do the actual connect
        conn.real_connect(*conn_opts)
        
        # swap the current connection for the connection we just set up
        old_conn, @connection = @connection, conn
        
        # set these options!
        execute("SET NAMES '#{encoding}'") if encoding
        # By default, MySQL 'where id is null' selects the last inserted id.
        # Turn this off. http://dev.rubyonrails.org/ticket/6778
        execute("SET SQL_AUTO_IS_NULL=0")
        
        # swap the old current connection back into place
        @connection = old_conn
      end
    
      def connect
        # if this is our first time in this method, then master will be
        # nil, and should get set.
        @master = @connection unless @master

        # set up the master connection
        setup_connection(@master, @connection_options)
                  
        clone_config = @config[:clones] || @config[:slaves]

        # if clones are specified, then set up those connections
        if clone_config
          # create the clone connections if they don't already exist
          init_clones unless @clones
          
          # produce a pairing of connection options with an existing clone
          clones_with_configs = @clones.zip(clone_config)
          
          clones_with_configs.each do |clone_and_config|
            clone, config = clone_and_config
            
            # Cause the individual clone Mysql instances to (re)connect
            # Note - the instances aren't being replaced. This is critical,
            # as otherwise the current connection could end up pointed at a 
            # bad connection object in the case of a failure.
            setup_connection(clone, 
              [
                config["host"], 
                config["username"], config["password"], 
                config["database"], config["port"], config["socket"]
              ]
            )
          end
        else
          # warning, no slaves specified.
          warn "Warning: MysqlReplicationAdapter in use, but no slave database connections specified."
        end
      end
      
    end
  end
end

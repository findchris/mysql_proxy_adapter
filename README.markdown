MysqlProxyAdapter
=======================

MysqlReplicationAdapter is a simple ActiveRecord database adapter that allows database connection control when using [MySQL Proxy](http://forge.mysql.com/wiki/MySQL_Proxy). 










Configuration
================
1. Install the plugin. 
-------------------
Download from Rubyforge via the bug patch.

2. Edit your environment.rb (ONLY FOR RAILS 1).
-------------------
Because of the way that Rails 1 loads database adapters, you must force it to load the new adapter.  You have to add this ABOVE the initializer block.  As follows:

$:.unshift File.join(File.dirname(__FILE__), '../vendor/plugins/mysql_replication_adapter/lib')
require 'mysql_replication_adapter'
...
Rails::Initializer.run do |config|


3. Add slaves to your database.yml.
-------------------
Slaves are configured on a by-environment basis, so pick any of your existing environments (development, production, etc.). Change the "driver" entry to "mysql_replication". Then, add a clones section like the one seen below.

production:
  adapter: mysql_proxy
  database: db_name
  username: root
  password:
  host: localhost
  port: 4040
  reconnect: true
  retries: 2
  pool: 5
  named_servers:
    master:
      database: db_name
      username: root
      password: 
      host: db_master.company.com
      reconnect: true
      retries: 2
      pool: 5
    slave:
      database: db_name
      username: root
      password: 
      host: db_slave.company.com
      reconnect: true
      retries: 2
      pool: 5

And so on. Add as many slaves as you'd like. There are no built-in limits.

And that's it. It's configured now. 

Usage
================
There are a number of ways to make use of the MysqlReplicationAdapter's slave-balancing capabilities. The simplest way is to pass a new option to ActiveRecord::Base#find. The option is called :use_slave, and it should => true when you want to send the query to a slave. For instance:

class Author < ActiveRecord::Base; end;

Author.find(:all, :use_slave => true)

Credits
================
The MysqlReplicationAdapter served as a guideline when approaching the task of writing an ActiveRecord database adapter.
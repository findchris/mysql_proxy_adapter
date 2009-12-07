MysqlProxyAdapter
=======================

MysqlReplicationAdapter is a simple ActiveRecord database adapter that allows database connection control when using [MySQL Proxy](http://forge.mysql.com/wiki/MySQL_Proxy). 










Configuration
================
1. Install the plugin. 
-------------------
script/plugin install git://github.com/findchris/mysql_proxy_adapter.git

2. Add named connections to your database.yml.
-------------------
Be sure to set the 'adapter' attribute to 'mysql_proxy', and then add a 'named_connections' attribute containing your named connection as in the below example:

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
  named_connections:
    master:
      adapter: mysql
      database: db_name
      username: root
      password: 
      host: db_master.company.com
      reconnect: true
      retries: 2
      pool: 5
    slave:
      adapter: mysql
      database: db_name
      username: root
      password: 
      host: db_slave.company.com
      reconnect: true
      retries: 2
      pool: 5


Usage
================
Obviously, your MySQL Proxy configuration will direct read/writes to your slaves/master respectively.  Should you want to explicitly use one of your named connections instead of letting your MySQL Proxy configuration dictate the database to be queried, you can simple add a ':use_db' query option to any of ActiveRecord's query methods.  Example: 

class Author < ActiveRecord::Base; end;

Author.find(:all, :use_db => :master)



Credits
================
The MysqlReplicationAdapter served as a guideline when approaching the task of writing an ActiveRecord database adapter.
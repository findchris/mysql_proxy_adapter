require 'active_record'
require 'active_record/connection_adapters/mysql_proxy_adapter'

module ActiveRecord
  class Base
    class << self
      VALID_FIND_OPTIONS << :use_db
    end
  end
end
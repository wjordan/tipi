# frozen_string_literal: true

require_relative './handler'

module Tipi
  module Configuration
    class << self
      def supervise_config
        current_runner = nil
        while (config = receive)
          old_runner, current_runner = current_runner, spin { run(config) }
          old_runner&.stop
        end
      end
      
      def run(config)
        config[:forked] ? forked_supervise(config) : simple_supervise(config)
      end
      
      def simple_supervise(config)
        virtual_hosts = setup_virtual_hosts(config)
        start_listeners(config, virtual_hosts)
        suspend
      rescue Interrupt
        # Ctrl-C to exit
      end
      
      def forked_supervise(config)
        config[:reuse_port] = true
        config[:forked].times do
          supervise_process { simple_supervise(config) }
        end
      end

      def supervise_process(&block)
        Polyphony.fork { block.call }
      end

      def setup_virtual_hosts(config)
        {
          '*': Tipi::DefaultHandler.new(config)
        }
      end

      def start_listeners(config, virtual_hosts)
        config.merge!(
          reuse_addr: true,
          dont_linger: true
        )
        spin do
          port = config[:port] || 1234
          puts "pid #{Process.pid} listening on port #{port}"
          server = Polyphony::Net.tcp_listen('0.0.0.0', port, config)
          while (connection = server.accept)
            spin { virtual_hosts[:'*'].call(connection) }
          end
        end
      end
    end
  end
end

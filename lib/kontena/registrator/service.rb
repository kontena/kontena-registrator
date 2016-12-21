require 'celluloid'

require 'kontena/logging'
require 'kontena/etcd'

module Kontena
  class Registrator
    class Service
      include Kontena::Logging
      include Celluloid

      ETCD_TTL = 30

      # @param docker_observable [Kontena::Observable<Kontena::Registrator::Docker::State>]
      # @param policy [Kontena::Registrator::Policy]
      def initialize(docker_observable, policy, start: true)
        @docker_observable = docker_observable
        @etcd_writer = Kontena::Etcd::Writer.new(ttl: ETCD_TTL)
        @policy = policy

        self.start if start
      end

      def start
        refresh_interval = @etcd_writer.ttl / 2
        logger.info "refreshing etcd every #{refresh_interval}s..."

        self.async.run

        # Run a refresh loop to keep etcd nodes alive
        every(refresh_interval) do
          self.refresh
        end
      end

      # Apply @policy, and update etcd
      #
      # @param docker_state [Docker::State]
      def update(docker_state)
        etcd_nodes = @policy.call(docker_state)

        logger.info "Update with Docker #containers=#{docker_state.containers.size} => etcd #nodes=#{etcd_nodes.size}"

        @etcd_writer.update(etcd_nodes)
      end

      # Observe Docker::State,
      def run
        logger.debug "observing #{@docker_observable}"

        @docker_observable.observe do |docker_state|
          self.update(docker_state)
        end
      end

      # Refresh etcd nodes written by update
      #
      # Runs concurrently with run -> update
      def refresh
        @etcd_writer.refresh
      end
    end
  end
end

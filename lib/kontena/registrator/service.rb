require 'celluloid'

require 'kontena/logging'
require 'kontena/etcd'

# Apply a Policy against Docker::State and update Kontena::Etcd::Writer
class Kontena::Registrator::Service
  include Kontena::Logging
  include Celluloid

  ETCD_TTL = 30

  # @param docker_observable [Kontena::Observable<Kontena::Registrator::Docker::State>]
  # @param policy [Kontena::Registrator::Policy]
  # @param config [Kontena::Registrator::Policy::Config, nil] policy#config_model instance
  # @param start [Boolean] autostart when supervised, set to false for test cases
  def initialize(policy, config = nil, docker_observable: , start: true)
    @docker_observable = docker_observable
    @etcd_writer = Kontena::Etcd::Writer.new(ttl: ETCD_TTL)
    @policy = policy
    @context = policy.apply_context(config)

    self.start if start
  end

  def to_s
    if @context.config
      "#{@policy}:#{@context.config}"
    else
      "#{@policy}"
    end
  end

  # Start update+refresh loop
  def start
    refresh_interval = @etcd_writer.ttl / 2
    logger.info "refreshing etcd every #{refresh_interval}s..."

    self.async.run

    # Run a refresh loop to keep etcd nodes alive
    every(refresh_interval) do
      self.refresh
    end
  end

  # Update config while running.
  #
  # The config should never be nil.
  #
  # This is different from a restart, in that it preserves the Etcd::Writer state
  #
  # @param config [Kontena::Registrator::Policy::Config] policy#config_model instance
  def reload(config)
    # replace the policy ApplyContext
    @context = @policy.apply_context(config)

    # immediately re-apply current Docker state to update any changes to etcd
    self.update(@docker_observable.get)
  end

  # Remove nodes from etcd, and terminate.
  def stop
    # XXX: is this safe against concurrent run, refresh?
    #      poision just to be sure
    @context = nil

    # flush any nodes
    @etcd_writer.clear

    # XXX: must be higher priority over the other messages...
    self.terminate
  end

  # Apply @policy, and update etcd
  #
  # @param docker_state [Docker::State]
  def update(docker_state)
    etcd_nodes = @policy.apply(docker_state, @context)

    logger.info "Update with Docker #containers=#{docker_state.containers.size} => etcd #nodes=#{etcd_nodes.size}"

    @etcd_writer.update(etcd_nodes)
  end

  # Loop on Docker::State and update
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

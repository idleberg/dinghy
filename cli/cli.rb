$LOAD_PATH << File.dirname(__FILE__)+"/thor/lib"
require 'thor'
$LOAD_PATH << File.dirname(__FILE__)+"/daemons/lib"
require 'daemons'

$LOAD_PATH << File.dirname(__FILE__)

require 'dinghy.rb'
require 'dinghy/check_env'
require 'dinghy/docker'
require 'dinghy/dnsmasq'
require 'dinghy/fsevents_to_vm'
require 'dinghy/http_proxy'
require 'dinghy/preferences'
require 'dinghy/unfs'
require 'dinghy/machine'
require 'dinghy/machine/create_options'
require 'dinghy/system'
require 'dinghy/version'

$0 = 'dinghy' # fix our binary name, since we launch via the _dinghy_command wrapper

class DinghyCLI < Thor
  option :memory,
    type: :numeric,
    aliases: :m,
    desc: "virtual machine memory size (in MB) (default #{MEM_DEFAULT})"
  option :cpus,
    type: :numeric,
    aliases: :c,
    desc: "number of CPUs to allocate to the virtual machine (default #{CPU_DEFAULT})"
  option :disk,
    type: :numeric,
    aliases: :d,
    desc: "size of the virtual disk to create, in MB (default #{DISK_DEFAULT})"
  option :provider,
    aliases: :p,
    desc: "which docker-machine provider to use, 'virtualbox', 'vmware', 'xhyve', or 'parallels'"
  option :boot2docker_url,
    type: :string,
    aliases: :u,
    desc: 'URL of the boot2docker image'
  desc "create", "create the docker-machine VM"
  def create
    if machine.created?
      $stderr.puts "The VM '#{machine.name}' already exists in docker-machine."
      $stderr.puts "Run `dinghy up` to bring up the VM, or `dinghy destroy` to delete it."
      exit(1)
    end

    create_options = (preferences[:create] || {}).merge(options)
    create_options['provider'] = machine.translate_provider(create_options['provider'])

    if create_options['provider'].nil?
      $stderr.puts("Invalid value for required option --provider. Valid values are: 'virtualbox', 'vmware', 'xhyve', or 'parallels'")
      exit(1)
    end

    puts "Creating the #{machine.name} VM..."
    machine.create(create_options)
    start_services
    preferences.update(create: create_options)
  end

  option :proxy,
    type: :boolean,
    desc: "start the HTTP proxy as well"
  option :fsevents,
    type: :boolean,
    desc: "start the FS event forwarder"
  desc "up", "start the Docker VM and services"
  def up
    vm_must_exist!
    if machine.running?
      $stderr.puts "The VM '#{machine.name}' is already running."
      exit(1)
    end

    puts "Starting the #{machine.name} VM..."
    start_services
  end

  map "start" => :up

  desc "ssh [args...]", "ssh to the VM"
  def ssh(*args)
    vm_must_exist!
    machine.ssh_exec(*args)
  end

  desc "status", "get VM and services status"
  def status
    puts "  VM: #{machine.status}"
    puts " NFS: #{unfs.status}"
    puts "FSEV: #{fsevents.status}"
    puts " DNS: #{dns.status}"
    puts "HTTP: #{http_proxy.status}"
    return unless machine.status == 'running'
    [unfs, dns, fsevents].each do |daemon|
      if !daemon.running?
        puts "\n\e[33m#{daemon.name} failed to run\e[0m"
        puts "details available in log file: #{daemon.logfile}"
      end
    end
    puts
    CheckEnv.new(machine).run
  end

  desc "ip", "get the VM's IP address"
  def ip
    vm_must_exist!
    if machine.running?
      puts machine.vm_ip
    else
      $stderr.puts "The VM is not running, `dinghy up` to start"
      exit 1
    end
  end

  desc "halt", "stop the VM and services"
  def halt
    vm_must_exist!
    fsevents.halt
    puts "Stopping the #{machine.name} VM..."
    machine.halt
    unfs.halt
    dns.halt
  end

  map "down" => :halt
  map "stop" => :halt

  desc "restart", "restart the VM and services"
  def restart
    halt
    up
  end

  option :force,
    type: :boolean,
    aliases: :f,
    desc: "destroy without confirmation"
  desc "destroy", "stop and delete all traces of the VM"
  def destroy
    halt
    machine.destroy(force: options[:force])
  end

  desc "upgrade", "upgrade the boot2docker VM to the newest available"
  def upgrade
    vm_must_exist!
    machine.upgrade
    # restart to re-enable the http proxy, etc
    restart
  end

  desc "shellinit", "returns env variables to set, should be run like $(dinghy shellinit)"
  def shellinit
    vm_must_exist!
    CheckEnv.new(machine).print
  end

  map "env" => :shellinit

  map "-v" => :version
  desc "version", "display dinghy version"
  def version
    puts "Dinghy #{DINGHY_VERSION}"
  end

  no_commands {
    # this command is only used internally, when we sudo to start the nfs daemon
    def nfs(cmd, port, host_ip)
      if Process.uid != 0
        $stderr.puts "nfs command must be run as root"
        return
      end

      unfs.port = port.to_i
      unfs.host_ip = host_ip
      case cmd
      when "start"
        unfs.up
      when "stop"
        unfs.halt
      else
        $stderr.puts "unknown nfs subcommand: #{cmd}"
      end
    end
  }

  private

  def vm_must_exist!
    if !machine.created?
      $stderr.puts "The VM '#{machine.name}' does not exist in docker-machine."
      $stderr.puts "Run `dinghy create` to create the VM, `dinghy help create` to see available options."
      exit(1)
    end
  end

  def preferences
    @preferences ||= Preferences.load
  end

  def proxy_disabled?
    preferences[:proxy_disabled] == true
  end

  def fsevents_disabled?
    preferences[:fsevents_disabled] == true
  end

  def machine
    @machine ||= Machine.new(preferences[:machine_name])
  end

  def unfs
    @unfs ||= Unfs.new(machine)
  end

  def dns
    @dns ||= Dnsmasq.new(machine, preferences[:dinghy_domain])
  end

  def http_proxy
    @http_proxy ||= HttpProxy.new(machine, dns.dinghy_domain)
  end

  def fsevents
    FseventsToVm.new(machine)
  end

  def start_services
    machine.up
    unfs.up
    if unfs.wait_for_unfs
      machine.mount(unfs)
    else
      puts "NFS mounting failed"
    end
    use_fsevents = options[:fsevents] || (options[:fsevents].nil? && !fsevents_disabled?)
    if use_fsevents
      fsevents.up
    end
    dns.up
    proxy = options[:proxy] || (options[:proxy].nil? && !proxy_disabled?)
    if proxy
      # this is hokey, but it can take a few seconds for docker daemon to be available
      # TODO: poll in a loop until the docker daemon responds
      sleep 5
      http_proxy.up
    end

    preferences.update(
      proxy_disabled: !proxy,
      fsevents_disabled: !fsevents,
    )

    status
  end
end

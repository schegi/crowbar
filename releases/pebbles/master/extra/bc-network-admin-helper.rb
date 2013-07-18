#!/usr/bin/ruby

require 'rubygems'
require 'getoptlong'
require 'ipaddr'
require 'json'

REQUIRED_NETWORKS = {
  'admin' => ['admin', 'dhcp', 'host', 'switch'],
  'bmc' => ['host'],
  'bmc_vlan' => ['host'],
  'nova_fixed' => ['dhcp', 'router'],
  'nova_floating' => ['host'],
  'os_sdn' => ['host'],
  'public' => ['dhcp', 'host'],
  'storage' => ['host']
}

@options = [
    [ [ '--help', '-h', GetoptLong::NO_ARGUMENT ], "--help or -h - help" ],
    [ [ '--admin-ip', GetoptLong::REQUIRED_ARGUMENT ], "--admin-ip <ip> - IP address of the Administration Server" ],
]

@admin_ip = nil
@networks = {}


### Helpers

def usage (rc)
  puts "Usage: bc-network-admin-helper --admin-ip=IP filename"
  @options.each do |options|
    puts "  #{options[1]}"
  end
  exit rc
end

def opt_parse()
  sub_options = @options.map { |x| x[0] }
  opts = GetoptLong.new(*sub_options)

  opts.each do |opt, arg|
    case opt
      when '--help'
        usage 0
      when '--admin-ip'
        if @admin_ip.nil?
          @admin_ip = arg
        else
          usage -1
        end
      else
        usage -1
    end
  end

  if ARGV.length > 1
    usage -1
  end
end


### Classes

class CrowbarNetworkRange
  attr_reader :name
  attr_reader :start
  attr_reader :end
  attr_reader :start_addr
  attr_reader :end_addr

  def initialize name, json
    @name = name

    if not json.is_a?(Hash)
      raise "range '#{@name}' is not a hash"
    end

    @start = json['start']
    @end = json['end']

    @start_addr = IPAddr.new(@start)
    @end_addr = IPAddr.new(@end)
  end

  def validate
    if @start_addr > @end_addr
      raise "start of range '#{@name}' ('#{@range_start}') is greater than its end ('#{@range_end}')"
    end
  end
end

class CrowbarNetwork
  attr_reader :name
  attr_reader :subnet_addr
  attr_reader :broadcast_addr
  attr_reader :subnet_addr_full
  attr_reader :ranges

  def initialize name, json
    @name = name

    if not json.is_a?(Hash)
      raise "definition is not a hash"
    end

    if !json.has_key?('ranges') || !json['ranges'].is_a?(Hash) || json['ranges'].length == 0
      raise "no valid range defined"
    end

    @subnet = json['subnet']
    @netmask = json['netmask']
    @broadcast = json['broadcast']
    @router = json['router']

    @subnet_addr = IPAddr.new(@subnet)
    @netmask_addr = IPAddr.new(@netmask)
    @broadcast_addr = IPAddr.new(@broadcast)
    @router_addr = nil
    @router_addr = IPAddr.new(@router) unless @router.nil?

    @subnet_addr_full = IPAddr.new("#{@subnet}/#{@netmask}")

    @ranges = {}

    json['ranges'].each do |range_name, range_value|
      @ranges[range_name] = CrowbarNetworkRange.new(range_name, range_value)
    end
  end

  def validate
    netmask_bits = @netmask_addr.to_i.to_s(2).count("1")

    sub = IPAddr.new("#{@subnet}/#{@netmask_bits}")
    if sub != @subnet_addr_full
      raise "invalid netmask '#{@netmask}'"
    end

    if @subnet_addr != @subnet_addr&@netmask_addr
      raise "invalid subnet '#{@subnet}' for netmask '#{@netmask}'"
    end

    if @broadcast_addr != @subnet_addr|~@netmask_addr
      raise "invalid broadcast '#{@broadcast}' for subnet '#{@subnet}/#{@netmask}' (should be '#{(@subnet_addr|~@netmask_addr).to_s}')"
    end

    unless @router.nil?
      if not @subnet_addr_full.include?(@router_addr)
        raise "invalid router '#{@router}' for subnet '#{@subnet}/#{@netmask}'"
      end
    end

    @ranges.each_value do |range|
      range.validate

      if not @subnet_addr_full.include?(range.start_addr)
        return "start of range '#{range.name}' ('#{range.start}') is not part of subnet '#{@subnet}/#{@netmask}'"
      end
      if not @subnet_addr_full.include?(range.end_addr)
        return "end of range '#{range.name}' ('#{range.end}') is not part of subnet '#{@subnet}/#{@netmask}'"
      end
    end

    ranges_array = @ranges.values.sort { |a,b| [a.start_addr, a.end_addr, a.name] <=> [b.start_addr, b.end_addr, b.name] }
    for i in 0..ranges_array.length-2 do
      if ranges_array[i].end_addr >= ranges_array[i+1].start_addr
        raise "ranges '#{ranges_array[i].name}' and '#{ranges_array[i+1].name}' are conflicting"
      end
    end
  end
end


### Validation functions

def validate_structure databag
  if not databag.has_key?('attributes')
    raise "Invalid network JSON: missing attribute: attributes"
  end

  if not databag['attributes'].has_key?('network')
    raise "Invalid network JSON: missing attribute: attributes.network"
  end

  if not databag['attributes']['network'].has_key?('teaming')
    raise "Invalid network JSON: missing attribute: attributes.network.teaming"
  end

  if not databag['attributes']['network'].has_key?('conduit_map')
    raise "Invalid network JSON: missing attribute: attributes.network.conduit_map"
  end

  if not databag['attributes']['network'].has_key?('networks')
    raise "Invalid network JSON: missing attribute: attributes.network.networks"
  end
end


def validate_basic_attributes databag
  mode = databag['attributes']['network']['mode']
  if not ['single', 'dual', 'team'].include?(mode)
    raise "Invalid mode '#{mode}': must be one of 'single', 'dual', 'team'"
  end

  teaming_mode = databag['attributes']['network']['teaming']['mode']
  if not Range.new(0, 6).include?(teaming_mode)
    raise "Invalid teaming mode '#{teaming_mode}': must be a value between 0 and 6, see https://www.kernel.org/doc/Documentation/networking/bonding.txt"
  end
end


def no_conflicting_ranges(neta, netb)
  error = false
  neta.ranges.each do |namea, rangea|
    netb.ranges.each do |nameb, rangeb|
      if neta.subnet_addr >= rangeb.start_addr && neta.subnet_addr <= rangeb.end_addr
        error = true
      elsif neta.broadcast_addr >= rangeb.start_addr && neta.broadcast_addr <= rangeb.end_addr
        error = true
      end
      raise "Network '#{neta.name}' and range '#{nameb}' from network '#{netb.name}' are conflicting" if error

      if rangea.start_addr >= rangeb.start_addr && rangea.start_addr <= rangeb.end_addr
        error = true
      elsif rangea.end_addr >= rangeb.start_addr && rangea.end_addr <= rangeb.end_addr
        error = true
      end
      raise "Range '#{namea}' from network '#{neta.name}' and range '#{nameb}' from network '#{netb.name}' are conflicting" if error
    end
  end
end


def validate_networks databag
  networks = databag['attributes']['network']['networks']

  REQUIRED_NETWORKS.each do |name, ranges|
    if not networks.has_key?(name)
      raise "Missing definition of network '#{name}'"
    end

    ranges.each do |range|
      if not networks[name]['ranges'].has_key?(range)
        raise "Missing range '#{range}' in definition of network '#{name}'"
      end
    end
  end

  networks.each do |name, value|
    begin
      net = CrowbarNetwork.new(name, value)
      net.validate
      @networks[name] = net
    rescue Exception => e
      raise "Cannot validate definition for network '#{name}': #{e.to_s}"
    end
  end

  if not @networks['public'].subnet_addr_full.include?(@networks['nova_floating'].subnet_addr_full)
    raise "'nova_floating' network must be a subnetwork of 'public' network"
  end

  if not @networks['admin'].subnet_addr_full.include?(@networks['bmc'].subnet_addr_full)
    raise "'bmc' network must be a subnetwork of 'admin' network"
  end

  if not @networks['admin'].subnet_addr_full.include?(@networks['bmc_vlan'].subnet_addr_full)
    raise "'bmc_vlan' network must be a subnetwork of 'admin' network"
  end

  @networks.each do |namea, neta|
    @networks.each do |nameb, netb|
      unless namea == nameb
        no_conflicting_ranges(neta, netb)
      end
    end
  end
end


def validate_admin_ip
  admin_range = @networks['admin'].ranges['admin']

  if @admin_ip_addr < admin_range.start_addr || @admin_ip_addr > admin_range.end_addr
    raise "IP #{@admin_ip} of Administration Server is not in admin range (#{admin_range.start} to #{admin_range.end})"
  end
end


### Main

opt_parse

if ARGV.length != 1
  usage -1
end

if @admin_ip.nil?
  usage -1
end

@admin_ip_addr = IPAddr.new(@admin_ip)

filename = File.expand_path(ARGV[0])
unless File.exists?(filename)
  puts "File #{filename} does not exist."
  exit 1
end

begin
  databag = JSON.load(File.open(filename).read())
rescue Exception => e
  puts "File #{filename} is not a valid JSON file: #{e.to_s}"
  exit 1
end


begin
  validate_structure(databag)
  validate_basic_attributes(databag)
  validate_networks(databag)
  validate_admin_ip
rescue Exception => e
  puts e.to_s
  exit 1
end

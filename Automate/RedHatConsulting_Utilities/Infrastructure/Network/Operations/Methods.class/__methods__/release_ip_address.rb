# Attempts to retire an IP address by using the DDI provider for the network of the provided VM.
#
# @set retired_ip_address String IP address retired from the DDI provider for the network of the provided VM.
#
@DEBUG = false

DDI_PROVIDERS_URI = 'Infrastructure/Network/DDIProviders'.freeze

def dump_object(object_string, object)
  $evm.log("info", "Listing #{object_string} Attributes:") 
  object.attributes.sort.each { |k, v| $evm.log("info", "\t#{k}: #{v}") }
  $evm.log("info", "===========================================") 
end

def dump_current
  $evm.log("info", "Listing Current Object Attributes:") 
  $evm.current.attributes.sort.each { |k, v| $evm.log("info", "\t#{k}: #{v}") }
  $evm.log("info", "===========================================") 
end

def dump_root
  $evm.log("info", "Listing Root Object Attributes:") 
  $evm.root.attributes.sort.each { |k, v| $evm.log("info", "\t#{k}: #{v}") }
  $evm.log("info", "===========================================") 
end

# Log an error and exit.
#
# @param msg Message to error with
def error(msg)
  $evm.log(:error, msg)
  $evm.root['ae_result'] = 'error'
  $evm.root['ae_reason'] = msg.to_s
  exit MIQ_STOP
end

# There are many ways to attempt to pass parameters in Automate.
# This function checks all of them in priorty order as well as checking for symbol or string.
#
# Order:
#   1. Inputs
#   2. Current
#   3. Object
#   4. Root
#   5. State
#
# @return Value for the given parameter or nil if none is found
def get_param(param)  
  # check if inputs has been set for given param
  param_value ||= $evm.inputs[param.to_sym]
  param_value ||= $evm.inputs[param.to_s]
  
  # else check if current has been set for given param
  param_value ||= $evm.current[param.to_sym]
  param_value ||= $evm.current[param.to_s]
 
  # else cehck if current has been set for given param
  param_value ||= $evm.object[param.to_sym]
  param_value ||= $evm.object[param.to_s]
  
  # else check if param on root has been set for given param
  param_value ||= $evm.root[param.to_sym]
  param_value ||= $evm.root[param.to_s]
  
  # check if state has been set for given param
  param_value ||= $evm.get_state_var(param.to_sym)
  param_value ||= $evm.get_state_var(param.to_s)

  $evm.log(:info, "{ '#{param}' => '#{param_value}' }") if @DEBUG
  return param_value
end

# Function for getting the current VM and associated options based on the vmdb_object_type.
#
# Supported vmdb_object_types
#   * miq_provision
#   * vm
#   * automation_task
#
# @return vm,options
def get_vm_and_options()
  $evm.log(:info, "$evm.root['vmdb_object_type'] => '#{$evm.root['vmdb_object_type']}'.")
  case $evm.root['vmdb_object_type']
    when 'miq_provision'
      # get root object
      $evm.log(:info, "Get VM and dialog attributes from $evm.root['miq_provision']") if @DEBUG
      miq_provision = $evm.root['miq_provision']
      dump_object('miq_provision', miq_provision) if @DEBUG
      
      # get VM
      vm = miq_provision.vm
    
      # get options
      options = miq_provision.options
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'vm'
      # get root objet & VM
      $evm.log(:info, "Get VM from paramater and dialog attributes form $evm.root") if @DEBUG
      vm = get_param(:vm)
      dump_object('vm', vm) if @DEBUG
    
      # get options
      options = $evm.root.attributes
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    when 'automation_task'
      # get root objet
      $evm.log(:info, "Get VM from paramater and dialog attributes form $evm.root") if @DEBUG
      automation_task = $evm.root['automation_task']
      dump_object('automation_task', automation_task) if @DEBUG
      
      # get VM
      vm  = get_param(:vm)
      
      # get options
      options = get_param(:options)
      options = JSON.load(options)     if options && options.class == String
      options = options.symbolize_keys if options
      #merge the ws_values, dialog, top level options into one list to make it easier to search
      options = options.merge(options[:ws_values]) if options[:ws_values]
      options = options.merge(options[:dialog])    if options[:dialog]
    else
      error("Can not handle vmdb_object_type: #{$evm.root['vmdb_object_type']}")
  end
  
  # standerdize the option keys
  options = options.symbolize_keys()
  
  return vm,options
end

# Get the network configuration for a given network
#
# @param network_name Name of the network to get the configuraiton for
# @return Hash Configuration information about the given network
#                network_purpose
#                network_address_space
#                network_gateway
#                network_nameservers
#                network_ddi_provider
@network_configurations         = {}
@missing_network_configurations = {}
NETWORK_CONFIGURATION_URI       = 'Infrastructure/Network/Configuration'.freeze
def get_network_configuration(network_name)
  if @network_configurations[network_name].blank? && @missing_network_configurations[network_name].blank?
    begin
      @network_configurations[network_name] = $evm.instantiate("#{NETWORK_CONFIGURATION_URI}/#{network_name}")
    rescue => e
      @missing_network_configurations[network_name] = "WARN: No network configuration exists"
      $evm.log(:warn, "No network configuration for Network <#{network_name}> exists")
    end
  end
  return @network_configurations[network_name]
end

begin
  vm,options = get_vm_and_options()
  
  # NOTE: this is hard coded to the first network interface because can't
  #       decide how to determine which network interfaces to release the IPs for...
  #
  # TODO: don't hard code this to first interface
  network_name          = vm.hardware.networks[0].guest_device.lan.name
  network_configuration = get_network_configuration(network_name)
  $evm.log(:info, "network_name          => #{network_name}")          if @DEBUG
  $evm.log(:info, "network_configuration => #{network_configuration}") if @DEBUG

  # determine the DDI provider
  ddi_provider = network_configuration['network_ddi_provider']
  $evm.log(:info, "ddi_provider => #{ddi_provider}") if @DEBUG
  
  if !ddi_provider.blank?
    # instantiate instance to aquire IP
    begin
      $evm.log(:info, "Release IP address using DDI Provider <#{ddi_provider}>") if @DEBUG
    
      $evm.root['network_name'] = network_name
      $evm.instantiate("#{DDI_PROVIDERS_URI}/#{ddi_provider}#release_ip_address")
      released_ip_address = get_param(:released_ip_address)
    
      $evm.log(:info, "Released IP address <#{released_ip_address}> using DDI Provider <#{ddi_provider}>") if @DEBUG
    ensure
      success = $evm.root['ae_result'] == nil || $evm.root['ae_result'] == 'ok'
      reason  = $evm.root['ae_reason'] if !success
    
      # clean up root
      $evm.root['ae_result'] = nil
      $evm.root['ae_reason'] = nil
      
      # clean up after call
      $evm.root['network_name']       = nil
      $evm.root['released_ip_address'] = nil
      
      $evm.root['ae_reason'] = "Released IP address <#{released_ip_address}>"
    end
  else
    $evm.root['ae_reason'] = "Can not retire IP for VM <#{vm.name}>, no DDI Provider found for Network <#{network_name}>."
    $evm.root['ae_level']  = :warning
  end
  
  # set the aquired IP
  $evm.object['released_ip_address'] = released_ip_address
  $evm.root['ae_result'] = 'ok'
end

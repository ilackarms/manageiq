class ExtManagementSystem < ApplicationRecord
  def self.types
    leaf_subclasses.collect(&:ems_type)
  end

  def self.supported_types
    supported_subclasses.collect(&:ems_type)
  end

  def self.leaf_subclasses
    descendants.select { |d| d.subclasses.empty? }
  end

  def self.supported_subclasses
    subclasses.flat_map do |s|
      s.subclasses.empty? ? s : s.supported_subclasses
    end
  end

  def self.supported_types_and_descriptions_hash
    supported_subclasses.each_with_object({}) do |klass, hash|
      if Vmdb::PermissionStores.instance.supported_ems_type?(klass.ems_type)
        hash[klass.ems_type] = klass.description
      end
    end
  end

  belongs_to :provider
  include CustomAttributeMixin
  belongs_to :tenant
  has_many :container_deployments, :foreign_key => :deployed_on_ems_id, :inverse_of => :deployed_on_ems
  has_many :endpoints, :as => :resource, :dependent => :destroy, :autosave => true

  has_many :hosts, :foreign_key => "ems_id", :dependent => :nullify, :inverse_of => :ext_management_system
  has_many :non_clustered_hosts, -> { non_clustered }, :class_name => "Host", :foreign_key => "ems_id"
  has_many :clustered_hosts, -> { clustered }, :class_name => "Host", :foreign_key => "ems_id"
  has_many :vms_and_templates, :foreign_key => "ems_id", :dependent => :nullify,
           :class_name => "VmOrTemplate", :inverse_of => :ext_management_system
  has_many :miq_templates,     :foreign_key => :ems_id, :inverse_of => :ext_management_system
  has_many :vms,               :foreign_key => :ems_id, :inverse_of => :ext_management_system
  has_many :hardwares,         :through => :vms_and_templates
  has_many :networks,          :through => :hardwares
  has_many :disks,             :through => :hardwares

  has_many :storages,       -> { distinct },          :through => :hosts
  has_many :ems_events,     -> { order "timestamp" }, :class_name => "EmsEvent",    :foreign_key => "ems_id",
                                                      :inverse_of => :ext_management_system
  has_many :generated_events, -> { order "timestamp" }, :class_name => "EmsEvent", :foreign_key => "generating_ems_id",
                                                          :inverse_of => :generating_ems
  has_many :policy_events,  -> { order "timestamp" }, :class_name => "PolicyEvent", :foreign_key => "ems_id"

  has_many :blacklisted_events, :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system
  has_many :miq_alert_statuses, :foreign_key => "ems_id"
  has_many :ems_folders,    :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system
  has_many :ems_clusters,   :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system
  has_many :resource_pools, :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system
  has_many :customization_specs, :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system
  has_many :storage_profiles,    :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system
  has_many :physical_servers,    :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system

  has_one  :iso_datastore, :foreign_key => "ems_id", :dependent => :destroy, :inverse_of => :ext_management_system

  belongs_to :zone

  has_many :metrics,        :as => :resource  # Destroy will be handled by purger
  has_many :metric_rollups, :as => :resource  # Destroy will be handled by purger
  has_many :vim_performance_states, :as => :resource # Destroy will be handled by purger
  has_many :miq_events,             :as => :target, :dependent => :destroy
  has_many :cloud_subnets, :foreign_key => :ems_id, :dependent => :destroy

  validates :name,     :presence => true, :uniqueness => {:scope => [:tenant_id]}
  validates :hostname, :presence => true, :if => :hostname_required?
  validate :hostname_uniqueness_valid?, :if => :hostname_required?

  serialize :options

  def hostname_uniqueness_valid?
    return unless hostname_required?
    return unless hostname.present? # Presence is checked elsewhere
    # check uniqueness per provider type

    existing_hostnames = (self.class.all - [self]).map(&:hostname).compact.map(&:downcase)

    errors.add(:hostname, N_("has to be unique per provider type")) if existing_hostnames.include?(hostname.downcase)
  end

  include NewWithTypeStiMixin
  include UuidMixin
  include EmsRefresh::Manager
  include TenancyMixin
  include AvailabilityMixin
  include SupportsFeatureMixin
  include ComplianceMixin
  include CustomAttributeMixin

  after_destroy { |record| $log.info "MIQ(ExtManagementSystem.after_destroy) Removed EMS [#{record.name}] id [#{record.id}]" }

  acts_as_miq_taggable

  include FilterableMixin
  include EventMixin
  include MiqPolicyMixin
  include RelationshipMixin
  self.default_relationship_type = "ems_metadata"

  include AggregationMixin

  include AuthenticationMixin
  include Metric::CiMixin
  include AsyncDeleteMixin

  delegate :ipaddress,
           :ipaddress=,
           :hostname,
           :hostname=,
           :port,
           :port=,
           :security_protocol,
           :security_protocol=,
           :certificate_authority,
           :certificate_authority=,
           :to => :default_endpoint,
           :allow_nil => true

  alias_method :address, :hostname # TODO: Remove all callers of address

  virtual_column :ipaddress,               :type => :string,  :uses => :endpoints
  virtual_column :hostname,                :type => :string,  :uses => :endpoints
  virtual_column :port,                    :type => :integer, :uses => :endpoints
  virtual_column :security_protocol,       :type => :string,  :uses => :endpoints

  virtual_column :emstype,                 :type => :string
  virtual_column :emstype_description,     :type => :string
  virtual_column :last_refresh_status,     :type => :string
  virtual_total  :total_vms_and_templates, :vms_and_templates
  virtual_total  :total_vms,               :vms
  virtual_total  :total_miq_templates,     :miq_templates
  virtual_total  :total_hosts,             :hosts
  virtual_total  :total_storages,          :storages
  virtual_total  :total_clusters,          :clusters
  virtual_column :zone_name,               :type => :string, :uses => :zone
  virtual_column :total_vms_on,            :type => :integer
  virtual_column :total_vms_off,           :type => :integer
  virtual_column :total_vms_unknown,       :type => :integer
  virtual_column :total_vms_never,         :type => :integer
  virtual_column :total_vms_suspended,     :type => :integer
  virtual_total  :total_subnets,           :cloud_subnets
  virtual_column :supports_block_storage,  :type => :boolean
  virtual_column :supports_cloud_object_store_container_create, :type => :boolean

  virtual_aggregate :total_vcpus, :hosts, :sum, :total_vcpus
  virtual_aggregate :total_memory, :hosts, :sum, :ram_size
  virtual_aggregate :total_cloud_vcpus, :vms, :sum, :cpu_total_cores
  virtual_aggregate :total_cloud_memory, :vms, :sum, :ram_size

  alias_method :clusters, :ems_clusters # Used by web-services to return clusters as the property name
  alias_attribute :to_s, :name

  default_value_for :enabled, true

  def self.with_ipaddress(ipaddress)
    joins(:endpoints).where(:endpoints => {:ipaddress => ipaddress})
  end

  def self.with_hostname(hostname)
    joins(:endpoints).where(:endpoints => {:hostname => hostname})
  end

  def self.with_role(role)
    joins(:endpoints).where(:endpoints => {:role => role})
  end

  def self.with_port(port)
    joins(:endpoints).where(:endpoints => {:port => port})
  end

  def self.create_discovered_ems(ost)
    ip = ost.ipaddr
    unless with_ipaddress(ip).exists?
      hostname = Socket.getaddrinfo(ip, nil)[0][2]

      ems_klass, ems_name = if ost.hypervisor.include?(:scvmm)
                              [ManageIQ::Providers::Microsoft::InfraManager, 'SCVMM']
                            elsif ost.hypervisor.include?(:rhevm)
                              [ManageIQ::Providers::Redhat::InfraManager, 'RHEV-M']
                            else
                              [ManageIQ::Providers::Vmware::InfraManager, 'Virtual Center']
                            end

      ems = ems_klass.create(
        :ipaddress => ip,
        :name      => "#{ems_name} (#{ip})",
        :hostname  => hostname,
        :zone_id   => MiqServer.my_server.zone.id
      )

      _log.info "#{ui_lookup(:table => "ext_management_systems")} #{ems.name} created"
      AuditEvent.success(
        :event        => "ems_created",
        :target_id    => ems.id,
        :target_class => "ExtManagementSystem",
        :message      => "%{provider_type} %{provider_name} created" % {
          :provider_type => Dictionary.gettext("ext_management_systems",
                                               :type      => :table,
                                               :notfound  => :titleize,
                                               :plural    => false,
                                               :translate => false),
          :provider_name => ems.name})
    end
  end

  def self.model_name_from_emstype(emstype)
    model_from_emstype(emstype).try(:name)
  end

  def self.model_from_emstype(emstype)
    emstype = emstype.downcase
    ExtManagementSystem.leaf_subclasses.detect { |k| k.ems_type == emstype }
  end

  def self.short_token
    if self == ManageIQ::Providers::BaseManager
      nil
    elsif parent == ManageIQ::Providers
      # "Infra"
      name.demodulize.sub(/Manager$/, '')
    elsif parent != Object
      # "Vmware"
      parent.name.demodulize
    end
  end

  def self.short_name
    if (t = short_token)
      "Ems#{t}"
    else
      name
    end
  end

  def self.base_manager
    (ancestors.select { |klass| klass < ::ExtManagementSystem } - [::ManageIQ::Providers::BaseManager]).last
  end

  def self.db_name
    base_manager.short_name
  end

  def self.provision_class(_via)
    self::Provision
  end

  def self.provision_workflow_class
    self::ProvisionWorkflow
  end

  # UI methods for determining availability of fields
  def supports_port?
    false
  end

  def supports_api_version?
    false
  end

  def supports_security_protocol?
    false
  end

  def supports_provider_id?
    false
  end

  def supports_authentication?(authtype)
    authtype.to_s == "default"
  end

  # UI method for determining which icon to show for a particular EMS
  def image_name
    emstype.downcase
  end

  def default_endpoint
    default = endpoints.detect { |e| e.role == "default" }
    default || endpoints.build(:role => "default")
  end

  # Takes multiple connection data
  # endpoints, and authentications
  def connection_configurations=(options)
    options.each do |option|
      add_connection_configuration_by_role(option)
    end

    delete_unused_connection_configurations(options)
  end

  def delete_unused_connection_configurations(options)
    chosen_endpoints = options.map { |x| x.deep_symbolize_keys.fetch_path(:endpoint, :role).try(:to_sym) }.compact.uniq
    existing_endpoints = endpoints.pluck(:role).map(&:to_sym)
    # Delete endpoint that were not picked
    roles_for_deletion = existing_endpoints - chosen_endpoints
    endpoints.select { |x| x.role && roles_for_deletion.include?(x.role.to_sym) }.each(&:mark_for_destruction)
    authentications.select { |x| x.authtype && roles_for_deletion.include?(x.authtype.to_sym) }.each(&:mark_for_destruction)
  end

  def connection_configurations
    roles = endpoints.map(&:role)
    options = {}

    roles.each do |role|
      conn = connection_configuration_by_role(role)
      options[role] = conn
    end

    connections = OpenStruct.new(options)
    connections.roles = roles
    connections
  end

  # Takes a hash of connection data
  # hostname, port, and authentication
  # if no role is passed in assume is default role
  def add_connection_configuration_by_role(connection)
    connection.deep_symbolize_keys!
    unless connection[:endpoint].key?(:role)
      connection[:endpoint][:role] ||= "default"
    end
    if connection[:authentication].blank?
      connection.delete(:authentication)
    else
      unless connection[:authentication].key?(:role)
        endpoint_role = connection[:endpoint][:role]
        authentication_role = endpoint_role == "default" ? default_authentication_type.to_s : endpoint_role
        connection[:authentication][:role] ||= authentication_role
      end
    end

    build_connection(connection)
  end

  def connection_configuration_by_role(role = "default")
    endpoint = endpoints.detect { |e| e.role == role }

    if endpoint
      authtype = endpoint.role == "default" ? default_authentication_type.to_s : endpoint.role
      auth = authentications.detect { |a| a.authtype == authtype }

      options = {:endpoint => endpoint, :authentication => auth}
      OpenStruct.new(options)
    end
  end

  def hostnames
    hostnames ||= endpoints.map(&:hostname)
    hostnames
  end

  def authentication_check_role
    'ems_operations'
  end

  def self.hostname_required?
    true
  end
  delegate :hostname_required?, :to => :class

  def my_zone
    zone.try(:name).presence || MiqServer.my_zone
  end
  alias_method :zone_name, :my_zone

  def emstype_description
    self.class.description || emstype.titleize
  end

  def with_provider_connection(options = {})
    raise _("no block given") unless block_given?
    _log.info("Connecting through #{self.class.name}: [#{name}]")
    yield connect(options)
  end

  def self.refresh_all_ems_timer
    ems_ids = where(:zone_id => MiqServer.my_server.zone.id).pluck(:id)
    refresh_ems(ems_ids, true) unless ems_ids.empty?
  end

  def self.refresh_ems(ems_ids, reload = false)
    ems_ids = [ems_ids] unless ems_ids.kind_of?(Array)

    ExtManagementSystem.where(:id => ems_ids).each { |ems| ems.reset_vim_cache_queue if ems.respond_to?(:reset_vim_cache_queue) } if reload

    ems_ids = ems_ids.collect { |id| [ExtManagementSystem, id] }
    EmsRefresh.queue_refresh(ems_ids)
  end

  def last_refresh_status
    if last_refresh_date
      last_refresh_error ? "error" : "success"
    else
      "never"
    end
  end

  def refresh_ems(opts = {})
    if missing_credentials?
      raise _("no %{table} credentials defined") % {:table => ui_lookup(:table => "ext_management_systems")}
    end
    unless authentication_status_ok?
      raise _("%{table} failed last authentication check") % {:table => ui_lookup(:table => "ext_management_systems")}
    end
    EmsRefresh.queue_refresh(self, nil, opts)
  end

  def self.ems_infra_discovery_types
    @ems_infra_discovery_types ||= %w(virtualcenter scvmm rhevm)
  end

  def self.ems_physical_infra_discovery_types
    @ems_physical_infra_discovery_types ||= %w(lenovo_ph_infra)
  end

  def disable!
    _log.info "Disabling EMS [#{name}] id [#{id}]."
    update!(:enabled => false)
  end

  def enable!
    _log.info "Enabling EMS [#{name}] id [#{id}]."
    update!(:enabled => true)
  end

  def self.destroy_queue(ids)
    ids = Array.wrap(ids)
    _log.info("Queuing destroy of #{name} with the following ids: #{ids.inspect}")
    ids.each do |id|
      schedule_destroy_queue(id)
    end
  end

  # override destroy_queue from AsyncDeleteMixin
  def destroy_queue
    self.class.schedule_destroy_queue(id)
  end

  def self.schedule_destroy_queue(id, deliver_on = nil)
    MiqQueue.put(
      :class_name  => name,
      :instance_id => id,
      :method_name => "orchestrate_destroy",
      :deliver_on  => deliver_on,
    )
  end

  # Wait until all associated workers are dead to destroy this ems
  def orchestrate_destroy
    disable! if enabled?

    if self.destroy == false
      _log.info("Cannot destroy #{self.class.name} with id: #{id}, workers still in progress. Requeuing destroy...")
      self.class.schedule_destroy_queue(id, 15.seconds.from_now)
    else
      _log.info("#{self.class.name} with id: #{id} destroyed")
    end
  end

  before_destroy :assert_no_queues_present

  def assert_no_queues_present
    throw(:abort) if MiqWorker.find_alive.where(:queue_name => queue_name).any?
  end

  def disconnect_inv
    hosts.each { |h| h.disconnect_ems(self) }
    vms.each   { |v| v.disconnect_ems(self) }

    ems_folders.destroy_all
    ems_clusters.destroy_all
    resource_pools.destroy_all
  end

  def queue_name
    "ems_#{id}"
  end

  def enforce_policy(target, event)
    inputs = {:ext_management_system => self}
    inputs[:vm]   = target if target.kind_of?(Vm)
    inputs[:host] = target if target.kind_of?(Host)
    MiqEvent.raise_evm_event(target, event, inputs)
  end

  alias_method :all_storages,           :storages
  alias_method :datastores,             :storages # Used by web-services to return datastores as the property name

  #
  # Relationship methods
  #

  # Folder relationship methods
  def ems_folder_root
    folders.first
  end

  def folders
    children(:of_type => 'EmsFolder').sort_by { |c| c.name.downcase }
  end

  alias_method :add_folder,    :set_child
  alias_method :remove_folder, :remove_child

  def remove_all_folders
    remove_all_children(:of_type => 'EmsFolder')
  end

  def get_folder_paths(folder = nil)
    exclude_root_folder = folder.nil?
    folder ||= ems_folder_root
    return [] if folder.nil?
    folder.child_folder_paths(
      :exclude_root_folder         => exclude_root_folder,
      :exclude_datacenters         => true,
      :exclude_non_display_folders => true
    )
  end

  def resource_pools_non_default
    if @association_cache.include?(:resource_pools)
      resource_pools.select { |r| !r.is_default }
    else
      resource_pools.where("is_default != ?", true).to_a
    end
  end

  def event_where_clause(assoc = :ems_events)
    ["#{events_table_name(assoc)}.ems_id = ?", id]
  end

  def vm_count_by_state(state)
    vms.inject(0) { |t, vm| vm.power_state == state ? t + 1 : t }
  end

  def total_vms_on;        vm_count_by_state("on");        end

  def total_vms_off;       vm_count_by_state("off");       end

  def total_vms_unknown;   vm_count_by_state("unknown");   end

  def total_vms_never;     vm_count_by_state("never");     end

  def total_vms_suspended; vm_count_by_state("suspended"); end

  def supports_block_storage
    supports_block_storage?
  end

  def supports_cloud_object_store_container_create
    supports_cloud_object_store_container_create?
  end

  def get_reserve(field)
    (hosts + ems_clusters).inject(0) { |v, obj| v + (obj.send(field) || 0) }
  end

  def cpu_reserve
    get_reserve(:cpu_reserve)
  end

  def memory_reserve
    get_reserve(:memory_reserve)
  end

  def vm_log_user_event(_vm, user_event)
    $log.info(user_event)
    $log.warn "User event logging is not available on [#{self.class.name}] Name:[#{name}]"
  end

  #
  # Metric methods
  #

  PERF_ROLLUP_CHILDREN = :hosts

  def perf_rollup_parents(interval_name = nil)
    [MiqRegion.my_region].compact unless interval_name == 'realtime'
  end

  def perf_capture_enabled?
    return @perf_capture_enabled unless @perf_capture_enabled.nil?
    @perf_capture_enabled = ems_clusters.any?(&:perf_capture_enabled?) || host.any?(&:perf_capture_enabled?)
  end
  alias_method :perf_capture_enabled, :perf_capture_enabled?
  Vmdb::Deprecation.deprecate_methods(self, :perf_capture_enabled => :perf_capture_enabled?)

  ###################################
  # Event Monitor
  ###################################

  def after_update_authentication
    stop_event_monitor_queue_on_credential_change
  end

  def self.event_monitor_class
    nil
  end
  delegate :event_monitor_class, :to => :class

  def event_monitor
    return if event_monitor_class.nil?
    event_monitor_class.find_by_ems(self).first
  end

  def start_event_monitor
    return if event_monitor_class.nil?
    event_monitor_class.start_worker_for_ems(self)
  end

  def stop_event_monitor
    return if event_monitor_class.nil?
    _log.info "EMS [#{name}] id [#{id}]: Stopping event monitor."
    event_monitor_class.stop_worker_for_ems(self)
  end

  def stop_event_monitor_queue
    MiqQueue.put_unless_exists(
      :class_name  => self.class.name,
      :method_name => "stop_event_monitor",
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :zone        => my_zone,
      :role        => "event"
    )
  end

  def stop_event_monitor_queue_on_change
    if event_monitor_class && !self.new_record? && default_endpoint.changed.include_any?("hostname", "ipaddress")
      _log.info("EMS: [#{name}], Hostname or IP address has changed, stopping Event Monitor.  It will be restarted by the WorkerMonitor.")
      stop_event_monitor_queue
    end
  end

  def stop_event_monitor_queue_on_credential_change
    if event_monitor_class && !self.new_record? && self.credentials_changed?
      _log.info("EMS: [#{name}], Credentials have changed, stopping Event Monitor.  It will be restarted by the WorkerMonitor.")
      stop_event_monitor_queue
    end
  end

  def blacklisted_event_names
    (
      self.class.blacklisted_events.where(:enabled => true).pluck(:event_name) +
      blacklisted_events.where(:enabled => true).pluck(:event_name)
    ).uniq.sort
  end

  def self.blacklisted_events
    BlacklistedEvent.where(:provider_model => name, :ems_id => nil)
  end

  # @return [Boolean] true if a datastore exists for this type of ems
  def self.datastore?
    IsoDatastore.where(:ems_id => all).exists?
  end

  def tenant_identity
    User.super_admin.tap { |u| u.current_group = tenant.default_miq_group }
  end

  private

  def build_connection(options = {})
    build_endpoint_by_role(options[:endpoint])
    build_authentication_by_role(options[:authentication])
  end

  def build_endpoint_by_role(options)
    return if options.blank?
    endpoint = endpoints.detect { |e| e.role == options[:role].to_s }
    if endpoint
      endpoint.assign_attributes(options)
    else
      endpoints.build(options)
    end
  end

  def build_authentication_by_role(options)
    return if options.blank?
    role = options.delete(:role)
    creds = {}
    creds[role] = options
    update_authentication(creds,options)
  end

  def clear_association_cache
    @storages = nil
    super
  end
end

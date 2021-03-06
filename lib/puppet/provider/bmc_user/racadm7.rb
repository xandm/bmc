require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'racadm', 'racadm.rb'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'bmc.rb'))
require 'digest'

Puppet::Type.type(:bmc_user).provide(:racadm7) do
  desc 'Manage local users via racadm7.'

  has_feature :racadm

  mk_resource_methods

  confine osfamily: [:redhat, :debian]
  confine exists: '/opt/dell/srvadmin/bin/idracadm7'

  def self.prefetch(resources)
    resources.each_value do |type|
      call_info = {
        bmc_username: type.value(:bmc_username),
        bmc_password: type.value(:bmc_password),
        bmc_server_host: type.value(:bmc_server_host),
      }
      # the getconfig method is deprecated but have not been able to figure out how the alternative "get Idrac.Users"
      # support search by username
      racadm_out = Racadm.racadm_call(
        call_info,
        ['getconfig', '-u', "'#{type.name}'"],
        true,
      )
      getconfig_user = Racadm.parse_racadm racadm_out
      if getconfig_user.empty?
        type.provider = new(
          ensure: :absent,
          name: type.name,
        )
      else
        racadm_out = Racadm.racadm_call(
          call_info,
          ['get', "iDRAC.Users.#{getconfig_user['#cfgUserAdminIndex']}"],
        )
        idrac_user = Racadm.parse_racadm racadm_out
        type.provider = new(
          id: getconfig_user['#cfgUserAdminIndex'],
          ensure: :present,
          enable: Bmc.boolean_to_symbol(Racadm.s_to_bool(idrac_user['Enable'])),
          privilege:
            {
              'Lan' => Racadm.s_to_role(idrac_user['IpmiLanPrivilege']),
              'Serial' => Racadm.s_to_role(idrac_user['IpmiSerialPrivilege']),
            },
          idrac: idrac_user['Privilege'].to_i(16),
          md5v3key: idrac_user['MD5v3Key'],
          password_sha256: idrac_user['SHA256Password'],
          password_salt: idrac_user['SHA256PasswordSalt'],
          snmpv3_authentication_type: ['SNMPv3AuthenticationType'],
          snmpv3_enable: Bmc.boolean_to_symbol(Racadm.s_to_bool(idrac_user['SNMPv3Enable'])),
          snmpv3_privacy_type: ['SNMPv3PrivacyType'],
          sol_enable: Bmc.boolean_to_symbol(Racadm.s_to_bool(idrac_user['SolEnable'])),
          name: idrac_user['UserName'],
        )
      end
    end
  end

  def privilege
    if @resource[:privilege].class == Hash
      @property_hash[:privilege]
    elsif @property_hash[:privilege].values.select! { |value| value == @resource[:privilege] }.nil?
      @resource[:privilege]
    else
      @property_hash[:privilege]
    end
  end

  def privilege=(value)
    if value.class == Hash && value.key?('Lan')
      Racadm.racadm_call(
        @resource,
        ['set', "iDRAC.Users.#{@property_hash[:id]}.IpmiLanPrivilege", Racadm.role_to_s(value['Lan'])],
      )
    elsif Racadm.role_to_s(value)
      Racadm.racadm_call(
        @resource,
        ['set', "iDRAC.Users.#{@property_hash[:id]}.IpmiLanPrivilege", Racadm.role_to_s(value)],
      )
    end
    if value.class == Hash && value.key?('Serial')
      Racadm.racadm_call(
        @resource,
        ['set', "iDRAC.Users.#{@property_hash[:id]}.IpmiSerialPrivilege", Racadm.role_to_s(value['Serial'])],
      )
    elsif Racadm.role_to_s(value)
      Racadm.racadm_call(
        @resource,
        ['set', "iDRAC.Users.#{@property_hash[:id]}.IpmiSerialPrivilege", Racadm.role_to_s(value)],
      )
    end
  end

  def password
    newpass = Digest::SHA256.hexdigest(
      @resource[:password] +
      @property_hash[:password_salt].gsub(%r{..}) { |pair| pair.hex.chr },
    ).upcase
    @resource[:password] if newpass.eql? @property_hash[:password_sha256]
  end

  def password=(value)
    Racadm.racadm_call(
      @resource, ['set', "iDRAC.Users.#{@property_hash[:id]}.Password", value]
    )
  end

  def idrac=(value)
    Racadm.racadm_call(
      @resource, ['set', "iDRAC.Users.#{@property_hash[:id]}.Privilege", "0x#{value.to_s(16)}"]
    )
  end

  def enable=(value)
    Racadm.racadm_call(
      @resource, ['set', "iDRAC.Users.#{@property_hash[:id]}.enable", Racadm.bool_to_s(value)]
    )
  end

  def username=(value)
    Racadm.racadm_call(
      @resource, ['set', "iDRAC.Users.#{@property_hash[:id]}.UserName", value]
    )
  end

  def sol_enable=(value)
    Racadm.racadm_call(
      @resource, ['set', "iDRAC.Users.#{@property_hash[:id]}.SolEnable", Racadm.bool_to_s(value)]
    )
  end

  def next_free_id
    racadm_out = Racadm.racadm_call(
      @resource,
      ['get', 'iDRAC.Users'],
    )
    idrac_users = Racadm.parse_racadm racadm_out
    idrac_users.each_key do |key|
      # ship user because it is readonly anonymous
      next if 'iDRAC.Users.1'.eql?(key)
      racadm_out = Racadm.racadm_call(@resource, ['get', key])
      idrac_user = Racadm.parse_racadm racadm_out
      if idrac_user['UserName'].empty?
        return key.split('.').last
      end
    end
    raise Puppet::Error, 'There are no free userids to assign to a new user'
  end

  def create
    @property_hash[:ensure] = :present
    @property_hash[:id] = next_free_id
    self.username = @resource[:name] unless @resource[:name].nil?
    self.password = @resource[:password] unless @resource[:password].nil?
    self.idrac = @resource[:idrac] unless @resource[:idrac].nil?
    self.privilege = @resource[:privilege] unless @resource[:privilege].nil?
    self.sol_enable = true
    self.enable = true
  end

  def destroy
    self.enable = false
    self.sol_enable = false
    self.idrac = 0
    self.privilege = 'no_access'
    self.password = "''"
    self.username = "''"
  end

  def exists?
    @property_hash[:ensure] == :present
  end
end

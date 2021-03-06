require 'puppet/provider/package'

Puppet::Type.type(:package).provide(:brew, :parent => Puppet::Provider::Package) do
  desc 'Package management using HomeBrew on OSX'

  confine :operatingsystem => :darwin

  has_feature :installable
  has_feature :uninstallable
  has_feature :upgradeable
  has_feature :versionable

  has_feature :install_options

  commands :brew => '/usr/local/bin/brew'
  commands :stat => '/usr/bin/stat'

  def self.execute(cmd, failonfail = false, combine = false)
    owner = stat('-nf', '%Uu', '/usr/local/bin/brew').to_i
    group = stat('-nf', '%Ug', '/usr/local/bin/brew').to_i
    home  = Etc.getpwuid(owner).dir

    if owner == 0
      raise Puppet::ExecutionFailure, 'Homebrew does not support installations owned by the "root" user. Please check the permissions of /usr/local/bin/brew'
    end

    Dir.chdir('/'){super(cmd, :uid => owner, :gid => group, :combine => combine,
                         :custom_environment => { 'HOME' => home }, :failonfail => failonfail)}
  end

  def self.instances(justme = false)
    package_list.collect { |hash| new(hash) }
  end

  def execute(*args)
    # This does not return exit codes in puppet <3.4.0
    # See https://projects.puppetlabs.com/issues/2538
    self.class.execute(*args)
  end

  def fix_checksum(files)
    begin
      for file in files
        File.delete(file)
      end
    rescue Errno::ENOENT
      Puppet.warning "Could not remove mismatched checksum files #{files}"
    end

    raise Puppet::ExecutionFailure, "Checksum error for package #{name} in files #{files}"
  end

  def install_name
    resource_name = @resource[:name].downcase
    should = @resource[:ensure].downcase

    case should
    when true, false, Symbol
      resource_name
    else
      "#{resource_name}-#{should}"
    end
  end

  def install_options
    Array(resource[:install_options]).flatten.compact
  end

  def latest
    package = self.class.package_list(:justme => resource[:name].downcase)
    package[:ensure]
  end

  def query
    self.class.package_list(:justme => resource[:name].downcase)
  end

  def install
    resource_name = install_name

    begin
      Puppet.debug "Looking for #{resource_name} package..."
      execute([command(:brew), :info, resource_name], failonfail: true)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not find package: #{resource_name}"
    end

    begin
      Puppet.debug "Package found, installing..."
      output = execute([command(:brew), :install, resource_name, *install_options], failonfail: true)

      if output =~ /sha256 checksum/
        Puppet.debug "Fixing checksum error..."
        mismatched = output.match(/Already downloaded: (.*)/).captures
        fix_checksum(mismatched)
      end
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not install package: #{detail}"
    end
  end

  def uninstall
    resource_name = @resource[:name].downcase

    begin
      Puppet.debug "Uninstalling #{resource_name}"
      execute([command(:brew), :uninstall, resource_name], failonfail: true)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not uninstall package: #{detail}"
    end
  end

  def update
    resource_name = @resource[:name].downcase

    begin
      Puppet.debug "Upgrading #{resource_name}"
      execute([command(:brew), :upgrade, resource_name], failonfail: true)
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not upgrade package: #{detail}"
    end
  end

  def self.package_list(options={})
    Puppet.debug "Listing installed packages"
    begin
      if resource_name = options[:justme]
        result = execute([command(:brew), :list, '--versions', resource_name])
        if result.empty?
          Puppet.debug "Package #{resource_name} not installed"
        else
          Puppet.debug "Found package #{result}"
        end
      else
        result = execute([command(:brew), :list, '--versions'])
      end
      list = result.lines.map {|line| name_version_split(line)}
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not list packages: #{detail}"
    end

    if options[:justme]
      return list.shift
    else
      return list
    end
  end

  def self.name_version_split(line)
    if line =~ (/^(\S+)\s+(.+)/)
      {
        :name     => $1,
        :ensure   => $2,
        :provider => :brew
      }
    else
      Puppet.warning "Could not match #{line}"
      nil
    end
  end
end
